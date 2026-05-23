/* ============================================================
 * CHIP-8 Phase B: CPU エミュレータ + IBM ロゴ ROM
 * ============================================================
 *
 * PS の C で CHIP-8 CPU をエミュレート (全 35 命令)。ローカル
 * フレームバッファ (fb[32][8]) を保持し、毎フレーム PL の AXI
 * フレームバッファへ転送して HDMI に表示。
 *
 * Phase B では IBM ロゴ ROM をハードコードで実行 (キー入力・音なし)。
 *
 * AXI レジスタマップ (0xA0000000):
 *   アドレス = (y * 8 + byte_idx) * 4   (y 0-31, byte_idx 0-7)
 *   データ   = 8 ピクセル (MSB=左端)
 */

#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xparameters.h"
#include "xdppsu.h"
#include "xavbuf.h"
#include "xavbuf_clk.h"
#include "xuartps_hw.h"
#include "sleep.h"
#include <stdint.h>

#define UART_BASE        0xFF010000U   /* KV260 USB-UART = UART_1 */
#define KEY_HOLD_FRAMES  12            /* UART キー押下の保持フレーム数 (取りこぼし防止) */
#define CYCLES_PER_FRAME 7             /* 1 フレームの命令実行数 (↓でゲーム全体が遅くなる) */
#define PHOSPHOR_FRAMES  2             /* 残光: 消灯後この数フレーム表示維持 (ちらつき低減) */

#ifndef SDT
#define DPPSU_DEVICE_ID   XPAR_PSU_DP_DEVICE_ID
#define AVBUF_DEVICE_ID   XPAR_PSU_DP_DEVICE_ID
#define DPPSU_BASEADDR    XPAR_PSU_DP_BASEADDR
#define AVBUF_BASEADDR    XPAR_PSU_DP_BASEADDR
#else
#define DPPSU_BASEADDR    XPAR_XDPPSU_0_BASEADDR
#define AVBUF_BASEADDR    XPAR_XDPPSU_0_BASEADDR
#endif

#define CHIP8_BASE      0xA0000000U
#define FB_ADDR(y, bx)  (CHIP8_BASE + ((y)*8 + (bx))*4)

typedef enum { LINK_RATE_270 = 0x0A } LinkRate_t;

static XDpPsu DpPsu;
static XAVBuf AVBuf;

static int  InitDP(void);
static void RunDP(void);
static void SetupVideoStream(void);
static u32  TrainLink(void);

/* ============================================================
 * CHIP-8 エミュレータ状態
 * ============================================================ */
static uint8_t  mem[4096];        /* メモリ 4KB */
static uint8_t  V[16];            /* レジスタ V0-VF */
static uint16_t I;                /* インデックスレジスタ */
static uint16_t pc;               /* プログラムカウンタ */
static uint16_t stack[16];        /* コールスタック */
static uint8_t  sp;               /* スタックポインタ */
static uint8_t  delay_timer;
static uint8_t  sound_timer;
static uint8_t  fb[32][8];        /* フレームバッファ (1bit/px, MSB=左) */
static uint8_t  decay[32][64];    /* 残光カウンタ (表示用、ちらつき低減) */
static uint8_t  keys[16];         /* キー状態: 残り保持フレーム数 (0=離鍵) */
static uint32_t rng_state = 0x1234ABCDu;

/* フォントセット (0-F、各 5 バイト) */
static const uint8_t fontset[80] = {
    0xF0,0x90,0x90,0x90,0xF0, /* 0 */
    0x20,0x60,0x20,0x20,0x70, /* 1 */
    0xF0,0x10,0xF0,0x80,0xF0, /* 2 */
    0xF0,0x10,0xF0,0x10,0xF0, /* 3 */
    0x90,0x90,0xF0,0x10,0x10, /* 4 */
    0xF0,0x80,0xF0,0x10,0xF0, /* 5 */
    0xF0,0x80,0xF0,0x90,0xF0, /* 6 */
    0xF0,0x10,0x20,0x40,0x40, /* 7 */
    0xF0,0x90,0xF0,0x90,0xF0, /* 8 */
    0xF0,0x90,0xF0,0x10,0xF0, /* 9 */
    0xF0,0x90,0xF0,0x90,0x90, /* A */
    0xE0,0x90,0xE0,0x90,0xE0, /* B */
    0xF0,0x80,0x80,0x80,0xF0, /* C */
    0xE0,0x90,0x90,0x90,0xE0, /* D */
    0xF0,0x80,0xF0,0x80,0xF0, /* E */
    0xF0,0x80,0xF0,0x80,0x80  /* F */
};

