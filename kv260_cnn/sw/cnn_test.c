// -----------------------------------------------------------------------------
// cnn_test.c -- KV260 の Linux から PL の CNN を動かす（段13 段階C）
//
//   PL に載せた cnn_axi(0xA0000000) に画像を書き、答えとスコアを読む。
//   シミュレーションで使ったのと同じテスト画像・期待値を読み込み、
//   1 ビットでも違わないかを確かめる。
//
//   【使い方】
//     gcc -O2 -o cnn_test cnn_test.c
//     sudo ./cnn_test test_images.hex test_scores.hex
//
//   test_images.hex / test_scores.hex は sim/ にあるものをそのまま送る。
//
//   【レジスタ】0x10 刻み（cnn_axi.v と一致させること）
//     0x00 ID(R) 0xC4400001 / 0x10 STATUS(R) / 0x20 CTRL(W)
//     0x30 IMG(W) / 0x40 DIGIT(R) / 0x50 SEL(W) / 0x60 SCORE(R)
//   【実機での結果（2026-09-18）】
//     ID = 0xC4400001 … AXI 疎通 OK
//     10 枚すべて答えとスコアが一致。1 枚あたり 1.991 ms（毎秒 502.2 枚）。
// -----------------------------------------------------------------------------
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <time.h>

#define CNN_BASE   0xA0000000UL
#define MAP_SIZE   0x1000

#define REG_ID     (0x00 / 4)
#define REG_STATUS (0x10 / 4)
#define REG_CTRL   (0x20 / 4)
#define REG_IMG    (0x30 / 4)
#define REG_DIGIT  (0x40 / 4)
#define REG_SEL    (0x50 / 4)
#define REG_SCORE  (0x60 / 4)

#define NIMG 10
#define XLEN 784
#define NOUT 10

static volatile unsigned int *reg;

/* hex ファイル（1 行 1 語）を読む */
static int read_hex(const char *path, unsigned int *out, int n)
{
    FILE *fp = fopen(path, "r");
    if (!fp) { perror(path); return -1; }
    char line[64];
    int i = 0;
    while (i < n && fgets(line, sizeof(line), fp))
        out[i++] = (unsigned int)strtoul(line, NULL, 16);
    fclose(fp);
    if (i != n) {
        fprintf(stderr, "%s: %d 語しかない（%d 語必要）\n", path, i, n);
        return -1;
    }
    return 0;
}

static double now_sec(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

int main(int argc, char **argv)
{
    const char *img_path = (argc > 1) ? argv[1] : "test_images.hex";
    const char *scr_path = (argc > 2) ? argv[2] : "test_scores.hex";

    static unsigned int images[NIMG * XLEN];
    static unsigned int scores[NIMG * NOUT];
    if (read_hex(img_path, images, NIMG * XLEN)) return 1;
    if (read_hex(scr_path, scores, NIMG * NOUT)) return 1;

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem（sudo で実行すること）"); return 1; }
    void *p = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, CNN_BASE);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    reg = (volatile unsigned int *)p;

    /* ---- 疎通確認 ---- */
    unsigned int id = reg[REG_ID];
    printf("ID = 0x%08X ", id);
    if (id != 0xC4400001u) {
        printf("… 違う（期待 0xC4400001）\n");
        printf("PL にビットストリームが載っていないか、PL クロックが止まっている。\n");
        printf("  sudo fpgautil -b ~/design_1_wrapper.bit\n");
        printf("  sudo devmem 0xFF5E00C0 32 0x01010A00\n");
        return 1;
    }
    printf("… AXI 疎通 OK\n\n");

    int total_bad = 0;
    double t_all = 0.0;

    for (int n = 0; n < NIMG; n++) {
        /* ---- 画素ポインタを戻し、終了フラグを消す ---- */
        reg[REG_CTRL] = 0x6;

        /* ---- 画像を 784 個書く ---- */
        for (int i = 0; i < XLEN; i++)
            reg[REG_IMG] = images[n * XLEN + i] & 0xFF;

        unsigned int st = reg[REG_STATUS];
        if (((st >> 8) & 0xFFF) != 0) {
            printf("画像%d: 画素ポインタが %u（期待 0）\n", n, (st >> 8) & 0xFFF);
            total_bad++;
        }

        /* ---- 開始して終了を待つ ---- */
        double t0 = now_sec();
        reg[REG_CTRL] = 0x1;
        int guard = 0;
        do {
            st = reg[REG_STATUS];
            if (++guard > 100000000) {
                printf("画像%d: done が立たない（STATUS=0x%08X）\n", n, st);
                return 1;
            }
        } while (!(st & 0x2));
        double t1 = now_sec();
        t_all += t1 - t0;

        /* ---- 期待される答え（同点は先勝ち。numpy.argmax と同じ）---- */
        int exp_digit = 0;
        for (int i = 1; i < NOUT; i++)
            if ((int)scores[n * NOUT + i] > (int)scores[n * NOUT + exp_digit])
                exp_digit = i;

        /* ---- 答えとスコアを突き合わせる ---- */
        int bad = 0;
        unsigned int digit = reg[REG_DIGIT] & 0xF;
        if ((int)digit != exp_digit) {
            printf("    答え PL=%u 期待=%d\n", digit, exp_digit);
            bad++;
        }
        for (int i = 0; i < NOUT; i++) {
            reg[REG_SEL] = i;
            int got = (int)reg[REG_SCORE];
            int exp = (int)scores[n * NOUT + i];
            if (got != exp) {
                printf("    スコア[%d] PL=%d 期待=%d\n", i, got, exp);
                bad++;
            }
        }
        total_bad += bad;

        if (bad == 0)
            printf("画像%d: 答え=%u 一致（%.3f ms）\n", n, digit, (t1 - t0) * 1e3);
        else
            printf("画像%d: 不一致 %d 箇所\n", n, bad);
    }

    printf("\n");
    printf("1 枚あたり平均 %.3f ms（毎秒 %.1f 枚）\n",
           t_all / NIMG * 1e3, NIMG / t_all);
    if (total_bad == 0)
        printf("=== 合格: 実機の結果が Python の量子化版と 1 ビットも違わない ===\n");
    else
        printf("=== 失敗: 不一致 %d 箇所 ===\n", total_bad);

    munmap(p, MAP_SIZE);
    close(fd);
    return total_bad ? 1 : 0;
}
