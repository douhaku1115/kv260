# 万華鏡を KV260 の FPGA で動かす

ブラウザで動いている「オイル万華鏡」と同じ映像を、Kria KV260 の PL で毎画素計算して
HDMI に出す。

参照実装（目標の映像そのもの）:

```
E:\Dropbox\claude\APP\kaleidoscope\index.html
```

WebGL2 / 単一 HTML / 1592 行。ブラウザで開くだけで動く。

---

## 何をしているか

万華鏡は「のぞき穴から出た光線を、三角形に並べた3枚の鏡で反射させながら奥へ進め、
セル面（オイルとピースが入った部屋）に届いた位置の色を見る」もの。

鏡は筒の軸と平行なので、光線追跡は**断面の 2D 問題**に落ちる。
これを 1 画素 1 クロックの 16 段パイプラインにして PL に載せた。

```
画素座標 ──> slope = sp/focal ──> p = slope*Z_MIRROR ──┐
                                                        │
      ┌─────────────────────────────────────────────────┘
      v
  [ scope_stage x16 ]   1段 = 3枚の壁との交差判定 + 反射
      │
      v
  c = p / TUBE_R ──> cell_mem (セル画像) ──> 減光 ──> 周辺減光 ──> HDMI
```

### パイプラインを軽くした2つの工夫

**1. 光線を正規化しない**

`p(z) = slope * z` なので、媒介変数に奥行き z をそのまま使える。
参照実装の

```glsl
float sl = length(slope);
vec2 dir = slope / sl;
float remain = sl * (Z_CELL - Z_MIRROR);
```

は、`dir = slope`（正規化しない）、`remain = Z_CELL - Z_MIRROR`（**全画素で同じ定数**）
と完全に等価。平方根も正規化の除算も要らなくなる。

**2. 一番近い壁を選ぶのに除算を使わない**

```
t_w = a_w / dn_w        a_w = wd_w - dot(p, n_w),  dn_w = dot(dir, n_w) > 0
t_i < t_j  ⟺  a_i * dn_j < a_j * dn_i
```

掛け算の大小比較で最小の壁を決め、**選ばれた1枚だけ除算**する。
残り距離との比較（`t < remain ⟺ a < remain * dn`）も同じ手で除算不要。
結果、1段あたり除算は1個。

除算器も IP を使わず、逆数表（512エントリ）+ ニュートン1回で組んだ（`divq.v`）。

---

## 数の形式（固定小数点）

| 量 | 形式 | 幅 | 範囲 / 分解能 |
|---|---|---|---|
| p, dir | Q3.15 | 18bit 符号付き | ±4 / 3.1e-5 cm |
| 法線 n | Q2.16 | 18bit 符号付き | \|n\| = 1 |
| a, wd | Q4.14 | 18bit 符号付き | ±8 |
| dn | Q3.15 | 18bit 符号付き | |
| q, remain | Q6.14 | 20bit 符号なし | 0〜11.9 |

18bit に揃えてあるので、掛け算はすべて DSP48E2 1個に収まる。

浮動小数点の正解（`tools/ref_scope.py`）と比べて **平均誤差 0.32/255、反射回数の不一致 0.14%**。

## 筒の寸法

```
TUBE_R   = 2.25 cm   筒の内側の半径 = セルの半径
Z_MIRROR = 0.3  cm   のぞき穴 → 鏡の手前の端
Z_CELL   = 12.2 cm   のぞき穴 → セル手前層
鏡の外接円 R = 2.05 cm、頂角 180/ポイント数
```

反射回数はポイント数8・傾き0で最大16回（実測、`tools/refl_hist.py`）。
だから K=16 で足りる。平均は 7.5 回。

---

## ファイル

