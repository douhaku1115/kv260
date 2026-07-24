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

/* ---- スペクトル: 音ブロックを FFT してパソコンへ送る ---- */
#define NFFT   8192                 /* FFT点数（分解能 ≒ 48828/8192 ≒ 5.96Hz） */
#define NSEND  840                  /* 送る低域ビン数（0〜約5000Hz） */

/* 反復 radix-2 FFT（その場計算） */
static void fft(float *re, float *im)
{
    int n = NFFT;
    for (int i = 1, j = 0; i < n; i++) {
        int bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) {
            float t;
            t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }
    for (int len = 2; len <= n; len <<= 1) {
        double ang = -2.0 * M_PI / len;
        float wr = cosf(ang), wi = sinf(ang);
        for (int i = 0; i < n; i += len) {
            float cr = 1, ci = 0;
            for (int k = 0; k < len / 2; k++) {
                float xr = re[i+k+len/2] * cr - im[i+k+len/2] * ci;
                float xi = re[i+k+len/2] * ci + im[i+k+len/2] * cr;
                re[i+k+len/2] = re[i+k] - xr;
                im[i+k+len/2] = im[i+k] - xi;
                re[i+k] += xr;
                im[i+k] += xi;
                float ncr = cr * wr - ci * wi;
                ci = cr * wi + ci * wr;
                cr = ncr;
            }
        }
    }
}

/* スペクトル送信先(パソコン)。argv[2] で IP を指定されたら有効 */
static int g_sock = -1;
static struct sockaddr_in g_dest;

/* 左ch標本(NFFT点)を FFT し、低域NSENDビンの振幅をパソコンへ UDP 送信する */
static void fft_send(const int16_t *mono, double sec, double total_sec)
{
    static float re[NFFT], im[NFFT];
    for (int i = 0; i < NFFT; i++) {
        float w = 0.5f - 0.5f * cosf(2.0f * M_PI * i / (NFFT - 1)); /* Hann窓 */
        re[i] = mono[i] * w;
        im[i] = 0.0f;
    }
    fft(re, im);

    static float mag[NSEND];
    for (int k = 0; k < NSEND; k++)
        mag[k] = sqrtf(re[k] * re[k] + im[k] * im[k]);

    if (g_sock >= 0)
        sendto(g_sock, mag, sizeof(mag), 0,
               (struct sockaddr *)&g_dest, sizeof(g_dest));

    printf("\r再生 %3.0f / %3.0f 秒", sec, total_sec);
    fflush(stdout);
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
    static int16_t accbuf[NFFT];        /* FFT用に左chを NFFT点ためる */
    int     accn = 0;
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

        /* 左chを NFFT 点ためて、たまるごとに FFT して送信 */
        for (size_t i = 0; i < n; i++) {
            accbuf[accn++] = buf[2 * i];
            if (accn >= NFFT) {
                fft_send(accbuf, played / FS, total / FS);
                accn = 0;
            }
        }
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
