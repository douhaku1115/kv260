// -----------------------------------------------------------------------------
// main.c -- R5_1 (2 コア目) の Zephyr。Linux の remoteproc から起動され、RPMsg で話す
//
//   R5_0 (apps/rpmsg_r5) は音・CNN など PL を使う時間に正確な仕事、R5_1 は重い計算を受け持つ。
//   2 つのコアは独立しているので、R5_1 が 100% 計算していても R5_0 の音は乱れない (それを測る)。
//
//   窓口 (名前はどれも rpmsg-raw。番号は R5_0 と重ならないようにする。R5 側で使えるのは 0x400〜0x47F)
//     0x401  エコー: "R5_1: " を付けて送り返す (linux/rpmsg_rtt.py で往復を測る)
//     0x441  shell (prj.conf。linux/r5_shell.sh 1089 でつなぐ)
//     0x450  計算役: n 以下の素数を割り算で数え、かかった時間を返す (linux/r5_1_calc.py)
//     0x460  音の分業: 音を作ってリバーブを掛け、R5_0 と共有の輪バッファに書く (r51_audio.c)
//       依頼  u32 magic = 0x434C4143 ("CALC")  u32 seq  u32 n
//       返事  u32 magic = 0x524C4143 ("CALR")  u32 seq  u32 n  u32 count  u32 us
//
//   起動の流れ (platform_init / create_vdev) は apps/rpmsg_r5/src/main.c と同じ。違いは
//   共有メモリと IPI の番地 (rpmsg_r5_1.overlay) と、UART を使わないこと。
// -----------------------------------------------------------------------------
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/ipm.h>
#include <zephyr/shell/shell.h>
#include <zephyr/shell/shell_rpmsg.h>
#include <string.h>

#include <openamp/open_amp.h>
#include <metal/sys.h>
#include <metal/io.h>
#include <resource_table.h>
#include <addr_translation.h>

#include "r2r_shm.h"
#include "ipi_early_clear.h"

/* 前回の R5_1 が残した IPI の合図で起動が止まらないよう、割り込み解禁前に消す (ipi_early_clear.h) */
IPI_EARLY_CLEAR(DT_NODELABEL(rpu1_ipi));

void r51_audio_kick(void);                         /* r51_audio.c */
int r51_audio_init(struct rpmsg_device *rpdev);    /* r51_audio.c */

#define SHM_NODE       DT_CHOSEN(zephyr_ipc_shm)
#define SHM_START_ADDR DT_REG_ADDR(SHM_NODE)
#define SHM_SIZE       DT_REG_SIZE(SHM_NODE)

#define EPT_NAME  "rpmsg-raw"
#define ECHO_ADDR 0x401
#define CALC_ADDR 0x450

#define MAGIC_REQ 0x434C4143u   /* "CALC" */
#define MAGIC_RES 0x524C4143u   /* "CALR" */

static const struct device *const ipm = DEVICE_DT_GET(DT_CHOSEN(zephyr_ipc));

static metal_phys_addr_t shm_physmap = SHM_START_ADDR;
static metal_phys_addr_t rsc_tab_physmap;
static struct metal_io_region shm_io_data;
static struct metal_io_region rsc_io_data;
static struct rpmsg_virtio_device rvdev;
static void *rsc_table;

static struct rpmsg_endpoint echo_ept, calc_ept;
static uint32_t n_echo;

static K_SEM_DEFINE(ipi_sem, 0, 1);

static void ipm_cb(const struct device *dev, void *ctx, uint32_t id, volatile void *data)
{
	k_sem_give(&ipi_sem);
}

static int mailbox_notify(void *priv, uint32_t id)
{
	ipm_send(ipm, 0, id, &id, sizeof(id));
	return 0;
}