/* IBM ロゴ ROM (132 バイト) — 画面に "IBM" を描いて無限ループ */
static const uint8_t ibm_logo[] = {
    0x00,0xE0, 0xA2,0x2A, 0x60,0x0C, 0x61,0x08, 0xD0,0x1F, 0x70,0x09, 0xA2,0x39, 0xD0,0x1F,
    0xA2,0x48, 0x70,0x08, 0xD0,0x1F, 0x70,0x04, 0xA2,0x57, 0xD0,0x1F, 0x70,0x08, 0xA2,0x66,
    0xD0,0x1F, 0x70,0x08, 0xA2,0x75, 0xD0,0x1F, 0x12,0x28, 0xFF,0x00, 0xFF,0x00, 0x3C,0x00,
    0x3C,0x00, 0x3C,0x00, 0x3C,0x00, 0xFF,0x00, 0xFF,0xFF, 0x00,0xFF, 0x00,0x38, 0x00,0x3F,
    0x00,0x3F, 0x00,0x38, 0x00,0xFF, 0x00,0xFF, 0x80,0x00, 0xE0,0x00, 0xE0,0x00, 0x80,0x00,
    0x80,0x00, 0xE0,0x00, 0xE0,0x00, 0x80,0xF8, 0x00,0xFC, 0x00,0x3E, 0x00,0x3F, 0x00,0x3B,
    0x00,0x39, 0x00,0xF8, 0x00,0xF8, 0x03,0x00, 0x07,0x00, 0x0F,0x00, 0xBF,0x00, 0xFB,0x00,
    0xF3,0x00, 0xE3,0x00, 0x43,0xE0, 0x00,0xE0, 0x00,0x80, 0x00,0x80, 0x00,0x80, 0x00,0x80,
    0x00,0xE0, 0x00,0xE0
};

/* キー移動テスト ROM (手書き) — '0' スプライトをキー 2/4/6/8 で上下左右に動かす
 *   CHIP-8 key 4=左, 6=右, 2=上, 8=下
 *   キーボード:        4='q', 6='e', 2='2', 8='s'  (標準マッピング)
 */
static const uint8_t keytest_rom[] = {
    0x60,0x20,  /* 0x200 LD V0,0x20  x=32        */
    0x61,0x10,  /* 0x202 LD V1,0x10  y=16        */
    0x62,0x00,  /* 0x204 LD V2,0     digit 0     */
    0x00,0xE0,  /* 0x206 CLS                     */
    0xF2,0x29,  /* 0x208 LD F,V2     I=font[V2]  */
    0xD0,0x15,  /* 0x20A DRW V0,V1,5             */
    0x64,0x04,  /* 0x20C LD V4,4                 */
    0xE4,0xA1,  /* 0x20E SKNP V4     key4 左     */
    0x70,0xFF,  /* 0x210 ADD V0,-1               */
    0x64,0x06,  /* 0x212 LD V4,6                 */
    0xE4,0xA1,  /* 0x214 SKNP V4     key6 右     */
    0x70,0x01,  /* 0x216 ADD V0,1                */
    0x64,0x02,  /* 0x218 LD V4,2                 */
    0xE4,0xA1,  /* 0x21A SKNP V4     key2 上     */
    0x71,0xFF,  /* 0x21C ADD V1,-1               */
    0x64,0x08,  /* 0x21E LD V4,8                 */
    0xE4,0xA1,  /* 0x220 SKNP V4     key8 下     */
    0x71,0x01,  /* 0x222 ADD V1,1                */
    0x12,0x06   /* 0x224 JP 0x206    loop        */
};

