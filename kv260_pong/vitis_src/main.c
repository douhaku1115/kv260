// ============================================================
// main.c — KV260 Pong (完成版)
// ============================================================
//
// PS から PL の AXI スレーブ (0xA0000000) 経由で左パドル/右パドル/ボールの
// 位置を制御。UART のキー入力でプレイヤーがパドルを動かし、ボールは自動で
// 移動・反射する Pong ゲーム。
//
// 【操作】
//   w / s : 左パドル 上/下
//   i / k : 右パドル 上/下
//
// 【スコア】
//   ボールがパドルを抜けて壁に到達するたびに +1。シリアル端末に
//   "Score: L - R" として表示。
//
// 【AXI レジスタマップ (ベース 0xA0000000)】
//   0x00 PADL_X   R/W   左パドル X
//   0x04 PADL_Y   R/W   左パドル Y
//   0x08 PADR_X   R/W   右パドル X
//   0x0C PADR_Y   R/W   右パドル Y
//   0x10 BALL_X   R/W   ボール X
//   0x14 BALL_Y   R/W   ボール Y
//
// 【UART】
//   KV260 の USB-UART は psu_uart_1 (0xFF010000)。
//   xil_printf 出力 (BSP の stdin/stdout 経由) と同じハードウェアだが、
//   RX を直接レジスタで読むため UART_BASE を 0xFF010000 で固定。
//
// 【キー応答】
//   OS の自動リピート遅延 (約 500ms) を吸収するため、1 押下で
//   KEY_FRAMES (36 フレーム ≒ 600ms) ぶん継続移動する方式。

#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xparameters.h"
#include "xdppsu.h"
#include "xavbuf.h"
#include "xavbuf_clk.h"
#include "xuartps_hw.h"
#include "sleep.h"

/* KV260 PS UART_1 (USB-UART) */
#define UART_BASE  0xFF010000U
#ifndef SDT
#include "xscugic.h"
#else
#include "xinterrupt_wrap.h"
#endif

/* HDMI 出力制御用ハードウェア定義 (Xilinx XPAR_PSU_DP_* は内部ドライバ名) */
#ifndef SDT
#define DPPSU_DEVICE_ID   XPAR_PSU_DP_DEVICE_ID
#define AVBUF_DEVICE_ID   XPAR_PSU_DP_DEVICE_ID
#define INTC_DEVICE_ID    XPAR_SCUGIC_0_DEVICE_ID
#define DPPSU_INTR_ID     151
#define DPPSU_BASEADDR    XPAR_PSU_DP_BASEADDR
#define AVBUF_BASEADDR    XPAR_PSU_DP_BASEADDR
#else
#define DPPSU_BASEADDR    XPAR_XDPPSU_0_BASEADDR
#define AVBUF_BASEADDR    XPAR_XDPPSU_0_BASEADDR
#define INTC_BASEADDR     XPAR_XSCUGIC_0_BASEADDR
#endif

/* Pong AXI レジスタ (Phase A2: 3 オブジェクト) */
#define PONG_BASE     0xA0000000U
#define PONG_PADL_X   (PONG_BASE + 0x00)
#define PONG_PADL_Y   (PONG_BASE + 0x04)
#define PONG_PADR_X   (PONG_BASE + 0x08)
#define PONG_PADR_Y   (PONG_BASE + 0x0C)
#define PONG_BALL_X   (PONG_BASE + 0x10)
#define PONG_BALL_Y   (PONG_BASE + 0x14)

#define SCREEN_W   1280
#define SCREEN_H   720
#define PAD_W      20
#define PAD_H      100
#define BALL_W     20
#define BALL_H     20

typedef enum { LINK_RATE_270 = 0x0A } LinkRate_t;

static XDpPsu DpPsu;
static XAVBuf AVBuf;
static XScuGic Intr;

static int  InitDP(void);
static void RunDP(void);
static void SetupVideoStream(void);
static void HpdEvent(void *ref);
static void HpdPulse(void *ref);
static u32  TrainLink(void);

/* UART ノンブロッキング読み込み (UART_1 を使用) */
static int uart_getchar_nb(void)
{
    u32 sr = XUartPs_ReadReg(UART_BASE, XUARTPS_SR_OFFSET);
    if (sr & XUARTPS_SR_RXEMPTY) return -1;
    return (int)(XUartPs_ReadReg(UART_BASE, XUARTPS_FIFO_OFFSET) & 0xFF);
}

