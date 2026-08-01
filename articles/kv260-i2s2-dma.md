---
title: "自作AXI4マスタでCPUを使わずに音を鳴らす（KV260・Pmod I2S2・段10/11）"
emoji: "🚚"
type: "tech"
topics: ["fpga", "kv260", "verilog", "axi", "dma"]
published: true
---

## はじめに

Xilinx Kria KV260 の PL（FPGA）で音を扱う記事の続きです。

- 段5〜9 では、PS（Linux）が **AXI4-Lite で 1 標本ずつ書き込んで**音を鳴らしていました。
  再生中ずっと CPU が働き続けます。
- この記事では **段10（イコライザ・歪み）** と、**段11：自作 AXI4 マスタで PL が PS の
  DDR を直接読み、CPU を一切使わずに再生する**ところまで進めます。

「PCIe をやりたい」から始まった話ですが、KV260 の K26 SOM には GTH/GTY トランシーバが
無く PCIe は作れません。代わりに **AXI HP ポート経由の DMA** に取り組みました。

## 段10: イコライザと歪み

段7 で作った音量・エコーに、低音／高音の調整と歪みを足します。

```
FIFO → 音量 → イコライザ(低音×BASS + 高音×TREBLE) → 歪み → エコー → I2S
```

### イコライザ

1次ローパス（1極 IIR）で低音成分を取り出し、**残りを高音成分**とします。

```verilog
lp += (in - lp) >> K        // K=5 で遮断 ≒ 48828/(2π·32) ≒ 243Hz
hi  = in - lp               // 高音 = 元の音 − 低音
out = (lp*BASS + hi*TREBLE) >> 6
```

引き算1つで高音が得られるのが要点です。BASS=255／TREBLE=0 にするとこもった音に、
逆にすると薄い音になります。

### 歪み

一定の高さで波形の頭を切ります。切った分が高調波になり、歪んだ音になります。

```verilog
lim = 32767 >> DIST[7:4]                 // 切る高さ
out = clip(in, lim) << DIST[7:4]         // 切った後、同じだけ戻して音量を保つ
```

### Verilog の関数は使う前に定義する

`clip16` などの関数を、使う場所より後ろに書いていて合成が通りませんでした。
Verilog は関数の前方参照ができません。**モジュールの先頭側に置く**のが安全です。

## 段11: 自作 AXI4 マスタで DDR を読む

ここからが本題です。**PL が主人になって PS のメモリを読みに行きます。**

```
PS DDR ←─ S_AXI_HP0 ←─ 自作AXI4読み出しマスタ ─→ FIFO ─→ audio_fx ─→ I2S
                            ↑ PS はレジスタで指示するだけ
```

### AXI4 読み出しマスタ（自作）

AXI DMA IP を使わず自作しました。読み出しだけなので構造は単純です。

1. **AR チャネル**で「このアドレスから N 個読みたい」と要求を出す
2. **R チャネル**でデータが順に返る。最後に `RLAST=1` が付く

1 回の要求でまとめて連続転送する（**バースト転送**）のが AXI4-Lite との違いです。
ここでは 1 転送 = 64bit、16 転送 = 128 バイトを 1 バーストにしました。

```verilog
ADDR: begin
    if (!M_AXI_ARVALID) begin
        M_AXI_ARADDR  <= cur_addr;
        M_AXI_ARLEN   <= this_beats - 1;   // AXI は「長さ-1」で指定
        M_AXI_ARVALID <= 1'b1;
    end else if (M_AXI_ARREADY) begin
        M_AXI_ARVALID <= 1'b0;
        st            <= DATA;
    end
end
DATA: if (M_AXI_RVALID && out_ready) begin
    read_cnt <= read_cnt + BYTES;
    cur_addr <= cur_addr + BYTES;
    remain   <= remain - BYTES;
    if (M_AXI_RLAST) st <= ADDR;           // このバースト終わり → 次へ
end
```

実機に載せる前に、擬似 AXI スレーブを繋いだテストベンチで検証しました。
256 バイト＝2 バーストが正しい順序・正しいデータで読めることを確認してから実機へ。

### ハマりどころ 4 点

**1. PS 側で HP ポートを有効にする**

```tcl
CONFIG.PSU__USE__S_AXI_GP2 {1}      # S_AXI_GP2 = S_AXI_HP0_FPD
CONFIG.PSU__SAXIGP2__DATA_WIDTH {64}
```

制御用の HPM（AXI4-Lite・細い）とは別に、データ転送用の広帯域ポートがあります。

**2. クロック周波数が一致しないと BD 検証が落ちる**

```
ERROR: [BD 41-237] Bus Interface property FREQ_HZ does not match
       between /ps/S_AXI_HP0_FPD(12501995) and /i2s/M_AXI(100000000)
```

自作モジュールの M_AXI は既定で 100MHz と見なされます。ここで **`12500000` と書いても
駄目**でした。PS 側は clk_wiz が実際に出す値（12501995）を見ているためです。

```tcl
set_property CONFIG.FREQ_HZ [get_property CONFIG.FREQ_HZ [get_bd_pins clk/clk_out1]] \
    [get_bd_intf_pins i2s/M_AXI]
```

実値を取ってきて設定するのが確実です。

**3. DMA から見た DDR のアドレス割り当てが要る**

```tcl
assign_bd_address -target_address_space [get_bd_addr_spaces i2s/M_AXI] \
    [get_bd_addr_segs ps/SAXIGP2/HP0_DDR_LOW] -force
```

