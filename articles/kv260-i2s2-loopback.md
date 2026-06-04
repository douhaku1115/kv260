---
title: "KV260のPLでI2Sループバック：ADC→デジタル増幅→DAC（Pmod I2S2・段2）"
emoji: "🎙️"
type: "tech"
topics: ["fpga", "kv260", "vivado", "verilog", "i2s"]
published: false
---

## はじめに

前回（段1）は KV260 の PL でサイン波を生成し、Pmod I2S2 の DAC からイヤホンで鳴らしました。今回（段2）は **ADC で受けた音を PL でデジタル増幅して DAC へ戻すループバック**を作ります。クロック生成・I2S 送信（直列化）・I2S 受信（並列化）を 1 つの Verilog モジュールに統合し、最後にデジタルゲインを 1 段足します。

**結果**: ADC→PL→DAC のデジタル経路は完全に動作。ただし「マイク→スピーカー」を実際に成立させるには、Pmod I2S2 の **ライン入力**に対してマイクの信号が弱すぎるという、アナログ前段の壁にぶつかりました。そこまで含めて正直に書きます。

前回: https://github.com/douhaku1115/kv260/tree/main/kv260_i2s2

## 全体構成

Pmod I2S2 は ADC(CS5343) と DAC(CS4344) が別々の I2S 端子を持ちます。PL がマスタとなり、ADC・DAC の両方へ同じ MCLK / SCLK / LRCK を供給し、ADC からの SDOUT を受けて DAC へ SDIN を出します。

```
ADC(CS5343) ─SDOUT→ i2s_loop ┬ RX: SCLK立上りで16bit復元(L/R)
                              ├ GAIN倍(飽和付き)
                              └ TX: 標準I2Sで直列化 ─SDIN→ DAC(CS4344)
共通クロック: MCLK 12.5MHz(256fs) / SCLK 3.125MHz(64fs) / LRCK ≒48.8kHz(fs)
```

段1のクロック設計（12.5MHz を MCLK にして分周）をそのまま使います。

## 1モジュールに統合する理由

TX と RX を別モジュールにしてクロックを配線で渡すと、ビット位置の位相合わせでミスが出やすくなります。そこで**単一のフレームカウンタ**（256 MCLK = 1 サンプル）で、TX の送信ビット位置と RX の取り込みビット位置を同じ `cb`（チャンネル内ビット位置）から導きました。これで送受のビット境界が原理的にずれません。

```verilog
reg [7:0] c;                       // フレームカウンタ(256 mclk = 1 fs)
wire [5:0] bi = c[7:2];            // フレーム内ビット位置 0..63
wire [4:0] cb = bi[4:0];           // チャンネル内ビット位置 0..31
wire       lr = c[7];              // 0=L / 1=R
```

### RX: ADC SDOUT の取り込み

自分が出している SCLK の立上りエッジ（`c[1]` の 0→1）で SDOUT をサンプリングし、`cb=1..16` を MSB..LSB として 16bit を復元します。I2S 規約（WS エッジの 1SCLK 後に MSB）どおりです。

```verilog
reg sclk_d;
always @(posedge mclk or negedge rst_n)
    if (!rst_n) sclk_d <= 1'b0; else sclk_d <= c[1];
wire sclk_rise = (c[1] == 1'b1) && (sclk_d == 1'b0);

reg signed [15:0] rxsh, rxL, rxR;
always @(posedge mclk or negedge rst_n) begin
    if (!rst_n) begin rxsh<=0; rxL<=0; rxR<=0; end
    else if (sclk_rise) begin
        if (cb >= 1 && cb <= 16) rxsh <= {rxsh[14:0], adc_sdout};
        if (cb == 16) begin
            if (lr == 1'b0) rxL <= {rxsh[14:0], adc_sdout};
            else            rxR <= {rxsh[14:0], adc_sdout};
        end
    end
end
```

### TX: デジタルゲイン（飽和付き）→ 直列化

復元した左右サンプルを `GAIN` 倍し、16bit を超えたら ±最大値でクリップして DAC へ送ります。

```verilog
function signed [15:0] sat;        // 32bit値を16bitに飽和
    input signed [31:0] v;
    begin
        if      (v >  32767) sat =  32767;
        else if (v < -32768) sat = -32768;
        else                 sat =  v[15:0];
    end
endfunction

wire signed [31:0] ampL = $signed(rxL) * GAIN;
wire signed [31:0] ampR = $signed(rxR) * GAIN;

reg signed [15:0] txL, txR;
always @(posedge mclk)
    if (c == 8'hFF) begin txL <= sat(ampL); txR <= sat(ampR); end
```

`GAIN` を 2 の冪（例 32）にすると、合成時に乗算がシフトへ最適化され DSP を使いません（実際 DSP 使用 0 でした）。

## ビルドとタイミング

段1と同じく Tcl でブロックデザイン（Zynq PS + Clocking Wizard 12.5MHz + i2s_loop を Module Reference で取り込み、BD ラッパをトップ）を生成し、合成〜ビットストリームまで通しました。WNS は +77ns と余裕があります。外部ポートは DAC 側 `dac_mclk/sclk/lrck/sdin`、ADC 側 `adc_mclk/sclk/lrck/sdout` です。

## 信号源が無くてもデジタル経路を検証する

ここが今回の実用的なコツです。ライン入力に挿したプラグの金属端子に**濡れた指で触れる**と、体がアンテナになって 50/60Hz の電源ハムを拾い、それが ADC に入ります。これがゲイン倍されてスピーカーから「ブーン」と鳴れば、

クロック → ADC 取り込み → RX 復元 → ゲイン → TX 直列化 → DAC 出力

の全経路が一度に検証できます。音源もケーブルも要りません。実際これで「デジタル側は完全に正常」と確定できました。

## ぶつかった壁：マイクがライン入力を駆動できない

指のハムは大きく鳴るのに、マイクを挿して話しても**ブーン（ハム）だけが大きくなり、声は乗りません**。原因はデジタルではなくアナログ前段でした。

Pmod I2S2 の ADC 入力(J5)は**ライン入力**で、エレクトレットマイクは**バイアス電圧＋プリアンプ**が無いと信号を出せません（内部 FET がバイアスなしでは動作しない）。出力がほぼゼロなので、ゲインをいくら上げても増幅されるのは環境ハムだけ、という結果になります。

対策は次のいずれかです。

- **アンプ内蔵マイクモジュール**（MAX9814〔AGC付き〕や MAX4466）でライン級まで増幅してから J5 に入れる
- スマホ/PC の**ライン出力**を 3.5mm ケーブルで J5 に入れる（ハムで経路は実証済みなので確実）

なお `GAIN=32` は極小信号向けの設定で、ライン級の入力ではすぐ飽和します。ライン音源を使うときは `GAIN` を 1 前後へ下げて作り直します（1 行の変更）。

## まとめ

- クロック生成・I2S 送受・ビット位置合わせを 1 モジュールに統合し、ADC→PL→DAC のループバックを実装
- デジタルゲイン段（飽和付き、2 の冪でシフト最適化）を追加
- 指のハム注入で、音源なしにデジタル全経路を検証できた
- 「マイク→スピーカー」は Pmod I2S2 のライン入力にマイクが弱すぎるのが壁。PL 側の設計は完成しており、残りはアナログ前段（アンプ内蔵マイク or ライン音源）の問題

次は音声経路に FIR を挿し、PL でのリアルタイム音声フィルタへ進みます。

コード: https://github.com/douhaku1115/kv260/tree/main/kv260_i2s2
