/* ============================================================
 * KV260 NES 段E: ROM を読み込んで動かし、UART のキーで操作する
 * ============================================================
 *
 * CPU・PPU は PL にある。PS の仕事は
 *   1. HDMI の初期化 (InitDP / RunDP)
 *   2. CPU を止めたまま PRG / CHR を AXI で PL に書き、実行させる
 *   3. UART のキーをコントローラの押下状態にして PAD に書く (約 60Hz)
 *   4. ROM が複数あれば、起動時にメニュー (ゲームの一覧) を画面に出して選ばせる
 * ROM は vitis_src/rom_data.h (python tools/rom2c.py ROM.nes [ROM2.nes ...] で作る)。
 * メニュー: 上下で選び、A か Start で開始。ゲーム中に Select+Start を 1 秒押し続けるか m キーでメニューに戻る。
 *
 * キー:  x / k = A     z / j = B     スペース = Select   Enter = Start
 *        矢印 / w a s d = 上下左右    r = リセット    m = メニュー
 * UART は「押した」しか届かないので、押したら KEY_HOLD_FRAMES フレーム押しっぱなしにする。
 * 押し続けると端末のキーリピートで保持が延びる。
 *
 * 押し続けが要るゲーム用に、PC の tools/nes_pad.py が「'P' + 押下状態 1 バイト」を送る
 * (並びは PAD と同じ)。受けた状態はそのまま押下とし、PAD_TIMEOUT_FRAMES 届かなければ離したとみなす。
 *
 * AXI マップ (0xA0000000, 256KB)。レジスタは 0x10 刻み:
 *   0x00000 CTRL  (RW)  bit0=1 実行 (0 でリセット保持) / bit2=1 垂直ミラー / bit3=1 CHR-RAM
 *                       [7:4] マッパー番号 / [11:8] PRG の 16KB 個数-1 / [15:12] CHR の 8KB 個数-1
 *                       (bit0 以外は rom_data.h の ROM_CTRL をそのまま書く)
 *   0x00010 ID    (R)   0x4E455301
 *   0x00020 PAD   (RW)  [0]A [1]B [2]Select [3]Start [4]上 [5]下 [6]左 [7]右 (1 = 押下)
 *   0x00030 FRAME (R)   映像のフレーム数
 *   0x00040 PC    (R)   CPU の PC
 *   0x00060 PFRM  (R)   PPU のフレーム数
 *   0x00070 LOAD  (RW)  書き込み窓の位置 [2:0] = PRG の 32KB 単位 / [7:4] = CHR の 8KB 単位
 *   0x10000〜     FB    (W)  画面バッファ。CPU 停止中 (メニュー) に PS が文字を書く
 *   0x20000〜     PRG   (W)  32KB の窓。1 語 = 4 バイト
 *   0x30000〜     CHR   (W)  8KB の窓。1 語 = 1 バイト
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
#include "rom_data.h"
#include "font8x8.h"

#define UART_BASE        0xFF010000U   /* KV260 USB-UART = UART_1 */
#define KEY_HOLD_FRAMES  12            /* キー 1 回でボタンを押しておくフレーム数 */
#define PAD_TIMEOUT_FRAMES 30          /* 'P' の状態がこのフレーム数届かなければ 0 に戻す */

#ifndef SDT
#define DPPSU_DEVICE_ID   XPAR_PSU_DP_DEVICE_ID
#define AVBUF_DEVICE_ID   XPAR_PSU_DP_DEVICE_ID
#define DPPSU_BASEADDR    XPAR_PSU_DP_BASEADDR
#define AVBUF_BASEADDR    XPAR_PSU_DP_BASEADDR
#else
#define DPPSU_BASEADDR    XPAR_XDPPSU_0_BASEADDR
#define AVBUF_BASEADDR    XPAR_XDPPSU_0_BASEADDR
#endif

#define NES_BASE     0xA0000000U
#define NES_CTRL     (NES_BASE + 0x00000)
#define NES_ID       (NES_BASE + 0x00010)
#define NES_PAD      (NES_BASE + 0x00020)
#define NES_FRAME    (NES_BASE + 0x00030)
#define NES_PC       (NES_BASE + 0x00040)
#define NES_PFRM     (NES_BASE + 0x00060)
#define NES_LOAD     (NES_BASE + 0x00070)
#define NES_FB       (NES_BASE + 0x10000)
#define NES_PRG      (NES_BASE + 0x20000)
#define NES_CHR      (NES_BASE + 0x30000)

#define CTRL_RUN     0x1U

