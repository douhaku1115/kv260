/* ---------------------------------------------------------------------------
 * play.c -- 長時間再生: 音声ファイルを PL の FIFO に流し込む
 *
 *   使い方:
 *     gcc -O2 -o play play.c
 *     sudo ./play song.raw
 *
 *   再生中のキー操作:
 *     f … 10秒送り   b … 10秒戻し   q … 終了
 *
 *   音源の作り方(パソコン側): ステレオ(2ch)で変換する
 *     ffmpeg -i 曲.mp3 -ac 2 -ar 48828 -f s16le -acodec pcm_s16le song.raw
 *
 *   レジスタ (ベース 0xA000_0000。0x10 刻みに整列。非整列だと読み出しが 0 になる):
 *     0x00 [W]  DATA   左右1組を書き込む([31:16]=左, [15:0]=右, 各16ビット)
 *     0x10 [R]  STATUS bit0:満杯 bit1:空 bit29..16:溜まっている数
 *     0x20 [RW] CTRL   bit0:再生有効
 *
 *   速度の調整:
 *     状態レジスタが読める場合  … 満杯を見て待つ(正確)
 *     読めない場合              … 時計で刻む(予備の方法)
 * ------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <termios.h>
#include <math.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define BASE_ADDR   0xA0000000UL
#define MAP_SIZE    0x1000UL

/* レジスタは 0x10 刻みに配置(0x10 境界に整列しないと devmem/mmap の読み出しが 0 になる) */
#define REG_DATA    0x00
#define REG_STATUS  0x10
#define REG_CTRL    0x20
/* 0x50 BASS / 0x60 TREBLE / 0x70 DIST はエフェクト用（devmem で操作する） */
#define REG_FBIN    0x80            /* PL FFT: 読み出すビン番号を書く */
#define REG_FRE     0x90            /* PL FFT: そのビンの実部 */
#define REG_FIM     0xA0            /* PL FFT: そのビンの虚部 */

#define ST_FULL     0x1
#define ST_EMPTY    0x2

#define FS          48828.125       /* 標本化周波数 */
#define CHUNK       2048            /* 一度に書く標本数 */
#define SEEK_SEC    10              /* 早送り・巻き戻しの1回の秒数 */

static volatile uint32_t *regs;

static inline void reg_write(int off, uint32_t val) { regs[off / 4] = val; }
static inline uint32_t reg_read(int off)            { return regs[off / 4]; }

