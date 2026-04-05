#include "xil_printf.h"
#include "xil_cache.h"
#include "xparameters.h"
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

typedef enum { LANE_COUNT_1 = 1, LANE_COUNT_2 = 2 } LaneCount_t;
typedef enum { LINK_RATE_162 = 0x06, LINK_RATE_270 = 0x0A, LINK_RATE_540 = 0x14 } LinkRate_t;

static XDpPsu DpPsu;
static XAVBuf AVBuf;
static XScuGic Intr;

/* Forward declarations */
static int InitDP(void);
static void RunDP(void);
static void SetupVideoStream(void);
static void HpdEvent(void *ref);
static void HpdPulse(void *ref);
static u32 TrainLink(void);

int main(void)
{
    Xil_DCacheDisable();
    Xil_ICacheDisable();

    xil_printf("KV260 Rectangle Display Start\r\n");

    if (InitDP() != XST_SUCCESS) {
        xil_printf("DP init failed\r\n");
        return XST_FAILURE;
    }

    sleep(1);
    RunDP();

    /* Setup HPD interrupts */
    u32 IntrMask = XDPPSU_INTR_HPD_IRQ_MASK | XDPPSU_INTR_HPD_EVENT_MASK;
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, XDPPSU_INTR_DIS, 0xFFFFFFFF);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, XDPPSU_INTR_MASK, 0xFFFFFFFF);
    XDpPsu_SetHpdEventHandler(&DpPsu, HpdEvent, NULL);
    XDpPsu_SetHpdPulseHandler(&DpPsu, HpdPulse, NULL);

#ifndef SDT
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
    XSetupInterruptSystem(&DpPsu, &XDpPsu_HpdInterruptHandler,
                          DpPsu.Config.IntrId, DpPsu.Config.IntrParent,
                          XINTERRUPT_DEFAULT_PRIORITY);
    XDpPsu_WriteReg(DpPsu.Config.BaseAddr, XDPPSU_INTR_EN, IntrMask);
#endif

    xil_printf("Running. Waiting for HPD events...\r\n");
    while (1);
    return 0;
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
