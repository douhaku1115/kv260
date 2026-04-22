/*
 * KV260 UART送信 + Verilogカウンタ (案4)
 *
 * 概要:
 *   PL上のVerilogカウンタの値を読み取り、PS UART1経由でPCに送信する。
 *   同時にオンボードLED(MIO7)でカウンタの動作を可視化する。
 *
 * ハードウェア構成:
 *   PS (Cortex-A53) --AXI--> axi_gpio_0 (出力) --gpio_io_o--> counter.speed
 *                   --AXI--> axi_gpio_1 (入力) <--gpio_io_i--- counter.count_out
 *   PS UART1 (MIO 36/37) --> USB Debug Port --> PC (tio -b 115200 /dev/ttyUSB1)
 *   PS GPIO MIO7 --> LED1 (オンボード)
 *
 * UART出力例:
 *   === KV260 UART + Counter Demo (案4) ===
 *   speed changes every ~2 seconds
 *
 *   [0001] speed=1  count=0x01A2B3C4
 *   [0002] speed=1  count=0x03456789
 *   ...
 *
 * ビルド環境: Vivado/Vitis 2025.1, JTAG実行
 *
 * 注意事項:
 *   - AXI GPIOアドレスはM_AXI_HPM0_LPD経由のため0x80000000始まり
 *     （HPM0_FPDの0xA0000000ではない）
 *   - psu_initは本プロジェクトのものを使用（UART1初期化が含まれる）
 *     案2(kv260_led_pl)のpsu_initではUART1が初期化されない
 *   - UART0 (MIO 18/19) はQSPIと競合するため使用不可。UART1を使う
 */

#include "xparameters.h"   /* ハードウェアアドレス定義（Vitisが自動生成） */
#include "xgpiops.h"       /* PS GPIO制御ドライバ（XGpioPs_*関数群） */
#include "xil_io.h"        /* Xil_Out32/Xil_In32: PLレジスタ読み書き */
#include "xil_printf.h"    /* xil_printf: 軽量printf（浮動小数点非対応） */
#include "sleep.h"         /* usleep: マイクロ秒単位のウェイト */

/* ========== AXI GPIO (PL側) の定義 ========== */

/*
 * AXI GPIOベースアドレス (Vivadoのアドレスエディタで割り当て)
 *
 * M_AXI_HPM0_LPD のアドレス空間は 0x80000000〜0x9FFFFFFF (512MB)
 * HPM0_FPDの0xA0000000はLPDでは使えないので注意
 *
 * axi_gpio_0: PSからcounterへspeed値を送る（出力方向、C_ALL_OUTPUTS=1）
 * axi_gpio_1: counterからPSへcount_out値を読む（入力方向、C_ALL_INPUTS=1）
 */
#define GPIO_SPEED_BASEADDR   0x80000000  /* axi_gpio_0 */
#define GPIO_COUNT_BASEADDR   0x80010000  /* axi_gpio_1 */

/* AXI GPIO データレジスタオフセット (チャネル1のデータレジスタは+0x00) */
#define GPIO_DATA_OFFSET      0x00

/*
 * SET_SPEED(val) - axi_gpio_0にspeed値を書き込む
 *   PL側counter.vの speed 入力ポートを駆動する。
 *   値が大きいほどカウンタの増分が大きく変化が速い。
 *
 * GET_COUNT() - axi_gpio_1からcount値を読み出す
 *   PL側counter.vの count_out 出力ポートの現在値を取得��る。
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
 * 1(遅い) → 16(速い) → 1(���い) を繰り返す
 */
static const u32 speed_table[] = { 1, 2, 4, 8, 16, 8, 4, 2 };

/*
 * main - エントリポイント
 *
 * 処理の流れ:
 *   1. PS GPIO MIO7を出力モードに初期化（LED制御用）
 *   2. UART1にヘッダメッセージを出力
 *   3. axi_gpio_0にspeed初期値を書き込む
 *   4. 500msごとにカウンタ値を読み取り、UART出力 + LED更新
 *   5. 約2秒ごとにspeed_tableを巡回してspeedを変更
 *
 * 戻り値: 0（正常終了、実際にはwhile(1)で到達しない）
 *         -1（GPIO初期化失敗）
 */
int main(void)
{
    XGpioPs_Config *cfg;
    u32 count_val;
    int led_state;
    int speed_idx = 0;     /* speed_table の現在のインデックス */
    int cycle_count = 0;   /* ループ回数カウンタ（speed変更タイミング用） */
    u32 print_count = 0;   /* UART出力の通し番号 */

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

    /* UART1にヘッダ出力（xil_printfはstdoutに出力 → BSP設定でpsu_uart_1） */
    xil_printf("\r\n=== KV260 UART + Counter Demo (案4) ===\r\n");
    xil_printf("speed changes every ~2 seconds\r\n\r\n");

    /* 初期speed設定: speed_table[0]=1 をcounterに書き込み */
    SET_SPEED(speed_table[0]);

    /* メインループ: 500msごとにカウンタ値をUART出力 + LED更新 */
    while (1) {
        /* PL側カウンタの現在値を読み取り (AXI Read) */
        count_val = GET_COUNT();

        /*
         * count_outのbit24を取り出してLEDに反映
         * bit24は一定周期で0/1を繰り返すので、LEDが点滅する
         */
        led_state = (count_val >> LED_BIT) & 0x01;
        XGpioPs_WritePin(&Gpio, LED_PIN, led_state);

        /* UART出力: 通し番号、現在のspeed値、カウンタの16進値 */
        print_count++;
        xil_printf("[%04lu] speed=%-2lu count=0x%08lX\r\n",
                   print_count, speed_table[speed_idx], count_val);

        /*
         * 約2秒ごとにspeedを変更 (4回 × 500ms = 2000ms)
         * speed_tableを巡回し、点滅速度を段階的に変化させる
         */
        cycle_count++;
        if (cycle_count >= 4) {
            cycle_count = 0;
            speed_idx = (speed_idx + 1) % (sizeof(speed_table) / sizeof(speed_table[0]));
            SET_SPEED(speed_table[speed_idx]);
        }

        usleep(500000);  /* 500ms待機（ポーリング間隔） */
    }

    return 0;  /* ここには到達しない */
}