/* ---- エコー ---- */
static int echo_cb(struct rpmsg_endpoint *e, void *data, size_t len, uint32_t src, void *priv)
{
	static char tx[RPMSG_BUFFER_SIZE];
	size_t n = MIN(len, sizeof(tx) - 6);

	memcpy(tx, "R5_1: ", 6);
	memcpy(tx + 6, data, n);
	n_echo++;
	rpmsg_send(e, tx, n + 6);
	return RPMSG_SUCCESS;
}

/* ---- 計算役: 受信は依頼を受け取るだけ。計算は別スレッド (管理スレッドを止めないため) ---- */
struct calc_req {
	uint32_t magic, seq, n;
} __packed;

struct calc_res {
	uint32_t magic, seq, n, count, us;
} __packed;

static struct calc_req req;
static K_SEM_DEFINE(calc_sem, 0, 1);
static uint32_t n_calc, n_bad;
static uint64_t calc_sum_us;

static int calc_cb(struct rpmsg_endpoint *e, void *data, size_t len, uint32_t src, void *priv)
{
	const struct calc_req *q = data;

	if (len != sizeof(*q) || q->magic != MAGIC_REQ || k_sem_count_get(&calc_sem)) {
		n_bad++;
		return RPMSG_SUCCESS;
	}
	req = *q;
	k_sem_give(&calc_sem);
	return RPMSG_SUCCESS;
}

/* n 以下の素数の数 (奇数で割っていくだけ。わざと重い計算) */
static uint32_t count_primes(uint32_t n)
{
	uint32_t c = n >= 2;

	for (uint32_t m = 3; m <= n; m += 2) {
		bool prime = true;

		for (uint32_t d = 3; d * d <= m; d += 2) {
			if (m % d == 0) {
				prime = false;
				break;
			}
		}
		c += prime;
	}
	return c;
}

static void calc_thread(void *a, void *b, void *c)
{
	for (;;) {
		k_sem_take(&calc_sem, K_FOREVER);
		struct calc_res r = {.magic = MAGIC_RES, .seq = req.seq, .n = req.n};
		uint32_t c0 = k_cycle_get_32();

		r.count = count_primes(req.n);
		r.us = (uint32_t)((uint64_t)(k_cycle_get_32() - c0) * 1000000U /
				  sys_clock_hw_cycles_per_sec());
		n_calc++;
		calc_sum_us += r.us;
		rpmsg_send(&calc_ept, &r, sizeof(r));
	}
}
/* 優先度は低め (7)。計算中も shell と通信は動く */
K_THREAD_DEFINE(calc_tid, 1024, calc_thread, NULL, NULL, NULL, 7, 0, 0);

/* ---- R5_0 からの直接の IPI (Linux を通さない。R5_0 の r2r.c と対、形は apps/common/r2r_shm.h) ----
 * 割り込みの中で呼ばれる。PING はそのまま返し、KICK は音を作るスレッドを起こす。
 * data はドライバ内の struct xlnx_ipi_data。中身は先頭から 8 バイト目 (r2r.c の説明)
 */
static const struct device *const r2r = DEVICE_DT_GET(DT_NODELABEL(rpu1_rpu0_mailbox));
static uint32_t n_r2r;

static void r2r_cb(const struct device *dev, void *ctx, uint32_t id, volatile void *data)
{
	const volatile struct r2r_msg *m = (const volatile struct r2r_msg *)((volatile uint8_t *)data + 8);

	n_r2r++;
	/* Zephyr の IPI ドライバは ISR のビットを「読んで OR して書き戻す」で消すため、この合図を消す時に
	 * 同時に来ていた Linux の合図 (APU のビット) まで消してしまう (W1C のレジスタ)。KICK は 1ms ごとに
	 * 来るので実際に起きた (段B で Linux の命令が 15 個目で止まった)。消されても取りこぼさないよう、
	 * ここで毎回 main に受信リングを見に行かせる (何も無ければ空振りするだけ)
	 */
	k_sem_give(&ipi_sem);
	if (m->type == R2R_PING) {   /* 往復の測定: そのまま返す */
		struct r2r_msg back = {R2R_PING, m->val};

		ipm_send(r2r, 0, 0, &back, sizeof(back));
	} else if (m->type == R2R_KICK) {   /* 輪バッファを読んだので足して (r51_audio.c) */
		r51_audio_kick();
	}
}