これが無いと、そもそも DDR が見えません。

**4. 読み出し専用でも書き込みチャネルの端子が要る**

AW/W/B の端子が無いと Vivado が AXI4 インターフェースとして認識しません。
0 に固定して用意しておきます。

### 動作確認

DDR に目印を書いて、PL に読ませます。

```bash
sudo devmem 0x10000000 32 0x11223344     # DDR に書く
sudo devmem 0xA00000B0 32 0x10000000     # 開始アドレス
sudo devmem 0xA00000C0 32 8              # 8バイト読む
sudo devmem 0xA00000D0 32 1              # 開始
sudo devmem 0xA00000E0 32                # → 0x00008002 (done + 読了)
sudo devmem 0xA00000F0 32                # → 0x11223344 ✓
```

## 物理連続メモリをどう確保するか

ここが段11 の本当の壁でした。

**Linux の通常メモリは物理的に断片化しています。** ユーザー空間から見て連続でも、
物理アドレスはバラバラです。PL に「ここから連続で読め」と教えられません。

上の確認では `0x10000000` に直接書きましたが、`/proc/iomem` を見ると

```
00000000-7fefffff : System RAM
```

——**Linux が使っている領域のど真ん中**でした。運良く壊れなかっただけで、危険です。

### 解決: 起動引数で領域を予約する

CMA から取る（udmabuf 等のドライバが要る）、デバイスツリーで reserved-memory を切る、
などの方法がありますが、**最も簡単で確実だったのは起動引数でした。**

KV260 の SD ブート領域に `uEnv.txt` があります。

```
/run/media/boot-mmcblk1p1/uEnv.txt
```

ここの `bootargs` に **`mem=1536M`** を足します。

```
bootargs=earlycon console=ttyPS1,115200 root=/dev/mmcblk1p2 rw rootwait cma=256M mem=1536M
```

再起動すると：

```
00000000-5fffffff : System RAM     ← Linux はここまでしか使わない
```

| 領域 | 用途 |
|---|---|
| 0x00000000〜0x5FFFFFFF (1.5GB) | Linux |
| **0x60000000〜0x7FEFFFFF (約511MB)** | **誰も使わない。PL 専用** |

**音声に限らず、映像フレームバッファや PL の作業領域としても使える汎用の置き場**が
手に入ります。SD のブート領域は FAT なので、失敗しても SD をパソコンに挿して
`uEnv.txt` を戻せば復旧できます（バックアップは必ず取ってください）。

## 流量制御を PL 内に移す

FIFO が満杯なら DMA を止める必要があります。段5〜10 では **CPU が STATUS を読んで
判断していました**が、段11 では PL 内の配線1本で完結します。

```verilog
wire dma_ready  = !dma_half & !fifo_full;   // FIFO に空きがある時だけ受ける
wire dma_accept = dma_out_valid & dma_ready;
```

この `dma_ready` を `axi_reader` の `out_ready` に繋ぐだけ。**CPU は関与しません。**

1 転送（64bit）は左右2組ぶんなので、2 クロックに分けて FIFO へ入れています。
また `DMA_CTRL` の bit1 を立てると、読み終わりに自動で先頭へ戻る（繰り返し再生）
ようにしました。ここまで来ると、CPU が介入する余地がありません。

## 結果

再生プログラムはこれだけです。

```c
wr(REG_DMA_ADDR, BUF_PHYS);        /* ここから */
wr(REG_DMA_LEN,  fsize);           /* これだけ読め */
wr(REG_DMA_CTRL, 0x3);             /* 開始 + 繰り返し */
/* ここでプログラムは終了する */
```

**プログラムが終了しても音は鳴り続けます。** 300MB・27分の曲を、PL が自分で DDR から
読みながら再生します。

| | 段5〜10 | 段11 |
|---|---|---|
| データ供給 | CPU が 48828回/秒 書き込む | PL が自分で DDR を読む |
| 流量制御 | CPU が STATUS を見て待つ | PL 内の配線1本 |
| 再生中の CPU | 働き続ける | **完全に空く** |

## まとめ

- **KV260 では PCIe は作れない**（K26 SOM に GTH/GTY トランシーバが無い）。
  高速転送をやりたいなら AXI HP + DMA が代替になる。
- AXI4 の読み出しマスタは、AR で要求して R で受けるだけ。**IP を使わず自作できる。**
  テストベンチで先に検証してから実機に載せると切り分けが速い。
- **物理連続メモリは `uEnv.txt` の `mem=` で確保するのが最も簡単。**
  Linux の使用領域を制限して、その上を PL 専用にする。汎用の置き場として使い回せる。
- 流量制御を CPU から PL に移すと、CPU は完全に空く。音楽単体では体感は変わらないが、
  「PL が自律的に動く」構造そのものが目的。

## ソースコード

- `rtl/axi_reader.v` … 自作 AXI4 読み出しマスタ
- `sim/tb_axi_reader.v` … 擬似 AXI スレーブでの単体検証
- `rtl/audio_fx.v` … 音量・イコライザ・歪み・エコー
- `sw/dmaplay.c` … 転送して DMA を起動するだけの再生プログラム

音声データ自体は第三者の録音由来のためリポジトリには含めていません。
`ffmpeg` の変換手順を載せてあるので、各自の音源で再現できます。
