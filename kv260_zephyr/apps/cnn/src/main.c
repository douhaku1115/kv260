// -----------------------------------------------------------------------------
// main.c -- KV260 の R5 (Zephyr) から PL の CNN (kv260_cnn) を動かす
//
//   kv260_cnn/sw/cnn_test.c (Linux 版) の移植。PL の cnn_axi(0xA0000000) に画像を書き、
//   答えとスコアを読んで、シミュレーションと同じ期待値と 1 ビットでも違わないかを確かめる。
//
//   Linux 版との違い:
//     - /dev/mem + mmap の代わりに sys_read32/sys_write32 で直接たたく。
//       0xA0000000 は pl_axi.overlay で MPU に入出力領域として登録してある (無いとアボート)
//     - テスト画像と期待値は gen_cnn_data.py で cnn_data.h に埋め込む (ファイルが無いので)
//     - 時間は k_cycle_get_32 で測る。printk は小数を出せないので μs の整数で出す
//
//   【レジスタ】0x10 刻み（cnn_axi.v と一致させること）
//     0x00 ID(R) 0xC4400001 / 0x10 STATUS(R) / 0x20 CTRL(W)
//     0x30 IMG(W) / 0x40 DIGIT(R) / 0x50 SEL(W) / 0x60 SCORE(R)
// -----------------------------------------------------------------------------
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/sys/sys_io.h>

#include "cnn_data.h"

#define CNN_BASE   0xA0000000UL

#define REG_ID     (CNN_BASE + 0x00)
#define REG_STATUS (CNN_BASE + 0x10)
#define REG_CTRL   (CNN_BASE + 0x20)
#define REG_IMG    (CNN_BASE + 0x30)
#define REG_DIGIT  (CNN_BASE + 0x40)
#define REG_SEL    (CNN_BASE + 0x50)
#define REG_SCORE  (CNN_BASE + 0x60)

/* サイクル数を μs に */
static uint32_t cyc_to_us(uint32_t cyc)
{
	return (uint32_t)((uint64_t)cyc * 1000000U / sys_clock_hw_cycles_per_sec());
}

int main(void)
{
	/* ---- 疎通確認 ---- */
	uint32_t id = sys_read32(REG_ID);

	printk("ID = 0x%08X ", id);
	if (id != 0xC4400001u) {
		printk("... 違う（期待 0xC4400001）\n");
		printk("PL にビットストリームが載っていないか、PL クロックが止まっている。\n");
		printk("run_zephyr.tcl に CNN のビットファイルと cnn_ps_fix.tcl を渡したか確かめる。\n");
		return 0;
	}
	printk("... AXI 疎通 OK\n\n");

	int total_bad = 0;
	uint32_t cyc_all = 0;

	for (int n = 0; n < NIMG; n++) {
		/* ---- 画素ポインタを戻し、終了フラグを消す ---- */
		sys_write32(0x6, REG_CTRL);

		/* ---- 画像を 784 個書く ---- */
		for (int i = 0; i < XLEN; i++) {
			sys_write32(test_images[n * XLEN + i], REG_IMG);
		}

		uint32_t st = sys_read32(REG_STATUS);

		if (((st >> 8) & 0xFFF) != 0) {
			printk("画像%d: 画素ポインタが %u（期待 0）\n", n, (st >> 8) & 0xFFF);
			total_bad++;
		}

		/* ---- 開始して終了を待つ ---- */
		uint32_t c0 = k_cycle_get_32();
		int guard = 0;

		sys_write32(0x1, REG_CTRL);
		do {
			st = sys_read32(REG_STATUS);
			if (++guard > 100000000) {
				printk("画像%d: done が立たない（STATUS=0x%08X）\n", n, st);
				return 0;
			}
		} while (!(st & 0x2));
		uint32_t cyc = k_cycle_get_32() - c0;

		cyc_all += cyc;

		/* ---- 期待される答え（同点は先勝ち。numpy.argmax と同じ）---- */
		int exp_digit = 0;

		for (int i = 1; i < NOUT; i++) {
			if ((int32_t)test_scores[n * NOUT + i] >
			    (int32_t)test_scores[n * NOUT + exp_digit]) {
				exp_digit = i;
			}
		}

		/* ---- 答えとスコアを突き合わせる ---- */
		int bad = 0;
		uint32_t digit = sys_read32(REG_DIGIT) & 0xF;

		if ((int)digit != exp_digit) {
			printk("    答え PL=%u 期待=%d\n", digit, exp_digit);
			bad++;
		}
		for (int i = 0; i < NOUT; i++) {
			sys_write32(i, REG_SEL);
			int32_t got = (int32_t)sys_read32(REG_SCORE);
			int32_t exp = (int32_t)test_scores[n * NOUT + i];

			if (got != exp) {
				printk("    スコア[%d] PL=%d 期待=%d\n", i, got, exp);
				bad++;
			}
		}
		total_bad += bad;

		if (bad == 0) {
			printk("画像%d: 答え=%u 一致（%u us）\n", n, digit, cyc_to_us(cyc));
		} else {
			printk("画像%d: 不一致 %d 箇所\n", n, bad);
		}
	}

	printk("\n1 枚あたり平均 %u us（タイマ %u Hz）\n", cyc_to_us(cyc_all) / NIMG,
	       sys_clock_hw_cycles_per_sec());
	if (total_bad == 0) {
		printk("=== 合格: 実機の結果が Python の量子化版と 1 ビットも違わない ===\n");
	} else {
		printk("=== 失敗: 不一致 %d 箇所 ===\n", total_bad);
	}
	return 0;
}
