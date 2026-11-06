// -----------------------------------------------------------------------------
// cnn_uio.c -- 段14: PL の CNN を UIO 経由で動かし、ポーリングと割り込みを比べる
//
//   段13 の cnn_test.c は /dev/mem を root で開き、STATUS を読み続けて終わりを
//   待っていた（その間 CPU は 100% 回りっぱなし）。ここでは
//     poll : 同じく STATUS を読み続ける（比較用）
//     irq  : /dev/uioN を read() して眠り、PL の割り込みで起こしてもらう
//   の両方で同じ画像を流し、次の 3 つを測る。
//     ・待ち時間        start を打ってから結果が読めるまで（壁時計）
//     ・CPU 使用時間    その間にこのプロセスが CPU を使った時間
//     ・LAT             PL が終わってから CPU の最初の読み出しが届くまで
//                       （PL の 0x70。100MHz なので 1 クロック = 10ns）
//   結果は毎回 Python の量子化版の期待値と 1 ビット単位で突き合わせる。
//
//   【前提】cnn_uio.dtso を足し、uio_pdrv_genirq に結び付けてあること
//           （/sys/class/uio/uioN/name が "cnn_uio@a0000000" になる）
//
//   【使い方】
//     gcc -O2 -o cnn_uio cnn_uio.c
//     sudo ./cnn_uio test_images.hex test_scores.hex [枚数(既定1000)]
//
//   【UIO の割り込みの扱い】
//     uio_pdrv_genirq は割り込みが来ると、その割り込みを止めてから read() を返す。
//     irq はレベル（終了フラグそのもの）なので、
//       CTRL bit2 で終了フラグを消す → /dev/uioN に 1 を書いて割り込みを再開
//     の順にする。逆だと High のままなのですぐにもう一度入ってしまう。
// -----------------------------------------------------------------------------
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <poll.h>
#include <time.h>

#define MAP_SIZE   0x1000

#define REG_ID     (0x00 / 4)
#define REG_STATUS (0x10 / 4)
#define REG_CTRL   (0x20 / 4)
#define REG_IMG    (0x30 / 4)
#define REG_DIGIT  (0x40 / 4)
#define REG_SEL    (0x50 / 4)
#define REG_SCORE  (0x60 / 4)
#define REG_LAT    (0x70 / 4)

#define NIMG 10
#define XLEN 784
#define NOUT 10

static volatile uint32_t *reg;
static int uio_fd;
static unsigned int images[NIMG * XLEN];
static unsigned int scores[NIMG * NOUT];

static int read_hex(const char *path, unsigned int *out, int n)
{
    FILE *fp = fopen(path, "r");
    if (!fp) { perror(path); return -1; }
    char line[64];
    int i = 0;
    while (i < n && fgets(line, sizeof(line), fp))
        out[i++] = (unsigned int)strtoul(line, NULL, 16);
    fclose(fp);
    if (i != n) { fprintf(stderr, "%s: %d 語しかない（%d 語必要）\n", path, i, n); return -1; }
    return 0;
}

