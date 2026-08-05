/* ---------------------------------------------------------------------------
 * playraw.c -- 録音済みの生音声(fm.raw)を FIFO に流して鳴らす（切り分け用）
 *
 *   radio.c は rtl_fm を裏で走らせながらリアルタイムに FIFO へ流し込む。
 *   そのため「USB の取りこぼし」「パイプの詰まり」「rtl_fm の遅れ」といった
 *   リアルタイム要因が混ざり、プチプチ音の原因を特定できない。
 *
 *   このプログラムは入力をファイル(fm.raw)に差し替えただけのもの。
 *   FIFO への書き込み方・音質設定は radio.c と全く同じにしてある。
 *
 *   【判定】
 *     プチプチが出る   → 原因は PL 側か、この書き込みループ
 *     プチプチが出ない → 原因は rtl_fm のリアルタイム供給側
 *
 *   fm.raw の作り方:
 *     sudo timeout 10 rtl_fm -f 84.2M -M wbfm -s 244140 -r 48828 - 2>/dev/null > fm.raw
 *
 *   使い方:
 *     gcc -O2 -o playraw playraw.c
 *     sudo ./playraw              # fm.raw を繰り返し再生
 *     sudo ./playraw fm.raw 1     # 1回だけ再生
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
#include <sys/mman.h>

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

#define ST_FULL     0x1
#define ST_EMPTY    0x2

/* radio.c と同じ設定にしておく（比較のため） */
#define FM_GAIN     0x40
#define FM_BASS     0x40
#define FM_TREBLE   0x40

#define FS          48828.125

/* ---- デエンファシス（日本仕様 50µs）: radio.c と同一 ---- */
#define DEEMP_A  86
static int32_t deemp_y = 0;

static inline int16_t deemphasis(int16_t x)
{
    deemp_y += (((int32_t)x - deemp_y) * DEEMP_A) >> 8;
    return (int16_t)deemp_y;
}

static volatile uint32_t *regs;
static inline void reg_write(int off, uint32_t v) { regs[off / 4] = v; }
static inline uint32_t reg_read(int off)          { return regs[off / 4]; }

int main(int argc, char **argv)
{
    const char *path = (argc >= 2) ? argv[1] : "fm.raw";
    int loop = (argc >= 3) ? 0 : 1;      /* 引数3つ目があれば1回だけ */

    /* ---- ファイルを丸ごと読む ---- */
    FILE *fp = fopen(path, "rb");
    if (!fp) { perror("fm.raw を開けない"); return 1; }
    fseek(fp, 0, SEEK_END);
    long bytes = ftell(fp);
    fseek(fp, 0, SEEK_SET);

    long n = bytes / 2;                  /* 16bit モノラル */
    int16_t *buf = malloc(n * 2);
    if (!buf) { perror("メモリ確保できない"); return 1; }
    if (fread(buf, 2, n, fp) != (size_t)n) { perror("読み込み失敗"); return 1; }
    fclose(fp);

    printf("%s : %ld 標本 (%.2f 秒)\n", path, n, n / FS);

    /* ---- レジスタを開く ---- */
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("/dev/mem を開けない (sudo で実行すること)"); return 1; }

    regs = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, BASE_ADDR);
    if (regs == MAP_FAILED) { perror("mmap 失敗"); return 1; }

    reg_write(REG_GAIN,   FM_GAIN);
    reg_write(REG_BASS,   FM_BASS);
    reg_write(REG_TREBLE, FM_TREBLE);
    reg_write(REG_DIST,   0);
    reg_write(REG_ECHO,   0);
    reg_write(REG_CTRL,   1);            /* 再生有効 */

    printf("再生中... (Ctrl+C で終了)\n");
    printf("音量の変更例: sudo devmem 0xA0000030 32 0x20\n");

    /* ---- FIFO へ流す（radio.c と同じ書き方）----
     *   ついでに「FIFO が空になった回数」を数える。
     *   これが増えるなら供給が間に合っていない＝プチプチの原因。 */
    long empty_cnt = 0;
    long played = 0;

    do {
        for (long i = 0; i < n; i++) {
            uint32_t st;
            while ((st = reg_read(REG_STATUS)) & ST_FULL) usleep(500);
            if (st & ST_EMPTY) empty_cnt++;          /* 空＝供給が間に合っていない */

            int16_t  s = deemphasis(buf[i]);
            uint32_t v = (uint32_t)(uint16_t)s;
            reg_write(REG_DATA, (v << 16) | v);
        }
        played++;
        printf("\r%ld 周目  FIFO が空だった回数 = %ld", played, empty_cnt);
        fflush(stdout);
    } while (loop);

    printf("\n");
    reg_write(REG_CTRL, 0);
    munmap((void *)regs, MAP_SIZE);
    close(fd);
    free(buf);
    return 0;
}