/* オブジェクト位置設定ヘルパー */
static inline void set_padl(int x, int y)
{
    Xil_Out32(PONG_PADL_X, (u32)x);
    Xil_Out32(PONG_PADL_Y, (u32)y);
}
static inline void set_padr(int x, int y)
{
    Xil_Out32(PONG_PADR_X, (u32)x);
    Xil_Out32(PONG_PADR_Y, (u32)y);
}
static inline void set_ball(int x, int y)
{
    Xil_Out32(PONG_BALL_X, (u32)x);
    Xil_Out32(PONG_BALL_Y, (u32)y);
}

int main(void)
{
    Xil_DCacheDisable();
    Xil_ICacheDisable();

    xil_printf("KV260 Pong Phase A2 Start\r\n");

    /* ========== AXI 動作確認 ========== */
    xil_printf("--- AXI early diag ---\r\n");
    xil_printf("  PADL X=%d Y=%d\r\n", (int)Xil_In32(PONG_PADL_X), (int)Xil_In32(PONG_PADL_Y));
    xil_printf("  PADR X=%d Y=%d\r\n", (int)Xil_In32(PONG_PADR_X), (int)Xil_In32(PONG_PADR_Y));
    xil_printf("  BALL X=%d Y=%d\r\n", (int)Xil_In32(PONG_BALL_X), (int)Xil_In32(PONG_BALL_Y));
    xil_printf("--- AXI early diag done ---\r\n");

    if (InitDP() != XST_SUCCESS) {
        xil_printf("DP init failed\r\n");
        return XST_FAILURE;
    }

    sleep(1);
    RunDP();

    xil_printf("Entering animation loop\r\n");
    xil_printf("Controls: w/s = left paddle up/down, i/k = right paddle up/down\r\n");
    xil_printf("Pong start: 0 - 0\r\n");

    /* ========== Phase D: 衝突判定 + スコア ========== */
    int padl_x = 50,   padl_y = (SCREEN_H - PAD_H) / 2;
    int padr_x = 1210, padr_y = (SCREEN_H - PAD_H) / 2;
    int ball_x = (SCREEN_W - BALL_W) / 2;
    int ball_y = (SCREEN_H - BALL_H) / 2;
    int ball_dx = 6, ball_dy = 4;
    int left_score = 0, right_score = 0;

    /* キー押下を「移動継続フレーム数」に変換するバッファ。
       連続フレームで滑らかに動かす。 */
    int padl_up_f = 0, padl_dn_f = 0;
    int padr_up_f = 0, padr_dn_f = 0;
    const int PAD_VEL    = 5;   // 1 フレームあたりの移動量 (px)
    const int KEY_FRAMES = 36;  // 1 押下で 36 フレーム継続 (約 600ms)
                                // Windows の連打開始遅延 (250-500ms) を埋めるため長め

    set_padl(padl_x, padl_y);
    set_padr(padr_x, padr_y);
    set_ball(ball_x, ball_y);

    while (1) {
        /* キー入力を全て吸い上げて「移動継続フレーム数」を加算 */
        int c;
        while ((c = uart_getchar_nb()) >= 0) {
            switch (c) {
                case 'w': case 'W': padl_up_f = KEY_FRAMES; break;
                case 's': case 'S': padl_dn_f = KEY_FRAMES; break;
                case 'i': case 'I': padr_up_f = KEY_FRAMES; break;
                case 'k': case 'K': padr_dn_f = KEY_FRAMES; break;
                default: break;
            }
        }

        /* 継続フレームに応じてパドルを毎フレーム移動 */
        if (padl_up_f > 0) { padl_y -= PAD_VEL; padl_up_f--; }
        if (padl_dn_f > 0) { padl_y += PAD_VEL; padl_dn_f--; }
        if (padr_up_f > 0) { padr_y -= PAD_VEL; padr_up_f--; }
        if (padr_dn_f > 0) { padr_y += PAD_VEL; padr_dn_f--; }

        /* パドル位置のクランプ */
        if (padl_y < 0) padl_y = 0;
        if (padl_y > (int)(SCREEN_H - PAD_H)) padl_y = SCREEN_H - PAD_H;
        if (padr_y < 0) padr_y = 0;
        if (padr_y > (int)(SCREEN_H - PAD_H)) padr_y = SCREEN_H - PAD_H;

        /* ボール移動 */
        ball_x += ball_dx;
        ball_y += ball_dy;

        /* 上下の壁: 反射 */
        if (ball_y <= 0) { ball_y = 0; ball_dy = -ball_dy; }
        if (ball_y >= (int)(SCREEN_H - BALL_H)) {
            ball_y = SCREEN_H - BALL_H;
            ball_dy = -ball_dy;
        }

        /* 左パドル衝突 */
        if (ball_dx < 0 &&
            ball_x <= padl_x + PAD_W && ball_x + BALL_W >= padl_x &&
            ball_y + BALL_H >= padl_y && ball_y <= padl_y + PAD_H) {
            ball_dx = -ball_dx;
            ball_x = padl_x + PAD_W;  // パドル右端に位置補正
        }

        /* 右パドル衝突 */
        if (ball_dx > 0 &&
            ball_x + BALL_W >= padr_x && ball_x <= padr_x + PAD_W &&
            ball_y + BALL_H >= padr_y && ball_y <= padr_y + PAD_H) {
            ball_dx = -ball_dx;
            ball_x = padr_x - BALL_W;  // パドル左端に位置補正
        }

        /* スコア: 左壁通過 = 右の得点 */
        if (ball_x + BALL_W <= 0) {
            right_score++;
            xil_printf("Score: %d - %d\r\n", left_score, right_score);
            ball_x = (SCREEN_W - BALL_W) / 2;
            ball_y = (SCREEN_H - BALL_H) / 2;
            ball_dx = 6;  // 右側にサーブ
        }
        /* 右壁通過 = 左の得点 */
        if (ball_x >= SCREEN_W) {
            left_score++;
            xil_printf("Score: %d - %d\r\n", left_score, right_score);
            ball_x = (SCREEN_W - BALL_W) / 2;
            ball_y = (SCREEN_H - BALL_H) / 2;
            ball_dx = -6;  // 左側にサーブ
        }

        set_padl(padl_x, padl_y);
        set_padr(padr_x, padr_y);
        set_ball(ball_x, ball_y);
        usleep(16000);
    }
    return 0;
}

