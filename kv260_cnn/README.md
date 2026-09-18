# 段13 KV260 の PL に自作 CNN（MNIST 手書き数字認識）

FPGA（KV260 の PL）に畳み込みニューラルネットを自分で書いて載せ、手書き数字を認識させる。
学習は PyTorch、推論は全部 Verilog。**実機の答えが Python の量子化版と 1 ビットも違わないこと**を合格条件にした。

## 結果

| | 正解率 | 速度 |
|---|---|---|
| 浮動小数点（PyTorch） | 97.70% | — |
| 8ビット整数（Python） | 97.10% | — |
| **RTL シミュレーション** | 完全一致 | 199,088 クロック/枚 |
| **KV260 実機** | **完全一致** | **1.991 ms/枚（毎秒 502 枚）** |

資源は LUT 2,220（KV260 の約 2%）、DSP **0 個**、BRAM 4 個。タイミング余裕 WNS = 2.280 ns。

## ネットワーク

```
入力 28x28x1
 → conv1 3x3 1ch→8ch  + ReLU → 26x26x8
 → maxpool 2x2               → 13x13x8
 → conv2 3x3 8ch→16ch + ReLU → 11x11x16
 → maxpool 2x2               → 5x5x16
 → 全結合 400→10 → argmax
```

## 量子化

重み int8 / 特徴マップ uint8 / 積和 int32。スケール合わせは右シフトだけなので掛け算器が要らない。

```
acc = バイアス + Σ(重み × 入力)
y   = clip(acc >>> SHIFT, 0, 255)      ← ReLU と 8ビット飽和を同時に行う
```

シフト量は `rtl/cnn_param.vh` に自動生成される（`CONV1_SHIFT=9  CONV2_SHIFT=10  FC_SHIFT=0`）。

**全結合層のシフトが 0 なのは偶然ではない。** 最終層で欲しいのは 10 個のスコアの大小関係だけで、
絶対値に意味がない。無理にスケールを合わせると（最大値が 1 になるよう 18 ビット右シフトすると）
スコアが全部 0 に潰れて壊れる。おかげで RTL 側もシフト回路が不要になっている。

## ファイル

| | 内容 |
|---|---|
| `train/train_mnist.py` | 学習 → 量子化 → 係数と期待値の書き出し |
| `rtl/conv3x3.v` | 3x3 畳み込み + ReLU + 飽和。conv1/conv2 兼用 |
| `rtl/maxpool2.v` | 2x2 最大値プーリング。pool1/pool2 兼用 |
| `rtl/fc.v` | 全結合 400→10 + argmax |
| `rtl/cnn_core.v` | 全体の状態機械。バッファ 2 枚を交互に使う |
| `rtl/cnn_axi.v` | AXI4-Lite の窓口（0xA0000000） |
| `sim/tb_*.v` | 層ごと＋通し＋AXI 越しの検証 |
| `sw/cnn_test.c` | 実機（Linux）から動かして期待値と突き合わせる |
| `create_cnn_project.tcl` | Vivado プロジェクト生成〜ビットストリームまで |

Vivado のプロジェクトと MNIST 本体は容量が大きいので git に入れていない。どちらも再生成できる。

## 使い方

### 1. 学習と係数の生成

```
cd train
python train_mnist.py data      # MNIST を取得
python train_mnist.py train     # 学習（CPU で数分）
python train_mnist.py quant     # 量子化して rtl/*.hex と sim/test_*.hex を書き出す
```

### 2. シミュレーション

```
bash sim/run_sim.sh all         # conv1 / pool1 / conv2 / fc / 通し / AXI
```

層ごとに Python の中間値と 1 バイトずつ突き合わせる。1 バイトでも違えば失敗。

### 3. 合成

```
E:\vivado\2025.2\Vivado\bin\vivado.bat -mode batch -source E:/fpga/kria260/kv260_cnn/create_cnn_project.tcl
```

`vivado/cnn_mnist.runs/impl_1/design_1_wrapper.bit` ができる。

### 4. 実機（KV260 の電源を入れ直すたびに 1 から全部）

```bash
# ① パソコンから送る（IP は ip addr で確認）
scp -O vivado\cnn_mnist.runs\impl_1\design_1_wrapper.bit petalinux@192.168.0.8:~/
scp -O sw\cnn_test.c petalinux@192.168.0.8:~/
scp -O sim\test_images.hex sim\test_scores.hex petalinux@192.168.0.8:~/

# ② KV260 側
sudo fpgautil -b ~/design_1_wrapper.bit        # PL 書き込み（JTAG では PS-PL が初期化されない）
sudo devmem 0xFF5E00C0 32 0x01010A00           # PL クロック有効化
gcc -O2 -o cnn_test cnn_test.c
sudo ./cnn_test test_images.hex test_scores.hex
```

## レジスタ（0x10 刻み、base 0xA0000000）

| 番地 | 向き | 内容 |
|---|---|---|
| 0x00 | R | ID。`0xC4400001` が返れば AXI 疎通 OK |
| 0x10 | R | STATUS: bit0=計算中, bit1=終了, [19:8]=画素ポインタ |
| 0x20 | W | CTRL: bit0=開始, bit1=ポインタを0に戻す, bit2=終了フラグを消す |
| 0x30 | W | 画素を1つ書く（書くたびにポインタが進む） |
| 0x40 | R | 答え（0〜9） |
| 0x50 | W | 読み出すスコアの番号 |
| 0x60 | R | スコア（int32） |

**0x10 刻みに整列させるのは必須。** ZynqMP の HPM を 32 ビット幅で使うと、
整列していない番地は devmem/mmap の読み出しが必ず 0 を返す（段11 で半日溶かした）。

## はまったところ

### 1. 量子化で正解率が 97.7% → 11.7% に落ちた

原因は 3 つあった。層ごとに切り分けて特定した（全float → conv1だけ整数 → conv2まで → 全部）。

1. 活性化のスケールを測るとき入力を 255 倍して流していた。`CONV1_SHIFT` が 8 ビット過大になり、
   特徴マップがほぼ全部 0 に潰れた
2. 次の層のシフト計算に「2の冪に丸める前のスケール」を使っていた。誤差が層ごとに積み上がる
3. 最終層の出力スケールを「最大値が 1 になる値」にしていた。これが決定打で、
   `FC_SHIFT=18` になりスコアが全部 0 に潰れた

量子化の誤りは例外を出さず、精度だけを静かに壊す。段階的に測るしかない。

### 2. テストベンチで最後の 1 語だけ不一致になった

`done` と最後の書き込みが同じクロックで立つため、ノンブロッキング代入が反映される前に
比較していた。値がたまたま 0 だと他の画像では一致してしまい、「1 枚目だけ失敗」という
紛らわしい出方をする。`done` を待った後に数クロック余分に待つ。

### 3. `.gitignore` の行末コメント

`kv260_cnn/vivado/   # コメント` と書くとパターンとして解釈されず効かない。
コメントは独立した行に書く。
