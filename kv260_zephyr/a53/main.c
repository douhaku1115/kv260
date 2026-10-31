// -----------------------------------------------------------------------------
// main.c -- A53 との分業の A53 側 (ベアメタル)。R5 の Zephyr に推論を頼み、結果を照合する
//
//   1. テスト画像 10 枚を共有メモリ (0x18000000) に置く
//   2. IPI で R5 に「画像 k を推論して」と頼み、返事をポーリングで待つ (割り込みは使わない)
//   3. 返事の答えと共有メモリのスコアを期待値と照合し、往復時間と一緒に共有メモリの統計へ書く
//   4. 2〜3 を止まらずに繰り返す
//
//   UART は R5 が使うので、ここでは何も表示しない。統計は R5 の shell の `amp stats` で見る。
//   取り決め (番地・構造体) は ../amp_shared.h。テスト画像と期待値は apps/cnn と共用。
// -----------------------------------------------------------------------------
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_mmu.h"
#include "xiltimer.h"

#include "../amp_shared.h"
#include "../apps/cnn/src/cnn_data.h"

/* APU の IPI (チャネル 0) */
#define APU_IPI      0xFF300000UL
#define IPI_TRIG     0x00
#define IPI_ISR      0x10
#define IPI_IDR      0x1C
#define IPI_BIT_RPU0 (1u << 8)

/* メッセージ用バッファ (Zephyr の rpu0_apu_mailbox と同じ番地) */
#define BUF_APU_TO_RPU0 0xFF990400UL   /* A53 が書く依頼 */
#define BUF_RPU0_TO_APU 0xFF990080UL   /* R5 が書く返事 */

#define TIMEOUT_US 100000   /* 推論は約 2ms。100ms 返事がなければ数える */

static volatile struct amp_shm *const shm = (volatile struct amp_shm *)AMP_SHM_BASE;

static uint32_t now_us(void)
{
	XTime t;

	XTime_GetTime(&t);
	return (uint32_t)(t / (COUNTS_PER_SECOND / 1000000));
}

/* 画像 n の期待される答え (同点は先勝ち。numpy.argmax と同じ) */
static uint32_t expected_digit(int n)
{
	int d = 0;

	for (int i = 1; i < NOUT; i++) {
		if ((int32_t)test_scores[n * NOUT + i] > (int32_t)test_scores[n * NOUT + d]) {
			d = i;
		}
	}
	return d;
}

int main(void)
{
	/* 共有メモリをキャッシュなしに (A53 の MMU は 2MB 単位。0x18000000 の 2MB をまとめて) */
	Xil_SetTlbAttributes(AMP_SHM_BASE, NORM_NONCACHE);

	/* IPI の割り込みは使わない。R5_0 からの前の残りを消す */
	Xil_Out32(APU_IPI + IPI_IDR, 0xFFFFFFFF);
	Xil_Out32(APU_IPI + IPI_ISR, IPI_BIT_RPU0);

	/* 統計を 0 にして画像を置く */
	shm->magic = 0;
	shm->count = shm->bad = shm->timeout = shm->seq_err = 0;
	shm->r5_count = 0;   /* R5 は依頼が来てから数えるので、ここで 0 にしてよい */
	shm->rtt_sum_us = 0;
	shm->rtt_min_us = 0xFFFFFFFF;
	shm->rtt_max_us = 0;
	for (int n = 0; n < AMP_NIMG; n++) {
		for (int i = 0; i < AMP_XLEN; i++) {
			shm->images[n][i] = test_images[n * XLEN + i];
		}
	}
	__asm__ volatile("dsb sy" ::: "memory");
	shm->magic = AMP_MAGIC_READY;

	for (uint32_t seq = 1;; seq++) {
		uint32_t img = seq % AMP_NIMG;

		/* ---- 依頼を書いて R5_0 に IPI ---- */
		Xil_Out32(BUF_APU_TO_RPU0 + 0, AMP_MAGIC_REQ);
		Xil_Out32(BUF_APU_TO_RPU0 + 4, seq);
		Xil_Out32(BUF_APU_TO_RPU0 + 8, img);
		__asm__ volatile("dsb sy" ::: "memory");
		uint32_t t0 = now_us();

		Xil_Out32(APU_IPI + IPI_TRIG, IPI_BIT_RPU0);

		/* ---- 返事を待つ (R5_0 からの ISR ビット) ---- */
		while (!(Xil_In32(APU_IPI + IPI_ISR) & IPI_BIT_RPU0)) {
			if (now_us() - t0 > TIMEOUT_US) {
				break;
			}
		}
		uint32_t rtt = now_us() - t0;

		if (!(Xil_In32(APU_IPI + IPI_ISR) & IPI_BIT_RPU0)) {
			shm->timeout++;
			continue;
		}
		uint32_t magic = Xil_In32(BUF_RPU0_TO_APU + 0);
		uint32_t rseq = Xil_In32(BUF_RPU0_TO_APU + 4);
		uint32_t digit = Xil_In32(BUF_RPU0_TO_APU + 8);

		Xil_Out32(APU_IPI + IPI_ISR, IPI_BIT_RPU0);   /* 読んだので消す */

		if (magic != AMP_MAGIC_RES || rseq != seq) {
			shm->seq_err++;
			continue;
		}

		/* ---- 答えとスコアを照合する ---- */
		uint32_t bad = (digit != expected_digit(img));

		for (int i = 0; i < AMP_NOUT; i++) {
			if (shm->scores[i] != (int32_t)test_scores[img * NOUT + i]) {
				bad++;
			}
		}

		/* ---- 統計 ---- */
		shm->bad += bad;
		shm->rtt_sum_us += rtt;
		if (rtt < shm->rtt_min_us) {
			shm->rtt_min_us = rtt;
		}
		if (rtt > shm->rtt_max_us) {
			shm->rtt_max_us = rtt;
		}
		shm->count++;
	}
	return 0;
}