static int platform_init(void)
{
	struct metal_init_params mp = METAL_INIT_DEFAULTS;
	int rsc_size;

	if (metal_init(&mp)) {
		return -1;
	}
	metal_io_init(&shm_io_data, (void *)SHM_START_ADDR, &shm_physmap, SHM_SIZE, -1, 0,
		      addr_translation_get_ops(shm_physmap));

	rsc_table_get(&rsc_table, &rsc_size);
	rsc_tab_physmap = (uintptr_t)rsc_table;
	metal_io_init(&rsc_io_data, rsc_table, &rsc_tab_physmap, rsc_size, -1, 0, NULL);

	if (!device_is_ready(ipm)) {
		return -2;
	}
	ipm_register_callback(ipm, ipm_cb, NULL);
	if (device_is_ready(r2r)) {
		ipm_register_callback(r2r, r2r_cb, NULL);
		ipm_set_enabled(r2r, 1);
	}
	return ipm_set_enabled(ipm, 1);
}

static struct rpmsg_device *create_vdev(void)
{
	struct fw_rsc_vdev_vring *vr;
	struct virtio_device *vdev;

	vdev = rproc_virtio_create_vdev(VIRTIO_DEV_DEVICE, VDEV_ID, rsc_table_to_vdev(rsc_table),
					&rsc_io_data, NULL, mailbox_notify, NULL);
	if (!vdev) {
		return NULL;
	}
	rproc_virtio_wait_remote_ready(vdev);

	vr = rsc_table_get_vring0(rsc_table);
	if (rproc_virtio_init_vring(vdev, 0, vr->notifyid, (void *)vr->da, &rsc_io_data, vr->num,
				    vr->align)) {
		goto fail;
	}
	vr = rsc_table_get_vring1(rsc_table);
	if (rproc_virtio_init_vring(vdev, 1, vr->notifyid, (void *)vr->da, &rsc_io_data, vr->num,
				    vr->align)) {
		goto fail;
	}
	if (rpmsg_init_vdev(&rvdev, vdev, NULL, &shm_io_data, NULL)) {
		goto fail;
	}
	return rpmsg_virtio_get_rpmsg_device(&rvdev);

fail:
	rproc_virtio_remove_vdev(vdev);
	return NULL;
}

int main(void)
{
	struct rpmsg_device *rpdev;

	if (platform_init()) {
		return 0;
	}
	rpdev = create_vdev();
	if (!rpdev) {
		return 0;
	}
	rpmsg_create_ept(&echo_ept, rpdev, EPT_NAME, ECHO_ADDR, RPMSG_ADDR_ANY, echo_cb, NULL);
	shell_backend_rpmsg_init_transport(rpdev);
	rpmsg_create_ept(&calc_ept, rpdev, EPT_NAME, CALC_ADDR, RPMSG_ADDR_ANY, calc_cb, NULL);
	r51_audio_init(rpdev);   /* 0x460: 音の分業 */

	for (;;) {
		k_sem_take(&ipi_sem, K_FOREVER);
		rproc_virtio_notified(rvdev.vdev, VRING1_ID);
	}
	return 0;
}

/* ---- shell: r51 stats ---- */
static int cmd_stats(const struct shell *sh, size_t argc, char **argv)
{
	shell_print(sh, "R5_1: エコー %u 通 / 計算 %u 回 (平均 %u us) / 形式違い %u / R5_0 から直接 %u 回",
		    n_echo, n_calc, n_calc ? (uint32_t)(calc_sum_us / n_calc) : 0, n_bad, n_r2r);
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_r51, SHELL_CMD(stats, NULL, "R5_1 の統計", cmd_stats),
			       SHELL_SUBCMD_SET_END);
SHELL_CMD_REGISTER(r51, &sub_r51, "R5_1 (2 コア目)", NULL);
