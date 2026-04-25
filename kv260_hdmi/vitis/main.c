/*
 * KV260 HDMI矩形表示 (案5)
 *
 * 概要:
 *   PL側で1280x720@60のVGAタイミング映像（青背景＋白矩形）を生成し、
 *   PS内蔵DisplayPortコントローラ経由でHDMIモニターに出力する。
 *   KV260ボード上のSTDP4320チップがDP→HDMI変換を行う。
 *
 * 信号経路:
 *   PL (rtl_top.v)                    PS                           外部
 *   ┌──────────────┐    ┌──────────────────────┐    ┌──────────┐
 *   │ VGAタイミング  │───→│ dp_live_video_in_*   │    │          │
 *   │ 矩形描画      │    │   ↓                  │    │ STDP4320 │──→ HDMI
 *   │ 1280x720     │    │ AVBuf(映像パイプライン) │    │ (DP→HDMI) │    モニター
 *   │              │    │   ↓                  │    │          │
 *   │              │    │ DPコントローラ        │───→│          │
 *   └──────────────┘    │   ↑                  │    └──────────┘
 *                       │ TrainLink(AUX通信)    │
 *                       └──────────────────────┘
 *
 * PL側Verilogモジュール:
 *   rtl_top.v          - トップモジュール。矩形描画、RGB24→RGB36変換
 *   vga_iface.v        - VGAタイミング生成（H/Vsync, DE, カウンタ）
 *   cdc_synchronizer.v - クロックドメイン間同期
 *   shift_register.v   - パイプライン遅延用シフトレジスタ
 *
 * クロック構成:
 *   pl_clk0 (100MHz) → clk_wiz_0 → clk_out1 → rtl_top.clk (ロジック用)
 *   dp_video_ref_clk (74.25MHz) → rtl_top.clkv (映像タイミング用)
 *                                → dp_video_in_clk (PS映像入力クロック)
 *
 * 処理の流れ:
 *   main() → InitDP() → sleep(1) → RunDP() → 割り込み設定 → 無限ループ(HPD待ち)
 *
 * ビルド環境: Vivado/Vitis 2025.1, JTAG実行
 *
 * 注意事項:
 *   - psu_initは本プロジェクトのものを使用
 *   - video_colorはdp_live_video_in_pixel1に接続（dp_live_gfx_pixel1_inではない）
 *   - SDT/非SDTの両方に対応（#ifndef SDTで分岐）
 *   - AVBuf Input Ref Clk = 3333333333 Hzの表示はドライバ仕様
 *     （33.333MHz × 100倍精度。バグではない）
 */

#include "xil_printf.h"    /* xil_printf: 軽量printf */
#include "xil_cache.h"     /* キャッシュ制御（DCacheDisable等） */
#include "xparameters.h"   /* ハードウェアアドレス定義 */
#include "xdppsu.h"        /* DisplayPort PSU ドライバ */
#include "xavbuf.h"        /* Audio/Video Buffer（映像パイプライン） */
#include "xavbuf_clk.h"    /* AVBufクロック設定（VPLL制御） */
#include "xdppsu.h"
#ifndef SDT
#include "xscugic.h"       /* GIC 割り込みコントローラ（非SDTモード） */
#else
#include "xinterrupt_wrap.h" /* 割り込みラッパー（SDTモード） */
#endif

/* ========== デバイスアドレス定義 ========== */
/*
 * SDT(System Device Tree)モード: Vitis 2025.1のデフォルト。ベースアドレスで識別。
 * 非SDTモード: 旧方式。デバイスIDで識別。
 */
#ifndef SDT
#define DPPSU_DEVICE_ID   XPAR_PSU_DP_DEVICE_ID
#define AVBUF_DEVICE_ID   XPAR_PSU_DP_DEVICE_ID
#define INTC_DEVICE_ID    XPAR_SCUGIC_0_DEVICE_ID
#define DPPSU_INTR_ID     151          /* DPの割り込み番号（GIC上のID） */
#define DPPSU_BASEADDR    XPAR_PSU_DP_BASEADDR
#define AVBUF_BASEADDR    XPAR_PSU_DP_BASEADDR
#else
#define DPPSU_BASEADDR    XPAR_XDPPSU_0_BASEADDR
#define AVBUF_BASEADDR    XPAR_XDPPSU_0_BASEADDR
#define INTC_BASEADDR     XPAR_XSCUGIC_0_BASEADDR
#endif

/* DisplayPortのレーン数・リンクレート定義 */
typedef enum { LANE_COUNT_1 = 1, LANE_COUNT_2 = 2 } LaneCount_t;
typedef enum { LINK_RATE_162 = 0x06, LINK_RATE_270 = 0x0A, LINK_RATE_540 = 0x14 } LinkRate_t;

