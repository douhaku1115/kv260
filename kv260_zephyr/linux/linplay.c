/*
 * linplay.c -- 比較用: Linux だけで PL の音声 FIFO を満たす (kv260_i2s2 段5〜の play.c と同じ流し方)
 *
 *   R5 に任せた場合 (r5play.py) と同じ負荷で比べるため、play.c の流し方はそのままに計測だけを足した。
 *     - FIFO が満杯でない間は 1 組ずつ書く。満杯なら usleep(500) で待つ (play.c と同じ)
 *     - STATUS を読むたびに残量を見て最小値を取る
 *     - 空になった回数: 書くのはこのプログラムだけなので、空のビットは次に書くまで立ったまま。
 *       Linux に止められている間に空になっても、戻ってきた最初の STATUS で必ず見える
 *     - ループ 1 周の最長間隔 = このプログラムが止められていた最長時間
 *
 *   gcc -O2 -o linplay linplay.c
 *   sudo ./linplay song.raw 30        30 秒鳴らして統計を出す (PL は stream.bit + devmem 0xFF5E00C0 を先に)
 *   sudo ./linplay song.raw 30 512    残量を 512 段 (約 10ms 分) までしか満たさない
 */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

#define REG_BASE   0xA0000000UL
#define MAP_SIZE   0x1000
#define REG_DATA   0x00
#define REG_STATUS 0x10
#define REG_CTRL   0x20
#define ST_FULL    0x1
#define ST_EMPTY   0x2
#define FIFO_DEPTH 8192
#define FS         48828.125
#define CHUNK      4096

static volatile uint32_t *regs;
static inline uint32_t reg_read(int off) { return regs[off / 4]; }
static inline void reg_write(int off, uint32_t v) { regs[off / 4] = v; }

static double now_sec(void)
{
	struct timespec t;
	clock_gettime(CLOCK_MONOTONIC, &t);
	return t.tv_sec + t.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "使い方: %s <生PCM> <秒数>\n", argv[0]);
		return 1;
	}
	FILE *fp = fopen(argv[1], "rb");
	if (!fp) { perror(argv[1]); return 1; }
	double dur = atof(argv[2]);
	/* 上限 N 段: 残量を N までしか満たさない (FIFO を浅く使い、遅延の小さい再生を真似る)。既定 8192 = play.c と同じ */
	uint32_t limit = argc > 3 ? (uint32_t)atoi(argv[3]) : FIFO_DEPTH;

	int fd = open("/dev/mem", O_RDWR | O_SYNC);
	if (fd < 0) { perror("/dev/mem"); return 1; }
	regs = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, REG_BASE);
	if (regs == MAP_FAILED) { perror("mmap"); return 1; }
	if (reg_read(REG_DATA) != 0xDEADBEEF) {
		fprintf(stderr, "PL が音声設計でない (0x00 = 0x%08X)\n", reg_read(REG_DATA));
		return 1;
	}

	/* 前の残りが鳴り終わるのを待ってから始める (FIFO を空にするレジスタはない) */
	reg_write(REG_CTRL, 1);
	while (!(reg_read(REG_STATUS) & ST_EMPTY)) usleep(10000);

	int16_t buf[CHUNK * 2];
	size_t n;
	long played = 0, n_status = 0, n_empty = 0;
	uint32_t min_level = FIFO_DEPTH;
	int primed = 0;                     /* 一度満杯になってから数える (出だしは空から始まるので) */
	double t0 = now_sec(), t_prev = t0, gap_max = 0;

	while ((n = fread(buf, 4, CHUNK, fp)) > 0 && now_sec() - t0 < dur) {
		for (size_t i = 0; i < n; i++) {
			for (;;) {
				uint32_t st = reg_read(REG_STATUS);
				double t = now_sec();

				uint32_t lv = (st >> 16) & 0x3FFF;

				n_status++;
				if (primed) {
					if (lv < min_level) min_level = lv;
					if (st & ST_EMPTY) n_empty++;
					if (t - t_prev > gap_max) gap_max = t - t_prev;
				}
				t_prev = t;
				if (!(st & ST_FULL) && lv < limit) break;   /* 上限まで満ちていなければ書く */
				primed = 1;
				usleep(500);
			}
			/* play.c と同じ詰め方 */
			uint32_t lr = ((uint32_t)(uint16_t)buf[2 * i] << 16) | (uint32_t)(uint16_t)buf[2 * i + 1];
			reg_write(REG_DATA, lr);
		}
		played += n;
	}
	double el = now_sec() - t0;
	while (!(reg_read(REG_STATUS) & ST_EMPTY)) usleep(10000);
	reg_write(REG_CTRL, 0);

	printf("上限 %u 段  ", limit);
	printf("%.1f 秒  送った %.1f 秒分  最小残量 %u (8192 段)  空 %ld 回  "
	       "止められていた最長 %.1f ms  STATUS 読み %ld 回\n",
	       el, played / FS, min_level, n_empty, gap_max * 1e3, n_status);
	fclose(fp);
	return 0;
}
