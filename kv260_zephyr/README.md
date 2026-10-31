# KV260 の R5 コアで Zephyr を動かす

Zephyr 公式のボード `kv260_r5`（Cortex-R5F の 1 コア目）を、PC から JTAG (xsdb) で直接起動する。
Linux も SD カードも使わない。Zephyr はアプリと一体の `zephyr.elf` になり、起動のたびに DDR/TCM へ流し込む。

確認済み (2026-10-19, Zephyr v4.5.0-rc2):
- `samples/hello_world` → COM14 に `Hello World! kv260_r5/zynqmp_rpu`
- `samples/subsys/shell/shell_module` → `kernel version` / `kernel uptime` / `kernel thread list` / `demo ping`→`pong` が応答

## ファイル
| ファイル | 役割 |
|---|---|
| `setup_env.sh` | WSL にビルド環境を作る (sudo 不要。venv + west + 取得を絞った Zephyr) |
| `build.sh` | `build.sh <サンプル> <名前> [cmake 引数]` でビルドし `<名前>.elf` をここへコピー |
| `run_zephyr.tcl` | `xsdb run_zephyr.tcl <elf> [ビット] [後設定 tcl]` で (PL を書き) PS を初期化し R5 #0 で起動 |
| `debug_r5.tcl` | 止まったときに DFSR/DFAR と PC を読む |
| `serlog.py` | `python serlog.py COM14 <秒> <出力>` でシリアルを記録 |
| `shell_test.py` | `python shell_test.py COM14 <出力> [コマンド...]` で shell にコマンドを送って応答を記録 |

`psu_init_nousb.tcl` と `*.elf` はリポジトリに入れない (下の手順で作る)。

## 環境 (WSL Ubuntu-24.04)
```
bash /mnt/e/fpga/kria260/kv260_zephyr/setup_env.sh      # ~/zephyrproject (3.0GB, 147 秒)
source ~/zephyrproject/.venv/bin/activate
cd ~/zephyrproject && west sdk install -t arm-zephyr-eabi   # ~/zephyr-sdk-1.0.1 (2.0GB)
```
hal は xilinx と cmsis だけに絞っている。bsim (nrf_hw_models) も外さないと cmake が hal_nordic を要求して止まる。

## psu_init_nousb.tcl を作る
万華鏡の PS 設定をそのまま使う (R5/UART1/TTC0 はどの KV260 設計でも同じ)。
```
python ../kaleidoscope/tools/make_psu_nousb.py ../kaleidoscope/project_1/project_1.gen/sources_1/bd/design_1/ip/design_1_zynq_ultra_ps_e_0_0/psu_init.tcl psu_init_nousb.tcl
```

## 実機での起動
1. KV260 の電源を入れる。Tera Term を開いていたら閉じる (COM14 を pyserial で使うため)
2. 先にシリアルの記録を始める: `python serlog.py COM14 40 ser.txt`
3. `E:/vivado/2025.2/Vitis/bin/xsdb.bat run_zephyr.tcl E:/fpga/kria260/kv260_zephyr/hello.elf`
4. `3. zephyr started` と `Cortex-R5 #0 (Running)` が出れば、COM14 に hello が出る

PL は書かない (PS だけで動く)。

## 公式手順 (FSBL) との違い — ここではまった
公式の `boards/amd/kv260_r5/support/xsdb.cfg` は R5 用 FSBL を先に走らせる。FSBL は電源直後に USB 初期化で
固まるので (../kaleidoscope/README.md の「実機の起動 (xsdb)」参照)、代わりに psu_init を使う。そのため FSBL がしていたことを自分でやる:

1. **lane2 の PLL ロック待ちを飛ばす** — `psu_resetout_init_data` の最後 `mask_poll 0XFD40A3E4` (lane2, USB3/DP 系) が
   タイムアウトする。リセット解除の書き込みはその前に済んでいるので catch して続ける