static double now_sec(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

/* ---- スペクトル: PL側FFTの結果を AXI で読んでパソコンへ送る ---- */
#define NBIN  256                   /* 512点FFTの片側ビン数(0〜約24kHz) */

/* スペクトル送信先(パソコン)。argv[2] で IP を指定されたら有効 */
static int g_sock = -1;
static struct sockaddr_in g_dest;

/* 周波数[Hz] → 音名(例 A4)。平均律、A4=440Hz基準 */
static const char *NOTE[12] = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"};
static void freq_to_note(double f, char *buf)
{
    if (f < 20.0) { strcpy(buf, "---"); return; }
    int midi = (int)(69.0 + 12.0 * log2(f / 440.0) + 0.5);
    int idx  = ((midi % 12) + 12) % 12;
    int oct  = midi / 12 - 1;
    sprintf(buf, "%s%d", NOTE[idx], oct);
}

/* PL の FFT結果(256ビン)を AXI で読み、振幅をパソコンへ UDP 送信する */
static void read_send_fft(double sec, double total_sec)
{
    static float mag[NBIN];
    float mx = 0.0f;
    int   maxbin = 2;
    for (int k = 0; k < NBIN; k++) {
        reg_write(REG_FBIN, (uint32_t)k);         /* 読みたいビンを選ぶ */
        (void)reg_read(REG_FRE);                  /* ダミー読み: reg_fbin反映を待つ */
        int32_t re = (int32_t)reg_read(REG_FRE);  /* 実部(符号拡張済み) */
        int32_t im = (int32_t)reg_read(REG_FIM);  /* 虚部 */
        mag[k] = sqrtf((float)re * re + (float)im * im);
        if (k >= 2 && mag[k] > mx) { mx = mag[k]; maxbin = k; }  /* DC近傍は除外 */
    }
    if (g_sock >= 0)
        sendto(g_sock, mag, sizeof(mag), 0,
               (struct sockaddr *)&g_dest, sizeof(g_dest));

    /* ピーク周波数を平滑化し、0.5秒ごとに音名を表示（速すぎて読めないのを防ぐ） */
    static double freq_sm = 0.0, last_disp = 0.0;
    double freq = maxbin * FS / 512.0;
    freq_sm = (freq_sm <= 0.0) ? freq : freq_sm * 0.7 + freq * 0.3;
    double now = now_sec();
    if (now - last_disp >= 0.5) {
        last_disp = now;
        char note[8];
        freq_to_note(freq_sm, note);
        printf("\r再生 %3.0f/%3.0f秒  ピーク %5.0fHz  %-3s   ",
               sec, total_sec, freq_sm, note);
        fflush(stdout);
    }
}

/* ---- 端末をキー1つずつ・非ブロッキングで読めるようにする ---- */
static struct termios orig_term;

static void restore_term(void)
{
    tcsetattr(STDIN_FILENO, TCSANOW, &orig_term);
}

static void raw_term(void)
{
    tcgetattr(STDIN_FILENO, &orig_term);
    struct termios t = orig_term;
    t.c_lflag &= ~(ICANON | ECHO);      /* 行編集・エコーを切る */
    t.c_cc[VMIN]  = 0;                   /* 入力が無ければ即戻る */
    t.c_cc[VTIME] = 0;
    tcsetattr(STDIN_FILENO, TCSANOW, &t);
    /* 標準入力を非ブロッキングに */
    int fl = fcntl(STDIN_FILENO, F_GETFL);
    fcntl(STDIN_FILENO, F_SETFL, fl | O_NONBLOCK);
}

/* 押されているキーを1つ返す(無ければ 0) */
static int get_key(void)
{
    unsigned char c;
    if (read(STDIN_FILENO, &c, 1) == 1) return c;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "使い方: %s <生PCMファイル> [スペクトル送信先パソコンIP]\n", argv[0]);
        return 1;
    }

    FILE *fp = fopen(argv[1], "rb");
    if (!fp) { perror("音声ファイルを開けない"); return 1; }

    fseek(fp, 0, SEEK_END);
    long fsize = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    long total = fsize / 4;          /* ステレオ: 1組=左右2標本=4バイト */
    printf("ファイル : %s\n", argv[1]);
    printf("左右組数 : %ld\n", total);
    printf("再生時間 : %.1f 秒\n", total / FS);

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem を開けない (sudo で実行すること)"); return 1; }

    regs = (volatile uint32_t *)mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE,
                                     MAP_SHARED, fd, BASE_ADDR);
    if (regs == MAP_FAILED) { perror("mmap 失敗"); return 1; }

    /* ---- スペクトルをパソコンへ送る(引数2でIP指定時) ---- */
    if (argc >= 3) {
        g_sock = socket(AF_INET, SOCK_DGRAM, 0);
        memset(&g_dest, 0, sizeof(g_dest));
        g_dest.sin_family = AF_INET;
        g_dest.sin_port   = htons(50007);
        inet_pton(AF_INET, argv[2], &g_dest.sin_addr);
        printf("スペクトルを %s:50007 へ送信します\n", argv[2]);
    }

    /* ---- 自己診断: レジスタの読み書きができるか調べる ---- */
    printf("\n--- 自己診断 ---\n");
    reg_write(REG_CTRL, 1);
    uint32_t ctrl_back = reg_read(REG_CTRL);
    uint32_t st0       = reg_read(REG_STATUS);
    printf("CTRL に 1 を書いて読み戻し : 0x%08X %s\n",
           ctrl_back, (ctrl_back & 1) ? "(読み出し成功)" : "(読み出せていない)");
    printf("STATUS 生の値              : 0x%08X\n", st0);

    /* 数組書いてから溜まり具合が増えるか見る */
    for (int i = 0; i < 100; i++) reg_write(REG_DATA, 0);
    uint32_t st1 = reg_read(REG_STATUS);
    printf("100組書いた後の STATUS     : 0x%08X  溜まり=%u\n",
           st1, (st1 >> 16) & 0x3FFF);

    int status_ok = (ctrl_back & 1) ? 1 : 0;
    printf("速度の調整方法             : %s\n",
           status_ok ? "満杯を見て待つ" : "時計で刻む(予備)");
    printf("----------------\n\n");

    /* ---- 再生 ---- */
    raw_term();
    reg_write(REG_CTRL, 1);
    printf("再生開始   [f=10秒送り  b=10秒戻し  q=終了]\n");

    int16_t buf[CHUNK * 2];             /* 左右インターリーブ L,R,L,R... */
    long played = 0;                    /* これまでに送った左右組数(=ファイル位置) */
    size_t n;
    double t_start = now_sec();
    long seek_step = (long)(SEEK_SEC * FS);  /* 10秒ぶんの組数 */

    while ((n = fread(buf, 4, CHUNK, fp)) > 0) {   /* n = 読めた組数 */
        for (size_t i = 0; i < n; i++) {
            if (status_ok) {
                /* 満杯の間は待つ */
                while (reg_read(REG_STATUS) & ST_FULL) usleep(500);
            }
            /* [31:16]=左, [15:0]=右 にまとめて1回で書く */
            uint32_t lr = ((uint32_t)(uint16_t)buf[2 * i]     << 16)
                        |  (uint32_t)(uint16_t)buf[2 * i + 1];
            reg_write(REG_DATA, lr);
        }
        played += n;

        if (!status_ok) {
            /* 時計で刻む: 本来この時刻になるまで待つ */
            double target  = played / FS;
            double elapsed = now_sec() - t_start;
            double wait    = target - elapsed;
            if (wait > 0) usleep((useconds_t)(wait * 1e6));
        }

        /* ---- キー操作: 早送り・巻き戻し・終了 ---- */
        int key = get_key();
        if (key == 'q') {
            break;
        } else if (key == 'f' || key == 'b') {
            long np = (key == 'f') ? played + seek_step : played - seek_step;
            if (np < 0)     np = 0;
            if (np > total) np = total;
            fseek(fp, np * 4, SEEK_SET);    /* 1組=4バイト */
            played  = np;
            t_start = now_sec() - played / FS;   /* 経過表示を位置に合わせる */
        }

        /* PL の FFT結果を読んでパソコンへ送る */
        read_send_fft(played / FS, total / FS);
    }

    if (status_ok) {
        while (!(reg_read(REG_STATUS) & ST_EMPTY)) usleep(10000);
    }
    reg_write(REG_CTRL, 0);
    restore_term();
    printf("\n再生終了\n");

    fclose(fp);
    munmap((void *)regs, MAP_SIZE);
    close(fd);
    return 0;
}
