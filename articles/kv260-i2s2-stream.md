---
title: "KV260のFPGAで28分の曲を丸ごと鳴らす（Pmod I2S2・PS→PL AXIストリーミング・段5）"
emoji: "🎶"
type: "tech"
topics: ["fpga", "kv260", "verilog", "axi", "petalinux"]
published: true
---

## はじめに

Xilinx Kria KV260 の PL（FPGA）から Pmod I2S2 で音を鳴らす記事の続きです。

- 段3/段4（[前回の記事](https://zenn.dev/)）では、メロディと、内蔵メモリ（BRAM）に焼いた
  4秒の録音を鳴らしました。
- しかし内蔵メモリは 5.1Mbit しかなく、16ビット・48kHz の単音では**6秒前後が上限**でした。

この記事では、その壁を越えて **28分の曲を丸ごと鳴らす**方法を書きます。
鍵は、音声データを FPGA に焼き込むのをやめ、**Linux（PS）から AXI 経由で PL の FIFO に
流し込み続ける**という構成です。ハマりどころだった「特定のアドレスだけ読み出しが 0 になる」
問題についても書きます。

## 全体の構成

内蔵メモリに全部を置くのではなく、Linux 側にファイルとして持ち、少しずつ PL に送ります。

```
PS(Linux)                          PL(FPGA)
 play song.raw                      ┌─────────────────────────┐
   │  AXI4-Lite                     │ i2s_stream_axi          │
   ├─ M_AXI_HPM0_FPD ─> Interconnect ─> FIFO(8192段) ─> I2S送信 ─SDIN→ DAC
   │                                └─────────────────────────┘
   └─ STATUS を読んで「満杯なら待つ」で流量を調整
```

- PS は 1 標本（16ビット）ずつ AXI で FIFO に書き込む
- PL は標本化周期（fs = 12.5MHz / 256 ≒ 48828Hz）ごとに FIFO から 1 標本取り出して送出
- FIFO が満杯になったら PS は書き込みを止めて待つ。これで**送りすぎ（＝早送り）を防ぐ**

## FIFO は「緩衝」と「流量制御」の両方を担う

PS 側の書き込みは OS のスケジューリングで不規則になります。一方 PL の消費は
48828 標本/秒で一定です。この速度差を吸収するのが FIFO（緩衝記憶）です。

FIFO は単一クロック（AXI も I2S も 12.5MHz）の同期 FIFO にしました。書き込み位置と
読み出し位置を 1 ビット余分に持ち、最上位ビットで周回を区別して満杯／空を判定します。

```verilog
// audio_fifo.v（抜粋）
reg [AW:0] wr_ptr, rd_ptr;                          // 1ビット余分に持つ
assign full  = (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]) && (wr_ptr[AW] != rd_ptr[AW]);
assign empty = (wr_ptr == rd_ptr);
assign count = wr_ptr - rd_ptr;                     // 溜まっている数
assign rd_data = empty ? {DW{1'b0}} : mem[rd_ptr[AW-1:0]];  // 空なら無音
```

PS 側は STATUS レジスタの満杯ビットを見て、満杯の間は書き込みを止めます。
FIFO が空になれば無音（0）を返すので、データが一瞬途切れても雑音になりません。

```c
// play.c（抜粋）: 満杯の間は待つ。これが正しい速さの源
while (reg_read(REG_STATUS) & ST_FULL) usleep(500);
reg_write(REG_DATA, (uint32_t)(uint16_t)sample);
```

## レジスタマップ ── ここに最大のハマりどころがあった

AXI4-Lite スレーブとして 3 つのレジスタを用意しました。

| オフセット | 種別 | 内容 |
|------|------|------|
| 0x00 | W  | DATA   標本を 1 つ書き込む |
| 0x10 | R  | STATUS bit0:満杯 bit1:空 bit29..16:溜まり数 |
| 0x20 | RW | CTRL   bit0:再生有効 |

最初、私はこれを **0x00 / 0x04 / 0x08** と 4 バイト刻みで並べていました。すると：

- `devmem 0xA0000000`（DATA、整列） → 正しく読める
- `devmem 0xA0000004`（STATUS） → **いつも 0**
- `devmem 0xA0000008`（CTRL） → **いつも 0**

STATUS も CTRL も読めないので、PS 側は満杯を検知できず、ファイルを最高速で流し込んで
しまい、あふれた分が捨てられて**早送り**になっていました。さらに再生開始の制御（CTRL）も
効かず無音になることもありました。

### 原因の切り分け

「AXI が届いていないのか、届いているが値が 0 なのか」を確かめるため、読み出しアドレス 0x00 に
**固定値 0xDEADBEEF** を返す仕掛けを入れました。

```verilog
case (S_AXI_ARADDR[5:4])
    2'd0: axi_rdata <= 32'hDEADBEEF;   // 0x00: 動作確認用の固定値
    2'd1: axi_rdata <= {2'b0, fifo_count, 14'b0, fifo_empty, fifo_full};  // 0x10 STATUS
    2'd2: axi_rdata <= {31'b0, reg_play};                                 // 0x20 CTRL
    default: axi_rdata <= 32'b0;
endcase
```

実機で `devmem 0xA0000000` を読むと **0xDEADBEEF が返りました**。
AXI は完全に届いていたのです。0x04 / 0x08 が 0 だったのは、**0x10 境界に整列していない
アドレスの読み出しが 0 を返す**ためでした（Zynq UltraScale+ の HPM を 32 ビット幅で
使ったときに知られている挙動）。

### 対策

レジスタを **0x10 刻み**に並べ直すだけで解決しました。DATA=0x00、STATUS=0x10、CTRL=0x20。
すべて 0x10 境界に整列させます。デコードは `ARADDR[5:4]` で行います。

並べ直したあとの自己診断：

```
CTRL に 1 を書いて読み戻し : 0x00000001 (読み出し成功)
STATUS 生の値              : 0x00000002   ← 空
100標本書いた後の STATUS   : 0x00620000  溜まり=98
速度の調整方法             : 満杯を見て待つ
```

STATUS も CTRL も読めるようになり、満杯待ちで正しい速さの再生になりました。
再生時間と経過時間が一致し、早送りは消えました。

## 早送り・巻き戻し

再生位置の制御は PL 側ではなく、PS 側のファイル読み位置で行えます。PL は
「FIFO から取り出して鳴らすだけ」なので、`play.c` で `fseek` するだけです。

```c
long np = (key == 'f') ? played + seek_step : played - seek_step;  // 10秒ぶん
if (np < 0)     np = 0;
if (np > total) np = total;
fseek(fp, np * 2, SEEK_SET);
played = np;
```

端末を非カノニカル・非ブロッキングにして、再生ループの各チャンクごとにキーを見ます。
**f** で 10 秒送り、**b** で 10 秒戻し、**q** で終了。FIFO に残った古い音（約 0.17 秒）が
先に鳴ってから新しい位置に切り替わりますが、実用上は気になりません。

## PLクロックの有効化（前回と同じ）

書き込みは JTAG ではなく `fpgautil` を使います。JTAG は PL しか書き換えず、PS の
クロック出力設定が変わらないため MCLK が出ず無音になります。

```bash
sudo fpgautil -b ~/stream.bit
sudo devmem 0xFF5E00C0 32 0x01010A00   # PL0_REF_CTRL の CLKACT(bit24) を立てる
gcc -O2 -o play play.c
sudo ./play song.raw
```

## まとめ

- 内蔵メモリの数秒制限は、**PS から AXI で FIFO に流し込む**ことで越えられる。曲まるごと鳴る。
- FIFO の満杯ビットを PS が見て流量を制御することで、早送りにならず正しい速さになる。
- **AXI4-Lite のレジスタは 0x10 境界に整列させる。** 非整列アドレスは devmem/mmap の
  読み出しが 0 になり、原因が非常に分かりにくい。固定値レジスタを 1 つ置くと切り分けが速い。
- 再生位置の制御は PS 側のファイル読み位置（fseek）で行える。PL は鳴らすだけでよい。

## ソースコード

- `rtl/i2s_stream_axi.v` … AXI4-Lite スレーブ + FIFO + I2S 送信
- `rtl/audio_fifo.v` … 単一クロック同期 FIFO
- `build_stream.tcl` … ブロックデザイン生成〜ビットストリーム
- `sw/play.c` … Linux 側の再生プログラム（満杯待ち・早送り対応）

音声データ自体は第三者の録音由来のためリポジトリには含めていません。
`ffmpeg` の変換手順を載せてあるので、各自の音源で再現できます。
