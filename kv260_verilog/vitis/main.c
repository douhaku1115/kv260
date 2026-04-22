/*
 * KV260 AXI GPIO + Verilogカウンタ LED制御 (案3)
 *
 * 概要:
 *   PL上のVerilogカウンタモジュールに対し、PSからAXI GPIO経由で
 *   speed値を設定し、カウンタ出力を読み取ってオンボードLED(MIO7)を制御する。
 *
 * ハードウェア構成:
 *   PS (Cortex-A53) --AXI--> axi_gpio_0 (出力) --gpio_io_o--> counter.speed
 *                   --AXI--> axi_gpio_1 (入力) <--gpio_io_i--- counter.count_out
 *   PS GPIO MIO7 --> LED1 (オンボード)
 *
 * PL側カウンタの動作 (counter.v):
 *   毎クロック(100MHz)で count <= count + speed を実行。
 *   speed=1 のとき 32bitカウンタが約42.9秒で一周する。
 *   bit24は 2^24 = 16,777,216 クロックで反転 → 約168msで0/1が切り替わる。
 *   speed=16 なら 168ms/16 ≒ 10.5ms で反転（高速点滅）。
 *
 * ソフトウェアの動作:
 *   1. PS GPIO MIO7を出力モードに初期化（LED制御用）
 *   2. axi_gpio_0にspeed値を書き込む（PS→PL、カウンタの加算量を設定）
 *   3. axi_gpio_1からcount_out値を読み取る（PL→PS、カウンタの現在値を取得）
 *   4. count_outのbit24を見てLEDをON/OFF
 *   5. 10msごとにポーリングし、約2秒ごとにspeedを変更
 *      speed: 1→2→4→8→16→8→4→2→1... と変化し、点滅速度が変わる
 *
 * 使用ライブラリ:
 *   - XGpioPs: PS側GPIO制御ドライバ（MIO7 LED用）
 *   - Xil_Out32/Xil_In32: メモリマップドI/O（AXI GPIOレジスタ直接アクセス）
 *
 * ツール: Vivado/Vitis 2025.1, JTAG実行
 */

#include "xparameters.h"
#include "xgpiops.h"     /* PS GPIO制御ドライバ（XGpioPs_*関数群） */
#include "xil_io.h"      /* Xil_Out32/Xil_In32: PLレジスタ読み書き */
#include "sleep.h"        /* usleep: マイクロ秒単位のウェイト */

/* ========== AXI GPIO (PL側) の定義 ========== */

/*
 * AXI GPIOベースアドレス (Vivadoのアドレスエディタで割り当て)
 * axi_gpio_0: PSからcounterへspeed値を送る（出力方向、C_ALL_OUTPUTS=1）
 * axi_gpio_1: counterからPSへcount_out値を読む（入力方向、C_ALL_INPUTS=1）
 */
#define GPIO_SPEED_BASEADDR   0xA0000000  /* axi_gpio_0 */
#define GPIO_COUNT_BASEADDR   0xA0010000  /* axi_gpio_1 */

/* AXI GPIO データレジスタオフセット (チャネル1のデータレジスタは+0x00) */
#define GPIO_DATA_OFFSET      0x00

/*
 * AXI GPIO操作マクロ
 * SET_SPEED: axi_gpio_0のデータレジスタに値を書き込み → counter.speedを駆動
 * GET_COUNT: axi_gpio_1のデータレジスタを読み出し → counter.count_outの現在値
 */
#define SET_SPEED(val)   Xil_Out32(GPIO_SPEED_BASEADDR + GPIO_DATA_OFFSET, (val))
#define GET_COUNT()      Xil_In32(GPIO_COUNT_BASEADDR + GPIO_DATA_OFFSET)

/* ========== PS GPIO (LED) の定義 ========== */

/*
 * PS_GPIO_DEVICE_ID: PS GPIOコントローラのベースアドレス
 *   Vitis 2025.1 (SDTベース) ではXPAR_XGPIOPS_0_BASEADDRを使用
 *   （旧バージョンのXPAR_XGPIOPS_0_DEVICE_IDは非推奨）
 */
#define PS_GPIO_DEVICE_ID  XPAR_XGPIOPS_0_BASEADDR
#define LED_PIN            7    /* MIO7 = LED1 (KV260オンボードheartbeat LED) */

/*
 * LED_BIT: カウンタ出力のどのビットでLEDを切り替えるか
 * bit24 → 2^24クロックごとに反転 = 100MHz / 2^24 ≒ 5.96Hz (片側約168ms)
 * speed値で倍率がかかる: speed=N → 周期は168ms/N
 */
#define LED_BIT            24

/* PS GPIOドライバのインスタンス（グローバル、初期化後にmainループで使用） */
static XGpioPs Gpio;

/*
 * speed設定テーブル: LED点滅速度のパターン
 * 値が大きいほどカウンタの増分が大きく、bit24の反転が速くなる
 * 1(遅い) → 16(速い) → 1(遅い) を繰り返す
 */
static const u32 speed_table[] = { 1, 2, 4, 8, 16, 8, 4, 2 };

int main(void)
{
    XGpioPs_Config *cfg;
    u32 count_val;
    int led_state;
    int speed_idx = 0;     /* speed_table の現在のインデックス */
    int cycle_count = 0;   /* ループ回数カウンタ（speed変更タイミング用） */

    /*
     * PS GPIO初期化
     * XGpioPs_LookupConfig: ベースアドレスからハードウェア設定情報を取得
     * XGpioPs_CfgInitialize: ドライバインスタンスを初期化
     * XGpioPs_SetDirectionPin: MIO7を出力(1)に設定
     * XGpioPs_SetOutputEnablePin: MIO7の出力を有効化
     */
    cfg = XGpioPs_LookupConfig(PS_GPIO_DEVICE_ID);
    if (!cfg) return -1;
    XGpioPs_CfgInitialize(&Gpio, cfg, cfg->BaseAddr);
    XGpioPs_SetDirectionPin(&Gpio, LED_PIN, 1);     /* 1=出力 */
    XGpioPs_SetOutputEnablePin(&Gpio, LED_PIN, 1);  /* 1=出力有効 */

    /* 初期speed設定: speed_table[0]=1 をcounterに書き込み */
    SET_SPEED(speed_table[0]);

    /* メインループ: 10msごとにカウンタを読んでLEDを更新 */
    while (1) {
        /* PL側カウンタの現在値を読み取り (AXI Read) */
        count_val = GET_COUNT();

        /*
         * count_outのbit24を取り出してLEDに反映
         * bit24は一定周期で0/1を繰り返すので、LEDが点滅する
         */
        led_state = (count_val >> LED_BIT) & 0x01;
        XGpioPs_WritePin(&Gpio, LED_PIN, led_state);

        /*
         * 約2秒ごとにspeedを変更 (200回 × 10ms = 2000ms)
         * speed_tableを巡回し、点滅速度を段階的に変化させる
         */
        cycle_count++;
        if (cycle_count >= 200) {
            cycle_count = 0;
            speed_idx = (speed_idx + 1) % (sizeof(speed_table) / sizeof(speed_table[0]));
            SET_SPEED(speed_table[speed_idx]);
        }

        usleep(10000);  /* 10ms待機（ポーリング間隔） */
    }

    return 0;  /* ここには到達しない */
}
