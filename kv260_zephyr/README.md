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
| `build.sh` | `build.sh <サンプル> <名前>` でビルドし `<名前>.elf` をここへコピー |
| `run_zephyr.tcl` | `xsdb run_zephyr.tcl <elf>` で PS を初期化し R5 #0 で起動 |
| `debug_r5.tcl` | 止まったときに DFSR/DFAR と PC を読む |
| `serlog.py` | `python serlog.py COM14 <秒> <出力>` でシリアルを記録 |
| `shell_test.py` | shell にコマンドを送って応答を記録 |

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

## 止まったとき
- `xsdb debug_r5.tcl` → CPSR のモードが 0x17 ならアボート。DFSR/DFAR で原因と番地がわかる
- PC は WSL で `arm-zephyr-eabi-addr2line -f -e build_<名前>/zephyr/zephyr.elf <PC>`
- 何も出ないのに `Cannot halt processor core` なら、R5 がロックステップのまま (手順 2 が効いていない)