static double clk_sec(clockid_t id)
{
    struct timespec t;
    clock_gettime(id, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

/* /sys/class/uio/uioN/name が "cnn_uio" で始まる N を探す
 * （実機では DT のノード名そのまま "cnn_uio@a0000000" になっていた） */
static int find_uio(void)
{
    for (int i = 0; i < 16; i++) {
        char path[64], name[64] = {0};
        snprintf(path, sizeof(path), "/sys/class/uio/uio%d/name", i);
        FILE *fp = fopen(path, "r");
        if (!fp) continue;
        if (fgets(name, sizeof(name), fp)) name[strcspn(name, "\n")] = 0;
        fclose(fp);
        if (strncmp(name, "cnn_uio", 7) == 0) return i;
    }
    return -1;
}

/* 1 枚分の答えとスコアを期待値と突き合わせる。不一致の数を返す */
static int check(int n)
{
    int bad = 0, exp_digit = 0;
    for (int i = 1; i < NOUT; i++)
        if ((int)scores[n * NOUT + i] > (int)scores[n * NOUT + exp_digit]) exp_digit = i;
    if ((int)(reg[REG_DIGIT] & 0xF) != exp_digit) bad++;
    for (int i = 0; i < NOUT; i++) {
        reg[REG_SEL] = i;
        if ((int)reg[REG_SCORE] != (int)scores[n * NOUT + i]) bad++;
    }
    return bad;
}

static int run(int use_irq, int count)
{
    double wall = 0, cpu = 0, lat_sum = 0;
    uint32_t lat_min = 0xFFFFFFFFu, lat_max = 0;
    int bad = 0;
    const uint32_t one = 1;

    /* 割り込みの回を始める前に、溜まっている「起こす合図」を捨てる。
     * UIO の割り込みは bind した時点で有効なので、先に poll の回を走らせると
     * その 1 枚目の終了で 1 回入り、合図が 1 つ残る（割り込みはそこで止まる）。
     * 捨てないと irq の 1 枚目が計算途中で起きてしまう（実機で不一致 22 が出た）。 */
    if (use_irq) {
        reg[REG_CTRL] = 0x4;                    /* 終了フラグ(=irq)を消す */
        if (write(uio_fd, &one, 4) != 4) { perror("uio write"); return -1; }
        struct pollfd pf = { .fd = uio_fd, .events = POLLIN };
        while (poll(&pf, 1, 0) > 0) {           /* 待たずに確かめ、あれば読み捨てる */
            uint32_t cnt;
            if (read(uio_fd, &cnt, 4) != 4) break;
            printf("  溜まっていた合図を捨てた（累計 %u 回目）\n", cnt);
        }
    }

    for (int k = 0; k < count; k++) {
        int n = k % NIMG;

        reg[REG_CTRL] = 0x6;                    /* ポインタを戻し、終了フラグ(=irq)を消す */
        for (int i = 0; i < XLEN; i++)
            reg[REG_IMG] = images[n * XLEN + i] & 0xFF;
        if (use_irq && write(uio_fd, &one, 4) != 4) { perror("uio write"); return -1; }

        double w0 = clk_sec(CLOCK_MONOTONIC);
        double c0 = clk_sec(CLOCK_PROCESS_CPUTIME_ID);
        reg[REG_CTRL] = 0x1;                    /* 開始 */

        uint32_t lat;
        if (use_irq) {
            uint32_t cnt;
            if (read(uio_fd, &cnt, 4) != 4) { perror("uio read"); return -1; }   /* ここで眠る */
            lat = reg[REG_LAT];                 /* 起きて最初の読み出し → ここで LAT が止まる */
            if (!(reg[REG_STATUS] & 0x2)) { printf("  %d枚目: 起きたのに終了ビットが 0\n", k); bad++; }
        } else {
            long guard = 0;
            while (!(reg[REG_STATUS] & 0x2))
                if (++guard > 100000000L) { printf("  %d枚目: done が立たない\n", k); return -1; }
            lat = reg[REG_LAT];
        }

        double c1 = clk_sec(CLOCK_PROCESS_CPUTIME_ID);
        double w1 = clk_sec(CLOCK_MONOTONIC);
        wall += w1 - w0;
        cpu  += c1 - c0;
        lat_sum += lat;
        if (lat < lat_min) lat_min = lat;
        if (lat > lat_max) lat_max = lat;

        bad += check(n);
    }

    printf("%-6s %d 枚: 待ち %.3f ms/枚, CPU %.3f ms/枚 (%.1f%%), "
           "LAT 平均 %.2f us 最小 %.2f us 最大 %.2f us, 不一致 %d\n",
           use_irq ? "irq" : "poll", count,
           wall / count * 1e3, cpu / count * 1e3, cpu / wall * 100.0,
           lat_sum / count * 0.01, lat_min * 0.01, lat_max * 0.01, bad);
    return bad;
}

int main(int argc, char **argv)
{
    const char *img_path = (argc > 1) ? argv[1] : "test_images.hex";
    const char *scr_path = (argc > 2) ? argv[2] : "test_scores.hex";
    int count = (argc > 3) ? atoi(argv[3]) : 1000;

    if (read_hex(img_path, images, NIMG * XLEN)) return 1;
    if (read_hex(scr_path, scores, NIMG * NOUT)) return 1;

    int u = find_uio();
    if (u < 0) { fprintf(stderr, "cnn_uio の UIO が見つからない（dtbo と bind を先に）\n"); return 1; }
    char dev[32];
    snprintf(dev, sizeof(dev), "/dev/uio%d", u);
    uio_fd = open(dev, O_RDWR);
    if (uio_fd < 0) { perror(dev); return 1; }
    void *p = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, uio_fd, 0);
    if (p == MAP_FAILED) { perror("mmap"); return 1; }
    reg = (volatile uint32_t *)p;

    uint32_t id = reg[REG_ID];
    printf("%s  ID = 0x%08X %s\n", dev, id, id == 0xC4400001u ? "… OK" : "… 違う");
    if (id != 0xC4400001u) return 1;

    int b1 = run(0, count);
    int b2 = run(1, count);

    munmap(p, MAP_SIZE);
    close(uio_fd);
    return (b1 || b2) ? 1 : 0;
}
