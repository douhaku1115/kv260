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
- [x] Step 4: ピースの描画（最小版まで完成。詰めと二重バッファが残り）
      - [x] 参照実装から取り出した本物のセル画像を焼き込み・2層合成と影（2026-09-19）
      - [x] シリアルのキー操作 + 画面に操作一覧（2026-09-19）
      - [x] PL でピース9種を描く
            - [x] 命令セットと9種のプログラム（正解と完全一致・2026-09-21）
            - [x] 演算器1レーンの Verilog と検証（2026-09-21）
            - [x] 並び替え器 `pshade_seq.v`（2026-09-24 実機で確認）
            - [x] セル画像を URAM へ（2026-10-09 実機。BRAM 94.1% → 28.8%）
                  ★ URAM は初期値を持てず語まるごとしか書けない。
                    中身は起動時に PS が AXI で流し込む。README の段5d-1 を読む
            - [x] 枠にピースを 4 個まで詰める（2026-10-09 実機。上限 20Hz → 30Hz）
                  ★ ここで段5c からの潜在バグ 3 つを見つけた。下の「ハマったところ」を読む
            - [x] 下の色を読んで α で重ねる（2026-10-09 実機）
                  ★ URAM は 1 拍に読みか書きのどちらかだけ。合成は 192 画素を
                    連続して書くので、**S_EXEC 中に先読みしてレジスタに溜める**。
                    2 拍に 1 画素にすると上限が 30Hz → 20Hz に落ちる。
                  ★ cell_uram の口B の読み出し遅延は **2 拍**（b_q0 → b_q1）。
                    並び替え器もテストベンチも 1 拍の前提だったので直した。
                  ★ 効き目は目では分からない（上書きとの差が平均 1.219/255。
                    油の地が暗いため）。`tools/blend_effect.py` で測れる。
            - [x] 合成を 2 段に分割してタイミングを戻す（2026-10-10 実機）
                  ★ WNS +0.045ns → **+2.410ns**（54 倍）。LUT +1000 だけ。
                    最悪パスがピース描画から折り返し (scope_i/stage[14]) へ移り、
                    論理段数 32 → 12 になった。もう最悪パスではない
                  ★ 当初「cBG に 1 段入れれば済む」と見立てたが外れ。
                    **最悪パスを実測してから直すこと**（下の「ハマったところ」）
            - [ ] 手前層も PL で描く・二重バッファ・AXI でピースを渡す ← **次はここ**
                  WNS +2.410ns と余裕があるので足せる
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

### 関数の中から外の信号を参照すると感度リストに入らない（2026-10-09）
```verilog
function signed [W-1:0] pick;
  input [RBITS-1:0] n;  input signed [W-1:0] rf;
  begin case (n) 5'd4: pick = pcs_r; ... endcase end   // ← 外の pcs_r を直参照
endfunction
wire signed [W-1:0] va = pick(ra_r, va_r);             // ← 駄目
```
`assign` の感度は**右辺の式に現れる信号だけ**。関数の中で参照している
`pcs_r` が変わっても `va` が作り直されない。**定数は必ず引数で渡す。**

段5c までは `pc_seed` が全スロットで同じだったので露出しなかった。
段5d-2 で枠に 4 個詰めてスロットごとに変わるようにして、2 個目以降の
ピースだけ形が崩れた。見つけ方は「`ra_r=4`（r4 を読む）かつ `pcs_r` は
正しい値、なのに `va` が 1 つ前のピースの値」という**矛盾**をダンプで見る。

### clamp の前に幅を狭めるとあふれる（2026-10-09・`ptrans.v` の SSTEP）
```verilog
wire signed [2*W-1:0] tprod = num6 * e2r;
wire signed [W-1:0]   traw  = tprod >>> FRAC;   // ← 駄目。ここであふれる
wire signed [W-1:0]   tclp  = (traw < 0) ? 0 : (traw > 1.0) ? 1.0 : traw;
```
smoothstep は結果を 0〜1 に丸めるので途中の `t` は 1.0 を大きく超えてよい
設計。ところが S6.17 の上限は 64 しかない。棒 (rod) は `1/(0.8*e)` で、
z が 1 に近い（e が小さい）と 38.5 になり、枠の隅の `d`≈2.3 との積が
**89 になってあふれ、符号が反転して clamp が 0 を返す**。
症状: **透明であるべき枠の隅が不透明な色で塗られる**。
z が 0.65 以下なら 56 で収まるので**奥のピースだけ壊れて見える**。
**シフトした後の値も幅を持った wire に受けてから丸める。**

### プログラムの中間値が S6.17 をあふれる（2026-10-09・ラメ）
```
MULI   ph, rot, 4           ph = rot*4       0〜25.1
MADDC  ph, seed, 60, ph     ph += seed*60    → 最大 85.1  ★ ±64 を超える
```
`rot` は 0〜2π、`seed` は 0〜1 なので合計が最大 85 になり、符号が反転する。
**既定の構成でラメの 14.6%（220 個中 32 個）が壊れていた。実機でも起きていた。**
直し方: `seed*60`（最大 60 でぎりぎり入る）を先に 2π で折り返してから
`rot*4` を足す。最大 31.4 に収まる（3 命令増、全体のクロックは +0.74%）。

**なぜ見逃したか**: `tools/piece_isa.py` の `check()` は
**seed=0.37 / rot=0.9 / z=0.7 の 1 点しか試していなかった**。
それでも「9 種すべて 0.00000 で一致」と出るので安心してしまう。

**プログラムをいじったら必ず `python tools/piece_isa.py` を走らせる。**
最後に `check_range()` が seed 0〜1・rot 0〜2π・z 0〜1 を振って、
命令ごとの結果の絶対値の最大と ±64 超えを出す。
いまの余裕: 天然石 52.5、ラメ 60.0（どちらも少ない）。

### 合成ログの警告より最悪パスを実測する（2026-10-10）
段5d-3 で WNS が +0.045ns しか残らず、合成ログの

```
RAM Pipeline Warning: Read Address Register Found For RAM cBG_reg.
```

を見て「`cBG` に 1 段入れれば済む」と考えた。**外れだった。**
最悪パスを実測したら

```
bi_d2 → cell_wdata   遅延 13.142ns   論理段数 32 (DSP 15 + CARRY8 6)
```

で、`cBG` だけでなく **`cA` `cK` `cW` `cAD` `cPS` `pb_*` すべての読み出しから
掛け算 3 段までが 1 拍に詰まっていた**。`cBG` に 1 段入れても他が残る。

直し方: 「粒の色 x K + W」でレジスタに受けて 2 段に分けた。
結果 **+0.045ns → +2.410ns**（54 倍）、LUT +1000、合成は 11 分短縮。

**最悪パスの出し方**:
```
grep -A 40 "Max Delay Paths" <impl>/design_1_wrapper_timing_summary_routed.rpt   | grep -E "Slack|Source:|Destination:|Data Path Delay|Logic Levels"
```

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
セル読み    : 2   (段5d-1 で cell_mem → cell_uram。段数は同じ)
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
