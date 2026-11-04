// -----------------------------------------------------------------------------
// r2r.c -- R5_0 と R5_1 が Linux を通さず直接話す (R5_0 側)
//
//   2 つの R5 の間には専用の IPI がある (Zephyr の DT では rpu0_rpu1_mailbox / rpu1_rpu0_mailbox)。
//   送る側は IPI 専用バッファ (0xFF990000〜、相手ごとに 32 バイト) に書いてから合図を打ち、
//   受ける側は割り込みの中で読む。Linux 用の受け口 (rpu0_apu_mailbox) と同じ割り込み (33) を
//   共有するが、ドライバが相手ごとのビットで区別する。
//
//   shell の r2r ping [回数]: 番号を R5_1 に送り、R5_1 がそのまま送り返すまでの往復を測る
//   (R5_1 側は apps/rpmsg_r5_1/src/main.c の r2r_cb)
// -----------------------------------------------------------------------------
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/ipm.h>
#include <zephyr/shell/shell.h>
#include <stdlib.h>

#include "r2r_shm.h"   /* apps/common: 伝言の形と共有 DDR の輪バッファ */
#include "ipi_early_clear.h"

/* 前回の R5_0 が残した IPI の合図で起動が止まらないよう、割り込み解禁前に消す (ipi_early_clear.h) */
IPI_EARLY_CLEAR(DT_NODELABEL(rpu0_ipi));

static const struct device *const r2r = DEVICE_DT_GET(DT_NODELABEL(rpu0_rpu1_mailbox));

static K_SEM_DEFINE(pong_sem, 0, 1);
static volatile uint32_t pong_val;

#define NPING_MAX 1000
static uint16_t rtt_cyc[NPING_MAX];   /* 1 往復のサイクル数 (100MHz なので 1 = 10ns) */

void rpmsg_poke(void);   /* main.c: Linux の合図を消されても受信リングを見に行かせる */

/* R5_1 からの IPI (割り込みの中) */
static void r2r_cb(const struct device *dev, void *ctx, uint32_t id, volatile void *data)
{
	/* data はドライバ内の struct xlnx_ipi_data { size_t len; void *user_data; uint8_t data[]; }
	 * (drivers/ipm/ipm_xlnx_ipi.c、公開ヘッダなし)。R5 は 32 ビットなので中身は先頭から 8 バイト目
	 */
	const volatile struct r2r_msg *m = (const volatile struct r2r_msg *)((volatile uint8_t *)data + 8);

	rpmsg_poke();   /* ドライバがこの合図を消す時に Linux の合図も消しうる (rpmsg_r5_1 の main.c の r2r_cb) */
	if (m->type == R2R_PING) {
		pong_val = m->val;
		k_sem_give(&pong_sem);
	}
}

/* R5_1 に「輪バッファを rd まで読んだので足して」と知らせる (audio_rpmsg.c の 1ms ごとの書き足しから) */
void r2r_kick(uint32_t rd)
{
	struct r2r_msg m = {R2R_KICK, rd};

	ipm_send(r2r, 0, 0, &m, sizeof(m));
}

static int r2r_init(void)
{
	if (!device_is_ready(r2r)) {
		return -ENODEV;
	}
	ipm_register_callback(r2r, r2r_cb, NULL);
	return ipm_set_enabled(r2r, 1);
}
SYS_INIT(r2r_init, APPLICATION, 90);

static int cmd_ping(const struct shell *sh, size_t argc, char **argv)
{
	uint32_t n = argc > 1 ? MIN(strtoul(argv[1], NULL, 10), NPING_MAX) : 100;
	uint32_t bad = 0, lost = 0, ok = 0;
	uint64_t sum = 0;

	for (uint32_t i = 1; i <= n; i++) {
		k_sem_reset(&pong_sem);
		uint32_t c0 = k_cycle_get_32();

		struct r2r_msg m = {R2R_PING, i};

		ipm_send(r2r, 0, 0, &m, sizeof(m));
		if (k_sem_take(&pong_sem, K_MSEC(10))) {
			lost++;
			continue;
		}
		uint32_t c = k_cycle_get_32() - c0;

		if (pong_val != i) {
			bad++;
			continue;
		}
		rtt_cyc[ok++] = (uint16_t)MIN(c, UINT16_MAX);
		sum += c;
	}
	if (!ok) {
		shell_print(sh, "返事なし %u 回 (R5_1 は動いている?)", lost);
		return 0;
	}
	/* 中央値を出すため並べる (挿入ソート。1000 個なら一瞬) */
	for (uint32_t i = 1; i < ok; i++) {
		uint16_t v = rtt_cyc[i];
		int j = i - 1;

		while (j >= 0 && rtt_cyc[j] > v) {
			rtt_cyc[j + 1] = rtt_cyc[j];
			j--;
		}
		rtt_cyc[j + 1] = v;
	}
	uint32_t hz = sys_clock_hw_cycles_per_sec() / 1000000U;   /* 1us あたりのサイクル */

	shell_print(sh, "R5_0 → R5_1 → R5_0: %u 往復 / 違う値 %u / 返事なし %u", ok, bad, lost);
	shell_print(sh, "最小 %u.%02u us  中央 %u.%02u us  平均 %u.%02u us  最大 %u.%02u us",
		    rtt_cyc[0] / hz, rtt_cyc[0] % hz * 100 / hz,
		    rtt_cyc[ok / 2] / hz, rtt_cyc[ok / 2] % hz * 100 / hz,
		    (uint32_t)(sum / ok) / hz, (uint32_t)(sum / ok) % hz * 100 / hz,
		    rtt_cyc[ok - 1] / hz, rtt_cyc[ok - 1] % hz * 100 / hz);
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_r2r,
	SHELL_CMD(ping, NULL, "R5_1 との往復を測る [回数 (最大 1000)]", cmd_ping),
	SHELL_SUBCMD_SET_END);
SHELL_CMD_REGISTER(r2r, &sub_r2r, "R5_1 と直接話す (Linux を通さない IPI)", NULL);