2. **R5 を分割モードにして RPU のリセットを解く** — 初期状態はロックステップ。Vitis と同じ `enable_split_mode` / `clear_rpu_reset`
3. **VINITHI=0** — `RPU_0_CFG` (0xFF9A0100) の bit2。1 のままだと例外ベクタが 0xFFFF0000 (OCM) になる。Zephyr はベクタを 0x0 に置く
4. **TCM をワード単位で 0 埋め** — TCM は ECC 付きで、未初期化のまま部分書き込みすると ECC エラーでアボートする
   (BSS のゼロ埋めで DFSR=0xC09, DFAR=0x8080)。R5_0 の ATCM 0xFFE00000 / BTCM 0xFFE20000 を各 64KB 埋める
   (FSBL の XFsbl_TcmEccInit と同じ)

## PL を Zephyr から動かす (CNN, 2026-10-31)
[../kv260_cnn](../kv260_cnn) の MNIST 推論回路 (0xA0000000) を R5 から動かした。合成はしていない (既存のビットファイル)。

結果 (COM14): `ID = 0xC4400001 ... AXI 疎通 OK` → 10 枚すべて答えとスコアが期待値と一致、
**1 枚 1991 us**。Linux (A53) から動かしたときの 1.991 ms と同じ (PL 100MHz で 199,088 クロック)。

```
# ビルド (pl_axi.overlay で 0xA0000000 を MPU に入出力領域として登録する。無いとアボート)
bash build.sh /mnt/e/fpga/kria260/kv260_zephyr/apps/cnn cnn -DDTC_OVERLAY_FILE=/mnt/e/fpga/kria260/kv260_zephyr/pl_axi.overlay
# 起動 (PL のビットファイルと PS の後設定を渡す)
xsdb.bat run_zephyr.tcl E:/fpga/kria260/kv260_zephyr/cnn.elf E:/fpga/kria260/kv260_cnn/vivado/cnn_mnist.runs/impl_1/design_1_wrapper.bit E:/fpga/kria260/kv260_zephyr/cnn_ps_fix.tcl
```
shell でたたくだけなら shell_module を同じオーバーレイ付きでビルドし `devmem 0xA0000000` (→ `0xc4400001`)。

| ファイル | 役割 |
|---|---|
| `pl_axi.overlay` | 0xA0000000 から 64KB を MPU の入出力領域に。zynqmp_rpu は MPU の背景領域を使わないので必須 |
| `cnn_ps_fix.tcl` | 万華鏡の psu_init との差分だけ合わせる: HPM0_FPD の幅を 32 ビットに (AFI_FS bit[9:8]=0) |
| `apps/cnn/` | `cnn_test.c` の移植。`gen_cnn_data.py` で `sim/test_*.hex` を `src/cnn_data.h` に埋め込む |

はまった所:
- **CNN の psu_init はそのまま使えない** — Linux から PL だけ載せる前提なので UART1 が設定されていない。
  PS は万華鏡の psu_init で初期化し、違いだけ後から書く
- **PL クロックの値を Linux 手順から写してはいけない** — `devmem 0xFF5E00C0 0x01010A00` (/10) は CNN 設計の
  IOPLL 1000MHz 用。万華鏡の psu_init は IOPLL 1500MHz なので /10 だと 150MHz になる (CNN は 100MHz 前提、
  WNS 2.28ns で上限 約 130MHz)。一度これをやり、1328 us/枚で「合格」と出た。一致したのはたまたま。
  万華鏡の値 (/15 = 100MHz) のまま触らないのが正しい。**時間が Linux 版と合うかで周波数を確かめる**

## Zephyr の部品で CNN を周期的に動かす (apps/cnn_rtos, 2026-10-31)
```
k_timer (割り込み) ──セマフォ──> 推論スレッド (優先 2) ──メッセージキュー──> 集計スレッド (優先 8)
  周期ごとに時刻を記録          PL で 1 枚推論 (PL はミューテックスで守る)     件数・不一致・遅れ
```
shell の自作コマンド `cnn start [ms]` / `stop` / `stats` / `once <番号>` / `watch on|off` で操作する。
ビルドと起動は apps/cnn と同じ (名前を `cnn_rtos` に)。確かめ方:
```
python shell_test.py COM14 out.txt "cnn once 3" "cnn watch on" "cnn start 100" "#sleep 1" "cnn watch off" "#sleep 5" "cnn stats" "cnn start 5" "#sleep 5" "cnn stats" "cnn stop" "kernel thread list"
```
実機の結果:
| 周期 | 推論回数 | 不一致 | 取りこぼし | 遅れ (割り込み→スレッド) |
|---|---|---|---|---|
| 100 ms | 101 | 0 | 0 | 最大 13 us / 平均 12 us |
| 5 ms | 1421 (約 7 秒) | 0 | 0 | 最大 12 us / 平均 12 us |

