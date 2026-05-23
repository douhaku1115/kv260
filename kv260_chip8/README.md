# KV260 CHIP-8

KV260 の HDMI 出力 + PL (FPGA) のフレームバッファを使った CHIP-8 エミュレータ。
PS (Cortex-A53) で CHIP-8 CPU をベアメタルでエミュレートし、PL が 64×32 の
モノクロ画面を 16 倍スケールで HDMI に描画する。

## 概要

```
[PC キーボード]
      │ UART (TeraTerm)
      ▼
[KV260 PS (Cortex-A53)]
      │  CHIP-8 CPU エミュレート (全 35 命令)
      │  AXI4-Lite (M_AXI_HPM0_FPD) でフレームバッファ転送
      ▼
[PL の chip8_axi_slave]  ──→  [rtl_top (VGA timing + 16x スケール描画)]
   64×32 = 2048bit FB              │ 36bit live video
                                   ▼
                          [PS のビデオコントローラ]
                                   │ HDMI
                                   ▼
                               [HDMI モニタ]
```

- 1280×720 60Hz の **Live Video** モード（フレームバッファ不使用、PL が直接ピクセル生成）
- CHIP-8 の 64×32 画面を中央に 16 倍スケール（1024×512 px）で表示、ON=緑/OFF=暗緑
- PS が CHIP-8 を毎フレーム実行し、ローカル FB を AXI で PL へ転送
- UART のキー入力を CHIP-8 の 16 キーへマッピング

## アーキテクチャ

### PL (Verilog)

| モジュール | 役割 |
|---|---|
| `chip8_axi_slave.v` | 64×32 = 2048bit パックドフレームバッファ。AXI 書込みでバイト単位更新 |
| `rtl_top.v` | 1280×720 VGA タイミング生成 + CHIP-8 ピクセルの 16x スケール描画 |
| `vga_iface.v` | VGA タイミング・カラー出力 |
| `cdc_synchronizer.v` / `shift_register.v` | クロックドメイン跨ぎ・リセット同期 |

### AXI レジスタマップ (0xA0000000, 1KB)

- アドレス = `(y * 8 + byte_idx) * 4`（y: 0–31, byte_idx: 0–7）
- データ = 8 ピクセル分のビット（MSB = 左端ピクセル、CHIP-8 sprite と同規約）

### PS (C, ベアメタル)

`vitis_src/main.c` に CHIP-8 エミュレータ本体:

- メモリ 4KB、レジスタ V0–VF、I、PC、スタック、delay/sound タイマー
- 全 35 命令デコード (`chip8_cycle`)
- `op_draw`: DXYN スプライト描画（XOR + 衝突検出 VF）
- `fb_push`: ローカル FB → PL へ転送。**残光処理**で XOR アニメのちらつきを低減
- DisplayPort Live Video 初期化 (`InitDP`/`RunDP`)

## 操作方法

CHIP-8 標準キーパッド → キーボードのマッピング:

```
CHIP-8:        キーボード:
1 2 3 C        1 2 3 4
4 5 6 D   ←→   q w e r
7 8 9 E        a s d f
A 0 B F        z x c v
```

| キー | Brix | Space Invaders |
|------|------|------|
| `q` | パドル左 | 左移動 |
| `e` | パドル右 | 右移動 |
| `w` | — | 発射 |
| `Enter` | リスタート | リスタート |

## チューニング (main.c 冒頭の #define)

```c
#define CYCLES_PER_FRAME 15  // ゲーム全体の速度。下げると遅くなる (Brix=7, Invaders=15 程度)
#define PHOSPHOR_FRAMES  2   // 残光フレーム数。ちらつくなら増、残像が嫌なら減
#define KEY_HOLD_FRAMES  12  // UART キー押下の保持フレーム数（取りこぼし防止）

// ROM ごとに挙動が変わる quirk (不具合が出たら切替)
#define QUIRK_SHIFT_VY    0  // 1=8XY6/8XYE は VY をシフト(原典) / 0=VX(モダン)
#define QUIRK_LOADSTORE_I 0  // 1=FX55/FX65 で I を加算(原典) / 0=不変(モダン)
```

## ビルド手順

### Vivado (PL)

```
vivado -mode batch -source vivado.tcl
```
→ `project_1/design_1_wrapper.xsa` 生成

### Vitis (PS)

1. XSA からプラットフォーム作成
2. Empty C App 作成、`vitis_src/main.c` を取込み
3. `UserConfig.cmake`: `USER_LINK_LIBRARIES` に `m` 追加（DP ドライバが nearbyint を使用）
4. Build → Debug（Reset APU ON）

## ROM の差し替え

`.ch8` を C 配列に変換して `main.c` の `game_rom[]` を置き換える。
`roms/` に変換元 `.ch8` と生成済みヘッダの例を置いている。

## 実装フェーズ

| Phase | 内容 | 状態 |
|---|---|---|
| A | 64×32 FB + 16x スケール描画、テストパターン | ✅ |
| B | CPU エミュレータ + IBM ロゴ ROM | ✅ |
| C | UART キー入力 → 16 キー | ✅ |
| D | delay/sound タイマー (60Hz) | ✅ |
| E | 実ゲーム ROM (Brix) 動作確認 | ✅ |
| F | Space Invaders 動作確認 | ✅ |

## CHIP-8 互換性 (quirk)

デフォルトはモダン互換。`QUIRK_*` の #define で原典挙動に切替可能:
- `FX55`/`FX65`: I レジスタを加算しない（`QUIRK_LOADSTORE_I=1` で加算）
- `8XY6`/`8XYE` シフト: VX を使用（`QUIRK_SHIFT_VY=1` で VY）
- `DXYN`: 画面端でクリップ（ラップしない、固定）

Brix・Space Invaders [David Winter] はともにモダン互換 (`QUIRK_*=0`) で動作確認済み。
