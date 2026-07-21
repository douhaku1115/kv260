---
title: "KV260のFPGAでメロディと実際の録音を鳴らす（Pmod I2S2・段3/段4）"
emoji: "🎵"
type: "tech"
topics: ["fpga", "kv260", "verilog", "i2s", "vivado"]
published: true
---

## はじめに

Xilinx Kria KV260 の PL（FPGA）から Pmod I2S2 経由で音を出す一連の記事の続きです。

- 段1: PL で作ったサイン波を鳴らす（固定 762Hz）
- 段2: ADC→PL→DAC のループバック
- **段3: 音階を切り替えてメロディを鳴らす** ← 本記事
- **段4: 実際の録音（音声ファイル）を鳴らす** ← 本記事

固定の「ピー」音から、きらきら星、そしてバッハの演奏録音まで到達しました。

**最大のハマりどころは音の作り方ではなく、ビットストリームの書き込み方法**でした。後半に書きます。

## 環境

| 項目 | 内容 |
|------|------|
| ボード | Kria KV260 (xck26-sfvc784-2LV-c) |
| ツール | Vivado 2025.2 |
| Pmod | Digilent Pmod I2S2 (CS4344 DAC) |
| OS | PetaLinux（ユーザー名 `petalinux`） |

Pmod I2S2 を J2 に直挿しし、DAC 出力ジャックにイヤホンを挿すだけです。手配線は要りません。

## 共通の構成

```
Zynq PS (pl_clk0 100MHz) → Clocking Wizard (12.5MHz) → I2S送信回路
                                                         ├ MCLK 12.5MHz
                                                         ├ SCLK 3.125MHz (MCLK/4)
                                                         ├ LRCK ≒48.8kHz (MCLK/256 = fs)
                                                         └ SDATA 標準I2S 16bit
```

標本化周波数は `fs = 12.5MHz ÷ 256 = 48828.125Hz` です。44.1kHz や 48kHz ちょうどではありませんが、DAC 側がクロックに従う従属動作なので問題なく鳴ります。

---

# 段3: メロディを鳴らす

## 固定トーンでは周波数を変えられない

段1の回路は、こう位相を進めていました。

```verilog
reg [5:0] phase;                       // 6bit = 64段階
always @(posedge mclk or negedge rst_n)
    if (!rst_n)          phase <= 6'd0;
    else if (c == 8'hFF) phase <= phase + 6'd1;   // 1標本ごとに +1
```

64点のサイン波テーブルを1標本につき1つずつ進めるので、64標本で1周します。つまり周波数は `fs ÷ 64 ≒ 762Hz` に**固定**され、変えようがありません。

## 位相アキュムレータにすると周波数が自由になる

そこで、位相を24ビットに広げ、**音ごとに違う増分を足す**方式（NCO: 数値制御発振器）に変えます。

```verilog
reg [23:0] phase_acc;
always @(posedge mclk or negedge rst_n) begin
    if (!rst_n)           phase_acc <= 24'd0;
    else if (sample_tick) phase_acc <= phase_acc + note_inc(melody(step));
end

// 上位6ビットで64点のサインテーブルを引く
always @(posedge mclk)
    if (sample_tick) sample <= sine[phase_acc[23:18]];
```

増分と周波数の関係はこうなります。

```
PHASE_INC = 周波数 × 2^24 ÷ fs
```

`fs = 48828.125Hz` なら係数は `2^24 ÷ 48828.125 = 343.597` です。各音の値は次のとおり。

| 音 | 周波数 | PHASE_INC |
|---|---|---|
| ド C4 | 261.63Hz | 89893 |
| レ D4 | 293.66Hz | 100902 |
| ミ E4 | 329.63Hz | 113258 |
| ファ F4 | 349.23Hz | 119994 |
| ソ G4 | 392.00Hz | 134687 |
| ラ A4 | 440.00Hz | 151183 |
| シ B4 | 493.88Hz | 169696 |
| ド C5 | 523.25Hz | 179787 |

24ビットに広げた理由は分解能です。増分1あたり約2.9Hz なので、音階を十分な精度で表現できます。

## 曲データとシーケンサ

音階テーブルと曲データを関数で持ち、一定時間ごとに次の音へ進めます。