/* ドライバインスタンス（グローバル） */
static XDpPsu DpPsu;   /* DisplayPortドライバ */
static XAVBuf AVBuf;   /* 映像パイプラインドライバ */
static XScuGic Intr;   /* 割り込みコントローラ */

/* 関数プロトタイプ */
static int InitDP(void);
static void RunDP(void);
static void SetupVideoStream(void);
static void HpdEvent(void *ref);
static void HpdPulse(void *ref);
static u32 TrainLink(void);

/*
 * main - エントリポイント
 *
 * 処理の流れ:
 *   1. キャッシュ無効化（ハードウェアレジスタ直接操作のため）
 *   2. InitDP() - DPコントローラ・映像パイプライン初期化
 *   3. sleep(1) - モニターのHPD信号安定待ち
 *   4. RunDP() - モニター接続確認、リンクトレーニング、映像出力開始
 *   5. 割り込み設定 - HDMIケーブル抜き差し（HPD）対応
 *   6. while(1) - HPD割り込みを待ち続ける
 */
int main(void)
{
    Xil_DCacheDisable();
    Xil_ICacheDisable();

    xil_printf("\r\nKV260 Rectangle Display Start\r\n");

    if (InitDP() != XST_SUCCESS) {
        xil_printf("DP init failed\r\n");
        return XST_FAILURE;
    }

    sleep(1);
    RunDP();

    /*
     * HPD(Hot Plug Detect)割り込み設定
     * ケーブル抜き差し時に自動でリンク再確立するため
     */
    u32 IntrMask = XDPPSU_INTR_HPD_IRQ_MASK | XDPPSU_INTR_HPD_EVENT_MASK;
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, XDPPSU_INTR_DIS, 0xFFFFFFFF);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, XDPPSU_INTR_MASK, 0xFFFFFFFF);
    XDpPsu_SetHpdEventHandler(&DpPsu, HpdEvent, NULL);
    XDpPsu_SetHpdPulseHandler(&DpPsu, HpdPulse, NULL);

#ifndef SDT
    /* 非SDTモード: GICを手動で初期化・接続 */
    XScuGic_Config *IntrCfg = XScuGic_LookupConfig(INTC_DEVICE_ID);
    XScuGic_CfgInitialize(&Intr, IntrCfg, IntrCfg->CpuBaseAddress);
    XScuGic_Connect(&Intr, DPPSU_INTR_ID,
                    (Xil_InterruptHandler)XDpPsu_HpdInterruptHandler, &DpPsu);
    XScuGic_SetPriorityTriggerType(&Intr, DPPSU_INTR_ID, 0x0, 0x03);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_IRQ_INT,
                                 (Xil_ExceptionHandler)XScuGic_DeviceInterruptHandler,
                                 INTC_DEVICE_ID);
    Xil_ExceptionEnableMask(XIL_EXCEPTION_IRQ);
    Xil_ExceptionEnable();
    XScuGic_Enable(&Intr, DPPSU_INTR_ID);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, XDPPSU_INTR_EN, IntrMask);
#else
    /* SDTモード: 統合APIで割り込み設定 */
    XSetupInterruptSystem(&DpPsu, &XDpPsu_HpdInterruptHandler,
                          DpPsu.Config.IntrId, DpPsu.Config.IntrParent,
                          XINTERRUPT_DEFAULT_PRIORITY);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, XDPPSU_INTR_EN, IntrMask);
#endif

    xil_printf("Running. Waiting for HPD events...\r\n");
    while (1);
    return 0;
}

/*
 * InitDP - DisplayPortコントローラと映像パイプラインの初期化
 *
 * 処理:
 *   1. DPドライバ初期化（LookupConfig → CfgInitialize → InitializeTx）
 *   2. 映像ソース設定: PLからのライブ入力(RGB 12bit/色)、出力RGB 8bit/色
 *   3. グラフィックスオーバーレイ無し、オーディオ無し
 *   4. クロックソース: 映像=PSクロック(VPLL)、出力=PLクロック(clk_wiz経由)
 *
 * 戻り値: XST_SUCCESS=成功, XST_FAILURE=失敗
 */
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

    /* PL→PS映像パイプライン設定 */
    XAVBuf_SetInputLiveVideoFormat(&AVBuf, RGB_12BPC);   /* PL入力: RGB 12bit/色 */
    XAVBuf_SetOutputVideoFormat(&AVBuf, RGB_8BPC);        /* 出力: RGB 8bit/色 */
    XAVBuf_InputVideoSelect(&AVBuf, XAVBUF_VIDSTREAM1_LIVE, XAVBUF_VIDSTREAM2_NONE);
    XAVBuf_InputAudioSelect(&AVBuf, XAVBUF_AUDSTREAM1_NO_AUDIO, XAVBUF_AUDSTREAM2_NO_AUDIO);

    /* ピクセルクロック設定（この時点ではMSA未設定のため0、SetupVideoStreamで再設定） */
    XDpPsu_MainStreamAttributes *Msa = &DpPsu.MsaConfig;
    XAVBuf_SetPixelClock(Msa->PixelClockHz);

    XAVBuf_ConfigureGraphicsPipeline(&AVBuf);
    XAVBuf_ConfigureOutputVideo(&AVBuf);
    XAVBuf_SetBlenderAlpha(&AVBuf, 0, 0);         /* アルファブレンド無し */
    XDpPsu_CfgMsaEnSynchClkMode(&DpPsu, 0);       /* 非同期クロックモード */
    XAVBuf_SetAudioVideoClkSrc(&AVBuf, XAVBUF_PS_CLK, XAVBUF_PL_CLK);
    XAVBuf_SoftReset(&AVBuf);

    return XST_SUCCESS;
}

