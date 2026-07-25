# kv260_i2s2 — Pmod I2S2 で I2S 送受信（段1〜段8）

KV260 の PL で I2S 送受信を組み、Pmod I2S2（CS5343 ADC / CS4344 DAC）で音を扱う。
- **段1**: PL 生成のサイン波を I2S 送信し、DAC からイヤホンで鳴らす（`i2s_tx.v` / `i2s2_tone`）
- **段2**: ADC 入力を PL でデジタル増幅して DAC へ戻すループバック（`i2s_loop.v` / `i2s2_loop`）
- **段3**: 位相アキュムレータでメロディ（きらきら星）を鳴らす（`i2s_melody.v`）
- **段4**: 内蔵メモリに焼いた録音を再生（`i2s_player.v`、上限6秒前後）
- **段5**: PS→PL AXI ストリーミングで曲まるごと再生（`i2s_stream_axi.v` / `audio_fifo.v`、早送り対応）
- **段6**: ステレオ化（FIFO32ビットで左右をまとめて流す）
- **段7**: PL でのリアルタイム音声加工（音量・エコー、`audio_fx.v`）
- **段8**: 再生中の音を FFT してパソコンにリアルタイムスペクトル表示（`spectrum_view.py`）

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

## 段3: メロディ再生（きらきら星）

固定トーンの NCO を拡張し、音階を切り替えてメロディを鳴らす（`i2s_melody.v` / `i2s2_melody`）。

### 固定トーンからの変更点

| | 段1（固定トーン） | 段3（メロディ） |
|---|---|---|
| 位相の進め方 | 1フレームごとに +1 | 24ビット位相アキュムレータに音ごとの増分を加算 |
| 周波数 | fs/64 = 762Hz 固定 | 任意（増分で決まる） |

```
PHASE_INC = 周波数 × 2^24 / fs        (fs = 48828.125Hz → 係数 343.597)
```

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

シーケンサは `NOTE_LEN`（12000標本 ≒ 0.25秒）ごとに次の音へ進み、16音でループする。

```bash
vivado -mode batch -source build_melody.tcl
# 生成物: vivado_melody/i2s2_melody.runs/impl_1/design_1_wrapper.bit
```

---

## 段4: 音声ファイル再生

内蔵メモリに焼き込んだ16ビットPCMを毎標本読み出して送出する（`i2s_player.v` / `i2s2_player`）。
合成ではなく、実際の録音をそのまま鳴らす。

```
音源(MP3等) --ffmpeg--> 生PCM --raw2hex.py--> audio_rom.hex --$readmemh--> 内蔵メモリ
```

音声データの作り方は [`audio/README.md`](audio/README.md) を参照。
音声データ自体は第三者の録音由来のためリポジトリには含めていない。

```bash
vivado -mode batch -source build_player.tcl
# 生成物: vivado_player/i2s2_player.runs/impl_1/design_1_wrapper.bit
```

### 容量

4秒（195312標本）で 3.12Mbit。内蔵メモリ 5.1Mbit の 61%。上限は6秒前後。

---

## 段5: 長時間再生（PS→PL AXI ストリーミング）

段4 は内蔵メモリに焼くため数秒が上限だった。段5 では PS(Linux) が音声標本を
AXI4-Lite 経由で PL の FIFO に流し込み、PL が 1 標本ずつ取り出して送出する。
内蔵メモリの容量制限が無くなり、**28分の曲でもそのまま鳴らせる**（`i2s_stream_axi.v` / `audio_fifo.v`）。

```
PS(Linux) ─M_AXI_HPM0_FPD─> AXI Interconnect ─AXI4-Lite─> i2s_stream_axi
   play song.raw                                            ├ FIFO(8192段)に積む
   (満杯を見て流量制御)                                       └ I2S 送信 ─SDIN→ DAC
```

### レジスタマップ（ベース 0xA000_0000）

| オフセット | 種別 | 内容 |
|------|------|------|
| 0x00 | W  | DATA   標本を1つ書き込む（下位16ビット） |
| 0x10 | R  | STATUS bit0:満杯 bit1:空 bit29..16:溜まっている数 |
| 0x20 | RW | CTRL   bit0:再生有効 |

**レジスタは 0x10 刻みに整列させる。** 0x10 境界に整列していないアドレスは
devmem/mmap の読み出しが 0 を返す（Zynq US+ の既知の挙動）。
0x04/0x08 に置いた STATUS/CTRL が常に 0 で読めず、原因究明に時間を要した。
動作確認用に 0x00 の読み出しで `0xDEADBEEF` を返すようにし、整列アドレスなら
正しく読めることを実機で確認して切り分けた。

### 使い方