/* ========== 以下、DP 初期化系 (kv260_rect から流用) ========== */

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

    u32 Status = XDpPsu_InitializeTx(&DpPsu);
    if (Status != XST_SUCCESS) {
        xil_printf("InitializeTx failed\r\n");
        return XST_FAILURE;
    }

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
    u32 Status;
    XDpPsu_LinkConfig *Link = &DpPsu.LinkConfig;

    Status = XDpPsu_GetRxCapabilities(&DpPsu);
    if (Status != XST_SUCCESS) {
        xil_printf("GetRxCaps failed\r\n");
        return XST_FAILURE;
    }

    XDpPsu_SetEnhancedFrameMode(&DpPsu, Link->SupportEnhancedFramingMode ? 1 : 0);
    XDpPsu_SetLaneCount(&DpPsu, Link->MaxLaneCount);
    XDpPsu_SetLinkRate(&DpPsu, LINK_RATE_270);
    XDpPsu_SetDownspread(&DpPsu, Link->SupportDownspreadControl);

    xil_printf("Training: %d lanes, rate 0x%x\r\n", DpPsu.LinkConfig.LaneCount, DpPsu.LinkConfig.LinkRate);
    Status = XDpPsu_EstablishLink(&DpPsu);
    if (Status == XST_SUCCESS)
        xil_printf("Training OK\r\n");
    else
        xil_printf("Training failed\r\n");

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

    if (!XDpPsu_IsConnected(&DpPsu)) {
        xil_printf("Not connected\r\n");
        return;
    }
    xil_printf("Connected\r\n");

    u8 AuxData = 0x1;
    XDpPsu_AuxWrite(&DpPsu, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &AuxData);
    XDpPsu_AuxWrite(&DpPsu, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &AuxData);

    /* Phase A1 簡略化: TrainLink + SetupVideoStream を 1 回だけ実行
       CheckLinkStatus ループは省略 */
    usleep(100000);
    if (TrainLink() == XST_SUCCESS) {
        SetupVideoStream();
    }
    xil_printf("RunDP returning\r\n");
}

static void HpdEvent(void *ref)
{
    xil_printf("HPD event\r\n");
    RunDP();
}

static void HpdPulse(void *ref)
{
    xil_printf("HPD pulse\r\n");
    u32 Status = XDpPsu_CheckLinkStatus(&DpPsu, DpPsu.LinkConfig.LaneCount);
    if (Status == XST_DEVICE_NOT_FOUND) return;

    XDpPsu_EnableMainLink(&DpPsu, 0);
    u8 Count = 0;
    do {
        Count++;
        Status = TrainLink();
        if (Status != XST_SUCCESS) continue;
        SetupVideoStream();
        Status = XDpPsu_CheckLinkStatus(&DpPsu, DpPsu.LinkConfig.LaneCount);
    } while ((Status != XST_SUCCESS) && (Count < 2));
}