/*
 * TrainLink - DisplayPortリンクトレーニング
 *
 * DisplayPortはモニターとの通信確立に「トレーニング」が必要。
 * 処理:
 *   1. モニターの能力取得（対応レーン数・速度）
 *   2. 拡張フレームモード・レーン数・リンクレート設定
 *   3. トレーニング実行（CR→EQ→完了）
 *
 * KV260は最大2レーン、リンクレート2.7Gbps/レーンで使用。
 */
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

/*
 * SetupVideoStream - 映像ストリーム設定
 *
 * トレーニング成功後に呼ばれ、映像パラメータを設定して出力開始。
 * MSA(Main Stream Attributes): 解像度・色深度・タイミング情報をモニターに伝える。
 *
 * 処理:
 *   1. 色空間(RGB)・色深度(8bit)・解像度(1280x720@60)設定
 *   2. ピクセルクロック設定（74.25MHz）
 *   3. DP送信器リセット・MSA書き込み・AVBufリセット
 *   4. メインリンク有効化 → 映像出力開始
 */
static void SetupVideoStream(void)
{
    XDpPsu_SetColorEncode(&DpPsu, XDPPSU_CENC_RGB);
    XDpPsu_CfgMsaSetBpc(&DpPsu, XVIDC_BPC_8);
    XDpPsu_CfgMsaUseStandardVideoMode(&DpPsu, XVIDC_VM_1280x720_60_P);

    XDpPsu_MainStreamAttributes *Msa = &DpPsu.MsaConfig;
    XAVBuf_SetPixelClock(Msa->PixelClockHz);

    /* DP送信器ソフトリセット */
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, XDPPSU_SOFT_RESET, 0x1);
    usleep(10);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, XDPPSU_SOFT_RESET, 0x0);

    /* MSA値をレジスタに書き込み */
    XDpPsu_SetMsaValues(&DpPsu);

    /* AVBufリセット（映像パイプライン再初期化） */
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, 0xB124, 0x3);
    usleep(10);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, 0xB124, 0x0);

    /* メインリンク有効化 → 映像出力開始 */
    XDpPsu_EnableMainLink(&DpPsu, 1);
    xil_printf("Video stream started\r\n");
}

/*
 * RunDP - モニター接続確認・トレーニング・映像出力
 *
 * 処理:
 *   1. メインリンク無効化（再設定のため）
 *   2. モニター接続確認
 *   3. AUXチャネル経由でモニターをスリープ解除
 *   4. リンクトレーニング → 映像出力（最大2回リトライ）
 */
static void RunDP(void)
{
    XDpPsu_EnableMainLink(&DpPsu, 0);

    if (!XDpPsu_IsConnected(&DpPsu)) {
        xil_printf("Not connected\r\n");
        return;
    }
    xil_printf("Connected\r\n");

    /* AUXチャネル経由でモニターのスリープ解除（2回送信で信頼性確保） */
    u8 AuxData = 0x1;
    XDpPsu_AuxWrite(&DpPsu, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &AuxData);
    XDpPsu_AuxWrite(&DpPsu, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &AuxData);

    u8 Count = 0;
    u32 Status;
    do {
        usleep(100000);
        Count++;
        Status = TrainLink();
        if (Status != XST_SUCCESS) continue;
        SetupVideoStream();
        Status = XDpPsu_CheckLinkStatus(&DpPsu, DpPsu.LinkConfig.LaneCount);
    } while ((Status != XST_SUCCESS) && (Count < 2));
}

/*
 * HpdEvent - HDMIケーブル接続/切断時のコールバック
 * モニターが接続されたらRunDP()を再実行してリンクを確立。
 */
static void HpdEvent(void *ref)
{
    xil_printf("HPD event\r\n");
    RunDP();
}

/*
 * HpdPulse - リンク異常時のコールバック
 * モニターがリンク再トレーニングを要求した場合に呼ばれる。
 */
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
