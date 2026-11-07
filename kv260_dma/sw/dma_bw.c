// -----------------------------------------------------------------------------
// dma_bw.c -- 段15: PL の AXI DMA で DDR の帯域を測る
//
//   PL: AXI DMA（SGなし, 128bit, バースト256, 250MHz）を HP0 経由で DDR へ
//       axis_route の mode（AXI GPIO）で
//         0: 複写     MM2S(読む) → S2MM(書く)   0x60000000 → 0x64000000
//         1: 読み捨て MM2S だけ                  0x60000000 を読むだけ
//   上限: 128bit × 250MHz = 片方向 4.0 GB/s
//
//   使う DDR は Linux の外（uEnv.txt の mem=1536M で 0x60000000 以降は空き）。
//   /dev/mem を O_SYNC で開くとキャッシュを通らないので、DMA との食い違いは起きない。
//
//   参考: CPU の memcpy（Linux のメモリ、キャッシュあり）も同じ大きさで測る。
//
//   使い方（PL 書込とクロック 250MHz の設定のあと）:
//     gcc -O2 -o dma_bw dma_bw.c
//     sudo ./dma_bw
//
//   AXI DMA のレジスタ（PG021, 単純モード）
//     MM2S: 0x00 DMACR  0x04 DMASR  0x18 SA  0x28 LENGTH（書くと開始）
//     S2MM: 0x30 DMACR  0x34 DMASR  0x48 DA  0x58 LENGTH（書くと受付開始）
//     DMACR bit0=RS(動かす) bit2=Reset
//     DMASR bit0=Halted bit1=Idle bit4=内部エラー bit5=スレーブエラー bit6=復号エラー
// -----------------------------------------------------------------------------
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>
#include <time.h>

#define DMA_BASE   0xA0000000u
#define GPIO_BASE  0xA0010000u
#define SRC_PHYS   0x60000000u
#define DST_PHYS   0x64000000u
#define BUF_MAX    (64u << 20)            /* 64MB */
#define LEN_MAX    (BUF_MAX - 16)         /* LENGTH は 26 ビット（最大 64MB-1）なので 16 引く */

#define MM2S_DMACR (0x00 / 4)
#define MM2S_DMASR (0x04 / 4)
#define MM2S_SA    (0x18 / 4)
#define MM2S_LEN   (0x28 / 4)
#define S2MM_DMACR (0x30 / 4)
#define S2MM_DMASR (0x34 / 4)
#define S2MM_DA    (0x48 / 4)
#define S2MM_LEN   (0x58 / 4)

#define SR_HALTED  0x1
#define SR_IDLE    0x2
#define SR_ERR     0x70

#define REPEAT 10

static volatile uint32_t *dma, *gpio;
static volatile uint32_t *src, *dst;

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}

static void *map(int fd, uint32_t phys, size_t len)
{
    void *p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, phys);
    if (p == MAP_FAILED) { perror("mmap"); exit(1); }
    return p;
}

static void dma_reset(void)
{
    dma[MM2S_DMACR] = 0x4;
    dma[S2MM_DMACR] = 0x4;
    for (int i = 0; i < 1000000; i++)
        if (!(dma[MM2S_DMACR] & 0x4) && !(dma[S2MM_DMACR] & 0x4)) return;
    printf("DMA のリセットが終わらない\n");
    exit(1);
}

/* 1 回の転送。止まるまで STATUS を読み続け、かかった秒を返す（失敗は負） */
static double dma_once(int copy, uint32_t len)
{
    dma_reset();
    gpio[0] = copy ? 0 : 1;               /* 0=複写 1=読み捨て（DMA が止まっている間に切り替える） */
    dma[MM2S_DMACR] = 0x1;
    if (copy) {
        dma[S2MM_DMACR] = 0x1;
        dma[S2MM_DA]    = DST_PHYS;
        dma[S2MM_LEN]   = len;            /* 受け側を先に構える */
    }
    dma[MM2S_SA] = SRC_PHYS;

    double t0 = now();
    dma[MM2S_LEN] = len;                  /* ここで読み出しが始まる */
    volatile uint32_t *sr = copy ? &dma[S2MM_DMASR] : &dma[MM2S_DMASR];
    long guard = 0;
    uint32_t s;
    while (!((s = *sr) & SR_IDLE)) {
        if (s & SR_ERR) { printf("DMA エラー DMASR=0x%08X\n", s); return -1; }
        if (++guard > 200000000L) { printf("DMA が終わらない DMASR=0x%08X\n", s); return -1; }
    }
    double t1 = now();
    if ((dma[MM2S_DMASR] | dma[S2MM_DMASR]) & SR_ERR) {
        printf("DMA エラー MM2S=0x%08X S2MM=0x%08X\n", dma[MM2S_DMASR], dma[S2MM_DMASR]);
        return -1;
    }
    return t1 - t0;
}