```
vivado.tcl              Vivado プロジェクト生成 → 合成 → XSA まで一括
timings.xdc             画素クロック 74.25MHz (1280x720@60) の宣言
pins.xdc                Pmod のピンコメント (映像には不要)

rtl/rtl_top.v           トップ。折り返し → セル読み → 減光 → HDMI
rtl/scope_pipe.v        前段(視線を作る) + scope_stage x K + 後段(セル添字)
rtl/scope_stage.v       1反射ぶん + 鏡の合わせ目。遅延 12 クロック
rtl/divq.v              q = a/dn。逆数表+ニュートン。遅延 6 クロック
rtl/cell_mem.v          セル画像 256x256 (BRAM)。奥層 RGB565 / 手前層 α付き32bit
rtl/font_rom.v          画面に出す文字の字形 8x16 ASCII
rtl/vga_iface.v         VGA タイミング生成 (miya4649)
rtl/shift_register.v    遅延線
rtl/cdc_synchronizer.v  クロック載せ替え
rtl/recip_lut.hex       逆数表 (divq.v)          ┐
rtl/loss_lut.hex        反射回数ぶんの減光        │ tools/gen_hex.py が生成
rtl/seam_lut.hex        鏡の合わせ目の係数        ┘
rtl/font_rom.hex        8x16 の字形 95文字             tools/gen_font.py
rtl/cell_test.hex       テスト用のセル画像 (市松模様)   tools/gen_hex.py
rtl/cell_real.hex       参照実装から取り出した本物      tools/cell_from_dump.py
rtl/cell_back_init.hex  ★PL が焼き込む奥層             tools/cell_from_dump.py
rtl/cell_front_init.hex ★PL が焼き込む手前層 (α付き)   tools/cell_from_dump.py
rtl/kaleido_axi_slave.v AXI4-Lite スレーブ (0xA0000000、2KB、0x10 刻み)

  ---- 段5c: ピースを PL で描く ----
rtl/pcordic.v           CORDIC。atan2/hypot/sin/cos を 1 台で。DSP をほぼ使わない
rtl/ptrans.v            log2 と exp2 の表だけで pow・exp・√・逆数・smoothstep
rtl/pshade_lane.v       演算器 1 レーン。24 画素を束ねて回し、遅延を隠す
rtl/ppixgen.v           枠の中を走査してレーンごとの座標を作る (行をまたいで詰める)
rtl/pshade_seq.v        並び替え器。初期値 → プログラム → 合成 → セルへ書く
rtl/pdriver.v           焼き込んだピースの表を順に流す (最小版。本番は AXI)
rtl/pprog.hex           9 種のプログラム 315 命令      ┐
rtl/pprog_base.hex      種類 → 開始番地                │ tools/pasm.py が生成
rtl/pprog_len.hex       種類 → 命令数                  │
rtl/pprog_pre.hex       種類 → 毎画素入れるレジスタ    ┘
rtl/log2_lut.hex        log2 の表 2048 点   ┐ tools/gen_pcore_hex.py
rtl/exp2_lut.hex        exp2 の表 2048 点   │
rtl/atan_lut.hex        CORDIC の角度表     ┘
rtl/pparts.hex          焼き込むピース 64 個  ┐ tools/gen_pparts.py
rtl/cell_oil.hex        油の地だけのセル画像  ┘

vitis_src/main.c        ベアメタル。DP 初期化 + 鏡の形の計算 + キー操作 + 画面の文字

tools/ref_scope.py      参照実装を浮動小数点で書き写したもの（正解画像）
tools/fx_scope.py       固定小数点モデル。Verilog はこれを写したもの
tools/refl_hist.py      反射回数の分布（段数 K を決めるため）
tools/trace_px.py       1画素だけ float と固定小数点を並べて追跡
tools/gen_hex.py        .hex を作る
tools/txt2png.py        シミュレーション出力 → PNG
tools/cmp_rtl.py        RTL 出力とモデルを突き合わせる
tools/cmp_webgl.py      RTL 出力と参照実装(WebGL)の出力を突き合わせる
tools/seam_tables.py    鏡の合わせ目の定数と表 (fx_scope.py と gen_hex.py が使う)
tools/refl_sweep.py     反射回数をパラメータ全域で測る (段数 K を決める)
tools/cell_res_test.py  セル解像度をいくつにすべきか測る
tools/two_layer_test.py 2層合成を入れるとどれだけ差が縮まるか測る
tools/make_ref_dump.py  参照実装のコピーに取り出し口を足す (原本は触らない)
tools/dump_server.py    ブラウザから画像とデータを受け取って ref/dump/ に保存
tools/cell_from_dump.py 取り出したセル画像を .hex にする
tools/check_launch.py   Vitis の Debug 構成が指すファイルの日付を一覧

  ---- 段5c の道具 ----
tools/ref_cell.py       参照実装 PART_FS の忠実な移植 (本物と 0.21/255 で一致)
tools/kv_cell.py        KV260 版 (六角柱・棒 1:1:3・大きさの幅)
tools/piece_table.py    9 種の表 (個数・大きさ・sink・cr)
tools/piece_isa.py      命令セットと 9 種のプログラム。正解との差を測る
tools/pasm.py           アセンブラ。プログラム → rtl/pprog*.hex
tools/pasm_check.py     レジスタの使い回しと 64bit への詰め方を検証
tools/gen_pcore_hex.py  log2/exp2/atan の表を作る
tools/gen_pparts.py     焼き込むピースの表と油の地を作る
tools/pshade_sched.py   並び替えをクロック単位で模擬して速さを測る
tools/piece_sheet.py    9 種を並べて 1 枚に。形を目で確かめる
tools/one_piece.py      1 種類を大きく描く
tools/kv_scope.py       KV260 版のセルを折り返して 1280x720 にする
tools/ooc_lane.tcl      演算器 1 レーンだけを単体合成して面積を測る
tools/tb_trans_check.py 表引き単体の検証     ┐
tools/tb_lane_check.py  レーンの検証         │ RTL と Python を突き合わせる
tools/tb_pixgen_check.py 座標生成の検証      │
tools/tb_seq_check.py   並び替え器の検証     ┘
tools/gen_font.py       Windows の Consolas から 8x16 の字形を起こす
tools/run_synth_timed.sh 合成を時刻つきで走らせて実測を残す

ref/dump/               参照実装から取り出した実物 (段5 の正解データ)
  cell_back.png         セルの奥層 1024x1024
  cell_front.png        セルの手前層 (α付き)
  scope_ref.png         そのセルで描いた 1280x720 の出力
  parts.json            ピース266個の全データ (x,y,z,r,rot,type,seed,色)

sim/tb_scope.v          1フレーム回して frame.txt を吐く
sim/tb_probe.v          scope_pipe と cell_mem だけを覗く (切り分け用・数秒)
sim/run_sim.sh          xsim で回す
```

