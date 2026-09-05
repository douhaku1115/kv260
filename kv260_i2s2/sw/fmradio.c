/* ---------------------------------------------------------------------------
 * fmradio.c -- FM 復調を PL(FPGA)で行うラジオ（段12 段階A）
 *
 *   radio.c は PS 側の rtl_fm が復調していた。ここでは rtl_sdr で IQ（複素数の
 *   生データ）をそのまま取り込み、**PL に載せた自作 FM 復調器**で音声にする。
 *
 *   【流れ】
 *     rtl_sdr（IQ生データ）→ PS が DDR(0x60000000)へ書く
 *                              → PL が DMA で読む → fm_demod → FIFO → I2S
 *
 *   【rtl_sdr の出力形式】
 *     符号なし8ビットの I, Q が交互（I,Q,I,Q...）。中心は 128。
 *     PL の復調器は符号付き16ビットを期待するので、PS 側で
 *       (値 - 128) << 6   ← 8ビット→16ビットに広げる
 *     の変換をして DDR に置く。1 組 = I(16bit) + Q(16bit) = 4 バイト。
 *
 *   使い方:
 *     gcc -O2 -o fmradio fmradio.c
 *     sudo ./fmradio               # 84.2MHz (NHK-FM 舞鶴)
 *     sudo ./fmradio 87.2M
 *
 *   ※ 事前に PL を用意しておくこと:
 *       sudo fpgautil -b ~/stream.bit
 *       sudo devmem 0xFF5E00C0 32 0x01010A00
 * ------------------------------------------------------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>              /* atan2/tan/log10（コンパイル時 -lm が要る） */
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define REG_BASE     0xA0000000UL
#define REG_SIZE     0x1000UL
#define BUF_PHYS     0x60000000UL      /* PL 専用メモリ（Linux 管理外） */

#define REG_CTRL     0x20
#define REG_GAIN     0x30
#define REG_BASS     0x50
#define REG_TREBLE   0x60
#define REG_DIST     0x70
#define REG_DMA_ADDR 0xB0
#define REG_DMA_LEN  0xC0
#define REG_DMA_CTRL 0xD0              /* bit0=開始 bit1=繰返 bit2=FM復調
                                          bit3=ステレオ許可 [15:8]=FM音量 */
#define REG_DMA_STAT 0xE0              /* bit2 = パイロットにロック中 */
#define REG_PILOT    0x100             /* 19kHz パイロットの強さ */
#define REG_PQUAD    0x110             /* PLL の直交成分（位相が合えば 0） */
#define REG_DLEVEL   0x120             /* L−R の平均振幅 */
#define REG_SLEVEL   0x130             /* L+R の平均振幅 */

/* ★IQ のサンプリング速度 = 48828 × 20
 *
 *   一度 244140（48828×5）に下げたが、これは誤りだった。
 *   PL の復調器（fm_demod.v）は sin(Δφ) ≒ Δφ の近似を使っており、
 *     Δφ = 2π × 75000 / fs
 *   なので fs を下げると Δφ が開く。244140Hz では 110°になり、
 *   90°を超えて sin が減少に転じるため強く歪む。
 *
 *   「雑音を取り込みすぎる」問題は正しいが、対策は**レートを下げること
 *   ではなく帯域を絞ること**。fm_demod.v の中で、間引かずに
 *   4点移動平均×3段を掛けて ±122kHz に制限している。
 *
 *   ※ 出力 48828Hz の整数倍にすること（端数があると間引きで歪む）*/
#define IQ_RATE      976560            /* IQ のサンプリング速度（48828×20）*/
#define SECONDS      20                /* 取り込む秒数 */
#define DEFAULT_FREQ "84.2M"           /* NHK-FM 舞鶴 */

static volatile uint32_t *regs;
static inline void wr(int off, uint32_t v) { regs[off / 4] = v; }
static inline uint32_t rd(int off)         { return regs[off / 4]; }

