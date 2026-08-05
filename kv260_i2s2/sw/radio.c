/* ---------------------------------------------------------------------------
 * radio.c -- RTL-SDR で受けた FM 放送を Pmod I2S2 で鳴らす
 *
 *   内部で rtl_fm を起動し、その出力（16bit モノラル）を PL の FIFO に
 *   流し込み続ける。既定の周波数は 87.2MHz（舞鶴で最も強い局）。
 *
 *   使い方:
 *     gcc -O2 -o radio radio.c -lm
 *     sudo ./radio                    # 87.2MHz を鳴らす
 *     sudo ./radio 84.5M              # 周波数を指定
 *     sudo ./radio 87.2M 192.168.0.14 # スペクトルもパソコンへ送る
 *
 *   ※ 事前に PL を用意しておくこと:
 *        sudo fpgautil -b ~/stream.bit
 *        sudo devmem 0xFF5E00C0 32 0x01010A00
 *
 *   周波数の探し方（電波の強い所を掃引で調べる）:
 *     sudo rtl_power -f 76M:95M:100k -g 30 -i 5 -1 scan.csv
 * ------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define BASE_ADDR   0xA0000000UL
#define MAP_SIZE    0x1000UL

#define REG_DATA    0x00
#define REG_STATUS  0x10
#define REG_CTRL    0x20
#define REG_GAIN    0x30
#define REG_ECHO    0x40
#define REG_BASS    0x50
#define REG_TREBLE  0x60
#define REG_DIST    0x70
#define REG_FBIN    0x80
#define REG_FRE     0x90
#define REG_FIM     0xA0

/* FM 放送向けの音質設定（段10 のイコライザ）
 *   デエンファシス（50µs）を deemphasis() で正しく掛けるので、
 *   イコライザは素通し（等倍）を既定とする。
 *   以前は 75µs のデエンファシス＋高音カット 0x20 で二重にこもらせていた。
 *   聞きながら調整するときは devmem 0xA0000050（低音）/0x60（高音）で変える。 */
#define FM_GAIN     0x40            /* 音量 等倍 */
#define FM_BASS     0x40            /* 低音 等倍 */
#define FM_TREBLE   0x40            /* 高音 等倍 */

#define ST_FULL     0x1
#define CHUNK       1024            /* 一度に読む標本数 */
#define NBIN        256             /* PL FFT の片側ビン数 */
#define FS          48828.125

/* 既定の周波数。舞鶴で受かる局:
 *   84.2M = NHK-FM（舞鶴中継局）
 *   87.2M = 別の局（掃引では最強）
 * 周波数の探し方: sudo rtl_power -f 76M:95M:100k -g 30 -i 5 -1 scan.csv */
#define DEFAULT_FREQ "84.2M"

static volatile uint32_t *regs;
static inline void reg_write(int off, uint32_t v) { regs[off / 4] = v; }
static inline uint32_t reg_read(int off)          { return regs[off / 4]; }

static int g_sock = -1;
static struct sockaddr_in g_dest;

/* ---- デエンファシス（日本仕様 50µs）----
 *   FM 放送は送信時に高音を持ち上げてから送る（プリエンファシス）。
 *   受信側で同じ量だけ下げないと、シャリついた音になる。
 *
 *   1次ローパス:  y += α × (x - y)
 *     α = 1 - exp(-1 / (fs × τ))
 *     fs = 48828.125、τ = 50µs（日本）→ α ≒ 0.336
 *
 *   整数演算にするため α × 256 = 86 を使う。
 *   ※ 米国は τ = 75µs。rtl_fm の -E deemp はこちらなので使わない。
 */
#define DEEMP_A  86                 /* α × 256（50µs @ 48828Hz）*/
static int32_t deemp_y = 0;

static inline int16_t deemphasis(int16_t x)
{
    deemp_y += (((int32_t)x - deemp_y) * DEEMP_A) >> 8;
    return (int16_t)deemp_y;
}

/* ---- 高域通過フィルタ（30Hz より下を切る）----
 *   FM を復調した波形には直流成分と数Hz〜数十Hz のうねりが大きく乗る。
 *   実測（fm.raw の周波数分布）では 0〜300Hz だけで全パワーのほぼ全部を
 *   占めており、0Hz が最大、11.9Hz が -6dB という状態だった。
 *   これがゴロゴロという低域雑音の正体で、gqrx は必ず切っている。
 *
 *   1次の高域通過:  y[n] = x[n] - x[n-1] + a × y[n-1]
 *     a = exp(-2π × 30 / 48828) ≒ 0.99615
 *   整数演算にするため a × 65536 = 65283 を使う。 */
#define HP_A  65283                 /* a × 65536（30Hz @ 48828Hz）*/
static int32_t hp_x1 = 0, hp_y1 = 0;

static inline int16_t highpass(int16_t x)
{
    int32_t y = (int32_t)x - hp_x1 + (int32_t)(((int64_t)hp_y1 * HP_A) >> 16);
    hp_x1 = x;
    if (y >  32767) y =  32767;
    if (y < -32768) y = -32768;
    hp_y1 = y;
    return (int16_t)y;
}

