/* ---------------------------------------------------------------------------
 * fftmeter.c -- PL 内蔵 FFT で再生中の音を測る（PS復調 と PL復調 の比較用）
 *
 *   段9 で PL に載せた 512点 FFT は FIFO の出力（＝実際に鳴っている音）を
 *   見ている。つまり **PS が復調しようが PL が復調しようが、同じレジスタから
 *   同じ土俵で出力スペクトルを読める**。
 *
 *   耳で「こっちが良い気がする」と判断すると間違える。数字で比べる。
 *
 *   【指標】
 *     音声   : 300Hz〜3kHz  のパワー
 *     雑音床 : 20k〜24.4kHz のパワー（ここには音声が無い＝純粋な雑音）
 *     差     : 大きいほど静か（＝SN が良い）
 *
 *     ※「雑音/音声」の比だけで見ると、放送内容（音楽か喋りか無音か）で
 *       大きく振れて比較にならない。雑音床の絶対値もあわせて見ること。
 *
 *   使い方:
 *     gcc -O2 -o fftmeter fftmeter.c -lm
 *
 *     sudo ./radio 87.2M &        # PS復調で鳴らす
 *     sudo ./fftmeter 20          # 20秒間測る
 *
 *     sudo ./fmradio 87.2M        # PL復調で鳴らす（繰り返し再生）
 *     sudo ./fftmeter 20
 *
 *   ※ 事前に PL を用意しておくこと:
 *       sudo fpgautil -b ~/stream.bit
 *       sudo devmem 0xFF5E00C0 32 0x01010A00
 * ------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <sys/mman.h>

#define BASE_ADDR   0xA0000000UL
#define MAP_SIZE    0x1000UL

#define REG_FBIN    0x80
#define REG_FRE     0x90
#define REG_FIM     0xA0

#define NBIN        256             /* PL FFT の片側ビン数（512点の半分） */
#define FS          48828.125
#define BINHZ       (FS / 512.0)    /* 1 ビンの幅 ≒ 95.4Hz */

/* 測る帯域（ビン番号に直して使う） */
#define VOICE_LO    300.0
#define VOICE_HI    3000.0
#define NOISE_LO    20000.0
#define NOISE_HI    24000.0

static volatile uint32_t *regs;
static inline void reg_write(int off, uint32_t v) { regs[off / 4] = v; }
static inline uint32_t reg_read(int off)          { return regs[off / 4]; }

int main(int argc, char **argv)
{
    int seconds = (argc >= 2) ? atoi(argv[1]) : 10;
    if (seconds < 1) seconds = 1;

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem を開けない (sudo で実行すること)"); return 1; }

    regs = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, BASE_ADDR);
    if (regs == MAP_FAILED) { perror("mmap 失敗"); return 1; }

    int vb_lo = (int)(VOICE_LO / BINHZ);
    int vb_hi = (int)(VOICE_HI / BINHZ);
    int nb_lo = (int)(NOISE_LO / BINHZ);
    int nb_hi = (int)(NOISE_HI / BINHZ);
    if (nb_hi > NBIN - 1) nb_hi = NBIN - 1;

    printf("測定時間 : %d 秒\n", seconds);
    printf("ビン幅   : %.1f Hz\n", BINHZ);
    printf("音声帯域 : bin %d〜%d (%.0f〜%.0f Hz)\n", vb_lo, vb_hi, VOICE_LO, VOICE_HI);
    printf("雑音帯域 : bin %d〜%d (%.0f〜%.0f Hz)\n", nb_lo, nb_hi, NOISE_LO, NOISE_HI);
    printf("測定中...\n");

    double acc_voice = 0.0, acc_noise = 0.0;
    long   nsweep = 0;

    /* 1回の掃引で 256 ビン全部を読む。それを制限時間まで繰り返して平均する。 */
    for (int s = 0; s < seconds; s++) {
        for (int rep = 0; rep < 20; rep++) {          /* 1秒あたり20回ほど */
            double v = 0.0, n = 0.0;

            for (int k = 0; k < NBIN; k++) {
                reg_write(REG_FBIN, (uint32_t)k);
                (void)reg_read(REG_FRE);              /* ダミー読み（段9の作法）*/
                int32_t re = (int32_t)reg_read(REG_FRE);
                int32_t im = (int32_t)reg_read(REG_FIM);
                double  p  = (double)re * re + (double)im * im;   /* パワー */

                if (k >= vb_lo && k <= vb_hi) v += p;
                if (k >= nb_lo && k <= nb_hi) n += p;
            }
            acc_voice += v;
            acc_noise += n;
            nsweep++;
            usleep(50000 / 20);
        }
        printf("\r%d / %d 秒", s + 1, seconds);
        fflush(stdout);
    }
    printf("\n\n");

    double voice = acc_voice / nsweep;
    double noise = acc_noise / nsweep;

    printf("掃引回数     : %ld\n", nsweep);
    if (voice <= 0.0 || noise <= 0.0) {
        printf("★測定できていない（音が鳴っていないか、FFT が動いていない）\n");
        printf("  voice=%.1f  noise=%.1f\n", voice, noise);
    } else {
        printf("音声(300Hz-3kHz)   : %8.1f dB\n", 10.0 * log10(voice));
        printf("雑音床(20k-24kHz)  : %8.1f dB   ← 小さいほど静か\n", 10.0 * log10(noise));
        printf("差 (SN)            : %8.1f dB   ← 大きいほど良い\n",
               10.0 * log10(voice / noise));
    }

    munmap((void *)regs, MAP_SIZE);
    close(fd);
    return 0;
}
