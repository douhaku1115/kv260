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
rtl/cell_mem.v          セル画像 256x256 RGB565 (BRAM)
rtl/vga_iface.v         VGA タイミング生成 (miya4649)
rtl/shift_register.v    遅延線
rtl/cdc_synchronizer.v  クロック載せ替え
rtl/recip_lut.hex       逆数表 (divq.v)          ┐
rtl/loss_lut.hex        反射回数ぶんの減光        │ tools/gen_hex.py が生成
rtl/seam_lut.hex        鏡の合わせ目の係数        ┘
rtl/cell_test.hex       テスト用のセル画像 (市松模様)   tools/gen_hex.py
rtl/cell_real.hex       参照実装から取り出した本物      tools/cell_from_dump.py
rtl/cell_init.hex       ★PL が焼き込むのはこれ。上のどちらかをコピーする
rtl/kaleido_axi_slave.v AXI4-Lite スレーブ (0xA0000000、0x10 刻み)

vitis_src/main.c        ベアメタル。DisplayPort の初期化だけ

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

## 段階

| 段 | 内容 | 状態 |
|---|---|---|
| 1 | 土台の疎通（テストパターンを HDMI に出す） | **実機で確認済み**（2026-09-18。青背景＋白矩形） |
| 2 | 折り返し（K=16、静止セル画像） | **実機で確認済み**（2026-09-18） |
| 3 | 鏡の合わせ目 | **実機で確認済み**（段4 に同梱、2026-09-19） |
| 4 | AXI でパラメータを渡して回す | **実機で確認済み**（2026-09-19）|
| 5 | セル画像を PL で描く（ピース） | |
| 6 | 物理演算を PS で回す | |
| 7 | 操作（UART / 視線の傾き） | |