/* Brick (Brix hack, 1990) — 286 bytes。パドルを key 4/6 で左右移動 */
static const uint8_t game_rom[] = {
    0x6E,0x05,0x65,0x00,0x6B,0x06,0x6A,0x00,0xA3,0x0C,0xDA,0xB1,
    0x7A,0x04,0x3A,0x40,0x12,0x08,0x7B,0x01,0x3B,0x12,0x12,0x06,
    0x6C,0x20,0x6D,0x1F,0xA3,0x10,0xDC,0xD1,0x22,0xF6,0x60,0x00,
    0x61,0x00,0xA3,0x12,0xD0,0x11,0x70,0x08,0xA3,0x0E,0xD0,0x11,
    0x60,0x40,0xF0,0x15,0xF0,0x07,0x30,0x00,0x12,0x34,0xC6,0x0F,
    0x67,0x1E,0x68,0x01,0x69,0xFF,0xA3,0x0E,0xD6,0x71,0xA3,0x10,
    0xDC,0xD1,0x60,0x04,0xE0,0xA1,0x7C,0xFE,0x60,0x06,0xE0,0xA1,
    0x7C,0x02,0x60,0x3F,0x8C,0x02,0xDC,0xD1,0xA3,0x0E,0xD6,0x71,
    0x86,0x84,0x87,0x94,0x60,0x3F,0x86,0x02,0x61,0x1F,0x87,0x12,
    0x47,0x1F,0x12,0xAC,0x46,0x00,0x68,0x01,0x46,0x3F,0x68,0xFF,
    0x47,0x00,0x69,0x01,0xD6,0x71,0x3F,0x01,0x12,0xAA,0x47,0x1F,
    0x12,0xAA,0x60,0x05,0x80,0x75,0x3F,0x00,0x12,0xAA,0x60,0x01,
    0xF0,0x18,0x80,0x60,0x61,0xFC,0x80,0x12,0xA3,0x0C,0xD0,0x71,
    0x60,0xFE,0x89,0x03,0x22,0xF6,0x75,0x01,0x22,0xF6,0x45,0xC0,
    0x13,0x18,0x12,0x46,0x69,0xFF,0x80,0x60,0x80,0xC5,0x3F,0x01,
    0x12,0xCA,0x61,0x02,0x80,0x15,0x3F,0x01,0x12,0xE0,0x80,0x15,
    0x3F,0x01,0x12,0xEE,0x80,0x15,0x3F,0x01,0x12,0xE8,0x60,0x20,
    0xF0,0x18,0xA3,0x0E,0x7E,0xFF,0x80,0xE0,0x80,0x04,0x61,0x00,
    0xD0,0x11,0x3E,0x00,0x12,0x30,0x12,0xDE,0x78,0xFF,0x48,0xFE,
    0x68,0xFF,0x12,0xEE,0x78,0x01,0x48,0x02,0x68,0x01,0x60,0x04,
    0xF0,0x18,0x69,0xFF,0x12,0x70,0xA3,0x14,0xF5,0x33,0xF2,0x65,
    0xF1,0x29,0x63,0x37,0x64,0x00,0xD3,0x45,0x73,0x05,0xF2,0x29,
    0xD3,0x45,0x00,0xEE,0xF0,0x00,0x80,0x00,0xFC,0x00,0xAA,0x00,
    0x00,0x00,0x00,0x00,0x6E,0x05,0x00,0xE0,0x12,0x04,
};

/* UART 1 文字ノンブロッキング読み込み (-1 if empty) */
static int uart_getchar_nb(void)
{
    u32 sr = XUartPs_ReadReg(UART_BASE, XUARTPS_SR_OFFSET);
    if (sr & XUARTPS_SR_RXEMPTY) return -1;
    return (int)(XUartPs_ReadReg(UART_BASE, XUARTPS_FIFO_OFFSET) & 0xFF);
}

/* キーボード文字 → CHIP-8 キー番号 (0-15)、対応なしは -1
 *   1 2 3 4      1 2 3 C
 *   q w e r  →   4 5 6 D
 *   a s d f      7 8 9 E
 *   z x c v      A 0 B F
 */
static int map_key(int c)
{
    switch (c) {
        case '1': return 0x1; case '2': return 0x2; case '3': return 0x3; case '4': return 0xC;
        case 'q': case 'Q': return 0x4; case 'w': case 'W': return 0x5;
        case 'e': case 'E': return 0x6; case 'r': case 'R': return 0xD;
        case 'a': case 'A': return 0x7; case 's': case 'S': return 0x8;
        case 'd': case 'D': return 0x9; case 'f': case 'F': return 0xE;
        case 'z': case 'Z': return 0xA; case 'x': case 'X': return 0x0;
        case 'c': case 'C': return 0xB; case 'v': case 'V': return 0xF;
        default: return -1;
    }
}

static uint8_t rng_next(void)
{
    /* xorshift32 */
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return (uint8_t)(rng_state & 0xFF);
}

