// -----------------------------------------------------------------------------
// main.c -- Linux (A53) と RPMsg で話す R5 側。Linux の remoteproc から起動される (段2)
//
//   Linux                                   R5 (この Zephyr)
//     remoteproc が elf を TCM に書き、
//     リソーステーブルに vring の番地を書いて R5 を起動
//                                           vring を作り「rpmsg-raw」という名前を名乗る
//     rpmsg_char が /dev/rpmsg0 を作る  <── (名前の通知)
//     /dev/rpmsg0 に書く   ──────────────>  受信コールバック: "R5: " を付けて送り返す
//     /dev/rpmsg0 から読む <──────────────
//
//   起動の流れは Zephyr の samples/subsys/ipc/openamp_rsc_table の main_remote.c と同じ。
//   shell と rpmsg-tty を外して小さくした (公式のままだと 83KB で TCM 64KB に入らない)。
//   共有メモリの番地は ../../rpmsg.overlay と linux/r5_rpmsg.dtso で合わせてある。
// -----------------------------------------------------------------------------
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/ipm.h>
#include <zephyr/sys/printk.h>
#include <string.h>

#include <openamp/open_amp.h>
#include <metal/sys.h>
#include <metal/io.h>
#include <resource_table.h>
#include <addr_translation.h>

#define SHM_NODE       DT_CHOSEN(zephyr_ipc_shm)
#define SHM_START_ADDR DT_REG_ADDR(SHM_NODE)
#define SHM_SIZE       DT_REG_SIZE(SHM_NODE)

#define EPT_NAME "rpmsg-raw"   /* Linux の rpmsg_char がこの名前で /dev/rpmsgN を作る */

static const struct device *const ipm = DEVICE_DT_GET(DT_CHOSEN(zephyr_ipc));

static metal_phys_addr_t shm_physmap = SHM_START_ADDR;
static metal_phys_addr_t rsc_tab_physmap;
static struct metal_io_region shm_io_data;   /* vdev0buffer (メッセージ本体) */
static struct metal_io_region rsc_io_data;   /* リソーステーブル */
static struct rpmsg_virtio_device rvdev;
static void *rsc_table;

static struct rpmsg_endpoint ept;
static uint32_t rx_count;

static K_SEM_DEFINE(ipi_sem, 0, 1);

/* ---- IPI の受信 (割り込みの中): 起こすだけ。中身は vring を見て処理する ---- */
static void ipm_cb(const struct device *dev, void *ctx, uint32_t id, volatile void *data)
{
	k_sem_give(&ipi_sem);
}

/* ---- OpenAMP から呼ばれる「相手に知らせて」: IPI を 1 回打つ ---- */
static int mailbox_notify(void *priv, uint32_t id)
{
	ipm_send(ipm, 0, id, &id, sizeof(id));
	return 0;
}

/* ---- rpmsg-raw の受信: "R5: " を付けて送り返す (管理スレッドの中で呼ばれる) ---- */
static int ept_cb(struct rpmsg_endpoint *e, void *data, size_t len, uint32_t src, void *priv)
{
	static char tx[RPMSG_BUFFER_SIZE];   /* 1 通の最大 (512 - ヘッダ) に収める */
	size_t n = MIN(len, sizeof(tx) - 4);

	memcpy(tx, "R5: ", 4);
	memcpy(tx + 4, data, n);
	rx_count++;
	/* 毎回表示すると UART (115200bps、1 行約 30 文字 = 約 2.6ms) が往復時間の大半になる。
	 * 最初の 3 通と 1000 通ごとだけ表示する
	 */
	if (rx_count <= 3 || rx_count % 1000 == 0) {
		printk("[R5] #%u 受信 %u バイト\n", rx_count, (unsigned int)len);
	}
	rpmsg_send(e, tx, n + 4);
	return RPMSG_SUCCESS;
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

	/* Linux がリソーステーブルに vring の番地を書き終えるのを待つ */
	rproc_virtio_wait_remote_ready(vdev);

	vr = rsc_table_get_vring0(rsc_table);
	printk("[R5] vring0 da=0x%08x num=%u\n", (unsigned int)vr->da, (unsigned int)vr->num);
	if (rproc_virtio_init_vring(vdev, 0, vr->notifyid, (void *)vr->da, &rsc_io_data, vr->num,
				    vr->align)) {
		goto fail;
	}
	vr = rsc_table_get_vring1(rsc_table);
	printk("[R5] vring1 da=0x%08x num=%u\n", (unsigned int)vr->da, (unsigned int)vr->num);
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
	int ret;

	printk("[R5] RPMsg 段2: 起動\n");

	ret = platform_init();
	if (ret) {
		printk("[R5] 初期化失敗 %d\n", ret);
		return 0;
	}
	printk("[R5] リソーステーブル @%p\n", rsc_table);
	rpdev = create_vdev();
	if (!rpdev) {
		printk("[R5] vdev 作成失敗\n");
		return 0;
	}
	ret = rpmsg_create_ept(&ept, rpdev, EPT_NAME, RPMSG_ADDR_ANY, RPMSG_ADDR_ANY, ept_cb,
			       NULL);
	printk("[R5] 窓口 \"%s\" %s\n", EPT_NAME, ret ? "作成失敗" : "作成 (Linux に通知済)");

	/* IPI が来るたびに vring を見る。受信コールバックはこの中から呼ばれる */
	for (;;) {
		k_sem_take(&ipi_sem, K_FOREVER);
		rproc_virtio_notified(rvdev.vdev, VRING1_ID);
	}
	return 0;
}
