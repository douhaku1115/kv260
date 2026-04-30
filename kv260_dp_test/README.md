# KV260 DisplayPort Non-Live サンプル (公式xdpdma_video_example)

Xilinx公式DPDMAサンプルをそのまま動かしたもの。
KV260のPS DisplayPortからHDMIモニターにグラフィックスオーバーレイを表示する。

## 表示結果

上半分: 黒（Alpha=0x0F、ほぼ透明で背景の黒が透ける）
下半分: 緑（Alpha=0xF0、ほぼ不透明）

## ファイル構成

```
src/
├── xdpdma_video_example.c   ... メイン関数、初期化、テスト画面生成
├── xdpdma_video_example.h   ... 型定義、関数プロトタイプ
└── xdppsu_interrupt.c        ... HPDハンドラ、リンクトレーニング、映像ストリーム設定
```

## 処理の全体フロー

```
main()
  │
  ├─ Xil_DCacheDisable / ICacheDisable  ← キャッシュ無効化（DPDMAがDDR直読みするため）
  │
  ├─ DpdmaVideoExample()
  │    │
  │    ├─ InitRunConfig()               ← 設定パラメータ初期化
  │    │     VideoMode = 1920x1080_60P
  │    │     LinkRate = 5.4Gbps, LaneCount = 2
  │    │
  │    ├─ InitDpDmaSubsystem()          ← DP/AVBuf/DPDMA初期化
  │    │     XDpPsu_InitializeTx()       DP TX初期化
  │    │     XDpDma_SetGraphicsFormat()  ピクセルフォーマット(RGBA8888)
  │    │     XAVBuf_EnableGraphicsBuffers()  グラフィックスバッファ有効化 ★重要
  │    │     XAVBuf_InputVideoSelect(NONE, NONLIVE_GFX)  non-liveモード設定
  │    │     XAVBuf_ConfigureGraphicsPipeline()
  │    │     XAVBuf_ConfigureOutputVideo()
  │    │     XAVBuf_SoftReset()
  │    │
  │    ├─ GraphicsOverlay()             ← テスト画面をDDRに書き込み
  │    │     Frame[0..半分] = 0x0F0000FF (赤+低Alpha → 透明で黒に見える)
  │    │     Frame[半分..末尾] = 0xF000FF00 (緑+高Alpha → 緑に見える)
  │    │
  │    ├─ FrameBuffer構造体設定
  │    │     .Address = Frame配列のアドレス
  │    │     .Stride = 1920 * 4 = 7680
  │    │     .Size = 1920 * 1080 * 4
  │    │
  │    └─ SetupInterrupts()             ← 割り込み設定 ★ここが核心
  │          GIC初期化
  │          DP HPD割り込み(ID=151)登録  → XDpPsu_HpdInterruptHandler
  │          DPDMA VSYNC割り込み(ID=154)登録 → XDpDma_InterruptHandler
  │          HPDイベントハンドラ登録     → DpPsu_IsrHpdEvent
  │          HPDパルスハンドラ登録       → DpPsu_IsrHpdPulse
  │
  ↓ ここで割り込みが有効になり、HDMIケーブル接続を検出
  ↓ HPDイベント発生 → DpPsu_IsrHpdEvent() が呼ばれる

DpPsu_IsrHpdEvent()  [xdppsu_interrupt.c]
  │
  └─ DpPsu_Run()
       │
       ├─ InitDpDmaSubsystem()         ← DPサブシステム再初期化
       ├─ XDpPsu_EnableMainLink(0)     ← メインリンク無効化
       ├─ XDpPsu_IsConnected()         ← 接続確認
       ├─ DpPsu_Wakeup()              ← モニターをスリープから起こす
       │
       └─ ループ (最大2回)
            ├─ DpPsu_Hpd_Train()       ← リンクトレーニング
            ├─ XDpDma_DisplayGfxFrameBuffer()  ← フレームバッファをDPDMAに登録
            ├─ DpPsu_SetupVideoStream()        ← 映像ストリーム設定(MSA, PixelClock)
            └─ XDpPsu_EnableMainLink(1)        ← 映像出力開始
                  ↓
              VSYNC割り込み発生
                  ↓
              XDpDma_InterruptHandler()
                  → DPDMAチャネルをトリガー
                  → DDRからピクセルデータ読み出し
                  → DisplayPortへ送出
                  → HDMIモニターに表示
```

## キーポイント

### 1. non-liveモードとは

PSのDisplayPortには2つの映像入力モードがある:
- **live**: PL(FPGA)からリアルタイム映像信号を入力（案5で使用）
- **non-live**: DPDMAがDDR上のフレームバッファを読み出し（本プログラムで使用）

non-liveではPLの映像回路が不要で、Cコードからメモリにピクセルを書くだけでHDMIに表示される。

### 2. 2つの割り込み

| 割り込み | ID | ハンドラ | 役割 |
|---------|-----|---------|------|
| DP HPD | 151 | XDpPsu_HpdInterruptHandler | HDMIケーブル接続/切断を検出し、リンクトレーニング実行 |
| DPDMA VSYNC | 154 | XDpDma_InterruptHandler | 毎フレーム(60Hz)DDRからピクセルデータを読み出してDPに送る |

serial_bare版ではDPDMA(154)のみ登録していたが、DP HPD(151)も必須。
HPD割り込みがないとリンクトレーニングが始まらず、映像が出ない。

### 3. DpPsu_Runの呼び出しタイミング

`DpPsu_Run`はmain()から直接呼ばれるのではなく、HPD割り込み経由で呼ばれる。
`SetupInterrupts()`で割り込みを有効にした時点でHDMIケーブルが接続されていれば、
自動的にHPDイベントが発生し、`DpPsu_IsrHpdEvent` → `DpPsu_Run` が実行される。

### 4. VSYNC駆動のDPDMA

DPDMAは1回の`DisplayGfxFrameBuffer`呼び出しで永続的に動くのではなく、
VSYNCごとに`XDpDma_InterruptHandler`が再トリガーする仕組み。
このハンドラがないとDPDMAは1フレーム転送後に停止する。

### 5. InitDpDmaSubsystemの再呼び出し

`DpPsu_Run`の中で毎回`InitDpDmaSubsystem`を呼び直している。
これはHPDイベント（ケーブル抜き差し）の度にDPサブシステムを
クリーンな状態から再設定するため。

## ビルド環境

- Vivado/Vitis 2025.1
- XSA: kv260_serial_bare/hw_export/design_1_wrapper.xsa（案5流用、DP+UART1有効）
- JTAG実行