```verilog
function [23:0] note_inc(input [2:0] n);
    case (n)
        3'd0: note_inc = 24'd89893;     // ド
        3'd4: note_inc = 24'd134687;    // ソ
        3'd5: note_inc = 24'd151183;    // ラ
        // ...
    endcase
endfunction

function [2:0] melody(input [3:0] step);
    case (step)                          // きらきら星 前半
        4'd0 : melody = 3'd0;   // ド
        4'd1 : melody = 3'd0;   // ド
        4'd2 : melody = 3'd4;   // ソ
        4'd3 : melody = 3'd4;   // ソ
        4'd4 : melody = 3'd5;   // ラ
        4'd5 : melody = 3'd5;   // ラ
        4'd6 : melody = 3'd4;   // ソ
        4'd7 : melody = 3'd4;   // ソ(伸ばし)
        // ... ファファ ミミ レレ ド
    endcase
endfunction
```

シーケンサは `NOTE_LEN`（12000標本 ≒ 0.25秒）ごとに `step` を1つ進め、4ビットなので16音で自動的に周回します。

```verilog
always @(posedge mclk or negedge rst_n) begin
    if (!rst_n) begin
        note_cnt <= 0;  step <= 0;
    end else if (sample_tick) begin
        if (note_cnt >= NOTE_LEN - 1) begin
            note_cnt <= 0;
            step     <= step + 4'd1;    // 16音でループ
        end else
            note_cnt <= note_cnt + 1;
    end
end
```

これできらきら星が繰り返し鳴ります。

---

# 段4: 実際の録音を鳴らす

合成した音ではなく、手元の音楽ファイルをそのまま鳴らします。仕組みは単純で、**PCM データを内蔵メモリに焼き込み、1標本ずつ読み出すだけ**です。

```
音源(MP3等) --ffmpeg--> 生PCM --Python--> hexテキスト --$readmemh--> 内蔵メモリ
```

## 音源の変換

FPGA は圧縮音声を扱えないので、パソコン側で 16ビットの数値列に展開します。

```bash
ffmpeg -y -ss 80 -t 4 -i 元の音源.mp3 \
       -ac 1 -ar 48828 -f s16le -acodec pcm_s16le clip.raw
```

| 指定 | 意味 |
|---|---|
| `-ss 80 -t 4` | 開始80秒から4秒間 |
| `-ac 1` | 単音（左右に同じ音を出す） |
| `-ar 48828` | 回路の fs に合わせる |
| `-f s16le` | 16ビット符号付き、下位バイト先行の生データ |

これを `$readmemh` 用の16進テキストに変換します。

```python
samples = struct.unpack("<%dh" % n, data[:n*2])

with open("audio_rom.hex", "w") as f:
    for s in samples:
        v = int(s * GAIN)
        if v >  32767: v =  32767
        if v < -32768: v = -32768
        f.write("%04X\n" % (v & 0xFFFF))   # 2の補数を4桁16進で
```

## 音量に注意

ここで一度つまずきました。変換したデータの**最大振幅が 3407**（16ビットの上限 32767 に対して約10%）しかなく、そのまま焼くと「鳴ってはいるが聞こえない」状態になります。

静かな演奏部分を切り出すとこうなるので、**変換スクリプトに最大振幅を表示させ、必要なら増幅**します。今回は8倍にしました。

```
標本数      : 195312
再生時間    : 4.00 秒 (48828Hz)
最大振幅    : 3407 (16ビット上限 32767)
必要メモリ  : 3.12 Mbit
```

## 再生回路

読み出すだけなので、段3より簡単です。

```verilog
(* rom_style = "block" *)
reg signed [15:0] audio [0:ROM_LEN-1];
initial $readmemh("audio_rom.hex", audio);

// 1標本ごとにアドレスを進め、終端で先頭へ戻る
always @(posedge mclk or negedge rst_n) begin
    if (!rst_n)
        addr <= 0;
    else if (sample_tick) begin
        if (addr >= ROM_LEN - 1) addr <= 0;
        else                     addr <= addr + 1;
    end
end

always @(posedge mclk)
    if (sample_tick) sample <= audio[addr];
```

I2S 送信部は段1から変えていません。音源の作り方だけが違います。

## 容量の壁

内蔵メモリ（Block RAM）は 5.1Mbit なので、16ビット・48828Hz・単音では次のとおりです。