/* REPEAT 回測って 最速・平均の GB/s を出す */
static int measure(const char *name, int copy, uint32_t len)
{
    double best = 1e9, sum = 0;
    for (int r = 0; r < REPEAT; r++) {
        double t = dma_once(copy, len);
        if (t < 0) return -1;
        if (t < best) best = t;
        sum += t;
    }
    printf("  %-8s %8u KB : 平均 %7.1f us  %5.2f GB/s   最速 %5.2f GB/s\n",
           name, len >> 10, sum / REPEAT * 1e6,
           len / (sum / REPEAT) / 1e9, len / best / 1e9);
    return 0;
}

static uint32_t pattern(uint32_t i) { return i * 2654435761u ^ 0x5A5A1234u; }

int main(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem"); return 1; }
    dma  = map(fd, DMA_BASE, 0x10000);
    gpio = map(fd, GPIO_BASE, 0x10000);
    src  = map(fd, SRC_PHYS, BUF_MAX);
    dst  = map(fd, DST_PHYS, BUF_MAX);

    printf("DMA MM2S DMASR=0x%08X S2MM DMASR=0x%08X（リセット前）\n",
           dma[MM2S_DMASR], dma[S2MM_DMASR]);

    /* 元データを書き、行き先を 0 で埋める */
    printf("64MB の元データを書いています...\n");
    for (uint32_t i = 0; i < BUF_MAX / 4; i++) { src[i] = pattern(i); dst[i] = 0; }

    /* まず 1 回複写して全部突き合わせる */
    if (dma_once(1, LEN_MAX) < 0) return 1;
    long bad = 0;
    for (uint32_t i = 0; i < LEN_MAX / 4; i++)
        if (dst[i] != pattern(i)) { if (bad < 5) printf("  不一致 [%u] 0x%08X != 0x%08X\n", i, dst[i], pattern(i)); bad++; }
    uint32_t tail = dst[LEN_MAX / 4];     /* 転送しなかった最後の 16 バイトは 0 のままのはず */
    printf("64MB 複写の突き合わせ: 不一致 %ld 語 / %u 語、範囲外 %s\n",
           bad, LEN_MAX / 4, tail == 0 ? "触っていない" : "書かれた（おかしい）");
    if (bad || tail) return 1;

    printf("\nPL の DMA（%d 回ずつ）\n", REPEAT);
    static const uint32_t sizes[] = { 4u<<10, 64u<<10, 1u<<20, 16u<<20, LEN_MAX };
    for (unsigned k = 0; k < sizeof(sizes) / sizeof(sizes[0]); k++) {
        if (measure("複写",     1, sizes[k])) return 1;
        if (measure("読み捨て", 0, sizes[k])) return 1;
    }

    /* 測り終えたあとの複写がまだ正しいか、先頭と末尾だけ確かめる */
    for (uint32_t i = 0; i < 1024; i++)
        if (dst[i] != pattern(i) || dst[LEN_MAX/4 - 1 - i] != pattern(LEN_MAX/4 - 1 - i)) bad++;
    printf("測定後の複写 先頭・末尾 4KB: 不一致 %ld\n", bad);

    /* 参考: CPU の memcpy（Linux のメモリ、キャッシュあり） */
    printf("\n参考: CPU の memcpy（%d 回ずつ）\n", REPEAT);
    char *a = malloc(BUF_MAX), *b = malloc(BUF_MAX);
    if (!a || !b) { printf("malloc 失敗\n"); return 1; }
    memset(a, 1, BUF_MAX); memset(b, 2, BUF_MAX);
    for (unsigned k = 0; k < sizeof(sizes) / sizeof(sizes[0]); k++) {
        double best = 1e9, sum = 0;
        for (int r = 0; r < REPEAT; r++) {
            double t0 = now();
            memcpy(b, a, sizes[k]);
            double t = now() - t0;
            if (t < best) best = t;
            sum += t;
        }
        printf("  memcpy   %8u KB : 平均 %7.1f us  %5.2f GB/s   最速 %5.2f GB/s\n",
               sizes[k] >> 10, sum / REPEAT * 1e6,
               sizes[k] / (sum / REPEAT) / 1e9, sizes[k] / best / 1e9);
    }
    printf("  (b[0]=%d … memcpy が最適化で消されないように使う)\n", b[0]);
    return bad ? 1 : 0;
}