推論時間はどれも 1991 us。遅れは周期を 20 倍にしても 12〜13 us で揺れない。
スタック使用量は推論スレッド 200/2048、集計スレッド 332/2048 バイト。

## A53 と R5 で分業する (apps/amp_r5 + a53, 2026-10-31)
```
A53 #0 (ベアメタル)                          R5 #0 (Zephyr)
  画像 10 枚を共有メモリ 0x18000000 に置く
  IPI「画像 k を推論して」 ───────────>  受信コールバック → メッセージキュー → 推論スレッド
                                           共有メモリの画像を PL の CNN へ、スコアを共有メモリへ
  ISR をポーリングして返事を待つ <───────  IPI で返事 (答え・推論時間)
  照合して統計を共有メモリへ               shell の `amp stats` で A53 の統計を表示
```
取り決め (番地・メッセージ・共有メモリの構造体) は `amp_shared.h` にまとめ、両方から include する。
A53 は UART を使わない (R5 が使う) し、割り込みも使わない (ポーリング)。

```
# R5 (WSL)
bash build.sh $K/apps/amp_r5 amp_r5 "-DDTC_OVERLAY_FILE=$K/pl_axi.overlay;$K/amp.overlay"
# A53 (Git Bash。万華鏡の Vitis プラットフォームの BSP を使い、gcc を直接呼ぶ)
bash a53/build.sh          # → a53_amp.elf (0x10000000 にリンク)
# 起動 (第 4 引数が A53 の elf)
xsdb.bat run_zephyr.tcl .../amp_r5.elf .../kv260_cnn/.../design_1_wrapper.bit .../cnn_ps_fix.tcl .../a53_amp.elf
python shell_test.py COM14 out.txt "#sleep 4" "amp stats" "#sleep 5" "amp stats"
```
実機の結果: 往復 3788 回で不一致 0・返事なし 0・番号違い 0。往復時間 最小 2318 / 平均 2326 / 最大 4083 us
(推論そのものは 1991 us)。

| ファイル | 役割 |
|---|---|
| `amp_shared.h` | IPI のバッファ番地・メッセージ・共有メモリの構造体 (A53/R5 で並びが同じことを _Static_assert で確認) |
| `amp.overlay` | R5_0 の IPI を有効に、共有メモリ 1MB を MPU にキャッシュなしで登録 |
| `apps/amp_r5/` | R5 側。IPI を受けて推論して返す |
| `a53/` | A53 側 (main.c / 0x10000000 用 lscript.ld / build.sh) |

はまった所:
- **A53 のアプリは既定で DDR 0 番地から**リンクされ、R5 の Zephyr (0〜64MB) と重なる。lscript.ld で 0x10000000 に
- **推論スレッドが PL を空回りで待つと shell が一切応答しない** — A53 が返事を受けるとすぐ次を頼むので、
  優先 2 のスレッドが CPU を独占する。終了待ちを `k_sleep(K_TICKS(1))` にしたら shell が動き、往復は
  約 2.24 ms → 2.33 ms になった
- R5 を xsdb で止めて調べるときは `catch {stop}` / `catch {con}` で必ず再開させる (止めたままにしたら
  共有メモリの往復が止まり、R5 が DMB で動かなくなった)

## 止まったとき
- `xsdb debug_r5.tcl` → CPSR のモードが 0x17 ならアボート。DFSR/DFAR で原因と番地がわかる
- PC は WSL で `arm-zephyr-eabi-addr2line -f -e build_<名前>/zephyr/zephyr.elf <PC>`
- 何も出ないのに `Cannot halt processor core` なら、R5 がロックステップのまま (手順 2 が効いていない)