/* PAD のビット */
#define BTN_A      0x01
#define BTN_B      0x02
#define BTN_SELECT 0x04
#define BTN_START  0x08
#define BTN_UP     0x10
#define BTN_DOWN   0x20
#define BTN_LEFT   0x40
#define BTN_RIGHT  0x80

typedef enum { LINK_RATE_270 = 0x0A } LinkRate_t;

static XDpPsu DpPsu;
static XAVBuf AVBuf;

static int  InitDP(void);
static void SetupAudio(void);
static void RunDP(void);
static void SetupVideoStream(void);
static u32  TrainLink(void);

/* UART 1 文字ノンブロッキング読み込み (-1 if empty) */
static int uart_getchar_nb(void)
{
    u32 sr = XUartPs_ReadReg(UART_BASE, XUARTPS_SR_OFFSET);
    if (sr & XUARTPS_SR_RXEMPTY) return -1;
    return (int)(XUartPs_ReadReg(UART_BASE, XUARTPS_FIFO_OFFSET) & 0xFF);
}

/* CPU を止めて ROM を書き、走らせ直す (CPU が止まっている間に書く約束) */
static void nes_load_and_run(const struct rom_entry *r)
{
    Xil_Out32(NES_CTRL, r->ctrl);                       /* bit0=0: リセット保持 */

    /* PRG: 32KB の窓ずつ。16KB の ROM は 2 回並べて 32KB 埋める
     * (マッパー無しの段F までのハードは 32KB をそのまま読むため。段G 以降は折り返すので害はない) */
    u32 prg_total = (r->prg_size < 32768) ? 32768 : r->prg_size;
    for (u32 base = 0; base < prg_total; base += 32768) {
        Xil_Out32(NES_LOAD, base / 32768);
        for (u32 i = 0; i < 32768; i += 4) {
            u32 s = (base + i) % r->prg_size;
            Xil_Out32(NES_PRG + i, r->prg[s] | (r->prg[s + 1] << 8) | (r->prg[s + 2] << 16)
                                   | ((u32)r->prg[s + 3] << 24));
        }
    }
    /* CHR-ROM: 8KB の窓ずつ (CHR-RAM なら書かない) */
    for (u32 base = 0; base < r->chr_size; base += 8192) {
        Xil_Out32(NES_LOAD, (base / 8192) << 4);
        for (u32 i = 0; i < 8192; i++)
            Xil_Out32(NES_CHR + i * 4, r->chr[base + i]);
    }
    Xil_Out32(NES_LOAD, 0);
    Xil_Out32(NES_PAD, 0);
    Xil_Out32(NES_CTRL, r->ctrl | CTRL_RUN);
}

/* ============================================================
 * メニュー (ゲームの一覧を画面に出して選ぶ)
 * ============================================================
 * CPU を止めると PPU もリセットのまま画面バッファに書かないので、PS が FB 窓に直接文字を書く。
 * 画面は 256x240 = 8x8 の文字で 32 桁 x 30 行。色は NES のパレット番号 (0〜63)。
 * FB の 1 語 = 横 4 画素 ([5:0]=x, [13:8]=x+1, [21:16]=x+2, [29:24]=x+3)、語番号 = y*64 + x/4。 */
#define COL_BG     0x0F   /* 黒 */
#define COL_TEXT   0x30   /* 白 */
#define COL_TITLE  0x28   /* 黄 */
#define COL_HINT   0x10   /* 灰 */
#define COL_SELBG  0x12   /* 選択中の行の背景 (青) */
#define MENU_TOP   5      /* 一覧の最初の行 */
#define MENU_ROWS  18     /* 一度に見せる本数 (多ければ送る) */

static void fb_fill(u32 color)
{
    u32 w = color * 0x01010101U;
    for (u32 i = 0; i < 240 * 64; i++)
        Xil_Out32(NES_FB + i * 4, w);
}

/* 文字 1 つを桁 cx・行 cy に書く。1 行 8 画素 = 2 語 */
static void fb_char(int cx, int cy, char ch, u32 fg, u32 bg)
{
    const uint8_t *g = font8x8[((u8)ch < 0x20 || (u8)ch > 0x7F) ? 0 : (u8)ch - 0x20];
    for (int y = 0; y < 8; y++) {
        u32 addr = NES_FB + ((cy * 8 + y) * 64 + cx * 2) * 4;
        for (int h = 0; h < 2; h++) {
            u32 w = 0;
            for (int p = 0; p < 4; p++)
                w |= ((g[y] >> (h * 4 + p)) & 1 ? fg : bg) << (p * 8);
            Xil_Out32(addr + h * 4, w);
        }
    }
}