```bash
# 音源(28分でも可)を生PCMに変換
ffmpeg -i 曲.mp3 -ac 1 -ar 48828 -f s16le -acodec pcm_s16le song.raw

# ビルド（生成物: vivado_stream/i2s2_stream.runs/impl_1/design_1_wrapper.bit）
vivado -mode batch -source build_stream.tcl

# KV260 側: 書き込み → クロック有効化 → 再生プログラムをコンパイルして実行
sudo fpgautil -b ~/stream.bit
sudo devmem 0xFF5E00C0 32 0x01010A00
gcc -O2 -o play play.c
sudo ./play song.raw
```

再生プログラム `sw/play.c` は STATUS の満杯ビットを見て流量を調整するので、
早送りにならず正しい速さで鳴る。再生中のキー操作：

- **f** … 10秒送り　**b** … 10秒戻し　**q** … 終了

---

## 段6: ステレオ化

段5 は左右同じ音（単音）だった。段6 では FIFO を32ビット幅にして1段に左右を
まとめて置き（`[31:16]=左, [15:0]=右`）、I2S 送出で LRCK の前半/後半に左右を振り分ける。

```bash
# 音源をステレオ(2ch)で変換する。以降は段5と同じ手順
ffmpeg -i 曲.mp3 -ac 2 -ar 48828 -f s16le -acodec pcm_s16le song.raw
```

`play.c` は左右2標本を `[31:16]=左, [15:0]=右` に詰めて1回で DATA に書く。
左右同じ値を書けばモノラルとしても使える。

---

## 段7: PL でのリアルタイム音声加工（音量・エコー）

FIFO と I2S 送出の間に信号処理モジュール `audio_fx.v` を挟み、PS から
`devmem` でリアルタイムに効き具合を変えられる。

```
FIFO → [音量 ×GAIN] → [+ エコー(遅延0.25秒×ECHO)] → 16bit飽和 → I2S
                              ↑___ BRAMディレイライン ___|
```

レジスタ追加（0x10刻みを維持）:

| オフセット | 種別 | 内容 |
|------|------|------|
| 0x30 | RW | GAIN 音量（64で等倍） |
| 0x40 | RW | ECHO エコー量（0=無効。大きいほど残響が長い） |

- **音量**: `in * GAIN >> 6`。左右それぞれに乗算
- **エコー**: BRAM ディレイライン（約0.25秒）から遅延音を読み、フィードバックで混ぜる（リバーブ風）

```bash
# 再生中に別端末（または止めてから）devmem で効かせる
sudo devmem 0xA0000040 32 0x80   # エコーを入れる
sudo devmem 0xA0000030 32 0x20   # 音量を半分に
```

---

## 段8: リアルタイムスペクトル表示

再生中の音を FFT して周波数成分をパソコンにグラフ表示する。

```
KV260(play.c)                          パソコン(spectrum_view.py)
  左chを8192点FFT ─ UDP:50007 ─> 1680ビン(0〜10kHz) ─> matplotlibで表示(dB軸)
```

- FFT は PS 側（`play.c`）で計算（反復 radix-2、8192点、分解能 ≒ 6Hz）
- 低域 1680 ビン（0〜約10kHz）の振幅を UDP でパソコンへ送る
- パソコンの `sw/spectrum_view.py`（matplotlib）が dB軸・塗りつぶし・ピークホールド・時間平滑化で描画

```bash
# パソコン側（matplotlib が必要）
pip install matplotlib numpy
python sw/spectrum_view.py

# KV260 側（第2引数にパソコンのIP。echo $SSH_CLIENT 等で確認）
sudo ./play song.raw <パソコンのIP>
```

FFT を PL に載せれば KV260 単体で完結できる（今後の課題）。

---

## ★書き込みは fpgautil を使う（重要）

**Vivado の JTAG 書き込みでは PL クロックが供給されず、無音になる。**
JTAG は PL のみを書き換え、PS 側の設定（クロック出力）を変更しないため。

```bash
# パソコン側（末尾の :~/ を忘れない。無いとローカルコピーになる）
scp -O <bitファイル> petalinux@<KV260のIP>:~/player.bit

# KV260 側
sudo fpgautil -b ~/player.bit              # ← JTAG ではなくこれ
sudo devmem 0xFF5E00C0 32 0x01010A00       # PLクロック有効化
```

止めるときは PL クロックを切る:

```bash
sudo devmem 0xFF5E00C0 32 0x00010A00
```

---

## 環境

- ボード: Kria KV260 (xck26-sfvc784-2LV-c)
- ツール: Vivado 2025.1 / 2025.2
- Pmod: Digilent Pmod I2S2 (CS5343 ADC / CS4344 DAC)
- OS: PetaLinux（ユーザー名 `petalinux`）
