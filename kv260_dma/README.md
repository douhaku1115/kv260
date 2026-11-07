# 段15 KV260 の PL の DMA で DDR の帯域を測る

PL に Xilinx の AXI DMA を載せ、PS の HP0 経由で DDR を読み書きして、PL から DDR にどれだけの速さで届くかを実測した。
CPU の memcpy とも比べた。

## 結果

KV260 実機、PL 250MHz・128 ビット（片方向の上限 4.0 GB/s）、各 10 回の平均（2026-11-07）:

| 大きさ | DMA 複写 | DMA 読み捨て | CPU memcpy（参考） |
|---|---|---|---|
| 4 KB | 1.34 GB/s | 2.55 GB/s | 1.79 GB/s |
| 64 KB | 3.50 GB/s | 3.83 GB/s | 4.07 GB/s |
| 1 MB | 3.87 GB/s | 3.94 GB/s | 3.38 GB/s |
| 16 MB | 3.90 GB/s | 3.97 GB/s | 2.08 GB/s |
| **64 MB** | **3.90 GB/s** | **3.97 GB/s** | 1.91 GB/s |

- 大きい転送では上限の 97〜99% が出る。複写は読みと書きが同時に 3.90 GB/s ずつ流れるので、DDR の上では合わせて約 7.8 GB/s になる
- 64MB の複写は全語（16,777,212 語）を突き合わせて不一致 0。転送範囲の外にも書き込みはない
- 小さい転送では、1 回あたり約 1.5 µs の起動の手間（Linux からのレジスタ設定を含む）が見える
- CPU の memcpy は、キャッシュに収まらない大きさになると約 1.9 GB/s まで落ちる。DMA はその約 2 倍

合成〜ビットストリームは 10 分 36 秒（実測）。WNS 0.755 ns、LUT 4,970（4.2%）、BRAM 17、DSP 0。

## 構成

```
PS ──HPM0(AXI4-Lite 32bit)──> axi_ic ─┬─> AXI DMA 設定窓口   0xA0000000
                                       └─> AXI GPIO(mode)     0xA0010000
AXI DMA（SG なし, 128bit, バースト 256, 長さ 26 ビット = 最大 64MB-1）
   M_AXI_MM2S(読む) ─┐
   M_AXI_S2MM(書く) ─┴─> SmartConnect ──> S_AXI_HP0_FPD ──> DDR
   M_AXIS_MM2S ──> axis_route ──> S_AXIS_S2MM
                    mode=0: 複写（0x60000000 → 0x64000000）
                    mode=1: 読み捨て（MM2S を常に受け取って捨てる）
```

使う DDR は Linux の外（uEnv.txt の `mem=1536M` で 0x60000000 以降は空き）。
`/dev/mem` を O_SYNC で開くとキャッシュを通らないので、DMA との食い違いは起きない。

## ファイル

| | 内容 |
|---|---|
| `rtl/axis_route.v` | DMA の読み出しの流れの行き先を切り替える（組み合わせ回路だけ） |
| `create_dma_project.tcl` | Vivado のプロジェクト生成〜ビットストリームまで |
| `sw/dma_bw.c` | 実機（Linux）で測る。64MB の全語突き合わせ＋大きさを振った測定＋memcpy |

## 使い方

### 1. 合成

```
E:\vivado\2025.2\Vivado\bin\vivado.bat -mode batch -source E:/fpga/kria260/kv260_dma/create_dma_project.tcl
```

`vivado/dma_bw.runs/impl_1/design_1_wrapper.bit` ができる。

### 2. 実機（KV260 の電源を入れ直すたびに 1 から全部）

```bash
# ① パソコンから送る
scp -O vivado/dma_bw.runs/impl_1/design_1_wrapper.bit petalinux@192.168.0.8:~/dma_bw.bit
scp -O sw/dma_bw.c petalinux@192.168.0.8:~/

# ② KV260 側
sudo rmdir /sys/kernel/config/device-tree/overlays/cnn 2>/dev/null   # 段14 の DT 差分が残っていれば外す
sudo fpgautil -b ~/dma_bw.bit                  # PL 書き込み
sudo devmem 0xFF5E00C0 32 0x01010400           # PL クロック 250MHz（IOPLL 1000MHz ÷ 4）
sudo devmem 0xFD615000 32 0x00000800           # ★HPM0 を 32 ビット幅にする（下記）
gcc -O2 -o dma_bw dma_bw.c
sudo ./dma_bw
```

## はまったところ

### HPM0 の幅は PS 側のレジスタ AFI_FS でも合わせる

最初は DMA の状態レジスタ（0x04, 0x34）が 0 しか返さず、DMA が動かなかった。
0x00 や 0x30 は読めるのに、0x04 や 0x34 は読めない。つまり 16 バイト境界の番地しか届いていなかった。

原因は PS の AFI_FS（0xFD615000）。KV260 の Linux を起動した直後は 0x00000A00 で、
HPM0・HPM1 とも 128 ビット幅になっている。PL は HPM0 を 32 ビットで作ってあるが、
fpgautil で書き込んでもこのレジスタは書き換わらない。
`sudo devmem 0xFD615000 32 0x00000800` で HPM0 を 32 ビット幅（bit9:8 = 00）にすると正しく動いた。

段11 以来「レジスタは 0x10 刻みに並べないと読めない」としてきたが、本当の原因もこれだとみられる
（段13・14 の CNN ではまだ確かめていない）。
自作の回路なら番地を 0x10 刻みにして逃げられるが、Xilinx の IP は番地を選べないので、この 1 行が必須になる。