static void chip8_init(void)
{
    for (int i = 0; i < 4096; i++) mem[i] = 0;
    for (int i = 0; i < 16; i++) { V[i] = 0; stack[i] = 0; keys[i] = 0; }
    for (int y = 0; y < 32; y++) {
        for (int bx = 0; bx < 8; bx++) fb[y][bx] = 0;
        for (int xx = 0; xx < 64; xx++) decay[y][xx] = 0;
    }
    I = 0; sp = 0; delay_timer = 0; sound_timer = 0;
    pc = 0x200;
    /* フォントを 0x50 に配置 */
    for (int i = 0; i < 80; i++) mem[0x50 + i] = fontset[i];
}

static void chip8_load_rom(const uint8_t *rom, int len)
{
    for (int i = 0; i < len; i++) mem[0x200 + i] = rom[i];
}

/* DXYN: スプライト描画 (XOR, VF=衝突) */
static void op_draw(uint8_t x, uint8_t y, uint8_t n)
{
    uint8_t xpos = V[x] & 63;
    uint8_t ypos = V[y] & 31;
    V[0xF] = 0;
    for (int row = 0; row < n; row++) {
        if (ypos + row >= 32) break;          /* 下端でクリップ */
        uint8_t sprite = mem[(I + row) & 0xFFF];
        for (int col = 0; col < 8; col++) {
            if (xpos + col >= 64) break;       /* 右端でクリップ */
            if (sprite & (0x80 >> col)) {
                int px = xpos + col;
                int py = ypos + row;
                uint8_t mask = 0x80 >> (px & 7);
                if (fb[py][px >> 3] & mask) V[0xF] = 1;  /* 衝突 */
                fb[py][px >> 3] ^= mask;
            }
        }
    }
}

static void chip8_cycle(void)
{
    uint16_t op = (mem[pc] << 8) | mem[pc + 1];
    pc += 2;

    uint8_t  x   = (op >> 8) & 0x0F;
    uint8_t  y   = (op >> 4) & 0x0F;
    uint8_t  n   = op & 0x0F;
    uint8_t  kk  = op & 0xFF;
    uint16_t nnn = op & 0x0FFF;

    switch (op & 0xF000) {
    case 0x0000:
        if (op == 0x00E0) {                    /* CLS */
            for (int yy = 0; yy < 32; yy++)
                for (int bx = 0; bx < 8; bx++) fb[yy][bx] = 0;
        } else if (op == 0x00EE) {             /* RET */
            if (sp > 0) pc = stack[--sp];
        }
        break;
    case 0x1000: pc = nnn; break;              /* JP nnn */
    case 0x2000: stack[sp++] = pc; pc = nnn; break; /* CALL nnn */
    case 0x3000: if (V[x] == kk) pc += 2; break;
    case 0x4000: if (V[x] != kk) pc += 2; break;
    case 0x5000: if (V[x] == V[y]) pc += 2; break;
    case 0x6000: V[x] = kk; break;             /* LD Vx, kk */
    case 0x7000: V[x] += kk; break;            /* ADD Vx, kk */
    case 0x8000:
        switch (n) {
        case 0x0: V[x] = V[y]; break;
        case 0x1: V[x] |= V[y]; break;
        case 0x2: V[x] &= V[y]; break;
        case 0x3: V[x] ^= V[y]; break;
        case 0x4: {
            uint16_t sum = V[x] + V[y];
            V[0xF] = (sum > 0xFF) ? 1 : 0;
            V[x] = sum & 0xFF;
        } break;
        case 0x5:
            V[0xF] = (V[x] >= V[y]) ? 1 : 0;
            V[x] = V[x] - V[y];
            break;
        case 0x6:
            V[0xF] = V[x] & 0x1;
            V[x] >>= 1;
            break;
        case 0x7:
            V[0xF] = (V[y] >= V[x]) ? 1 : 0;
            V[x] = V[y] - V[x];
            break;
        case 0xE:
            V[0xF] = (V[x] >> 7) & 0x1;
            V[x] <<= 1;
            break;
        default: break;
        }
        break;
    case 0x9000: if (V[x] != V[y]) pc += 2; break;
    case 0xA000: I = nnn; break;               /* LD I, nnn */
    case 0xB000: pc = nnn + V[0]; break;       /* JP V0, nnn */
    case 0xC000: V[x] = rng_next() & kk; break;
    case 0xD000: op_draw(x, y, n); break;      /* DRW */
    case 0xE000:
        if (kk == 0x9E) { if (keys[V[x] & 0xF]) pc += 2; }
        else if (kk == 0xA1) { if (!keys[V[x] & 0xF]) pc += 2; }
        break;
    case 0xF000:
        switch (kk) {
        case 0x07: V[x] = delay_timer; break;
        case 0x0A: {                            /* キー待ち */
            int pressed = -1;
            for (int k = 0; k < 16; k++) if (keys[k]) { pressed = k; break; }
            if (pressed < 0) pc -= 2;           /* 押されるまで足踏み */
            else V[x] = pressed;
        } break;
        case 0x15: delay_timer = V[x]; break;
        case 0x18: sound_timer = V[x]; break;
        case 0x1E: I += V[x]; break;
        case 0x29: I = 0x50 + (V[x] & 0xF) * 5; break; /* フォント */
        case 0x33:                              /* BCD */
            mem[I & 0xFFF]       = V[x] / 100;
            mem[(I + 1) & 0xFFF] = (V[x] / 10) % 10;
            mem[(I + 2) & 0xFFF] = V[x] % 10;
            break;
        case 0x55: for (int k = 0; k <= x; k++) mem[(I + k) & 0xFFF] = V[k]; break;
        case 0x65: for (int k = 0; k <= x; k++) V[k] = mem[(I + k) & 0xFFF]; break;
        default: break;
        }
        break;
    default: break;
    }
}