int main(int argc, char **argv)
{
    const char *freq = (argc >= 2) ? argv[1] : DEFAULT_FREQ;

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem を開けない (sudo で実行すること)"); return 1; }

    regs = mmap(NULL, REG_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, REG_BASE);
    if (regs == MAP_FAILED) { perror("レジスタの mmap 失敗"); return 1; }

    /* 取り込む量: 1 組 4 バイト（I16+Q16） */
    size_t pairs = (size_t)IQ_RATE * SECONDS;
    size_t bytes = pairs * 4;
    printf("周波数   : %s\n", freq);
    printf("取り込み : %d 秒 (%.1f MB)\n", SECONDS, bytes / 1048576.0);

    void *buf = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, BUF_PHYS);
    if (buf == MAP_FAILED) { perror("PL専用メモリの mmap 失敗"); return 1; }

    /* rtl_sdr を起動して IQ を受け取る */
    char cmd[256];
    snprintf(cmd, sizeof(cmd), "rtl_sdr -f %s -s %d -g 40 - 2>/dev/null",
             freq, IQ_RATE);
    FILE *sdr = popen(cmd, "r");
    if (!sdr) { perror("rtl_sdr を起動できない"); return 1; }

    /* 8ビット符号なし → 16ビット符号付きに変換しながら DDR へ */
    printf("IQ を取り込み中...\n");
    int16_t  *dst = (int16_t *)buf;
    uint8_t   raw[8192];
    size_t    got = 0;
    while (got < pairs) {
        size_t n = fread(raw, 1, sizeof(raw), sdr);
        if (n == 0) break;
        for (size_t i = 0; i + 1 < n && got < pairs; i += 2, got++) {
            dst[got * 2 + 0] = ((int16_t)raw[i]     - 128) << 6;   /* I */
            dst[got * 2 + 1] = ((int16_t)raw[i + 1] - 128) << 6;   /* Q */
        }
        if (got % (IQ_RATE) < 4096)
            printf("\r%.0f / %d 秒", (double)got / IQ_RATE, SECONDS), fflush(stdout);
    }
    pclose(sdr);
    printf("\n取り込み完了 (%zu 組)\n", got);

    /* ---- ★DC 成分の除去 ----
     *   RTL-SDR は局部発振器の漏れにより、同調周波数の真上に強い直流成分
     *   （DC スパイク）が出る。IQ に一定のベクトルが加わった状態になり、
     *   位相の読み取りが狂って雑音・歪みの原因になる。
     *
     *   rtl_fm はこれを避けるため、指定周波数から 316kHz ずらして同調し
     *   （オフセット同調）、内部で戻している。rtl_sdr にその機能は無いので、
     *   ここで I・Q それぞれの平均値を引いて直流成分を取り除く。
     *
     *   FM 信号は本来ぐるぐる回るので平均するとゼロになる。
     *   残った平均＝直流成分（DC スパイク）と見なせる。 */
    if (got > 0) {
        int64_t sum_i = 0, sum_q = 0;
        for (size_t j = 0; j < got; j++) {
            sum_i += dst[j * 2 + 0];
            sum_q += dst[j * 2 + 1];
        }
        int16_t dc_i = (int16_t)(sum_i / (int64_t)got);
        int16_t dc_q = (int16_t)(sum_q / (int64_t)got);
        printf("DC 成分: I=%d Q=%d （これを引きます）\n", dc_i, dc_q);
        for (size_t j = 0; j < got; j++) {
            dst[j * 2 + 0] -= dc_i;
            dst[j * 2 + 1] -= dc_q;
        }
    }

    /* 音質設定
     *   PL 側（fm_demod.v）で 50µs のデエンファシスを正しく掛けるので、
     *   イコライザは素通し（等倍）にする。
     *   聞きながら調整するときは devmem 0xA0000050（低音）/0x60（高音）で変える。 */
    wr(REG_GAIN,   0x40);       /* 音量 等倍 */
    wr(REG_BASS,   0x40);       /* 低音 等倍 */
    wr(REG_TREBLE, 0x40);       /* 高音 等倍 */
    wr(REG_DIST,   0);
    wr(REG_CTRL,   1);

    /* PL に FM 復調させる
     *   bit0=開始 bit1=繰返 bit2=FM復調 bit3=ステレオ許可 [15:8]=FM音量
     *
     *   ★bit3 を立てないとモノラルのままになる。
     *     PL は 19kHz パイロットを見て自動でステレオ/モノラルを切り替えるので、
     *     モノラル放送や弱電界でも bit3 は立てたままでよい。
     *     雑音がひどくて強制的にモノラルにしたいときだけ 0 にする。*/
    wr(REG_DMA_ADDR, BUF_PHYS);
    wr(REG_DMA_LEN,  (uint32_t)(got * 4));
    wr(REG_DMA_CTRL, (0x40 << 8) | 0xF);

    printf("PL で FM ステレオ復調して再生中（繰り返し）\n");
    printf("停止: sudo devmem 0xA00000D0 32 0\n");
    printf("FM音量の変更例: sudo devmem 0xA00000D0 32 0x800F\n");
    printf("強制モノラル:   sudo devmem 0xA00000D0 32 0x4007\n");
    printf("診断(L-Rを聞く): sudo devmem 0xA00000D0 32 0x401F\n");
    printf("  → 音楽なら本物のL-R / ピーなら折り返し / サーッなら雑音\n");

    /* パイロットの状態を見る。ロックまで約 40ms かかるので少し待つ。
     *   強さはしきい値 400 と比べる。実機で小さすぎるようなら
     *   stereo_pll.v の PILOT_TH を下げること。*/
    usleep(200000);
    printf("DMA_STAT = 0x%08X  (bit2=パイロットロック)\n", rd(REG_DMA_STAT));
    printf("パイロット強度 = %d  (しきい値 400)\n", (int)rd(REG_PILOT));
    printf("ステレオ判定: %s\n", (rd(REG_DMA_STAT) & 0x4) ? "ステレオ" : "モノラル");

    /* ---- 切り分け用の計測を 2 秒おきに 5 回表示 ----
     *   音を聞いても「位相が悪い」のか「L−R が無い」のか分からないので数字で見る。
     *
     *   位相誤差 = atan(PQUAD / PILOT)。38kHz 側ではその 2 倍が効き、
     *   分離度の上限は 20*log10(1/tan(2*位相誤差)) [dB]。
     *
     *   D/S は L−R と L+R の比。ステレオの音楽なら 0.2〜0.8 くらいになる。
     *   0.05 を切るなら L−R が取れていない。 */
    for (int k = 0; k < 5; k++) {
        int32_t quad  = (int32_t)rd(REG_PQUAD);
        int32_t pilot = (int32_t)rd(REG_PILOT);
        int32_t dlv   = (int32_t)rd(REG_DLEVEL);
        int32_t slv   = (int32_t)rd(REG_SLEVEL);
        double  perr  = (pilot != 0) ? atan2((double)quad, (double)pilot) : 0.0;
        double  deg   = perr * 180.0 / 3.14159265358979;
        double  t2    = tan(2.0 * perr);
        double  lim   = (t2 != 0.0) ? 20.0 * log10(1.0 / fabs(t2)) : 99.0;
        printf("  パイロット %5d  直交 %6d  位相誤差 %6.2f 度 (分離度上限 %.0f dB)"
               "   S=%6d D=%6d  D/S=%.3f\n",
               pilot, quad, deg, lim, slv, dlv,
               (slv != 0) ? (double)dlv / (double)slv : 0.0);
        sleep(2);
    }

    munmap(buf, bytes);
    munmap((void *)regs, REG_SIZE);
    close(fd);
    return 0;
}
