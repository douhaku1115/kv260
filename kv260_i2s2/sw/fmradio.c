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
#define REG_DMA_CTRL 0xD0              /* bit0=開始 bit1=繰返 bit2=FM復調 [15:8]=FM音量 */
#define REG_DMA_STAT 0xE0

/* ★IQ のサンプリング速度 = 48828 × 5
 *   広く取り込むほど不要な雑音が復調器に入る。FM 放送は ±100kHz 程度なので、
 *   244140Hz（±122kHz）に絞ると RTL-SDR 内蔵のフィルタが帯域を制限してくれる。
 *   976560Hz（±488kHz）だと雑音を約5倍取り込むことになる。
 *   ※ 出力 48828Hz の整数倍にすること（端数があると間引きで歪む）*/
#define IQ_RATE      244140            /* IQ のサンプリング速度（48828×5）*/
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

    /* PL に FM 復調させる: bit0=開始 bit1=繰返 bit2=FM復調 [15:8]=FM音量 */
    wr(REG_DMA_ADDR, BUF_PHYS);
    wr(REG_DMA_LEN,  (uint32_t)(got * 4));
    wr(REG_DMA_CTRL, (0x40 << 8) | 0x7);

    printf("PL で FM 復調して再生中（繰り返し）\n");
    printf("停止: sudo devmem 0xA00000D0 32 0\n");
    printf("FM音量の変更例: sudo devmem 0xA00000D0 32 0x8007\n");
    printf("DMA_STAT = 0x%08X\n", rd(REG_DMA_STAT));

    munmap(buf, bytes);
    munmap((void *)regs, REG_SIZE);
    close(fd);
    return 0;
}