---

## 作り方

### 1. シミュレーションで絵を確かめる

```bash
python tools/gen_hex.py           # 表とテストセル画像を作る
cp rtl/cell_real.hex rtl/cell_init.hex   # 本物のセル画像を使う場合
bash sim/run_sim.sh               # xsim で 1 フレーム回す (約6分)
python tools/cmp_rtl.py           # モデルと突き合わせて PNG を出す
```

`sim/rtl_scope.png` が RTL の出力、`sim/model_cell256.png` がモデルの出力。
差が大きい画素は `sim/diff.png` に赤で出る。

### 2. 合成

```
E:\vivado\2025.2\Vivado\bin\vivado.bat -mode batch -source E:/fpga/kria260/kaleidoscope/vivado.tcl
```

`project_1/design_1_wrapper.xsa` ができる。

### 3. 実機（ベアメタル Vitis）

SD カードは抜いておく。ただしこの KV260 は **QSPI にブートイメージがあるので
SD を抜いてもフルブートする**。それを前提にした手順が下の 8〜11。

1. Vitis Unified IDE を起動、ワークスペース `E:\Xilinx\project_vitis\ws_kv260_kaleido` を新規作成
2. Platform Component を作成し、`project_1/design_1_wrapper.xsa` を指定
3. Application Component `kaleido_app` を作成、Platform に紐付け
4. `vitis_src/main.c` をワークスペースの `src/` に **ファイルコピーで**同期（IDE の Import だけでは元ファイルの変更が反映されない）
5. `UserConfig.cmake` に `"../main.c"` の行が混入していたら削除。`USER_LINK_LIBRARIES` に `m` を追加（DP ドライバが `nearbyint` を使う）
6. Platform → Build、Application → Build
7. KV260 の電源を入れ、USB-UART のシリアル端末（115200）を開く
8. シリアルに `ZynqMP>` の U-Boot プロンプトが出たら、そのまま待つ
   （この個体は QSPI ブートなので SD を抜いてもここまで進む）