/* 文字列を書き、残りを width 桁まで背景で埋める */
static void fb_text(int cx, int cy, const char *s, int width, u32 fg, u32 bg)
{
    for (int i = 0; i < width; i++)
        fb_char(cx + i, cy, *s ? *s++ : ' ', fg, bg);
}

static void menu_draw_list(int sel, int top)
{
    for (int row = 0; row < MENU_ROWS; row++) {
        int n = top + row;
        if (n >= ROM_COUNT) { fb_text(0, MENU_TOP + row, "", 32, COL_TEXT, COL_BG); continue; }
        int on = (n == sel);
        fb_text(0, MENU_TOP + row, on ? " >" : "  ", 2, COL_TEXT, on ? COL_SELBG : COL_BG);
        fb_text(2, MENU_TOP + row, roms[n].name, 30, COL_TEXT, on ? COL_SELBG : COL_BG);
    }
}

static void menu_draw(int sel, int top)
{
    fb_fill(COL_BG);
    fb_text(2, 2, "KV260 NES  GAME SELECT", 28, COL_TITLE, COL_BG);
    menu_draw_list(sel, top);
    fb_text(1, 25, "UP/DOWN  : CHOOSE", 30, COL_HINT, COL_BG);
    fb_text(1, 26, "A / START: PLAY", 30, COL_HINT, COL_BG);
    fb_text(1, 27, "LB / F2  : BACK TO THIS MENU", 30, COL_HINT, COL_BG);
}

/* メニューに入る: CPU を止めて一覧を書く */
static void menu_enter(int sel, int top)
{
    Xil_Out32(NES_CTRL, 0);
    Xil_Out32(NES_PAD, 0);
    menu_draw(sel, top);
}

/* キーボード文字 → ボタン (対応なしは 0) */
static int map_key(int c)
{
    switch (c) {
    case 'x': case 'k': return BTN_A;
    case 'z': case 'j': return BTN_B;
    case ' ':           return BTN_SELECT;
    case '\r': case '\n': return BTN_START;
    case 'w': return BTN_UP;
    case 's': return BTN_DOWN;
    case 'a': return BTN_LEFT;
    case 'd': return BTN_RIGHT;
    default:  return 0;
    }
}

