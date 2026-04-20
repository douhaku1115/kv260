/*
 * KV260 カスタムAXI IP LED制御 (案1)
 *
 * 概要:
 *   PL上のカスタムAXI IPのレジスタにPS(ARM)からAXI経由で
 *   値を書き込み・読み返し、その値でオンボードLED(MIO7)を制御する。
 *
 * 構成:
 *   PS (Cortex-A53) --AXI--> SmartConnect --AXI--> カスタムIP (PL)
 *                                                    レジスタ0〜3
 *   PS GPIO MIO7 --> LED1
 *
 * 動作:
 *   1. led_patterns[]の値を順にカスタムIPのREG0に書き込む (AXI Write)
 *   2. REG0を読み返す (AXI Read)
 *   3. 読み返した値のbit0でLEDをON/OFF
 *   4. 500ms待って次のパターンへ
 *
 * ツール: Vivado/Vitis 2025.1, JTAG実行
 */

#include "xparameters.h"
#include "xgpiops.h"
#include "xil_io.h"
#include "sleep.h"

/* カスタムAXI IPベースアドレス (pl.dtsiで確認: 0x80000000) */
#define CUSTOM_IP_BASEADDR   0x80000000

/* IPレジスタオフセット (4レジスタ, 各32bit) */
#define REG0_OFFSET   0x00
#define REG1_OFFSET   0x04
#define REG2_OFFSET   0x08
#define REG3_OFFSET   0x0C

/* AXI IPレジスタ操作マクロ */
#define IP_WRITE(offset, val)  Xil_Out32(CUSTOM_IP_BASEADDR + (offset), (val))
#define IP_READ(offset)        Xil_In32(CUSTOM_IP_BASEADDR + (offset))

/* PS GPIO LED */
#define GPIO_DEVICE_ID   XPAR_XGPIOPS_0_BASEADDR
#define LED_PIN          7    /* MIO7 = LED1 (heartbeat) */

static XGpioPs Gpio;

/* LEDパターン: 点滅→2回点灯・2回消灯 */
static const u32 led_patterns[] = {
    0x01, 0x00, 0x01, 0x00,
    0x01, 0x01, 0x00, 0x00,
};

int main(void)
{
    XGpioPs_Config *cfg;
    u32 read_val;
    int i;

    /* PS GPIO初期化: MIO7を出力に設定 */
    cfg = XGpioPs_LookupConfig(GPIO_DEVICE_ID);
    if (!cfg) return -1;
    XGpioPs_CfgInitialize(&Gpio, cfg, cfg->BaseAddr);
    XGpioPs_SetDirectionPin(&Gpio, LED_PIN, 1);
    XGpioPs_SetOutputEnablePin(&Gpio, LED_PIN, 1);

    while (1) {
        for (i = 0; i < sizeof(led_patterns)/sizeof(led_patterns[0]); i++) {
            /* カスタムIPのREG0にパターン値を書き込み (PS→PL AXI Write) */
            IP_WRITE(REG0_OFFSET, led_patterns[i]);

            /* REG0を読み返し (PL→PS AXI Read) */
            read_val = IP_READ(REG0_OFFSET);

            /* 読み返した値のbit0でLED制御 */
            XGpioPs_WritePin(&Gpio, LED_PIN, read_val & 0x01);

            usleep(500000);  /* 500ms待機 */
        }
    }

    return 0;
}
