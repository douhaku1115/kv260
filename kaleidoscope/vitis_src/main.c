#include "xil_printf.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xparameters.h"
#include <math.h>
#include "xdppsu.h"
#include "xavbuf.h"
#include "xavbuf_clk.h"
#include "xdppsu.h"
#ifndef SDT
#include "xscugic.h"
#else
#include "xinterrupt_wrap.h"
#endif

/* Base addresses */
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

/* ========== 万華鏡のレジスタ (kaleido_axi_slave、0x10 刻み) ========== */
#define KAL_BASE      0xA0000000U
#define KAL_CTRL      (KAL_BASE + 0x000)   /* bit0 = 2枚鏡 */
#define KAL_KX        (KAL_BASE + 0x010)   /* 2^27 / (2*720*focal) */
#define KAL_Z_MIRROR  (KAL_BASE + 0x020)   /* Q16 */
#define KAL_REMAIN0   (KAL_BASE + 0x030)   /* Q14 */
#define KAL_INV_TR    (KAL_BASE + 0x040)   /* Q16 */
#define KAL_COS_T     (KAL_BASE + 0x050)   /* Q15 */
#define KAL_SIN_T     (KAL_BASE + 0x060)   /* Q15 */
#define KAL_WALL(w,i) (KAL_BASE + 0x070 + ((w)*3 + (i))*0x10)   /* nx,ny,wd */
#define KAL_VERT(v,i) (KAL_BASE + 0x100 + ((v)*2 + (i))*0x10)   /* x,y */
#define KAL_COMMIT    (KAL_BASE + 0x160)
#define KAL_FRAME_CNT (KAL_BASE + 0x170)

/* 筒の寸法 (cm)。参照実装と同じ */
#define TUBE_R    2.25f
#define Z_MIRROR  0.3f
#define Z_CELL    12.2f
#define MIRROR_R  2.05f

/* 設定。段7 で UART から変えられるようにする */
static int   set_points     = 8;      /* 3〜12 */
static int   set_mirror2    = 0;      /* 0 = 3枚鏡, 1 = 2枚鏡 */
static float set_zoom       = 1.0f;   /* 0.5〜2.5 */
static float set_autorotate = 1.00f;  /* 0〜1。段4の確認中は最大(0.6rad/s、約10秒で1周) */

typedef enum { LANE_COUNT_1 = 1, LANE_COUNT_2 = 2 } LaneCount_t;
typedef enum { LINK_RATE_162 = 0x06, LINK_RATE_270 = 0x0A, LINK_RATE_540 = 0x14 } LinkRate_t;

static XDpPsu DpPsu;
static XAVBuf AVBuf;

/* Forward declarations */
static int InitDP(void);
static void RunDP(void);
static void SetupVideoStream(void);
static u32 TrainLink(void);
static void KalSetGeometry(void);

int main(void)
{
    Xil_DCacheDisable();
    Xil_ICacheDisable();

    xil_printf("KV260 Kaleidoscope Start\r\n");

    if (InitDP() != XST_SUCCESS) {
        xil_printf("DP init failed\r\n");
        return XST_FAILURE;
    }

    sleep(1);
    RunDP();

    /* HPD 割り込みは設定しない。
       設定すると "Video stream started" の直後で止まり、映像が出ない
       （2026-09-18 実機で確認。ログが "Running." まで進まなかった）。
       動作実績のある kv260_pong も割り込みを一切設定していない。
       モニタの抜き差しに追従しなくなるが、表示には影響しない。 */
    /* ========== 万華鏡のパラメータを書く ========== */
    KalSetGeometry();
    xil_printf("Running. points=%d mirror=%d\r\n", set_points, set_mirror2 ? 2 : 3);

    /* ========== AXI の疎通確認 ==========
     * 書いた値が読み返せるか、PL のフレーム数が進んでいるかを見る。
     * 回らないときは、ここの出力で原因が分かる:
     *   KX が 109655 でない      → 書き込みが届いていない
     *   FRAME_CNT が 0 のまま    → frame_start が立っていない、か読み出し経路
     *   FRAME_CNT が進む         → PL 側は正常。待ちループ以外が原因
     */
    xil_printf("--- AXI diag ---\r\n");
    for (int i = 0; i < 5; i++) {
        xil_printf("  FRAME_CNT=%u  KX=%u  NX0=%u  COS=%u\r\n",
                   (unsigned)Xil_In32(KAL_FRAME_CNT),
                   (unsigned)Xil_In32(KAL_KX),
                   (unsigned)Xil_In32(KAL_WALL(0,0)),
                   (unsigned)Xil_In32(KAL_COS_T));
        usleep(100000);          /* 100ms = 6 フレームぶん */
    }
    xil_printf("--- AXI diag done ---\r\n");

    /* ========== 毎フレーム、筒の回転角を進める ========== */
    /* 参照実装の筒の回転速度 = autoRotate * 0.6 [rad/s] */
    float angle = 0.0f;
    const float dt = 1.0f / 60.0f;
    u32 last = Xil_In32(KAL_FRAME_CNT);
    int  use_frame_cnt = 1;
    int  reported = 0;
    int  tick = 0;

    while (1) {
        /* PL が数えたフレーム数が進むまで待つ (映像と歩調を合わせる)。
           進まない場合は待ち続けずに時間待ちへ切り替える。 */
        if (use_frame_cnt) {
            u32 now;
            int guard = 0;
            do { now = Xil_In32(KAL_FRAME_CNT); } while (now == last && ++guard < 2000000);
            if (guard >= 2000000) {
                if (!reported) { xil_printf("FRAME_CNT が進まない。時間待ちに切替\r\n"); reported = 1; }
                use_frame_cnt = 0;
            }
            last = now;
        } else {
            usleep(16667);       /* 60fps 相当 */
        }

        angle += set_autorotate * 0.6f * dt;
        if (angle > 6.2831853f) angle -= 6.2831853f;

        Xil_Out32(KAL_COS_T, (u32)(s32)(cosf(angle) * 32768.0f));
        Xil_Out32(KAL_SIN_T, (u32)(s32)(sinf(angle) * 32768.0f));
        Xil_Out32(KAL_COMMIT, 1);      /* ここまでの値を次のフレーム先頭で一括反映 */

        /* 回転が効いているかを目で確かめるため、1 秒ごとに角度を出す。
           読み返した COS/SIN がレジスタに入っていれば、書き込みは届いている。 */
        if (++tick >= 60) {
            tick = 0;
            xil_printf("angle=%d/1000 rad  COS=%d SIN=%d  FRAME_CNT=%u\r\n",
                       (int)(angle * 1000.0f),
                       (int)(s32)(Xil_In32(KAL_COS_T) << 12) >> 12,
                       (int)(s32)(Xil_In32(KAL_SIN_T) << 12) >> 12,
                       (unsigned)Xil_In32(KAL_FRAME_CNT));
        }
    }
    return 0;
}

