# KV260 NES (ファミコン)

KV260 の PL に NES を Verilog で自作する。6502 CPU・PPU (画面)・APU (音) をすべて PL に置く。
映像は HDMI (PS の Live Video)、音は Pmod I2S2 (J2)、入力は UART のキー。

ROM はテスト ROM (nestest / blargg) と、無料公開の自作ゲーム (NROM = マッパー0) を使う。
市販ゲームの ROM はリポジトリに入れない。

## 段

| 段 | 内容 | 状態 |
|---|---|---|
| A | 画面バッファ 256x240 を 3 倍で HDMI に表示、I2S2 の固定トーン | sim PASS・合成前 |
| B | 6502 CPU (公式命令)。nestest のログと 1 命令ずつ照合 | |
| C | CPU を実機へ。PRG を AXI で書き込み nestest を実行 | |
| D | PPU (背景・スクロール・NMI・スプライト) | |
| E | コントローラ ($4016) と UART キー | |
| F | APU (矩形波 2・三角波・ノイズ・DMC) → I2S2 | |
| G | マッパー追加 (任意) | |

## 構成 (段A)

```
PS (ベアメタル C)
  │ AXI4-Lite (0xA0000000, 256KB)
  ▼
nes_axi_slave ── 単純なバス ──► rtl_top
                                 ├ レジスタ (CTRL / ID / PAD / FRAME)
                                 ├ nes_fb      画面バッファ 256x240 x 6bit (4 バンク = x%4)
                                 ├ nes_palette 色番号 → RGB
                                 ├ vga_iface   1280x720 のタイミング
                                 └ i2s_tx      Pmod I2S2 へ固定トーン (12.5MHz)
```

- 表示: 256x240 を縦横 3 倍 (768x720) にして X=256 から。外側は暗い灰色
- 3 で割る計算は `n*683 >> 11` (n < 768 で floor(n/3) と一致。sim で全数確認)
- 映像クロック (74.25MHz) と NES 側 (100MHz) は画面バッファの 2 クロック RAM で切り離す

## AXI マップ (0xA0000000)

レジスタは 0x10 刻み (Zynq US+ の HPM で 0x10 境界にないと読めない事があった教訓)。

| 番地 | 名前 | 中身 |
|---|---|---|
| 0x00000 | CTRL | 段C で NES のリセット解除に使う |
| 0x00010 | ID | 0x4E455301 (読み専用) |
| 0x00020 | PAD | コントローラ (段E) |
| 0x00030 | FRAME | 映像のフレーム数 (読み専用) |
| 0x10000〜0x1EFFC | FB | 語番号 = y*64 + x/4。[5:0]=x, [13:8]=x+1, [21:16]=x+2, [29:24]=x+3 |

## ファイル

| ファイル | 中身 |
|---|---|
| `rtl/rtl_top.v` | トップ。レジスタ・表示・音 |
| `rtl/nes_axi_slave.v` | AXI4-Lite → 単純なバス |
| `rtl/nes_fb.v` | 画面バッファ |
| `rtl/nes_palette.v` | 64 色の表 |
| `rtl/vga_iface.v` ほか 2 本 | kv260_chip8 から流用 |
| `rtl/i2s_tx.v`, `sine_lut.hex` | kv260_i2s2 から流用 |
| `sim/tb_stageA.v` | 段A の検証 |
| `sim/run_sim.sh` | `bash sim/run_sim.sh tb_stageA` |
| `vivado.tcl` | プロジェクト生成・ビルド・XSA 出力 |
| `vitis_src/main.c` | 段A の PS 側 |

## 検証

```
bash sim/run_sim.sh tb_stageA
```

AXI で ID 読み出し → 画面バッファ全体を書く → 映像 1 フレーム 921,600 画素を全部照合 → FRAME が増えるか。

★ テストベンチで、連結式の中で同じ関数を何度も呼ぶと xsim では x になる。変数に受けてから組む。

## ビルド

```
E:\vivado\2025.2\Vivado\bin\vivado.bat -mode batch -source E:/fpga/kria260/kv260_nes/vivado.tcl
```
