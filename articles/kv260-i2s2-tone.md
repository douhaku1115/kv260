---
title: "KV260のPLで作ったサイン波をPmod I2S2で鳴らす（I2S送信・段1）"
emoji: "🔊"
type: "tech"
topics: ["fpga", "kv260", "vivado", "verilog", "i2s"]
published: false
---

## はじめに

Kria KV260 の PL（FPGA ファブリック）でサイン波を生成し、**I2S 送信**で Digilent **Pmod I2S2**（CS4344 DAC）からイヤホンで鳴らすところまでをまとめます。オーディオを FPGA で処理する一連の最初のステップ（段1：固定トーン再生）です。

**結果**: PL 内の NCO + サイン LUT が生成した約 762Hz のトーンを、Pmod I2S2 の DAC 出力からイヤホンで確認。

最大のハマりは「ビットストリームは書けたのに無音」で、原因は **PL ファブリッククロックがゲートOFF** でした。後半で詳しく書きます。

## 環境

| 項目 | 内容 |
|------|------|
| ボード | Kria KV260 (xck26-sfvc784-2LV-c) |
| ツール | Vivado 2025.1 |
| Pmod | Digilent Pmod I2S2 (CS5343 ADC / CS4344 DAC) |
| OS | PetaLinux 2025.1 系 |
| 接続 | JTAG + SSH |

## 全体構成

```
Zynq PS (pl_clk0 100MHz) → Clocking Wizard (12.5MHz) → i2s_tx
                                                         ├ MCLK 12.5MHz   (=256fs)
                                                         ├ SCLK  3.125MHz (=MCLK/4 = 64fs)
                                                         ├ LRCK  ≒48.8kHz (=MCLK/256 = fs)
                                                         └ SDATA 標準I2S 16bit
```

Pmod I2S2 の DAC（CS4344）は I2C 等の設定が不要な純粋な I2S スレーブで、MCLK / SCLK / LRCK / SDATA を正しい比で与えれば鳴ります。

## クロック設計

CS4344 は MCLK を必要とし、シングルスピードモードでは `MCLK = 256 × fs` が使えます。100MHz から MMCM で割り切れる **12.5MHz** を MCLK とし、ここから分周しました。

- MCLK = 12.5MHz
- SCLK = MCLK / 4 = 3.125MHz（= 64fs、1フレーム32bit×2ch）
- LRCK = MCLK / 256 ≒ 48.8kHz（= fs）

fs が 48.000kHz ちょうどでないのは 100MHz から整数分周で作るためですが、トーン確認には影響しません（CS4344 は MCLK/LRCK 比を自動検出するため、比が 256 で固定されていれば OK）。

## ピンアサインの確定

ここが一番間違えやすいところです。KV260 carrier の Pmod コネクタ **J2** と FPGA パッケージピンの対応を、ボードファイル（som240 → パッケージピン）と公式資料、Digilent Pmod I2S2 の物理ピン配置の3点照合で確定させました。

| 信号 | Pmod物理ピン | FPGA | som240 |
|------|------|------|--------|
| TX MCLK | 1 | H12 | a17 |
| TX LRCK | 2 | E10 | d20 |
| TX SCLK | 3 | D10 | d21 |
| TX SDATA | 4 | C11 | d22 |
| RX MCLK | 7 | B10 | b20 |
| RX LRCK | 8 | E12 | b21 |
| RX SCLK | 9 | D11 | b22 |
| RX SDATA | 10 | B11 | c22 |

Pmod I2S2 は J2 に直挿しなので手配線は不要です。バンク 45（HDA）の VCCO は 3.3V なので IOSTANDARD は `LVCMOS33`。

## I2S 送信ロジック（Verilog）

MCLK から全てを分周し、フレームカウンタ（256 MCLK = 1 サンプル）で SCLK / LRCK / ビット位置を作ります。NCO で 64 点のサイン LUT を読み出し、標準 I2S（WS エッジの 1SCLK 後に MSB）で直列化します。