int main(void)
{
    Xil_DCacheDisable();
    Xil_ICacheDisable();

    xil_printf("\r\n==== KV260 NES stage E ====\r\n");

    /* AXI が届いているか: ID を読む */
    u32 id = Xil_In32(NES_ID);
    xil_printf("ID    = 0x%08x (expect 0x4E455301) %s\r\n", id, (id == 0x4E455301U) ? "OK" : "NG");

    if (InitDP() != XST_SUCCESS) { xil_printf("DP init failed\r\n"); return XST_FAILURE; }
    sleep(1);
    RunDP();

    xil_printf("%d ROM(s)\r\n", ROM_COUNT);
    xil_printf("keys: x/k=A z/j=B space=Select Enter=Start arrows/wasd=dir r=reset m=menu\r\n");

    int sel = 0, top = 0;  /* メニューで選んでいる番号・一覧の先頭 */
    int in_menu;           /* 1 = メニュー中 (CPU は止めている) */
    u32 prev = 0;          /* 前のフレームの押下状態 (メニューで押した瞬間を見る) */
    int combo = 0;         /* Select+Start を押し続けているフレーム数 */
    int mute = 0;          /* 1 = 全部離すまで PAD に 0 を書く (メニューの A がゲームに入らないように) */
    if (ROM_COUNT == 1) {
        in_menu = 0;
        nes_load_and_run(&roms[0]);
        xil_printf("ROM %s\r\n", roms[0].name);
    } else {
        in_menu = 1;
        menu_enter(sel, top);
    }

    int hold[8] = {0};     /* ボタンごとの残りフレーム数 */
    int esc = 0;           /* 矢印キー ESC [ A〜D の読み途中 (0=なし 1=ESC 2=ESC[) */
    int n = 0;
    int pstate = 0;        /* 1 = 'P' の次 (状態バイト待ち) */
    u32 direct = 0;        /* nes_pad.py から来た押下状態 */
    int direct_age = 0;    /* 最後に状態が来てからのフレーム数 */

    /* 約 60Hz */
    while (1) {
        int c;
        while ((c = uart_getchar_nb()) >= 0) {
            int b = 0;
            if (pstate) { pstate = 0; direct = (u32)c & 0xFF; direct_age = 0; continue; }
            if (c == 'P') { pstate = 1; continue; }
            if (esc == 1) { esc = (c == '[') ? 2 : 0; continue; }
            if (esc == 2) {
                esc = 0;
                if      (c == 'A') b = BTN_UP;
                else if (c == 'B') b = BTN_DOWN;
                else if (c == 'C') b = BTN_RIGHT;
                else if (c == 'D') b = BTN_LEFT;
            } else if (c == 0x1B) {
                esc = 1; continue;
            } else if (c == 'r') {
                if (!in_menu) {
                    nes_load_and_run(&roms[sel]);
                    for (int i = 0; i < 8; i++) hold[i] = 0;
                    xil_printf("reset\r\n");
                }
                continue;
            } else if (c == 'm') {
                if (!in_menu && ROM_COUNT > 1) {
                    in_menu = 1;
                    menu_enter(sel, top);
                    for (int i = 0; i < 8; i++) hold[i] = 0;
                }
                continue;
            } else
                b = map_key(c);
            for (int i = 0; i < 8; i++)
                if (b & (1 << i)) hold[i] = KEY_HOLD_FRAMES;
        }

        if (direct_age < PAD_TIMEOUT_FRAMES) direct_age++;
        else                                 direct = 0;
        u32 pad = direct;
        for (int i = 0; i < 8; i++)
            if (hold[i] > 0) { pad |= 1U << i; hold[i]--; }
        u32 push = pad & ~prev;            /* このフレームで押されたボタン */
        prev = pad;

        if (in_menu) {
            int old = sel;
            if ((push & BTN_DOWN) && sel < ROM_COUNT - 1) sel++;
            if ((push & BTN_UP)   && sel > 0)             sel--;
            if (sel != old) {
                if (sel < top)              top = sel;
                if (sel >= top + MENU_ROWS) top = sel - MENU_ROWS + 1;
                menu_draw_list(sel, top);
            }
            if (push & (BTN_A | BTN_START)) {
                in_menu = 0;
                mute = 1;
                combo = 0;
                nes_load_and_run(&roms[sel]);
                xil_printf("ROM %s\r\n", roms[sel].name);
            }
        } else {
            /* Select+Start を 1 秒押し続けたらメニューへ */
            combo = ((pad & (BTN_SELECT | BTN_START)) == (BTN_SELECT | BTN_START)) ? combo + 1 : 0;
            if (combo >= 60 && ROM_COUNT > 1) {
                in_menu = 1;
                menu_enter(sel, top);
            } else {
                if (mute && pad == 0) mute = 0;
                Xil_Out32(NES_PAD, mute ? 0 : pad);
            }
        }

        /* 5 秒ごとに生存確認 (CPU の PC と PPU のフレーム数) */
        if (++n == 300) {
            n = 0;
            xil_printf("PC=%04x PFRM=%u\r\n", Xil_In32(NES_PC), Xil_In32(NES_PFRM));
        }
        usleep(16667);
    }
    return 0;
}

/* ============================================================
 * DisplayPort (HDMI) Live Video 初期化 (Tetris/Pong と同一)
 * ============================================================
 * KV260 の HDMI 出力は PS の DisplayPort コントローラが担う。
 * PL が生成したライブ映像 (rtl_top の video_*) を DP に流すには
 * 以下の順序で初期化が必要。これが無いと AXI は動くがモニタは無信号。
 *   main() → InitDP() : ドライバ初期化 + AVBuf を Live 入力に設定
 *          → RunDP()  : 接続確認 → TrainLink → SetupVideoStream
 */

/* InitDP: DP/AVBuf ドライバ初期化と映像経路の設定
 *   - XDpPsu (DP TX) と XAVBuf (映像ブレンダ) を Config から初期化
 *   - 入力 = Live Video(RGB 12bpc)、出力 = RGB 8bpc を選択
 *   - 映像ストリーム1・音声ストリーム1 を Live に構成 (音の設定は SetupAudio)
 *   - 音声クロックを PL クロック源に指定して AVBuf を SoftReset (映像・音声とも)
 *   戻り値: XST_SUCCESS / XST_FAILURE */
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
    XAVBuf_InputAudioSelect(&AVBuf, XAVBUF_AUDSTREAM1_LIVE, XAVBUF_AUDSTREAM2_NO_AUDIO);
    XDpPsu_MainStreamAttributes *Msa = &DpPsu.MsaConfig;
    XAVBuf_SetPixelClock(Msa->PixelClockHz);
    SetupAudio();
    XAVBuf_ConfigureGraphicsPipeline(&AVBuf);
    XAVBuf_ConfigureOutputVideo(&AVBuf);
    XAVBuf_SetBlenderAlpha(&AVBuf, 0, 0);
    XDpPsu_CfgMsaEnSynchClkMode(&DpPsu, 0);
    XAVBuf_SetAudioVideoClkSrc(&AVBuf, XAVBUF_PS_CLK, XAVBUF_PL_CLK);
    XAVBuf_SoftReset(&AVBuf);
    XAVBuf_AudioSoftReset(&AVBuf);
    return XST_SUCCESS;
}

