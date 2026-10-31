// -----------------------------------------------------------------------------
// main.c -- A53 との分業の R5 側。A53 から IPI で頼まれた画像を PL の CNN で推論して返す
//
//   A53 (ベアメタル)                         R5 (この Zephyr)
//     画像を共有メモリに置く
//     IPI「画像 k を推論して」 ──────────>  受信コールバック (割り込みの中) → メッセージキュー
//                                            推論スレッド: 共有メモリの画像を PL へ → 推論
//                                            スコアを共有メモリへ
//     返事をポーリングで待つ   <──────────  IPI で返事 (答えと推論時間)
//     スコアを照合して統計を共有メモリへ
//
//   取り決め (番地・構造体) は ../../amp_shared.h。UART は R5 だけが使い、A53 の統計は
//   shell の `amp stats` で共有メモリから読んで表示する。
// -----------------------------------------------------------------------------
#include <zephyr/drivers/ipm.h>
#include <zephyr/sys/barrier.h>
#include <zephyr/kernel.h>
#include <zephyr/shell/shell.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/sys_io.h>

#include "amp_shared.h"

#define CNN_BASE   0xA0000000UL
#define REG_ID     (CNN_BASE + 0x00)
#define REG_STATUS (CNN_BASE + 0x10)
#define REG_CTRL   (CNN_BASE + 0x20)
#define REG_IMG    (CNN_BASE + 0x30)
#define REG_DIGIT  (CNN_BASE + 0x40)
#define REG_SEL    (CNN_BASE + 0x50)
#define REG_SCORE  (CNN_BASE + 0x60)

/* 共有メモリ (amp.overlay で MPU にキャッシュなしで登録してある) */
static volatile struct amp_shm *const shm = (volatile struct amp_shm *)AMP_SHM_BASE;

static const struct device *const ipm = DEVICE_DT_GET(DT_NODELABEL(rpu0_apu_mailbox));

K_MSGQ_DEFINE(req_q, sizeof(struct amp_req), 8, 4);

static uint32_t bad_msg;   /* 形式の違う IPI メッセージの数 */

static uint32_t cyc_to_us(uint32_t cyc)
{
	return (uint32_t)((uint64_t)cyc * 1000000U / sys_clock_hw_cycles_per_sec());
}

/* ---- IPI の受信 (割り込みの中): 依頼をキューに入れるだけ ---- */
static void ipm_rx(const struct device *dev, void *user, uint32_t id, volatile void *data)
{
	/* ドライバ (ipm_xlnx_ipi.c、.c の中だけで定義) は
	 * struct xlnx_ipi_data { size_t len; void *user_data; uint8_t data[]; } を渡す。中身は data[]
	 */
	const struct amp_req *in = (const struct amp_req *)((const uint8_t *)data +
							      sizeof(size_t) + sizeof(void *));
	struct amp_req req = *in;

	if (req.magic != AMP_MAGIC_REQ || req.img >= AMP_NIMG ||
	    k_msgq_put(&req_q, &req, K_NO_WAIT) != 0) {
		bad_msg++;
	}
}

/* ---- 推論スレッド: 依頼を取り出して PL で推論し、IPI で返事する ---- */
static void server_thread(void *a, void *b, void *c)
{
	struct amp_req req;

	for (;;) {
		k_msgq_get(&req_q, &req, K_FOREVER);

		sys_write32(0x6, REG_CTRL);   /* 画素ポインタを戻し、終了フラグを消す */
		for (int i = 0; i < AMP_XLEN; i++) {
			sys_write32(shm->images[req.img][i], REG_IMG);
		}
		uint32_t c0 = k_cycle_get_32();

		/* 終了待ちは空回りしない。A53 は返事を受けるとすぐ次を頼むので、ここで回り続けると
		 * このスレッド (優先 2) が CPU を独占し、shell (優先 14) が一切応答しなくなる (実機で確認)。
		 * 1 ティック (1ms) ずつ休んで、その間に優先の低いスレッドを動かす
		 */
		sys_write32(0x1, REG_CTRL);
		while (!(sys_read32(REG_STATUS) & 0x2)) {
			k_sleep(K_TICKS(1));
		}

		struct amp_res res = {
			.magic = AMP_MAGIC_RES,
			.seq = req.seq,
			.digit = sys_read32(REG_DIGIT) & 0xF,
			.run_us = cyc_to_us(k_cycle_get_32() - c0),
		};

		for (int i = 0; i < AMP_NOUT; i++) {
			sys_write32(i, REG_SEL);
			shm->scores[i] = (int32_t)sys_read32(REG_SCORE);
		}
		shm->r5_count++;
		/* スコアが共有メモリに届いてから A53 に知らせる */
		barrier_dsync_fence_full();
		ipm_send(ipm, 0, 0, &res, sizeof(res));
	}
}
K_THREAD_DEFINE(server_tid, 2048, server_thread, NULL, NULL, NULL, 2, 0, 0);

/* ---- shell: A53 の統計を共有メモリから読んで表示する ---- */
static int cmd_stats(const struct shell *sh, size_t argc, char **argv)
{
	uint32_t n = shm->count;

	shell_print(sh, "A53: %s / 往復 %u 回 / 不一致 %u / 返事なし %u / 番号違い %u",
		    shm->magic == AMP_MAGIC_READY ? "動作中" : "未起動", n, shm->bad,
		    shm->timeout, shm->seq_err);
	if (n) {
		shell_print(sh, "往復時間 最小 %u us 平均 %u us 最大 %u us", shm->rtt_min_us,
			    (uint32_t)(shm->rtt_sum_us / n), shm->rtt_max_us);
	}
	shell_print(sh, "R5 : 処理 %u 件 / 形式違い %u", shm->r5_count, bad_msg);
	return 0;
}

SHELL_STATIC_SUBCMD_SET_CREATE(sub_amp,
	SHELL_CMD(stats, NULL, "A53 の往復の統計と R5 の件数", cmd_stats),
	SHELL_SUBCMD_SET_END);
SHELL_CMD_REGISTER(amp, &sub_amp, "A53 との分業", NULL);

int main(void)
{
	uint32_t id = sys_read32(REG_ID);

	printk("CNN ID = 0x%08X %s\n", id,
	       id == 0xC4400001u ? "(AXI 疎通 OK)" : "(違う: PL のビットファイルを確かめる)");
	if (!device_is_ready(ipm)) {
		printk("IPI のデバイスが使えない\n");
		return 0;
	}
	ipm_register_callback(ipm, ipm_rx, NULL);
	ipm_set_enabled(ipm, 1);
	printk("A53 からの依頼を待つ (amp stats で統計)\n");
	return 0;
}
