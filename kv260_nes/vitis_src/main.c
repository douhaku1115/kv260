/* ============================================================
 * KV260 NES 段A: 画面バッファ表示の確認
 * ============================================================
 *
 * PL の NES 画面バッファ (256x240, 1 画素 = 6bit の色番号) に PS から
 * 色見本を書き、HDMI に 3 倍 (768x720) で映るかを見る。
 * 同時に Pmod I2S2 (J2) から約 762Hz の固定トーンが鳴る (PL だけで鳴らす)。
 *
 * AXI マップ (0xA0000000, 256KB)。レジスタは 0x10 刻み:
 *   0x00000 CTRL  (RW)  段C で使う
 *   0x00010 ID    (R)   0x4E455301
 *   0x00020 PAD   (RW)  段E で使う
 *   0x00030 FRAME (R)   映像のフレーム数
 *   0x10000〜     FB    (W)  語番号 = y*64 + x/4、1 語 = 横 4 画素
 *                       [5:0]=x, [13:8]=x+1, [21:16]=x+2, [29:24]=x+3
 */

#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xparameters.h"
#include "xdppsu.h"
#include "xavbuf.h"
#include "xavbuf_clk.h"
#include "sleep.h"
#include <stdint.h>

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
#define NES_FB       (NES_BASE + 0x10000)

#define NES_W  256
#define NES_H  240

typedef enum { LINK_RATE_270 = 0x0A } LinkRate_t;

static XDpPsu DpPsu;
static XAVBuf AVBuf;

static int  InitDP(void);
static void RunDP(void);
static void SetupVideoStream(void);
static u32  TrainLink(void);

/* 色見本の 1 画素: 色番号 (0〜63) を返す
 *   外周 1 画素 = 白 (0x30)。NES 画面の端が欠けずに映っているかを見る
 *   内側 = 横 16 列 x 縦 4 段で 64 色を全部並べる (列 = 下位 4bit, 段 = 上位 2bit) */
static uint32_t test_color(int x, int y)
{
    if (x == 0 || x == NES_W - 1 || y == 0 || y == NES_H - 1) return 0x30;
    return (uint32_t)(((y / 60) << 4) | (x / 16));
}

/* 画面バッファ全体に色見本を書く (1 語 = 横 4 画素) */
static void fb_draw_test(void)
{
    for (int y = 0; y < NES_H; y++) {
        for (int x = 0; x < NES_W; x += 4) {
            uint32_t w = test_color(x, y)
                       | (test_color(x + 1, y) << 8)
                       | (test_color(x + 2, y) << 16)
                       | (test_color(x + 3, y) << 24);
            Xil_Out32(NES_FB + (uint32_t)((y * 64 + x / 4) * 4), w);
        }
    }
}

int main(void)
{
    Xil_DCacheDisable();
    Xil_ICacheDisable();

    xil_printf("\r\n==== KV260 NES stage A ====\r\n");

    /* AXI が届いているか: ID を読む */
    u32 id = Xil_In32(NES_ID);
    xil_printf("ID    = 0x%08x (expect 0x4E455301) %s\r\n", id, (id == 0x4E455301U) ? "OK" : "NG");

    if (InitDP() != XST_SUCCESS) { xil_printf("DP init failed\r\n"); return XST_FAILURE; }
    sleep(1);
    RunDP();

    /* 映像クロックが PL に来ているか: 1 秒でフレーム数が約 60 増えるか */
    u32 f0 = Xil_In32(NES_FRAME);
    sleep(1);
    u32 f1 = Xil_In32(NES_FRAME);
    xil_printf("FRAME %u -> %u (+%u, expect about 60)\r\n", f0, f1, f1 - f0);

    fb_draw_test();
    xil_printf("test pattern written: 64 colors (16 x 4) + white border\r\n");
    xil_printf("I2S2 (J2): about 762Hz tone should be playing\r\n");

    while (1) {
        sleep(5);
        xil_printf("FRAME %u\r\n", Xil_In32(NES_FRAME));
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
 *   - 映像ストリーム1 を Live に、音声は無しに構成
 *   - 映像クロックを PL クロック源に指定して AVBuf を SoftReset
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
