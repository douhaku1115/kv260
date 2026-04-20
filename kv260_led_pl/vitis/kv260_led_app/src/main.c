#include "xparameters.h"
#include "xtmrctr.h"
#include "xscugic.h"
#include "xgpiops.h"
#include "xil_exception.h"

/* AXI Timer */
#define TIMER_DEVICE_ID    XPAR_XTMRCTR_0_BASEADDR
#define TIMER_INTR_ID      XPAR_FABRIC_XTMRCTR_0_INTR
#define TIMER_COUNTER_0    0

/* GIC */
#define INTC_DEVICE_ID     XPAR_XSCUGIC_0_BASEADDR

/* PS GPIO LED */
#define GPIO_DEVICE_ID     XPAR_XGPIOPS_0_BASEADDR
#define LED_PIN            7

/* 約500ms (100MHz clock) */
#define TIMER_LOAD_VALUE   50000000

static XTmrCtr Timer;
static XScuGic Intc;
static XGpioPs Gpio;
static volatile int LedState = 0;

void TimerIntrHandler(void *CallBackRef, u8 TmrCtrNumber)
{
	LedState = !LedState;
	XGpioPs_WritePin(&Gpio, LED_PIN, LedState);
}

int main(void)
{
	XGpioPs_Config *gpio_cfg;
	XScuGic_Config *intc_cfg;
	int status;

	/* GPIO初期化 */
	gpio_cfg = XGpioPs_LookupConfig(GPIO_DEVICE_ID);
	if (!gpio_cfg) return -1;
	XGpioPs_CfgInitialize(&Gpio, gpio_cfg, gpio_cfg->BaseAddr);
	XGpioPs_SetDirectionPin(&Gpio, LED_PIN, 1);
	XGpioPs_SetOutputEnablePin(&Gpio, LED_PIN, 1);
	XGpioPs_WritePin(&Gpio, LED_PIN, 0);

	/* GIC初期化 */
	intc_cfg = XScuGic_LookupConfig(INTC_DEVICE_ID);
	if (!intc_cfg) return -1;
	status = XScuGic_CfgInitialize(&Intc, intc_cfg, intc_cfg->CpuBaseAddress);
	if (status != XST_SUCCESS) return -1;

	Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
			(Xil_ExceptionHandler)XScuGic_InterruptHandler, &Intc);
	Xil_ExceptionEnable();

	/* AXI Timer初期化 */
	status = XTmrCtr_Initialize(&Timer, TIMER_DEVICE_ID);
	if (status != XST_SUCCESS) return -1;

	XTmrCtr_SetHandler(&Timer, TimerIntrHandler, &Timer);
	XTmrCtr_SetOptions(&Timer, TIMER_COUNTER_0,
			XTC_INT_MODE_OPTION | XTC_AUTO_RELOAD_OPTION | XTC_DOWN_COUNT_OPTION);
	XTmrCtr_SetResetValue(&Timer, TIMER_COUNTER_0, TIMER_LOAD_VALUE);

	/* GICにタイマー割り込み接続 */
	status = XScuGic_Connect(&Intc, TIMER_INTR_ID,
			(Xil_InterruptHandler)XTmrCtr_InterruptHandler, &Timer);
	if (status != XST_SUCCESS) return -1;
	XScuGic_Enable(&Intc, TIMER_INTR_ID);

	/* タイマー開始 */
	XTmrCtr_Start(&Timer, TIMER_COUNTER_0);

	while (1) {
	}

	return 0;
}