/* SetupAudio: HDMI に音を出す設定 (Live_Audio_KV260_KR260_Template の InitDpDmaSubsystem と同じ)
 *   - 音声を止めてから、オーディオインフォフレーム (L-PCM・2ch・48kHz・16bit) を書く
 *   - チャンネル数 2 (書く値は 2-1)、音声を再開、ミキサの音量を 0x2000 (等倍) に
 *   XAVBuf_AudioMixerVolumeControl は引数が u8 で 0x2000 を渡せないので直接書く */
static void SetupAudio(void)
{
    u32 base = DpPsu.Config.BaseAddr;
    XDpPsu_WriteReg(base, XDPPSU_TX_AUDIO_CONTROL, 0);
    usleep(10000);
    XAVBuf_EnableAudio0Buffers(&AVBuf, 0);
    XAVBuf_EnableAudio1Buffers(&AVBuf, 0);

    /* インフォフレームの頭 4 バイト: 0x00, 種類 0x84, 長さ 27, 版 0x11 */
    u32 if00 = (0x11u << 2 << 24) | (27u << 16) | (0x84u << 8);
    /* 次の 4 バイト: 2ch (1) / L-PCM (1<<4), 48kHz (3<<2) / 16bit (1), 割り当て 0 */
    u32 if04 = (0u << 24) | (0u << 16) | (((3u << 2) | 1u) << 8) | (1u | (1u << 4));
    XDpPsu_WriteReg(base, XDPPSU_TX_AUDIO_INFO_DATA + 0, if00);
    XDpPsu_WriteReg(base, XDPPSU_TX_AUDIO_INFO_DATA + 4, if04);
    for (int i = 8; i < 32; i += 4)
        XDpPsu_WriteReg(base, XDPPSU_TX_AUDIO_INFO_DATA + i, 0);

    XDpPsu_WriteReg(base, XDPPSU_TX_AUDIO_CHANNELS, 1);
    XDpPsu_WriteReg(base, XDPPSU_TX_AUDIO_CONTROL, 1);
    usleep(10000);
    XAVBuf_WriteReg(AVBuf.Config.BaseAddr, XAVBUF_AUD_MIXER_VOLUME_CONTROL, 0x20002000);
}

/* TrainLink: DP リンクトレーニング
 *   ソース(KV260)とシンク(モニタ)間で電気的に最適な設定を交渉する。
 *   - GetRxCapabilities: モニタ対応のレーン数/速度を取得
 *   - SetLaneCount/SetLinkRate: 最大レーン数・2.7Gbps/lane(0x0A) に設定
 *   - SetEnhancedFrameMode/SetDownspread: 拡張フレーミング・EMI対策
 *   - EstablishLink: ★トレーニング本体(電圧振幅/プリエンファシス調整)
 *   戻り値が FAILURE ならケーブル/モニタ側の問題。 */
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

/* SetupVideoStream: 映像ストリームの確定と送出開始
 *   リンク確立後、流す映像フォーマット(解像度・色)を設定して開始する。
 *   - SetColorEncode/CfgMsaSetBpc: RGB / 8bit色
 *   - CfgMsaUseStandardVideoMode: 1280x720 60Hz
 *   - SOFT_RESET トグル: 映像パイプラインをリセット
 *   - SetMsaValues: ★MSA(同期・解像度等のタイミング諸元)を HW に書込み
 *   - 0xB124 トグル: DP ストリーム部の内部リセット(テンプレート固定手順)
 *   - EnableMainLink(1): ★メインリンク ON → 映像が流れ始める */
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

/* RunDP: DP 起動シーケンス全体 (DP 規格の標準手順)
 *   1. EnableMainLink(0): 一旦リンクを止めてクリーンな状態に
 *   2. IsConnected: ★ケーブル接続(HPD)確認。未接続なら中断
 *   3. AuxWrite(SET_POWER): AUX チャネルでシンクを電源ON(スリープ解除)。
 *      取りこぼし対策で 2 回送る
 *   4. usleep(100ms): シンクの起動待ち
 *   5. TrainLink 成功なら SetupVideoStream で映像送出開始 */
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