/* ローカル fb を PL の AXI フレームバッファへ転送 (残光処理付き)
 * 点灯ピクセルは decay を最大に、消灯ピクセルは decay を減算。
 * decay>0 を表示することで XOR アニメのちらつきを抑える。 */
static void fb_push(void)
{
    for (int y = 0; y < 32; y++) {
        for (int bx = 0; bx < 8; bx++) {
            uint8_t src = fb[y][bx];
            uint8_t out = 0;
            for (int bit = 0; bit < 8; bit++) {
                int x = (bx << 3) + bit;
                uint8_t m = 0x80 >> bit;
                if (src & m) decay[y][x] = PHOSPHOR_FRAMES;
                else if (decay[y][x] > 0) decay[y][x]--;
                if (decay[y][x] > 0) out |= m;
            }
            Xil_Out32(FB_ADDR(y, bx), (u32)out);
        }
    }
}

int main(void)
{
    Xil_DCacheDisable();
    Xil_ICacheDisable();

    xil_printf("\r\n==== CHIP-8 Phase E: Brix ====\r\n");
    xil_printf("Paddle:  q=left  e=right   Enter=restart\r\n");

    if (InitDP() != XST_SUCCESS) { xil_printf("DP init failed\r\n"); return XST_FAILURE; }
    sleep(1);
    RunDP();

    chip8_init();
    chip8_load_rom(game_rom, sizeof(game_rom));
    xil_printf("ROM loaded (%d bytes), PC=0x%03x\r\n", (int)sizeof(game_rom), pc);
    xil_printf("Enter key = restart\r\n");

    /* 約 60Hz フレーム */
    while (1) {
        /* UART キー入力を吸い上げ、対応キーの保持カウンタをセット */
        int c;
        while ((c = uart_getchar_nb()) >= 0) {
            if (c == '\r' || c == '\n') {     /* Enter でリスタート */
                chip8_init();
                chip8_load_rom(game_rom, sizeof(game_rom));
                xil_printf("restart\r\n");
                continue;
            }
            int k = map_key(c);
            if (k >= 0) keys[k] = KEY_HOLD_FRAMES;
        }

        for (int i = 0; i < CYCLES_PER_FRAME; i++) chip8_cycle();
        fb_push();

        /* タイマー (60Hz) */
        if (delay_timer > 0) delay_timer--;
        if (sound_timer > 0) sound_timer--;

        /* キー自動リリース (1 フレームごとに減算) */
        for (int k = 0; k < 16; k++)
            if (keys[k] > 0) keys[k]--;

        usleep(16667);  /* ~60Hz */
    }
    return 0;
}

