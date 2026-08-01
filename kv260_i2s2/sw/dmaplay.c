/* ---------------------------------------------------------------------------
 * dmaplay.c -- 段11 段階2: CPU を使わない再生（DMA）
 *
 *   段5〜10 の play.c は、CPU が 1 標本ずつ AXI4-Lite で書き込んでいた
 *   （再生中ずっと CPU が働き続ける）。
 *   ここでは音声データを DDR に置き、PL に「ここから読め」と伝えるだけ。
 *   以後 PL が自分で DDR を読んで鳴らすので、CPU は完全に空く。
 *
 *   使い方:
 *     gcc -O2 -o dmaplay dmaplay.c
 *     sudo ./dmaplay song.raw          # 転送して再生開始（すぐ戻る）
 *     sudo ./dmaplay --stop            # 停止
 *
 *   音源: ステレオ(2ch) 16bit 48828Hz の生PCM
 *     ffmpeg -i 曲.mp3 -ac 2 -ar 48828 -f s16le -acodec pcm_s16le song.raw
 *
 *   【PL 専用メモリ】
 *     uEnv.txt の bootargs に mem=1536M を足し、Linux の使用領域を
 *     0x00000000〜0x5FFFFFFF に制限してある。
 *     0x60000000 以降(約511MB)は Linux が触らないので PL 専用に使える。
 * ------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define REG_BASE    0xA0000000UL    /* 制御レジスタ */
#define REG_SIZE    0x1000UL

#define BUF_PHYS    0x60000000UL    /* PL 専用メモリの先頭（Linux 管理外） */
#define BUF_MAX     (400UL << 20)   /* 使う上限 400MB */

#define REG_CTRL     0x20           /* bit0: 再生有効 */
#define REG_GAIN     0x30
#define REG_DMA_ADDR 0xB0
#define REG_DMA_LEN  0xC0
#define REG_DMA_CTRL 0xD0           /* bit0=開始, bit1=繰り返し */
#define REG_DMA_STAT 0xE0

static volatile uint32_t *regs;
static inline void wr(int off, uint32_t v) { regs[off / 4] = v; }
static inline uint32_t rd(int off)         { return regs[off / 4]; }

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "使い方: %s <生PCM(ステレオ16bit48828Hz)> | --stop\n", argv[0]);
        return 1;
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem を開けない (sudo で実行すること)"); return 1; }

    regs = mmap(NULL, REG_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, REG_BASE);
    if (regs == MAP_FAILED) { perror("レジスタの mmap 失敗"); return 1; }

    /* ---- 停止 ---- */
    if (strcmp(argv[1], "--stop") == 0) {
        wr(REG_DMA_CTRL, 0);        /* 繰り返しを止める */
        wr(REG_CTRL, 0);            /* 再生を止める */
        printf("停止しました\n");
        return 0;
    }

    /* ---- 音声ファイルを読む ---- */
    FILE *fp = fopen(argv[1], "rb");
    if (!fp) { perror("音声ファイルを開けない"); return 1; }
    fseek(fp, 0, SEEK_END);
    long fsize = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    if ((unsigned long)fsize > BUF_MAX) {
        printf("ファイルが大きいので先頭 %luMB だけ使います\n", BUF_MAX >> 20);
        fsize = BUF_MAX;
    }
    /* 8バイト(1転送)の倍数に切り下げる */
    fsize &= ~7L;
    printf("ファイル : %s\n", argv[1]);
    printf("転送量   : %.1f MB (%.1f 秒)\n", fsize / 1048576.0, fsize / 4.0 / 48828.125);

    /* ---- PL 専用メモリへ転送 ---- */
    void *buf = mmap(NULL, fsize, PROT_READ | PROT_WRITE, MAP_SHARED, fd, BUF_PHYS);
    if (buf == MAP_FAILED) { perror("PL専用メモリの mmap 失敗"); return 1; }

    printf("DDR(0x%lX)へ転送中...\n", BUF_PHYS);
    size_t n = fread(buf, 1, fsize, fp);
    fclose(fp);
    printf("転送完了 (%zu バイト)\n", n);

    /* ---- PL に指示して再生開始 ---- */
    wr(REG_GAIN, 64);               /* 音量 等倍 */
    wr(REG_CTRL, 1);                /* 再生有効 */
    wr(REG_DMA_ADDR, BUF_PHYS);     /* 読み出し開始アドレス */
    wr(REG_DMA_LEN, (uint32_t)fsize);
    wr(REG_DMA_CTRL, 0x3);          /* bit0=開始, bit1=繰り返し */

    printf("再生開始。CPU は解放されました（このプログラムは終了します）\n");
    printf("停止するには: sudo %s --stop\n", argv[0]);
    printf("DMA_STAT = 0x%08X\n", rd(REG_DMA_STAT));

    munmap(buf, fsize);
    munmap((void *)regs, REG_SIZE);
    close(fd);
    return 0;
}
