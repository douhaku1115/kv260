/*
 * r2r_shm.h -- R5_0 と R5_1 の取り決め (Linux を通さない直接のやりとり)。両方のアプリが読む
 *
 *   IPI (R5_0 ⇔ R5_1 専用、rpu0_rpu1_mailbox / rpu1_rpu0_mailbox) で送る 8 バイト:
 *     u32 type  u32 val
 *       R2R_PING : R5_0 → R5_1 → R5_0。val をそのまま返す (往復時間の測定)
 *       R2R_KICK : R5_0 → R5_1。「輪バッファを読んだので足して」。val = 読んだ位置 (rd)
 *
 *   共有 DDR 0x7F000000 (1MB、Linux 管理外、両方の MPU にキャッシュなしで登録) の先頭に輪バッファ:
 *     R5_1 が音を作って buf に書き wr を進める。R5_0 が 1ms ごとに buf から PL の FIFO へ移し rd を進める。
 *     R5_1 は自分のタイマーでなく R5_0 の KICK で作るので、PL の音の時計 (48828Hz) とずれない。
 *     wr / rd は増え続ける標本の番号 (添字は & (R2R_RING - 1))。書くのはそれぞれ片方だけ。
 */
#ifndef R2R_SHM_H
#define R2R_SHM_H

#include <stdint.h>

#define R2R_SHM_ADDR 0x7F000000UL
#define R2R_RING     4096           /* 標本 (2 のべき)。約 84ms 分 */
#define R2R_MAGIC    0x52325231u    /* "1R2R": R5_1 が輪バッファを用意した印 */

enum { R2R_PING = 1, R2R_KICK = 2 };

struct r2r_msg {
	uint32_t type;
	uint32_t val;
};

struct r2r_ring {
	volatile uint32_t magic;        /* R5_1 が書く */
	volatile uint32_t wr;           /* R5_1 が書く: 作り終えた標本の数 */
	volatile uint32_t rd;           /* R5_0 が書く: FIFO へ移した標本の数 */
	volatile uint32_t fifo_level;   /* R5_0 が書く: 直近の FIFO の残量 (R5_1 が遅れの計算に使う) */
	uint32_t pad[4];
	volatile uint32_t buf[R2R_RING];   /* 1 語 = 左右 1 組 (左右同じ値) */
};

#define R2R ((struct r2r_ring *)R2R_SHM_ADDR)

#endif