/* ---- 低域通過フィルタ（15kHz より上を切る、63タップ FIR）----
 *   FM 放送の信号には音声(〜15kHz)のほかに 19kHz のパイロット信号
 *   （ステレオ放送の目印）が乗っている。実測でも 18〜20kHz が周囲より
 *   12dB 高かった。人の耳には聞こえないが、そのまま増幅段に入れると
 *   混変調で可聴帯域に歪みを生む。
 *
 *   係数は窓関数法（sinc × ハミング窓）で設計し、32768 倍して整数化した。
 *   実測の減衰量:  13kHz 0dB / 15kHz -6dB / 17kHz -60dB / 19kHz -56dB
 *
 *   積和は 63 個 × 48828 回/秒 = 約 308 万回/秒。Cortex-A53 では軽い。
 *   途中の合計が 32bit を超えるので 64bit で受けること。 */
#define LP_N  63
static const int16_t LP_H[LP_N] = {
        -4,    28,   -17,   -22,    44,    -4,   -61,    59,
        41,  -122,    44,   138,  -178,   -45,   284,  -171,
      -246,   431,   -21,  -560,   484,   357,  -948,   294,
      1073, -1329,  -441,  2487, -1609, -3400,  9737, 20122,
      9737, -3400, -1609,  2487,  -441, -1329,  1073,   294,
      -948,   357,   484,  -560,   -21,   431,  -246,  -171,
       284,   -45,  -178,   138,    44,  -122,    41,    59,
       -61,    -4,    44,   -22,   -17,    28,    -4
};
static int16_t lp_z[LP_N];          /* 過去の標本を置く輪（循環バッファ）*/
static int     lp_pos = 0;

static inline int16_t lowpass(int16_t x)
{
    lp_z[lp_pos] = x;

    int64_t acc = 0;
    int     idx = lp_pos;
    for (int k = 0; k < LP_N; k++) {
        acc += (int32_t)LP_H[k] * (int32_t)lp_z[idx];
        idx  = (idx == 0) ? (LP_N - 1) : (idx - 1);
    }
    lp_pos = (lp_pos + 1 == LP_N) ? 0 : (lp_pos + 1);

    int32_t y = (int32_t)(acc >> 15);       /* 係数は 32768 倍してある */
    if (y >  32767) y =  32767;
    if (y < -32768) y = -32768;
    return (int16_t)y;
}

/* PL の FFT 結果を読んでパソコンへ送る（段9 と同じ）
 *
 *   ★送り先が無いときは何もしないこと
 *     以前は判定が関数の最後にあり、パソコンの IP を指定していなくても
 *     毎秒 1024 回のレジスタ読み書きと 256 回の平方根計算が走っていた。
 *     その間 FIFO への供給が止まるので、1秒ごとにプチッと音が途切れていた。 */
static void send_spectrum(void)
{
    if (g_sock < 0) return;                       /* 送り先が無いなら即やめる */

    static float mag[NBIN];
    for (int k = 0; k < NBIN; k++) {
        reg_write(REG_FBIN, (uint32_t)k);
        (void)reg_read(REG_FRE);                  /* ダミー読み */
        int32_t re = (int32_t)reg_read(REG_FRE);
        int32_t im = (int32_t)reg_read(REG_FIM);
        mag[k] = sqrtf((float)re * re + (float)im * im);
    }
    sendto(g_sock, mag, sizeof(mag), 0,
           (struct sockaddr *)&g_dest, sizeof(g_dest));
}

/* ---- FIFO へ 1 標本書く（状態の読みすぎを避ける）----
 *   以前は 1 標本ごとに STATUS を読んでいた。48828 回/秒 の AXI 読みは
 *   それ自体が重く、rtl_fm からの読み取りを圧迫していた。
 *
 *   STATUS の bit[29:16] に FIFO の残量が入っている（全 8192 段）。
 *   一度読んで「あと何個書けるか」を覚えておき、その分は状態を読まずに
 *   書き込む。使い切ったら読み直す。これで AXI アクセスが大幅に減る。
 *
 *   MARGIN は安全のために残す余白。0 まで使い切らないようにする。 */
#define FIFO_DEPTH  8192
#define MARGIN      64

static int fifo_space = 0;                        /* あと何個書けるか */

static inline void fifo_put(uint32_t v)
{
    while (fifo_space <= 0) {
        uint32_t st  = reg_read(REG_STATUS);
        int      cnt = (st >> 16) & 0x3FFF;       /* 今 FIFO に溜まっている数 */
        fifo_space = FIFO_DEPTH - cnt - MARGIN;
        if (fifo_space <= 0) usleep(200);         /* 満杯に近いので少し待つ */
    }
    reg_write(REG_DATA, v);
    fifo_space--;
}

