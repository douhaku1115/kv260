/*
 * amp_shared.h -- A53 (ベアメタル) と R5 (Zephyr) の分業で両方が使う取り決め
 *
 *   A53: テスト画像を共有メモリに置き、IPI で「画像 k を推論して」と頼む。返事を照合して統計を取る
 *   R5 : IPI を受けて PL の CNN で推論し、スコアを共有メモリに書いて IPI で返事する
 *
 *   共有メモリは 0x18000000 から 1MB。両側ともキャッシュなしで見る
 *   (R5: amp.overlay で MPU をキャッシュなしに / A53: Xil_SetTlbAttributes で NORM_NONCACHE に)。
 *   A53 (aarch64) と R5 (arm32) で構造体の並びが同じになるよう、型の幅を固定し 8 バイト境界にそろえる。
 *
 *   IPI (32 バイトのメッセージ用バッファ。番地は Zephyr の zynqmp_rpu.dtsi の rpu0_apu_mailbox):
 *     A53 → R5 : A53 が 0xFF990400 に amp_req を書き、APU の IPI (0xFF300000) の TRIG に R5_0 のビット (bit8)
 *     R5 → A53 : R5 が 0xFF990080 に amp_res を書き、R5_0 の IPI (0xFF310000) の TRIG に APU のビット (bit0)
 *                A53 は割り込みを使わず、APU の ISR の bit8 をポーリングし、読んだら 1 を書いて消す
 */
#ifndef AMP_SHARED_H
#define AMP_SHARED_H

#include <stdint.h>

#define AMP_SHM_BASE   0x18000000UL
#define AMP_SHM_SIZE   0x100000UL

#define AMP_NIMG 10
#define AMP_XLEN 784
#define AMP_NOUT 10

#define AMP_MAGIC_READY 0xA53C0DE5u   /* A53 が画像を置き終えたら書く */
#define AMP_MAGIC_REQ   0x52455131u   /* "REQ1" */
#define AMP_MAGIC_RES   0x52455331u   /* "RES1" */

/* IPI のメッセージ (32 バイト以内) */
struct amp_req {
	uint32_t magic;   /* AMP_MAGIC_REQ */
	uint32_t seq;     /* 通し番号。返事に同じ値が入る */
	uint32_t img;     /* 共有メモリの何枚目を推論するか */
};

struct amp_res {
	uint32_t magic;   /* AMP_MAGIC_RES */
	uint32_t seq;
	uint32_t digit;   /* PL の答え (スコアは共有メモリ) */
	uint32_t run_us;  /* R5 で測った推論時間 */
};

/* 共有メモリの中身 */
struct amp_shm {
	/* ---- A53 が書く統計 (R5 の shell で表示する) ---- */
	uint64_t rtt_sum_us;     /* 往復時間の合計 */
	uint32_t magic;          /* AMP_MAGIC_READY */
	uint32_t count;          /* 往復した回数 */
	uint32_t bad;            /* 答え・スコアの不一致の数 */
	uint32_t timeout;        /* 返事が来なかった回数 */
	uint32_t seq_err;        /* 返事の通し番号が違った回数 */
	uint32_t rtt_min_us;
	uint32_t rtt_max_us;
	uint32_t pad0;
	/* ---- R5 が書く結果 ---- */
	int32_t scores[AMP_NOUT];
	uint32_t r5_count;       /* R5 が処理した依頼の数 */
	uint32_t pad1;
	/* ---- A53 が置く画像 ---- */
	uint8_t images[AMP_NIMG][AMP_XLEN];
};

_Static_assert(sizeof(struct amp_shm) <= AMP_SHM_SIZE, "共有メモリに収まらない");
_Static_assert(__builtin_offsetof(struct amp_shm, scores) == 40, "A53 と R5 で並びがずれる");
_Static_assert(__builtin_offsetof(struct amp_shm, images) == 88, "A53 と R5 で並びがずれる");

#endif
