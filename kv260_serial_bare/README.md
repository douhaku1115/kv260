# 案7: シリアル受信 → HDMI文字表示（ベアメタル版）

PCからシリアル通信で送った文字を、KV260のHDMIモニターにリアルタイム表示する。
PL(FPGA)は使わず、PS内蔵DisplayPortのnon-liveモードでDDRフレームバッファからHDMI出力する。

## PetaLinux版との違い

| 項目 | PetaLinux版 (kv260_serial_display) | ベアメタル版 (本プログラム) |
|------|-----------------------------------|--------------------------|
| OS | PetaLinux 2025.1 | なし (ベアメタル) |
| 描画先 | /dev/fb0 (Linuxフレームバッファ) | DDR上のFrame配列 |
| 映像出力 | Linuxのdrm/fbdevドライバ | DPDMA (non-liveモード) |
| シリアル | /dev/ttyPS1 + termios | XUartPs ドライバ |
| 実行方法 | SSH + Python | JTAG |
| 解像度 | 1920x1080 (16bpp RGB565) | 1920x1080 (32bpp RGBA8888) |

## システム構成

```
┌──────────┐    UART 115200bps    ┌──────────────────────────┐    HDMI    ┌──────────┐
│   PC     │ ──────────────────→ │       KV260 PS           │ ────────→ │ モニター  │
│ tio      │   USB-JTAGケーブル   │                          │           │ 文字表示  │
│/dev/     │                      │  UART1 → main loop      │           │          │
│ttyUSB1   │                      │            ↓             │           │          │
│          │                      │     fb_put_char()        │           │          │
│          │                      │            ↓             │           │          │
│          │                      │  Frame[] (DDR)           │           │          │
│          │                      │            ↓             │           │          │
│          │                      │  DPDMA → DisplayPort     │           │          │
└──────────┘                      └──────────────────────────┘           └──────────┘
```

## ファイル構成

```
src/
├── xdpdma_video_example.c   ... メイン: UART初期化、フォント、描画、受信ループ (★変更)
├── xdpdma_video_example.h   ... 型定義、関数プロトタイプ (公式サンプルそのまま)
└── xdppsu_interrupt.c        ... HPDハンドラ、リンクトレーニング (公式サンプルそのまま)
```

## 処理の全体フロー

```
main()
  │
  ├─ Xil_DCacheDisable / ICacheDisable  ← キャッシュ無効化（DPDMAがDDR直読みするため）
  │
  ├─ InitUart()                ← UART1 115200bps 8N1 初期化
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
  │    │     XAVBuf_EnableGraphicsBuffers()  グラフィックスバッファ有効化
  │    │     XAVBuf_InputVideoSelect(NONE, NONLIVE_GFX)  non-liveモード設定
  │    │
  │    ├─ GraphicsOverlay()             ← 画面を黒でクリア (公式: カラーバー)
  │    │
  │    ├─ FrameBuffer構造体設定
  │    │     .Address = Frame配列のアドレス
  │    │     .Stride = 1920 * 4 = 7680
  │    │     .Size = 1920 * 1080 * 4
  │    │
  │    └─ SetupInterrupts()             ← 割り込み設定
  │          GIC初期化
  │          DP HPD割り込み(ID=151)登録  → XDpPsu_HpdInterruptHandler
  │          DPDMA VSYNC割り込み(ID=154)登録 → XDpDma_InterruptHandler
  │
  ↓ HPDイベント発生 → DpPsu_IsrHpdEvent → DpPsu_Run
  ↓ リンクトレーニング → DisplayGfxFrameBuffer → 映像出力開始
  │
  ├─ 起動メッセージ表示 ("Serial Display Ready")
  │
  └─ メインループ (無限)
       └─ UART1受信 → fb_put_char() → Frame配列に描画
                                        → DPDMAが自動的にHDMI出力
```

## 公式サンプル(xdpdma_video_example)からの変更点

### xdpdma_video_example.c のみ変更

| 箇所 | 公式サンプル | 本プログラム |
|------|------------|------------|
| `GraphicsOverlay()` | カラーバー (赤+緑) | 画面を黒でクリア |
| `main()` | return で終了 | UART受信ループ (無限) |
| 追加: UART | なし | `InitUart()` UART1 115200bps |
| 追加: フォント | なし | 8x16ビットマップ (ASCII 0x20-0x7E) |
| 追加: 描画関数 | なし | `fb_draw_char`, `fb_put_char`, `fb_scroll_up` |

### xdppsu_interrupt.c, xdpdma_video_example.h は変更なし

公式サンプルの初期化フロー（HPD割り込み駆動のリンクトレーニング、VSYNC駆動のDPDMA）を
そのまま使うことで、DisplayPort出力が安定動作する。

## キーポイント

### 1. non-liveモードとは

PSのDisplayPortには2つの映像入力モードがある:
- **live**: PL(FPGA)からリアルタイム映像信号を入力
- **non-live**: DPDMAがDDR上のフレームバッファを読み出し（本プログラムで使用）

non-liveではPLの映像回路が不要で、Cコードからメモリにピクセルを書くだけでHDMIに表示される。

### 2. フレームバッファと描画

```
Frame[1920 * 1080 * 4] (u8配列, 256バイトアライン)
  ↓ u32*にキャスト
fb[y * 1920 + x] = COLOR_GREEN  (RGBA8888: 0xFF00FF00)

文字グリッド: 240桁 x 67行 (8x16ピクセル/文字)
```

DPDMAはVSYNC割り込みのたびに（60Hz）Frame配列からピクセルデータを読み出して
DisplayPortへ送る。アプリケーションはFrame配列に書き込むだけでよい。

### 3. 2つの必須割り込み

| 割り込み | ID | ハンドラ | 役割 |
|---------|-----|---------|------|
| DP HPD | 151 | XDpPsu_HpdInterruptHandler | HDMIケーブル検出 → リンクトレーニング実行 |
| DPDMA VSYNC | 154 | XDpDma_InterruptHandler | 毎フレーム(60Hz) DDRからピクセルデータ読み出し |

**両方必須。** HPD割り込みがないとリンクトレーニングが始まらず映像が出ない。
VSYNC割り込みがないとDPDMAは1フレーム転送後に停止する。

### 4. 以前の失敗と解決

最初に書いたベアメタル版(main.c)ではHDMIに映像が映らなかった。原因:
- DP HPD割り込み(ID=151)を登録していなかった
- `XDpDma_SetGraphicsFormat()` を呼んでいなかった
- `XAVBuf_EnableGraphicsBuffers()` を呼んでいなかった
- HPD駆動のリンクトレーニングフローが欠けていた

解決: 公式サンプル(xdpdma_video_example)をそのまま動かして映像出力を確認し、
その初期化フロー(xdppsu_interrupt.c)をそのまま使ってUART+フォントを追加した。

## ビルド環境

- Vivado/Vitis 2025.1
- XSA: kv260_serial_bare/hw_export/design_1_wrapper.xsa（案5のHW流用、DP+UART1有効）
- JTAG実行

## 使い方

1. Vitisでプロジェクトをビルド
2. JTAGで KV260 に書き込み・実行
3. HDMIモニターに "Serial Display Ready" と表示される
4. PC側で `tio -b 115200 /dev/ttyUSB1` を開く
5. tioで打った文字がHDMIモニターに緑色で表示される
