# 万華鏡 FPGA実装プロジェクト

## 最初に必ずやること

1. **`HANDOFF.md` を最後まで読む。** これは作業指示書。読まずに作業を始めない
2. **`ref/target_8point_photo.jpg` と `ref/target_6point_jewel.jpg` を Read ツールで開いて実際に見る。** これが目標映像
3. **`ref/motion.gif` を見る。** 静止画では分からない「動き」が目標の半分を占める
4. **`ref/cell_raw.jpg` を見る。** 万華鏡の折り返しをかける前の原画（Step 4で作るもの）
5. `ref/SCOPE_FS.glsl`（62行）を読む。これが実装の核心

## このプロジェクトは何か

KV260（Kria K26 SOM / Zynq UltraScale+ MPSoC）で、オイル万華鏡の映像を作ってHDMIに出す。
参照実装（WebGL版）が `E:\Dropbox\claude\APP\kaleidoscope\index.html` に既にあり、**それと同じ映像を作るのが目標**。
答えは全部そこにある。ゼロから考える必要は無い。

## 禁止事項

- 目標映像の画像・GIFを見ずに実装を始める
- HANDOFF.md の Step順を飛ばす
- **DE10-Nano用のQuartus/TCL資産（`E:\fpga\de10nano\`, `E:\Quartus\`）を流用しようとする** — Intel系。KV260はXilinx系で完全に別物
- 参照実装 `index.html` を書き換える。答え合わせ用の資産なので触らない
  （取り出しが要るときは `tools/make_ref_dump.py` でコピーを作る）
- KV260は未セットアップの可能性が高い。**勝手に環境構築を始めない。HANDOFF.md の Step 0 でユーザーに確認する**

## 現在の進捗

- [x] Step 0: 環境確認
- [x] Step 1: HDMIにテストパターン（2026-09-18）
- [x] Step 2: 万華鏡の折り返し（★本番）K=16（2026-09-18）
- [x] Step 3: 回転 + 鏡の合わせ目 + AXI（2026-09-19）
- [ ] Step 4: ピースの描画
      - [x] 参照実装から取り出した本物のセル画像を焼き込み・2層合成と影（2026-09-19）
      - [x] シリアルのキー操作 + 画面に操作一覧（2026-09-19）
      - [ ] PL でピース9種を描く ← **次はここ**
            - [x] 命令セットと9種のプログラム（正解と完全一致・2026-09-21）
            - [x] 演算器1レーンの Verilog と検証（2026-09-21）
            - [ ] 並び替え器 `pshade_seq.v`・セルを URAM へ・二重バッファ
- [ ] Step 5: 物理シミュレーション
- [ ] Step 6: 仕上げ

進んだらこのチェックを更新すること。詳しい状態は README.md の「段階」を見る。

---

## このプロジェクトの流儀

- **手書き Verilog + 固定小数点**。HLS は使わない
- **シミュレーションで絵を見てから合成する**。合成は 21〜26 分かかる。
  `bash sim/run_sim.sh` → `python tools/txt2png.py` → PNG を実際に開いて見る
- 数の形式を変えたら、まず `tools/fx_scope.py`（Python の固定小数点モデル）で
  正解画像との差を測る。Verilog はそのモデルを一行ずつ写したもの
- 1画素だけ追いたいときは `python tools/trace_px.py <x> <y>`
- **合成が通っただけの RTL を動くものとして扱わない。** 部品ごとに
  テストベンチを書いて Python と突き合わせてから上に積む

## 実機（毎回電源を入れ直すので省略せずに全部やる）

手順は README.md の「3. 実機」に番号付きで書いてある。

### ★ QSPI ブート競合（この KV260 固有）
この個体は **QSPI にブートイメージが書かれていて、SD を抜いてもフルブートする**
（QSPI 32bit Boot Mode → PMU → BL31 → U-Boot `ZynqMP>`）。
JTAG デバッグ時に次が出ることがある。

```
Failed to detect FSBL exit status using symbol: XFsbl_Exit
Could not find ARM device / AP transaction timeout
```

`Failed to detect FSBL exit` は**警告**。まずシリアルを見ること。
出力が出ていればアプリは動いている。

### Board Initialization の実績（launch.json を実際に調べた結果・2026-09-18）
Vitis Unified IDE 2025.2 の選択肢は **FSBL と TCL の2つだけ**。「None」は無い。

| ワークスペース | 内容 | isFsbl | 結果 |
|---|---|---|---|
| kv_pong2 | 映像 | true (FSBL) | 成功 |
| kv260_chip8 | 映像 | true (FSBL) | 成功 |
| kv_rect1 | 映像 | true (FSBL) | 成功 |
| kv_tetris6 | 映像 | true (FSBL) | 成功 |
| kv_mips22 / 23 | CPU | false (TCL) | 成功 |

**映像系はすべて FSBL で成功している。まず FSBL のままで試す。**
駄目なら TCL に切り替える。いずれも `resetSystem: true` / `programDevice: true`。

### DP の HPD 割り込みを設定すると止まる（2026-09-18 実機）
`kv260_rect/vitis_src/main.c` は RunDP のあとに HPD 割り込み
（`XScuGic` + `Xil_Exception` + `XDPPSU_INTR_EN`）を設定しているが、
**このボードではそこで止まる**。症状:

```
Video stream started          ← ここで止まる
（"Running." が出ない、画面も出ない）
```

動作実績のある `kv260_pong` / `kv260_chip8` は**割り込みを一切設定していない**。
`vitis_src/main.c` はその形に合わせてある。

切り分け方: 同じ環境で `E:\Xilinx\project_vitis\kv_pong2` を開いて Debug すると
Pong が映る。映れば環境は正常で、原因は自分のソフト側。

### ★ Platform を再ビルドしても psu_init は更新されない (2026-09-19)
PS の設定を変えた XSA で Platform を再ビルドしても、次が **古いまま残る**。

| ファイル | 誰が使う |
|---|---|
| `kaleido_plat/zynqmp_fsbl/psu_init.c` | FSBL (Board Init = FSBL) |
| `kaleido_plat/zynqmp_fsbl/zynqmp_fsbl_bsp/hw_artifacts/psu_init.c` | 同上 |
| `kaleido_plat/psu_cortexa53_0/.../bsp/hw_artifacts/psu_init.c` | アプリの BSP |
| `kaleido_app/_ide/psinit/psu_init.tcl` | Board Init = TCL |

正しいものは `kaleido_plat/export/kaleido_plat/hw/psu_init.c` / `.tcl` にある。
上の4箇所へ手でコピーしてから Platform を再ビルドすること。

**症状**: AXI マスタ (M_AXI_HPM0_FPD) を新たに有効にしたのに PS からの
書き込みが届かない。古い psu_init には `FPD_SLCR_AFI_FS` (0xFD615000、
AXI マスタのデータ幅設定) の書き込みが無い。

`tools/check_launch.py` で launch.json が指すファイルの日付を一覧できる。
`_ide/bitstream/` が自動更新されない罠と同じ性質。

## ハマったところ

### 逆数表の索引（2026-09-18）
仮数を [0.5,1) に正規化したあと、**最上位ビットを含めて**索引していた。
表は m = 0.5 + idx/1024 で作ってあるので、索引は最上位ビットの**下** 9 ビット。
間違えると 1/m が 6 ビット精度しか出ず、模様の構造が変わってしまう。
症状: 固定小数点版の模様が浮動小数点版と「似ているが明らかに違う」。

### 掛け算の式幅（2026-09-18・画面が真っ黒になった原因）
```verilog
reg [7:0] r_l;
r_l <= (r8 * gain) >> 8;   // ← 駄目。積が 9bit に切り捨てられてからシフトされる
```
Verilog は右辺の評価幅を「左辺と右辺の被演算子の最大幅」で決める。
上の例では 9bit で積を作ってから `>>8` するので、結果はほぼ 0 になる。
**掛け算は必ず幅を持った wire に受けてから切り出す。**
```verilog
wire [16:0] r_m = r8 * gain;
r_l <= r_m[15:8];
```
症状: 画面が真っ黒（値が 0 か 1 だけ）。scope_pipe 単体（`sim/tb_probe.v`）は
正しく動いていたので、切り分けでトップの配色部だと分かった。

### 部分選択は符号無しになる
`wd - pn[34:17]` は符号無し演算になって化ける。`$signed(pn[34:17])` と書くこと。

### kx が 18bit に入らない（2026-09-19 に再修正）
`slope = sp/focal` の係数 `kx = 2^(15+KX_SH)/(2*720*focal)` が 18bit を超えると
模様が壊れる。**現在は `KX_SH = 11`（`scope_pipe.v`）/ `KX_NUM = 2^26`（`main.c`）**。
`KX_SH = 12` にしていたときは zoom 0.837 以下で崩れるのを実機で確認した。
**この2つは必ず対で変える。** ずれると画角がちょうど2倍狂う。

## パイプライン遅延（変えたら vga_iface の PIXEL_DELAY も直す）

```
scope_pipe : SETUP 4 + K*STAGE 12 + OUT 3    K=16 なら 199
cell_mem   : 2
減光        : 1
2層合成     : 1
周辺減光    : 1
文字        : 1
--------------------------------
TOTAL_LAT  : 205   → vga_iface の PIXEL_DELAY
```

`rtl_top.v` の `TOTAL_LAT` が唯一の基準。周辺減光 `vq` と画面の文字は
自前の段数を持つので、`VQ_DELAY = TOTAL_LAT - 2 - 4`、
`TXT_DELAY = TOTAL_LAT - 4` として色の最終段に合わせている。

## 段が終わったら

コメントを整える → README.md を更新 → `git push`（リポジトリは `E:\fpga\kria260`）。