| 長さ | 標本数 | 必要メモリ | 使用率 |
|---|---|---|---|
| 2秒 | 97656 | 1.56 Mbit | 31% |
| **4秒** | **195312** | **3.12 Mbit** | **61%** |
| 6秒 | 292968 | 4.69 Mbit | 92% |

**数秒が限界**です。曲を丸ごと鳴らすには UltraRAM を使うか、PS 側の DDR から読み出す仕組み（AXI 経由）が要ります。

---

# 最大のハマりどころ: JTAG 書き込みでは鳴らない

ここが本記事でいちばん伝えたい点です。

## 症状

回路は正しいのに、**まったく音が出ない**。テスターで出力ピンを測っても信号が出ているように見えない。クロックの設定、ピン配置、配線を何度も見直しても原因がわからない。

## 原因

**Vivado の Hardware Manager による JTAG 書き込みでは、PL クロックが供給されない。**

JTAG は PL のファブリックだけを書き換え、**PS 側の設定（クロック出力の有効化）を変更しません**。そのため `pl_clk0` がゲート OFF のままで、FPGA 内の回路が1歩も動きません。

## 解決策: fpgautil でロードする

Linux 上の `fpgautil` でロードすると、PS-PL インターフェースが正しく初期化されます。

```bash
# パソコン側（末尾の :~/ を忘れないこと。無いとローカルコピーになる）
scp -O design_1_wrapper.bit petalinux@192.168.0.8:~/player.bit

# KV260 側
sudo fpgautil -b ~/player.bit                 # ← JTAG ではなくこれ
sudo devmem 0xFF5E00C0 32 0x01010A00          # PLクロック有効化
```

`0xFF5E00C0` は `PL0_REF_CTRL` レジスタで、bit24 が `CLKACT`（クロックの有効/無効）です。

```
0x00010A00  → bit24 = 0 → クロック無効（無音）
0x01010A00  → bit24 = 1 → クロック有効
```

**JTAG 書き込みから fpgautil に変えた瞬間に鳴りました。** これに気づくまでにかなりの時間を使いました。

## 音を止めるには

PL クロックを切ります。

```bash
sudo devmem 0xFF5E00C0 32 0x00010A00
```

## 補足: scp の落とし穴

転送先の `:~/` を書き忘れると、scp ではなく**ローカルコピー**として扱われ、`ホスト名@IPアドレス` という名前のファイルがパソコン側にできるだけです。転送されていないので `fpgautil` が「ファイルが無い」と言います。

また、OpenSSH 9.0 以降は `-O` オプション（レガシー SCP プロトコル）が必要な場合があります。

ユーザー名は `petalinux` です。プロンプトに出る `xilinx-kv260-starterkit-2025x` は**ホスト名**なので間違えやすいところです。

---

## まとめ

- 固定トーンから**位相アキュムレータ方式**に変えると、任意の音階が出せる（`PHASE_INC = 周波数 × 2^24 ÷ fs`）
- 実際の録音は **ffmpeg で生PCMに展開 → 内蔵メモリに焼く**だけで鳴る。合成より簡単
- 変換時は**最大振幅を確認**する。小さいと鳴っていても聞こえない
- 内蔵メモリでは**数秒が限界**。曲を丸ごとなら DDR からの読み出しが必要
- **KV260 では JTAG 書き込みではなく `fpgautil` を使う**。これを知らないと「回路は正しいのに無音」で延々と悩む

次は PS 側の DDR から読み出して長時間再生、あるいはステレオ化や DSD 再生に進む予定です。

## ソースコード

https://github.com/douhaku1115/kv260/tree/main/kv260_i2s2

音声データ自体は第三者の録音由来のため含めていません。変換手順（`audio/README.md`）に従って各自の音源から生成してください。

## 参考

- [Kria KV260 Vision AI Starter Kit](https://www.amd.com/en/products/system-on-modules/kria/k26/kv260-vision-starter-kit.html)
- [Digilent Pmod I2S2 Reference Manual](https://digilent.com/reference/pmod/pmodi2s2/reference-manual)
- [Zynq UltraScale+ Technical Reference Manual (UG1085)](https://docs.amd.com/r/en-US/ug1085-zynq-ultrascale-trm)