```verilog
module i2s_tx #(parameter integer DW = 16)(
    input  wire mclk, input wire rst_n,
    output wire mclk_o, output reg sclk, output reg lrck, output reg sdout
);
    reg [7:0] c;                       // フレームカウンタ(256 mclk = 1 fs)
    always @(posedge mclk or negedge rst_n)
        if (!rst_n) c <= 0; else c <= c + 1;

    wire [5:0] bi = c[7:2];            // フレーム内ビット位置 0..63
    wire [4:0] cb = bi[4:0];           // チャンネル内ビット位置 0..31

    reg [5:0] phase;                   // NCO
    always @(posedge mclk or negedge rst_n)
        if (!rst_n) phase <= 0; else if (c == 8'hFF) phase <= phase + 1;

    reg signed [15:0] sine [0:63];
    initial $readmemh("sine_lut.hex", sine);
    reg signed [15:0] sample;
    always @(posedge mclk) if (c == 8'hFF) sample <= sine[phase];

    reg sd;                            // I2S: cb=1→MSB ... cb=DW→LSB、他は0
    always @(*) sd = (cb >= 1 && cb <= DW) ? sample[DW-1-(cb-1)] : 1'b0;

    always @(posedge mclk or negedge rst_n)
        if (!rst_n) {sclk,lrck,sdout} <= 0;
        else begin sclk <= c[1]; lrck <= c[7]; sdout <= sd; end

    ODDRE1 #(.SRVAL(1'b0)) u_mclk (.Q(mclk_o), .C(mclk), .D1(1'b1), .D2(1'b0), .SR(1'b0));
endmodule
```

MCLK は出力ピンへ `ODDRE1` でクリーンに転送します。

## プロジェクト生成は Tcl で

ブロックデザイン（Zynq PS + Clocking Wizard + i2s_tx を Module Reference で取り込み、BD ラッパをトップ）を Tcl で組みました。IP の VLNV はバージョン差で落ちないよう、インストール済みの最新版を自動取得しています。

```tcl
set ps_vlnv  [lindex [lsort [get_ipdefs -all *:ip:zynq_ultra_ps_e:*]] end]
set clk_vlnv [lindex [lsort [get_ipdefs -all *:ip:clk_wiz:*]] end]
create_bd_cell -type ip -vlnv $ps_vlnv ps
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset 1} [get_bd_cells ps]
```

ここで2つ詰まりました。

- PS プリセットが AXI マスタ（HPM0/1_FPD）を有効化し、その `aclk` 未接続で validate に失敗 → `PSU__USE__M_AXI_GP0/1` を 0 にして解決。
- clk_wiz の入力周波数を `100.000` に固定したら、PS の `pl_clk0` 実値 `99.999001MHz` と `FREQ_HZ` 不一致でエラー → 入力を `99.999001` に合わせて解決。

合成〜ビットストリームまで通り、タイミングは WNS +77ns と余裕でした。

## 「書けたのに無音」── PLクロックがゲートOFF

ビットストリームを JTAG で書き込み、`End of startup status: HIGH`（FPGA 正常起動）まで確認できたのに、イヤホンから音が出ません。

切り分けると、PL ファブリッククロックが死んでいました。

```
$ sudo cat /sys/kernel/debug/clk/clk_summary | grep -w pl0_ref
pl0_ref  0  0  0  99999999  0  0  50000  N
```

レートは 100MHz に設定されているのに、末尾が **`N`**（ハードウェア無効＝ゲートOFF）。JTAG で PL だけ書き換えると、ファブリッククロックを有効化するデバイスツリー設定が効かず、ゲートが閉じたままになるためです。MCLK が出ないので DAC は当然無音です。

`/sys/class/fclk/` が無い環境だったので、**devmem で CRL_APB の `PL0_REF_CTRL`(0xFF5E00C0) の CLKACT(bit24) を直接立て**ました。

```bash
$ sudo devmem 0xFF5E00C0
0x00010A00                              # bit24=0 → ゲートOFF
$ sudo devmem 0xFF5E00C0 32 0x01010A00  # bit24=1 → 有効化
```

これで `pl0_ref` が `Y` になり、**イヤホンからトーンが鳴りました**。

恒久化するなら JTAG ではなく fpga_manager + デバイスツリーオーバーレイ（.dtbo）でロードし、クロックも overlay 側で自動有効化するのが正攻法です。

## まとめ

- KV260 J2 の Pmod ピンを3点照合で確定（H12/E10/D10/C11）
- 12.5MHz MCLK から I2S クロックを生成し、NCO + サイン LUT で標準 I2S 送信
- 「書けたのに無音」は PL ファブリッククロックのゲートOFF が原因。devmem で CLKACT を立てて解決

次は段2として I2S 受信（CS5343 ADC）を足し、PL 内でマイク → スピーカーのループバックに進みます。最終的には音声経路に FIR を挿し、FPGA でのリアルタイム音声フィルタを目指します。

コード: https://github.com/douhaku1115/kv260/tree/main/kv260_i2s2