int main(int argc, char **argv)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem を開けない (sudo で実行すること)"); return 1; }

    regs = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, BASE_ADDR);
    if (regs == MAP_FAILED) { perror("mmap 失敗"); return 1; }

    /* 引数1 = 周波数（省略時は既定値）、引数2 = スペクトル送信先のパソコン IP */
    const char *freq = (argc >= 2) ? argv[1] : DEFAULT_FREQ;

    if (argc >= 3) {
        g_sock = socket(AF_INET, SOCK_DGRAM, 0);
        memset(&g_dest, 0, sizeof(g_dest));
        g_dest.sin_family = AF_INET;
        g_dest.sin_port   = htons(50007);
        inet_pton(AF_INET, argv[2], &g_dest.sin_addr);
        fprintf(stderr, "スペクトルを %s:50007 へ送ります\n", argv[2]);
    }

    /* rtl_fm を内部で起動し、その出力を読む */
    char cmd[256];
    /* ★サンプリング速度は「出力の整数倍」かつ「広げすぎない」こと
     *   ・整数倍にする理由: rtl_fm は整数比でしか間引けない。200k → 48828 は
     *     4.096 倍で割り切れず、その端数が歪み・ノイズになる。
     *   ・広げすぎない理由: rtl_fm は復調の前に平均化フィルタで間引く。
     *     976560(=48828×20) だと復調前が 2 サンプル平均でほぼ効かず、
     *     ±488kHz の雑音が全部復調器に入る。FM 放送は ±100kHz 程度なので、
     *     244140(=48828×5) にすると帯域が ±122kHz に絞られ、
     *     復調前の平均も 5 サンプルになって効くようになる。
     * ★-E deemp は使わない
     *   rtl_fm のデエンファシスは 75µs（米国仕様）。日本は 50µs なので
     *   高音を落としすぎて音がこもる。代わりに下の deemphasis() で
     *   日本仕様の 50µs を自前で掛ける。 */
    /* ★チューナーのゲインは固定すること（-g 30）
     *   既定は自動（AGC）だが、実測すると自動は雑音が多い。
     *   87.2MHz を 20 秒ずつ録音して 20〜24kHz（音声の無い帯域）の
     *   雑音床を測った結果:
     *       -g 30 : 88.0dB  信号との差 39.8dB  ← 最良
     *       -g 20 : 88.5dB              38.7dB
     *       -g 40 : 87.1dB              36.2dB
     *       自動   : 90.2dB              33.6dB
     *       -g 49 : 92.9dB              31.8dB  ← 最大ゲインは最悪
     *   自動に対して約 5dB 改善する。
     *
     * ★-F 9（高品質FIR）は使わない
     *   名前に反して実測では雑音が 3〜6dB 増えた（91.8〜94.5dB）。
     * ★-s は 244140 のまま
     *   195312（±98kHz）に狭めると逆に悪化した（93.4dB）。 */
    snprintf(cmd, sizeof(cmd),
             "rtl_fm -f %s -M wbfm -s 244140 -r 48828 -g 30 - 2>/dev/null", freq);
    FILE *sdr = popen(cmd, "r");
    if (!sdr) { perror("rtl_fm を起動できない"); return 1; }

    /* 音質設定（ノイズが高域に多いので高音を下げる） */
    reg_write(REG_GAIN,   FM_GAIN);
    reg_write(REG_BASS,   FM_BASS);
    reg_write(REG_TREBLE, FM_TREBLE);
    reg_write(REG_DIST,   0);       /* 歪みは無効 */
    reg_write(REG_ECHO,   0);       /* エコーは無効 */
    reg_write(REG_CTRL,   1);       /* 再生有効 */
    fprintf(stderr, "%s を受信中... (Ctrl+C で終了)\n", freq);
    fprintf(stderr, "音質: 低音=0x%02X 高音=0x%02X (devmem 0xA0000050/0x60 で変更可)\n",
            FM_BASS, FM_TREBLE);

    int16_t buf[CHUNK];
    long total = 0;
    size_t n;

    /* rtl_fm から読めるだけ読んで、そのまま FIFO へ流し続ける */
    while ((n = fread(buf, 2, CHUNK, sdr)) > 0) {
        for (size_t i = 0; i < n; i++) {
            /* 処理の順番
             *   1. 高域通過  : 直流と超低域のうねりを落とす（雑音対策）
             *   2. デエンファシス: 送信側で持ち上げられた高音を戻す（50µs）
             *   3. 低域通過  : 15kHz より上（19kHz パイロット）を落とす */
            int16_t  s  = highpass(buf[i]);
            s = deemphasis(s);
            s = lowpass(s);
            uint32_t v  = (uint32_t)(uint16_t)s;
            fifo_put((v << 16) | v);                              /* 左右同じ値 */
        }
        total += n;

        /* 1秒ごとにスペクトル送信と表示 */
        static long last = 0;
        if (total - last >= 48828) {
            last = total;
            send_spectrum();
            fprintf(stderr, "\r受信 %.0f 秒", total / FS);
        }
    }

    reg_write(REG_CTRL, 0);
    pclose(sdr);
    fprintf(stderr, "\n終了\n");
    return 0;
}