/* ========== 鏡の三角形を計算して PL へ渡す ==========
 * 参照実装 mirrorGeometry() と同じ。頂角 180/points の二等辺三角形で、
 * 外接円の半径は MIRROR_R。頂点が上、底辺が下。
 * PL は三角関数を持たない。ここで計算した法線と頂点だけを渡す。
 */
static void KalSetGeometry(void)
{
    const float al = 3.14159265f / (float)set_points;
    const float R  = MIRROR_R;

    float vx[3], vy[3];
    vx[0] = 0.0f;                                 vy[0] = R;
    vx[1] = R * cosf(1.5f * 3.14159265f - al);    vy[1] = R * sinf(1.5f * 3.14159265f - al);
    vx[2] = R * cosf(1.5f * 3.14159265f + al);    vy[2] = R * sinf(1.5f * 3.14159265f + al);

    const float cx = (vx[0] + vx[1] + vx[2]) / 3.0f;
    const float cy = (vy[0] + vy[1] + vy[2]) / 3.0f;

    /* 壁の並びは参照実装と同じ: (A,B) (A,C) (B,C)。[2] が底辺 */
    const int pa[3] = {0, 0, 1};
    const int pb[3] = {1, 2, 2};

    for (int w = 0; w < 3; w++) {
        float ex = vx[pb[w]] - vx[pa[w]];
        float ey = vy[pb[w]] - vy[pa[w]];
        float l  = sqrtf(ex*ex + ey*ey);
        ex /= l; ey /= l;
        float nx =  ey, ny = -ex;
        /* 法線を外向きに揃える (重心と逆を向かせる) */
        if ((cx - vx[pa[w]]) * nx + (cy - vy[pa[w]]) * ny > 0.0f) { nx = -nx; ny = -ny; }
        float d = vx[pa[w]] * nx + vy[pa[w]] * ny;

        Xil_Out32(KAL_WALL(w,0), (u32)(s32)(nx * 65536.0f));   /* Q16 */
        Xil_Out32(KAL_WALL(w,1), (u32)(s32)(ny * 65536.0f));   /* Q16 */
        Xil_Out32(KAL_WALL(w,2), (u32)(s32)(d  * 16384.0f));   /* Q14 */
    }

    for (int v = 0; v < 3; v++) {
        Xil_Out32(KAL_VERT(v,0), (u32)(s32)(vx[v] * 32768.0f));  /* Q15 */
        Xil_Out32(KAL_VERT(v,1), (u32)(s32)(vy[v] * 32768.0f));  /* Q15 */
    }

    /* 画角。kx = 2^27 / (2 * 画面の高さ * focal),  focal = 0.85 * zoom */
    Xil_Out32(KAL_KX,       (u32)(134217728.0f / (1440.0f * 0.85f * set_zoom)));
    Xil_Out32(KAL_Z_MIRROR, (u32)(Z_MIRROR * 65536.0f));                 /* Q16 */
    Xil_Out32(KAL_REMAIN0,  (u32)((Z_CELL - Z_MIRROR) * 16384.0f));      /* Q14 */
    Xil_Out32(KAL_INV_TR,   (u32)(65536.0f / TUBE_R));                   /* Q16 */
    Xil_Out32(KAL_CTRL,     set_mirror2 ? 1 : 0);
    Xil_Out32(KAL_COS_T,    32768);
    Xil_Out32(KAL_SIN_T,    0);
    Xil_Out32(KAL_COMMIT,   1);
}

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

    /* Live video input, no audio */
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

    /* Wake up monitor */
    u8 AuxData = 0x1;
    XDpPsu_AuxWrite(&DpPsu, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &AuxData);
    XDpPsu_AuxWrite(&DpPsu, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &AuxData);

    /* TrainLink + SetupVideoStream を 1 回だけ実行する。
       XDpPsu_CheckLinkStatus のループは kv260_pong でも省略しており、
       入れるとハングすることがある。 */
    usleep(100000);
    if (TrainLink() == XST_SUCCESS) {
        SetupVideoStream();
    }
    xil_printf("RunDP returning\r\n");
}