9. Debug Configuration は **Board Initialization = FSBL** のままでよい
   （映像系の成功例 pong / chip8 / rect / tetris はすべて FSBL）。
   駄目なら TCL に切り替える
10. Debug 実行 → `main` で停止 → **Resume**
11. HDMI モニタに映像、UART に `KV260 Kaleidoscope Start` が出る

`Failed to detect FSBL exit status using symbol: XFsbl_Exit` は警告。
シリアルに出力が出ていればアプリは動いている。

ワークスペースを再利用すると `_ide/bitstream/` が自動更新されない。
`.bit` を手で置き換えるか、ワークスペースを作り直すこと。

---

## 操作

KV260 にはキーボードもマウスも標準では無い。既につながっている USB-UART を
入力に使う。Tera Term（115200）でキーを打つと設定が変わる。
**JIS 配列で Shift が要るキー（`<` `>` `+` `=`）は使わない。**

| キー | 動き |
|---|---|
| `q` `w` | ポイント数 3〜12 |
| `m` | ミラー 3枚 / 2枚 |
| `a` `s` | 模様の大きさ 50〜250 |
| `z` `x` | 回転の速さ 0〜100 |
| `i` | 操作一覧をモニターに出す / 消す |
| `0` | 初期設定に戻す |
| `h` | 一覧をシリアルに出す |

同じ一覧を HDMI モニタにも出す。画面の下中央 512x256 px の枠に
32桁 x 8行。PS が AXI の 0x400 以降へ ASCII を書き、PL がフォント ROM
（8x16 を 2 倍に拡大）で描く。枠の中は 1/4 に暗くして文字を読みやすくする。

**はまった点**: 文字の点を枠で区切らないと、枠の外でも桁・行の添字が
折り返して同じ一覧が画面いっぱいに並ぶ。枠の暗さと文字の両方を
同じ「枠の中か」で区切ること。

---

## 段階

| 段 | 内容 | 状態 |
|---|---|---|
| 1 | 土台の疎通（テストパターンを HDMI に出す） | **実機で確認済み**（2026-09-18。青背景＋白矩形） |
| 2 | 折り返し（K=16、静止セル画像） | **実機で確認済み**（2026-09-18） |
| 3 | 鏡の合わせ目 | **実機で確認済み**（段4 に同梱、2026-09-19） |
| 4 | AXI でパラメータを渡して回す | **実機で確認済み**（2026-09-19）|
| 5a | 本物のセル画像を焼き込む・2層合成と影 | **実機で確認済み**（2026-09-19） |
| 5b | シリアルのキー操作・画面に操作一覧 | **実機で確認済み**（2026-09-19） |
| 5c | セル画像を PL で描く（ピース9種） | **実機で確認済み**（2026-09-24。最小版） |
| 5d | 詰める・URAM・二重バッファ・AXI でピースを渡す | |
| 6 | 物理演算を PS で回す | |
| 7 | 仕上げ（視線の傾き / 遠くの暗さ / 色テーマ） | |

### 合成にかかる時間（実測）

| 工程 | 所要 |
|---|---|
| rtl_top の合成（他6個の IP と並列） | 4.5 分 |
| 全体の合成 synth_1 | 0.9 分 |
| 配置配線 + ビット生成 impl_1 | 15〜20 分 |
| **合計** | **21〜26 分** |

段5b 時点の消費: LUT 24125 (20.6%)、FF 19983 (8.5%)、BRAM 96.5 (67.0%)、
DSP 611 (49.0%)。タイミング WNS +2.143ns、違反 0 / 51270 エンドポイント。

段5c (最小版) の消費: LUT 82204 (**70.2%**)、FF 53675 (22.9%)、
BRAM 135.5 (**94.1%**)、URAM 0、DSP 751 (60.2%)。
WNS **+0.241ns**、違反 0 / 100259。合成 **44分**。
**BRAM が限界。セル画像を URAM へ移すのが次の必須作業。**

---

## 段5c — ピースを PL で描く