/* ===== DP 初期化 (Tetris/Pong と同一) ===== */
static int InitDP(void)
{
    XDpPsu_Config *Cfg;
#ifndef SDT
    Cfg = XDpPsu_LookupConfig(DPPSU_DEVICE_ID);
#else
    Cfg = XDpPsu_LookupConfig(DPPSU_BASEADDR);
#endif
    if (!Cfg) return XST_FAILURE;
    XDpPsu_CfgInitialize(&DpPsu, Cfg, Cfg->BaseAddr);
#ifndef SDT
    XAVBuf_CfgInitialize(&AVBuf, DpPsu.Config.BaseAddr, AVBUF_DEVICE_ID);
#else
    XAVBuf_CfgInitialize(&AVBuf, DpPsu.Config.BaseAddr);
#endif
    if (XDpPsu_InitializeTx(&DpPsu) != XST_SUCCESS) return XST_FAILURE;
    XAVBuf_SetInputLiveVideoFormat(&AVBuf, RGB_12BPC);
    XAVBuf_SetOutputVideoFormat(&AVBuf, RGB_8BPC);
    XAVBuf_InputVideoSelect(&AVBuf, XAVBUF_VIDSTREAM1_LIVE, XAVBUF_VIDSTREAM2_NONE);
    XAVBuf_InputAudioSelect(&AVBuf, XAVBUF_AUDSTREAM1_NO_AUDIO, XAVBUF_AUDSTREAM2_NO_AUDIO);
    XDpPsu_MainStreamAttributes *Msa = &DpPsu.MsaConfig;
    XAVBuf_SetPixelClock(Msa->PixelClockHz);
    XAVBuf_ConfigureGraphicsPipeline(&AVBuf);
    XAVBuf_ConfigureOutputVideo(&AVBuf);
    XAVBuf_SetBlenderAlpha(&AVBuf, 0, 0);
    XDpPsu_CfgMsaEnSynchClkMode(&DpPsu, 0);
    XAVBuf_SetAudioVideoClkSrc(&AVBuf, XAVBUF_PS_CLK, XAVBUF_PL_CLK);
    XAVBuf_SoftReset(&AVBuf);
    return XST_SUCCESS;
}

static u32 TrainLink(void)
{
    if (XDpPsu_GetRxCapabilities(&DpPsu) != XST_SUCCESS) return XST_FAILURE;
    XDpPsu_LinkConfig *Link = &DpPsu.LinkConfig;
    XDpPsu_SetEnhancedFrameMode(&DpPsu, Link->SupportEnhancedFramingMode ? 1 : 0);
    XDpPsu_SetLaneCount(&DpPsu, Link->MaxLaneCount);
    XDpPsu_SetLinkRate(&DpPsu, LINK_RATE_270);
    XDpPsu_SetDownspread(&DpPsu, Link->SupportDownspreadControl);
    xil_printf("Training: %d lanes, rate 0x%x\r\n", DpPsu.LinkConfig.LaneCount, DpPsu.LinkConfig.LinkRate);
    u32 Status = XDpPsu_EstablishLink(&DpPsu);
    xil_printf("Training %s\r\n", (Status == XST_SUCCESS) ? "OK" : "failed");
    return Status;
}

static void SetupVideoStream(void)
{
    XDpPsu_SetColorEncode(&DpPsu, XDPPSU_CENC_RGB);
    XDpPsu_CfgMsaSetBpc(&DpPsu, XVIDC_BPC_8);
    XDpPsu_CfgMsaUseStandardVideoMode(&DpPsu, XVIDC_VM_1280x720_60_P);
    XDpPsu_MainStreamAttributes *Msa = &DpPsu.MsaConfig;
    XAVBuf_SetPixelClock(Msa->PixelClockHz);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, XDPPSU_SOFT_RESET, 0x1);
    usleep(10);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, XDPPSU_SOFT_RESET, 0x0);
    XDpPsu_SetMsaValues(&DpPsu);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, 0xB124, 0x3);
    usleep(10);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, 0xB124, 0x0);
    XDpPsu_EnableMainLink(&DpPsu, 1);
    xil_printf("Video stream started\r\n");
}

static void RunDP(void)
{
    XDpPsu_EnableMainLink(&DpPsu, 0);
    if (!XDpPsu_IsConnected(&DpPsu)) { xil_printf("Not connected\r\n"); return; }
    xil_printf("Connected\r\n");
    u8 AuxData = 0x1;
    XDpPsu_AuxWrite(&DpPsu, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &AuxData);
    XDpPsu_AuxWrite(&DpPsu, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &AuxData);
    usleep(100000);
    if (TrainLink() == XST_SUCCESS) SetupVideoStream();
    xil_printf("RunDP returning\r\n");
}
