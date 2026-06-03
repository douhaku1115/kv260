# kv260_i2s2 — Pmod I2S2 で固定トーン再生（段1）

KV260 の PL で生成したサイン波を I2S 送信し、Pmod I2S2（CS4344 DAC）からイヤホンで鳴らす最小構成。

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

## 環境

- ボード: Kria KV260 (xck26-sfvc784-2LV-c)
- ツール: Vivado 2025.1
- Pmod: Digilent Pmod I2S2 (CS5343 ADC / CS4344 DAC)
