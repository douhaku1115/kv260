# main.c 解説

KV260のPS内蔵DisplayPortコントローラを初期化し、PL側で生成された映像をHDMIモニターに出力するプログラム。

## 全体の流れ

```
main() → InitDP() → sleep(1) → RunDP() → 割り込み設定 → 無限ループ(HPD待ち)
```

---

## 1. ヘッダとマクロ定義 (1-33行)

```c
#include "xdppsu.h"    // DisplayPort PSU ドライバ
#include "xavbuf.h"    // Audio/Video Buffer (映像パイプライン)
#include "xscugic.h"   // GIC 割り込みコントローラ
```

- `SDT` マクロ: Vitis 2025.2のSDTモードで自動定義される。デバイスの識別方法が変わる
  - SDT無し: デバイスIDで検索 (`XPAR_PSU_DP_DEVICE_ID`)
  - SDTあり: ベースアドレスで検索 (`XPAR_XDPPSU_0_BASEADDR`)
- `DPPSU_INTR_ID = 151`: DisplayPortの割り込み番号(GICでのID)

---

## 2. main() (43-89行)

```c
Xil_DCacheDisable();   // データキャッシュ無効化（ハードウェアレジスタ直接操作のため）
Xil_ICacheDisable();   // 命令キャッシュ無効化
```

### 処理順序:
1. **InitDP()** — DPコントローラと映像パイプラインの初期化
2. **sleep(1)** — モニターのHPD信号安定待ち(1秒)
3. **RunDP()** — モニター接続確認、リンクトレーニング、映像出力開始
4. **割り込み設定** — HDMIケーブル抜き差し(HPD)に対応するため
5. **while(1)** — HPD割り込みを待ち続ける

### 割り込み設定の流れ (58-84行):
```
全割り込み無効化 → HPDハンドラ登録 → GIC初期化 → GICにDP割り込み接続
→ 例外ハンドラ登録 → 例外有効化 → DP割り込み有効化
```

---

## 3. InitDP() (91-131行) — DP初期化

### 3.1 ドライバ初期化
```c
XDpPsu_LookupConfig()    // ハードウェア構成情報を取得
XDpPsu_CfgInitialize()   // DPドライバ初期化
XAVBuf_CfgInitialize()   // 映像パイプラインドライバ初期化
XDpPsu_InitializeTx()    // DP送信器の初期化(PHY設定含む)
```

### 3.2 映像パイプライン設定
```c
XAVBuf_SetInputLiveVideoFormat(&AVBuf, RGB_12BPC);   // PL→PS入力: RGB 12bit/色
XAVBuf_SetOutputVideoFormat(&AVBuf, RGB_8BPC);        // 出力: RGB 8bit/色
XAVBuf_InputVideoSelect(&AVBuf,
    XAVBUF_VIDSTREAM1_LIVE,     // 映像ソース = PLからのライブ入力
    XAVBUF_VIDSTREAM2_NONE);    // グラフィックスオーバーレイ = 無し
XAVBuf_InputAudioSelect(&AVBuf,
    XAVBUF_AUDSTREAM1_NO_AUDIO,  // オーディオ = 無し
    XAVBUF_AUDSTREAM2_NO_AUDIO);
```

**ポイント**: `XAVBUF_VIDSTREAM1_LIVE` がPL側のrtl_top.vからの映像を受け取る設定。

### 3.3 クロックとリセット
```c
XAVBuf_SetPixelClock(Msa->PixelClockHz);              // ピクセルクロック設定
XAVBuf_SetAudioVideoClkSrc(&AVBuf, XAVBUF_PS_CLK, XAVBUF_PL_CLK);
//                                   ↑映像クロック源   ↑出力クロック源
```
- 映像クロック: PSクロック (VPLL)
- 出力クロック: PLクロック (clk_wiz経由)

---

## 4. TrainLink() (133-157行) — リンクトレーニング

DisplayPortはモニターと「トレーニング」という通信確立手順が必要。

```
モニターの能力取得 → レーン数設定 → リンクレート設定 → トレーニング実行
```

### 各ステップ:
1. **XDpPsu_GetRxCapabilities()** — モニター(受信側)が対応するレーン数・速度を取得
2. **XDpPsu_SetEnhancedFrameMode()** — 拡張フレームモード(エラー耐性向上)
3. **XDpPsu_SetLaneCount()** — レーン数設定 (KV260は最大2レーン)
4. **XDpPsu_SetLinkRate(LINK_RATE_270)** — 2.7Gbps/レーン
5. **XDpPsu_SetDownspread()** — ダウンスプレッド(EMI低減)
6. **XDpPsu_EstablishLink()** — 実際のトレーニング実行(CR→EQ→完了)

---

## 5. SetupVideoStream() (159-179行) — 映像ストリーム設定

トレーニング成功後に映像パラメータを設定。

```c
XDpPsu_SetColorEncode(&DpPsu, XDPPSU_CENC_RGB);           // RGB色空間
XDpPsu_CfgMsaSetBpc(&DpPsu, XVIDC_BPC_8);                 // 8bit/色
XDpPsu_CfgMsaUseStandardVideoMode(&DpPsu, XVIDC_VM_1280x720_60_P);  // 720p60
```

### MSA (Main Stream Attributes):
DisplayPortで映像のフォーマット情報をモニターに伝えるためのデータ。解像度、色深度、タイミング情報などが含まれる。

```c
XDpPsu_WriteReg(..., XDPPSU_SOFT_RESET, 0x1);  // DP送信器リセット
XDpPsu_SetMsaValues(&DpPsu);                     // MSA値をレジスタに書き込み
XDpPsu_WriteReg(..., 0xB124, 0x3);               // AVBufリセット
XDpPsu_EnableMainLink(&DpPsu, 1);                // メインリンク有効化 → 映像出力開始
```

---

## 6. RunDP() (181-206行) — 接続・トレーニング・出力

```
メインリンク無効化 → 接続確認 → モニター起動 → トレーニング → 映像出力
```

### モニター起動 (AUX通信):
```c
XDpPsu_AuxWrite(&DpPsu, XDPPSU_DPCD_SET_POWER_DP_PWR_VOLTAGE, 1, &AuxData);
```
AUXチャネル経由でモニターのスリープを解除。DPCDレジスタ(モニター内の設定レジスタ)に書き込む。2回送信するのは信頼性のため。

### リトライ:
最大2回トレーニングを試行。失敗してもリトライすることで接続成功率を上げる。

---

## 7. HPDハンドラ (208-229行) — ケーブル抜き差し対応

### HpdEvent — ケーブル接続/切断時
モニターが接続されたら RunDP() を再実行してリンクを確立。

### HpdPulse — リンク異常時
モニターがリンク再トレーニングを要求した場合。リンク状態を確認し、必要ならリトライ。

---

## 全体の信号経路

```
PL (rtl_top.v)                    PS                           外部
┌──────────────┐    ┌──────────────────────┐    ┌──────────┐
│ VGAタイミング  │───→│ dp_live_video_in_*   │    │          │
│ 矩形描画      │    │   ↓                  │    │          │
│ 1280x720     │    │ AVBuf(映像パイプライン) │    │ STDP4320 │──→ HDMI
│              │    │   ↓                  │    │ (DP→HDMI) │    モニター
│              │    │ DPコントローラ        │───→│          │
└──────────────┘    │   ↑                  │    └──────────┘
                    │ TrainLink(AUX通信)    │
                    └──────────────────────┘
```
