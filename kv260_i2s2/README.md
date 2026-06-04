# kv260_i2s2 — Pmod I2S2 で I2S 送受信（段1: トーン再生 / 段2: ループバック）

KV260 の PL で I2S 送受信を組み、Pmod I2S2（CS5343 ADC / CS4344 DAC）で音を扱う。
- **段1**: PL 生成のサイン波を I2S 送信し、DAC からイヤホンで鳴らす（`i2s_tx.v` / `i2s2_tone`）
- **段2**: ADC 入力を PL でデジタル増幅して DAC へ戻すループバック（`i2s_loop.v` / `i2s2_loop`）

---

## 段1: 固定トーン再生

## 構成

```
Zynq PS (pl_clk0 100MHz) → Clocking Wizard (12.5MHz) → i2s_tx (Module Ref)
                                                          ├ MCLK 12.5MHz
                                                          ├ SCLK  3.125MHz (=MCLK/4, 64fs)
                                                          ├ LRCK  ≒48.8kHz (=MCLK/256, fs)
                                                          └ SDATA 標準I2S 16bit (NCO+64点サインLUT, ≒762Hz)
```

## ピンアサイン（KV260 carrier J2、Pmod I2S2 直挿し）

| 信号 | Pmod物理ピン | FPGA | 用途 |
|------|------|------|------|
| pmod_mclk | 1 | H12 | TX MCLK |
| pmod_lrck | 2 | E10 | TX LRCK |
| pmod_sclk | 3 | D10 | TX SCLK |
| pmod_sdin | 4 | C11 | TX SDATA(DACへ) |

（段2のRX用: B10/E12/D11/B11 = MCLK/LRCK/SCLK/SDOUT）

## 使い方

```bash
# プロジェクト生成
vivado -mode batch -source create_i2s2_project.tcl
# 合成→実装→ビットストリーム
vivado -mode batch -source build_bitstream.tcl
# 生成物: vivado/i2s2_tone.runs/impl_1/design_1_wrapper.bit
```

Vivado Hardware Manager で JTAG 書き込み後、Pmod I2S2 の DAC 出力ジャックにイヤホンを挿す。

## ハマりどころ：PLクロックがゲートOFF

JTAG で PL だけ書くと `pl0_ref` がゲートOFF（`clk_summary` で末尾 `N`）で MCLK が出ず**無音**になる。`/sys/class/fclk/` が無い環境では devmem で `PL0_REF_CTRL`(0xFF5E00C0) の CLKACT(bit24) を立てる：

```bash
sudo devmem 0xFF5E00C0           # 例: 0x00010A00 (bit24=0 → 無効)
sudo devmem 0xFF5E00C0 32 0x01010A00   # bit24=1 → 有効化
```

これでイヤホンからトーンが鳴る。恒久化するなら JTAG ではなく fpga_manager + デバイスツリーオーバーレイでロードし、クロックも自動有効化する。

---

## 段2: I2S ループバック（ADC→PL→DAC、デジタルゲイン付き）

ADC(CS5343) で受けた音を PL でデジタル増幅し、DAC(CS4344) へ戻す。クロック生成・TX 直列化・RX 並列化を 1 モジュール `i2s_loop.v` に統合し、単一のフレームカウンタで TX/RX のビット位置を揃える。

```
ADC(CS5343) ─SDOUT→ i2s_loop ┬ RX: SCLK立上りで16bit復元(L/R)
                              ├ GAIN倍(飽和付き, 既定32)
                              └ TX: 直列化 ─SDIN→ DAC(CS4344)
PL がマスタで ADC/DAC 両方へ MCLK12.5M / SCLK3.125M / LRCK≒48.8kHz を供給
```

### ピンアサイン（J2、DAC=上段 / ADC=下段）

| 信号 | Pmod物理ピン | FPGA | 用途 |
|------|------|------|------|
| dac_mclk/lrck/sclk/sdin | 1/2/3/4 | H12/E10/D10/C11 | DAC へ出力 |
| adc_mclk/lrck/sclk | 7/8/9 | B10/E12/D11 | ADC へクロック供給 |
| adc_sdout | 10 | B11 | ADC から入力 |

### 使い方

```bash
vivado -mode batch -source create_i2s2_loop_project.tcl
vivado -mode batch -source build_loop_bitstream.tcl
# 生成物: vivado_loop/i2s2_loop.runs/impl_1/design_1_wrapper.bit
```

書き込み後に段1と同じく PL クロックを有効化（`sudo devmem 0xFF5E00C0 32 0x01010A00`）。

### デジタル経路の検証（信号源が無い場合）

ライン入力(J5)に挿したプラグの金属に**濡れた指で触れる**と、体が拾う電源ハムが ADC に入る。これがゲイン倍されてスピーカーから「ブーン」と鳴れば、クロック・RX 取り込み・ループバック・DAC 出力まで全経路が正常と確認できる（音源やケーブル不要の切り分け）。

### 入力レベルの注意

Pmod I2S2 の ADC 入力(J5)は**ライン入力**。エレクトレットマイクはバイアス＋プリアンプが無いと信号を出せず、ゲインを上げてもハムだけが大きくなる。実用にはアンプ内蔵マイクモジュール(MAX9814 等)かライン級音源を使う。`GAIN` パラメータはライン級入力では `1` 前後に下げる（既定 32 は極小信号向けで、ライン級では飽和する）。

---

## 環境

- ボード: Kria KV260 (xck26-sfvc784-2LV-c)
- ツール: Vivado 2025.1
- Pmod: Digilent Pmod I2S2 (CS5343 ADC / CS4344 DAC)