### 考え方: 種類を焼き込まず、マイクロコードで持つ

9 種の形は 6 系統しかない（円 / 正多角形 / ゆらぎ円 / カプセル / 箱 / 差集合）。
部品も CORDIC・sin/cos 表・exp 表・log2/exp2 表・逆数・積和 の 6 つで足りる。
そこで **演算器 1 組 + 種類ごとのプログラム** にした。
**種類を足すのは `rtl/pprog.hex` を書き替えるだけで、再合成が要らない。**
`type` は 4bit なので 16 種まで入る（いま 9 種、7 つ空き）。

### 効いた決め事: プログラムは色を扱わない

プログラムが出すのは 3 つだけ。

```
A = 不透明度   K = 粒の色に掛ける係数   W = 白を足す量
最終色 = (粒の色 * K + W) * 奥行きの暗さ
```

9 種すべてがこの形に収まったので、RGB 3 本ぶんの演算がプログラムから消え、
最後に 1 回で済む。

### レーンとは

**算術回路ひと揃い。1 レーンが 1 画素を受け持つ。** 8 レーンが同じ命令を
同時に実行するので、命令メモリも解読回路も 1 組で足りる。
1 レーンは 24 画素を順に回して CORDIC の 21 クロックの遅延を埋める。
8 レーン x 24 画素 = 192 画素が常に処理の途中にある。

### 種類ごとの命令数 (実測)

| 種類 | 命令 | CORDIC | 表 | 種類 | 命令 | CORDIC | 表 |
|---|---|---|---|---|---|---|---|
| 天然石 | 63 | 7 | 3 | ビーズ | 30 | 1 | 3 |
| ラメ | 50 | 4 | 6 | 棒 | 25 | 1 | 2 |
| 色ガラス | 40 | 2 | 2 | 気泡 | 20 | 2 | 3 |
| 六角柱 | 38 | 1 | 4 | 三日月 | 18 | 2 | 1 |
| 丸い塊 | 31 | 4 | 2 | | | | |

毎画素の初期値は種類ごとに 2〜4 個（`qx qy vqx vqy` のうち使うものだけ）。
`seed` `e` `rot` `time` はピースごとに一定なのでレーンの定数バンクに置く。
`z` はどのプログラムも読まない。

### 速さ (クロック単位の模擬。`tools/pshade_sched.py`)

| レーン | 既定 271 個 | 上限 625 個 |
|---|---|---|
| 8 | 0.51 本 → **60Hz** | 1.81 本 → **30Hz** |
| 12 | 0.35 本 → 60Hz | 1.21 本 → 30Hz |
| 16 | 0.26 本 → 60Hz | 0.92 本 → 60Hz |

12 レーンにしても上限は 30Hz のままで無駄。**8 レーンに決めた。**

**枠にピースを詰めるかどうかが効く。** ラメは 1 個 112 画素しかなく、
枠は 192 画素あるので、詰めないと 3 割捨てる（無駄 8〜12% → 0.2%）。
4 個混ぜられれば十分で、それ以上は効かない。

### 検証

すべて Python の正解と突き合わせてある。

| 何を | 結果 |
|---|---|
| 参照実装の移植 (`ref_cell.py`) | 本物と **0.21/255** |
| 9 種のプログラム (`piece_isa.py`) | 正解と **0.00000** |
| アセンブラ (`pasm.py`) | 丸めなしで **0.00000** |
| 演算器 1 レーン (`tb_lane_check.py`) | 9 種 **0.02〜0.07/255** |
| 座標生成 (`tb_pixgen_check.py`) | 4 通りの枠で一致 |
| 並び替え器 (`tb_seq_check.py`) | 9 種 **0.02〜0.07/255** |

最大の差はどれも 8〜9.3/255 で、RGB565 の青 5bit (8.2 階調) とほぼ一致する。

### 最小版で割り切ったところ（次で直す）

- ピースは焼き込み（`rtl/pparts.hex`）。AXI も物理演算も無く、起動後に 1 回描いて止まる
- 枠にピースを詰めない
- 下の色を読まずに上書き（BRAM の口は 1 クロックに読みか書きのどちらかだけ）
- 二重バッファ無し
