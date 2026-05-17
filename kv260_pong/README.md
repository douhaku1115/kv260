# KV260 Pong

KV260 の DisplayPort 出力 + PL (FPGA) の自作 AXI スレーブを使った、PS + PL 連携の Pong ゲーム。

## 概要

```
[PC キーボード]
      │ UART (TeraTerm)
      ▼
[KV260 PS (Cortex-A53)]
      │ AXI4-Lite (M_AXI_HPM0_FPD)
      ▼
[PL の rect_axi_slave]  ──→  [rtl_top (VGA timing + 矩形描画)]
                                       │ 36bit live video
                                       ▼
                              [PS の DPDMA / DP コントローラ]
                                       │ DisplayPort
                                       ▼
                                   [HDMI モニタ]
```

- 1280x720 60Hz の **Live Video** モード (フレームバッファ不使用、PL が直接ピクセル生成)
- PS の C プログラムが AXI 経由でパドル・ボール位置を書き込み、PL が毎フレーム矩形描画
- UART のキー入力を非同期で読み、ゲームループに反映

## 操作方法

| キー | 動作 |
|------|------|
| `w` | 左パドル 上 |
| `s` | 左パドル 下 |
| `i` | 右パドル 上 |
| `k` | 右パドル 下 |

ボールはパドルで反射、外すと相手の得点。スコアはシリアル端末に `Score: X - Y` で表示。

## ハードウェア構成

```
PS Zynq UltraScale+ ────────────────────────────────────────┐
  │ pl_clk0 (99.99MHz)                                       │
  │   ↓                                                       │
  │ clk_wiz_0 (clk_out1)                                     │
  │   ↓                                                       │
  │ proc_sys_reset_0 ─→ peripheral_aresetn                   │
  │                                                           │
  │ M_AXI_HPM0_FPD ─→ axi_interconnect_0 ─→ rect_axi_slave  │
  │                                              │ (rect位置) │
  │                                              ↓            │
  │                                          rtl_top          │
  │                                              ↓ live video │
  │ dp_live_video_in ←─────────────────────────┘             │
  │                                                           │
  │ DP コントローラ → DisplayPort コネクタ                    │
  └───────────────────────────────────────────────────────────┘
```

## AXI レジスタマップ (ベース 0xA000_0000)

| オフセット | 名前    | 方向 | 内容 |
|-----------|---------|------|------|
| 0x00      | PADL_X  | R/W  | 左パドル X 座標 (0〜1279) |
| 0x04      | PADL_Y  | R/W  | 左パドル Y 座標 (0〜719)  |
| 0x08      | PADR_X  | R/W  | 右パドル X 座標 |
| 0x0C      | PADR_Y  | R/W  | 右パドル Y 座標 |
| 0x10      | BALL_X  | R/W  | ボール X 座標 |
| 0x14      | BALL_Y  | R/W  | ボール Y 座標 |

- パドル: 20 × 100 (白)
- ボール: 20 × 20 (白)
- 背景: 青

## ファイル構成

```
kv260_pong/
├── rtl/
│   ├── rtl_top.v          — トップ (VGA timing + 3 矩形描画 + CDC)
│   ├── rect_axi_slave.v   — AXI4-Lite スレーブ (6 レジスタ)
│   ├── vga_iface.v        — VGA タイミング生成
│   ├── cdc_synchronizer.v — クロックドメイン跨ぎ同期 (miya4649 由来)
│   └── shift_register.v   — リセット遅延用
├── vitis_src/
│   └── main.c             — PS 側ゲームロジック (DP 初期化 + UART + 衝突判定)
├── pins.xdc               — ピン制約 (使用なしだが残置)
├── timings.xdc            — タイミング制約
├── vivado.tcl             — Vivado プロジェクト生成スクリプト
├── CLAUDE.md              — 開発メモ
└── README.md              — 本ファイル
```

## ビルド・実行手順

### 1. Vivado でビットストリームを生成

```
vivado.bat -mode batch -source E:/fpga/kria260/kv260_pong/vivado.tcl
```

`project_1/design_1_wrapper.xsa` が出力される。

### 2. Vitis で実行

1. 新規ワークスペース作成 (`kv_pong2` 等)
2. **Platform Component**: XSA を選択して Build
3. **Application Component** (Empty C App) 作成
4. `vitis_src/main.c` を `app/src/` にコピー (Import ではなく直接コピー推奨)
   - **注意**: Vitis の Import を使うと `UserConfig.cmake` に `"../main.c"` という誤った行が混入してビルドエラーになる。混入したら手動で削除
5. Build → Debug
   - Debug Configuration の **Reset APU** をチェック
6. TeraTerm を **COM ポート 14** (or 環境次第)、**115200 / 8N1** で開く
7. KV260 の DP → HDMI モニタに接続
8. プレイ開始

## ゲーム実装メモ

### キー応答の滑らかさ

OS のキーオートリピートは「最初の押下 → 約 500ms 待ち → 連打開始」という挙動。
そのままだと「ピョコッ … 一拍空く … スルスル」という不自然な動き。

対策: 1 押下を「移動継続フレーム数」(36 フレーム ≒ 600ms) として保持し、自動連打の隙間を埋める。
- `PAD_VEL = 5` (1 フレームあたり 5px 移動)
- `KEY_FRAMES = 36` (1 押下で 36 フレーム継続)

### UART RX のアドレス

KV260 の USB-UART は **UART_1 (0xFF01_0000)**。BSP の stdin/stdout 設定が `psu_uart_0` でも実際は UART_1 が動いている (xil_printf が出力されるのが証拠)。

直接レジスタで RX するときは `UART_BASE = 0xFF010000` を使用。

### DP 初期化のハマりポイント

- `XSetupInterruptSystem` でハングする → 割込み設定は不要なら省略
- `XDpPsu_CheckLinkStatus` を含む `do-while` ループもハングする可能性 → 1 回呼び切りに簡略化

これらは `RunDP()` の中で対応済み。

## 段階的実装履歴 (Phase A1 → D)

| Phase | 内容 | 状態 |
|-------|------|------|
| A1    | AXI スレーブ追加、矩形 1 個の X 制御 | 完了 |
| A2    | 3 オブジェクト (左/右パドル + ボール) | 完了 |
| C     | UART キー入力でパドル制御            | 完了 |
| D     | パドル衝突判定 + スコア              | **完了** |

(Phase B は A2 に統合して省略)

## 関連プロジェクト

- `kv260_rect` — DP Live Video + 固定矩形描画 (Pong の出発点)
- `kv260_mips` — KV260 上の自作 MIPS プロセッサ
