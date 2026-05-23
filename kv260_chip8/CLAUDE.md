# KV260 CHIP-8 プロジェクト

KV260 の HDMI Live Video 出力で CHIP-8 エミュレータを実装。PS の C で CHIP-8 CPU を
ベアメタルエミュレートし、PL の 64×32 フレームバッファに AXI 経由で転送して描画。

## アーキテクチャ

```
PS (C: CHIP-8 CPU エミュレータ 全35命令)
   │ AXI4-Lite でフレームバッファ転送
   ▼
chip8_axi_slave (64×32 = 2048bit packed FB)
   │ (x,y) → pixel 読出
   ▼
rtl_top (1280x720 VGA timing + 16x スケール描画)
   │ live video
   ▼
PS のビデオコントローラ → HDMI コネクタ → モニタ
```

## AXI レジスタマップ (0xA0000000, 1KB)

- アドレス = `(y * 8 + byte_idx) * 4`（y: 0–31, byte_idx: 0–7）
- データ = 8 ピクセル（MSB = 左端、CHIP-8 sprite 規約）

## 重要パス

- プロジェクト: `E:\fpga\kria260\kv260_chip8\`
- XSA: `E:\fpga\kria260\kv260_chip8\project_1\design_1_wrapper.xsa`
- main.c: `E:\fpga\kria260\kv260_chip8\vitis_src\main.c`
- Vitis WS: `E:\Xilinx\project_vitis\kv260_chip8\`（app は `kv260_chip8_app`、ソースは `app/main.c`）

## 設計判断 (Tetris の教訓を反映)

- フレームバッファは `(* keep = "true" *) reg [2047:0] fb`（packed register、最適化回避）
- アドレス判定は `axi_awaddr[9:2]` の単純な unit_idx（bit pattern 判定回避）
- Tetris Phase F の AXI text 書込み問題はバイト単位 FB で回避できた

## 注意点 (前プロジェクトの教訓)

- **DP Live Video 初期化 (`InitDP`/`RunDP`) が必須**。これが無いと AXI は動くがモニタ無信号
- `UserConfig.cmake`: `USER_LINK_LIBRARIES` に `m` 追加（DP ドライバ `xdppsu_spm.c` が nearbyint 使用）
- Vitis WS の `UserConfig.cmake` は `"../main.c"` を参照 → ソースは `app/main.c` を上書き同期
- KV260 USB-UART RX は `0xFF010000` (UART_1)
- SD カード挿入時、OS が起動すると JTAG デバッグと競合。OS 未起動タイミングで Vitis が掌握
- 「HDMI 出力」呼称統一（DP と書かない）

## CHIP-8 タイミング・チューニング

main.c 冒頭の #define で調整:
- `CYCLES_PER_FRAME`: ゲーム全体速度（命令/フレーム）
- `PHOSPHOR_FRAMES`: 残光（XOR アニメのちらつき低減）
- `KEY_HOLD_FRAMES`: UART キー保持（取りこぼし防止）

## 関連プロジェクト

- [[project_kv260_pong]] / [[project_kv260_tetris]] — 同じ HDMI Live Video 基盤
