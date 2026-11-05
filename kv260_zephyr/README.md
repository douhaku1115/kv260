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
| `rpmsg.overlay` + `apps/rpmsg_r5` | 段2: Linux と RPMsg で話す R5 側 (TCM 配置) |
| `linux/r5_rpmsg.dtso` / `linux/rpmsg_rtt.py` | 段2: 起動 DT に足す差分 / 往復時間の測定 |
| `linux/uEnv_rpmsg.txt` / `linux/r5_start.sh` / `linux/r5-rpmsg.service` | 段2: 電源投入だけで rpmsg.dtb 起動 + R5 自動起動 |
| `linux/r5_shell.sh` / `linux/r5_term.py` | 段2: R5 の shell に Linux からつなぐ |
| `apps/rpmsg_r5/src/cnn_rpmsg.c` / `linux/cnn_rpmsg.py` | 段2: Linux から RPMsg で PL の CNN 推論を頼む |
| `apps/rpmsg_r5/src/audio_rpmsg.c` / `linux/r5play.py` | 段2: R5 が PL の音声 FIFO を 5ms ごとに満たす (Linux は指示だけ) |
| `linux/linplay.c` / `linux/audio_cmp.sh` | 段2: 比較用。Linux だけで FIFO を満たす場合と R5 の場合を測る |
| `linux/dp_audio.dtso` / `linux/hdmi_audio.sh` | 段6: Linux の HDMI ドライバを起動させる DT の差分 / HDMI の音声入力を PL に切り替える |
| `apps/rpmsg_r5/src/synth.c` / `linux/r5synth.py` / `linux/synth_cmp.sh` | 段2: R5 で音を作る (8 音シンセ + 楽譜演奏) |
| `rpmsg_r5_1.overlay` + `apps/rpmsg_r5_1` / `linux/r5_1_calc.py` / `linux/core_cmp.sh` | 段2: R5_1 (2 コア目) で重い計算。R5_0 の音が乱れないかを測る |

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

## Linux (PetaLinux) から remoteproc で起動する (段1: TCM だけ, 2026-10-31)
SD カードの PetaLinux 2025.1 (カーネル 6.12) を普通に起動したまま、Linux から R5_0 の Zephyr を起動・停止する。
xsdb も JTAG も使わない。**SD カードも U-Boot も変えない** (オーバーレイは起動中に当て、再起動で消える)。

カーネルには remoteproc (`CONFIG_XLNX_R5_REMOTEPROC=y`)・IPI・RPMsg が入っているが、デバイスツリーに
R5 のノードが無い。`linux/r5_rproc.dtso` で足す (カーネルの binding の分割モードの例そのまま)。

```
# PC → KV260 (petalinux@192.168.0.8。鍵 ~/.ssh/id_ed25519_kv260)
scp -O linux/r5_rproc.dtso hello.elf petalinux@192.168.0.8:~/
# KV260 (起動するたびに overlay から)
dtc -I dts -O dtb -o r5_rproc.dtbo r5_rproc.dtso
sudo mkdir /sys/kernel/config/device-tree/overlays/r5
sudo sh -c 'cat r5_rproc.dtbo > /sys/kernel/config/device-tree/overlays/r5/dtbo'
sudo cp hello.elf /lib/firmware/zephyr_hello.elf
R=/sys/class/remoteproc/remoteproc1          # ffe00000.r5f = R5_0 (remoteproc0 は R5_1)
echo zephyr_hello.elf | sudo tee $R/firmware
echo start | sudo tee $R/state               # → Hello World! kv260_r5/zynqmp_rpu が UART1 (COM14) に
echo stop  | sudo tee $R/state
```
結果: `remote processor ffe00000.r5f is now up` → COM14 に Hello World が出た → `stop` で offline。

制約と理由:
- **DDR のメモリ予約 (memory-region) を入れていない** — 予約は起動時にしか効かず、起動後のオーバーレイで足すと
  ドライバが見つけられない。なので Zephyr は **ATCM (64KB) に収まるもの**だけ (hello は 37KB)。0 番地リンクの
  xsdb 用 elf がそのまま使える。ドライバが起動前に TCM を 0 埋めするので ECC の問題も出ない
- `failed to get memory region dev node` は予約が無いため。`no resource table found` も想定どおり (RPMsg なし)
- UART1 は Linux のコンソール (ttyPS1) と共用。Zephyr の出力は Linux のコンソールに混ざる
- sudo をパスワードなしにした: `/etc/sudoers.d/zz-nopw` (`petalinux ALL=(ALL) NOPASSWD: ALL`)。
  sudoers.d は名前順に読まれ後が勝つので、`99-petalinux` / `dou` より後ろの名前にする必要があった。
  戻すときは `sudo rm /etc/sudoers.d/zz-nopw`

## Linux と R5 の Zephyr が RPMsg で話す (段2, apps/rpmsg_r5, 2026-10-31)
Linux の `/dev/rpmsg0` に書いた文字列を、R5 の Zephyr が `"R5: "` を付けて送り返す。
2000 往復で不一致 0。往復 (Python から 1000 回、中央値) は 32 バイトで 357us、400 バイトで 786us。
**★この数字は R5 が 16.7MHz で動いていたときのもの** (下の「R5 のクロックが止められていた」)。
直した後は 32 バイトで **61us**。

```
Linux (A53)                                  R5_0 (Zephyr, apps/rpmsg_r5)
  remoteproc が elf を TCM に書き、
  リソーステーブルに vring の番地を書いて起動
                                             vring を作り「rpmsg-raw」を名乗る
  rpmsg_char が /dev/rpmsg0 を作る     <──  (名前の通知)
  /dev/rpmsg0 に書く  ── vring + IPI ──>     受信コールバック → "R5: " を付けて送り返す
  /dev/rpmsg0 を読む  <── vring + IPI ──
```

段1との違いは 2 つ。

**1. メモリ予約を起動時のデバイスツリーに入れる。** 予約は起動後のオーバーレイでは効かないので、
今の起動 DT に `linux/r5_rpmsg.dtso` (予約 3 つ + IPI のメールボックス + R5 のノード) を重ねた
`rpmsg.dtb` を作り、U-Boot から手で指定して起動する。いまの起動は uEnv.txt の
`fatload Image; booti 0x200000 - ${fdtcontroladdr}` (image.ub は使っていない) なので、dtb の番地だけ差し替えればよい。
**SD の BOOT/uEnv.txt/U-Boot は変えない** (普通に電源を入れれば元の起動)。

| 番地 | 大きさ | 用途 |
|---|---|---|
| 0x3ED00000 | 16KB | vdev0vring0 (Linux → R5) |
| 0x3ED04000 | 16KB | vdev0vring1 (R5 → Linux) |
| 0x3ED40000 | 256KB | vdev0buffer (メッセージ本体、shared-dma-pool) |
| 0xFF990400/420 ⇔ 0xFF990080/0A0 | | IPI: APU(ch0) ⇔ RPU0 (xlnx,ipi-id = 1。段3と同じバッファ) |

**2. Zephyr を TCM に収める。** 公式サンプル `openamp_rsc_table` のままだと 83KB で ATCM (64KB) を超え、
ボード既定の置き場所「DDR 0 番地から」は Linux のメモリと重なる。shell を外して小さくし、
XIP の仕組みでコード 33KB を ATCM (0x0)、変数 7KB を BTCM (0x20000) に分けた (`rpmsg.overlay`)。

```
# ビルド (WSL)
bash build.sh /mnt/e/fpga/kria260/kv260_zephyr/apps/rpmsg_r5 rpmsg_r5 \
     -DDTC_OVERLAY_FILE=/mnt/e/fpga/kria260/kv260_zephyr/rpmsg.overlay
# PC → KV260
scp linux/r5_rpmsg.dtso linux/rpmsg_rtt.py rpmsg_r5.elf petalinux@192.168.0.8:~/
# KV260 (一度だけ。普通に起動した Linux で)
sudo cp /sys/firmware/fdt boot_now.dtb && sudo chown petalinux boot_now.dtb
dtc -@ -I dts -O dtb -o r5_rpmsg.dtbo r5_rpmsg.dtso
fdtoverlay -i boot_now.dtb -o rpmsg.dtb r5_rpmsg.dtbo
sudo cp rpmsg_r5.elf /lib/firmware/
```
起動 (毎回。Tera Term で `sudo reboot` → `Hit any key to stop autoboot` でキーを押し `ZynqMP>` で):
```
mmc list                                   # mmc@ff170000: 1 → SD は 1 番
ext4load mmc 1:2 0x100000 /home/petalinux/rpmsg.dtb
fatload mmc 1:1 0x200000 Image
setenv bootargs earlycon console=ttyPS1,115200 root=/dev/mmcblk1p2 rw rootwait cma=256M mem=1536M
booti 0x200000 - 0x100000
```
Linux が上がったら:
```
sudo modprobe rpmsg_char
R=/sys/class/remoteproc/remoteproc1          # ffe00000.r5f = R5_0
echo rpmsg_r5.elf | sudo tee $R/firmware
echo start | sudo tee $R/state               # dmesg: creating channel rpmsg-raw addr 0x400 → /dev/rpmsg0
sudo python3 rpmsg_rtt.py 1000 32            # 1000 往復 / 32 バイト / 不一致 0 / 中央 357 us
```
### 自動で起動する (U-Boot の手入力と R5 の start をなくす)
電源を入れるだけで `rpmsg.dtb` で起動し、R5 も動く (確認: 起動 11.6 秒で R5 running、1000 往復不一致 0・中央 357us)。
- `linux/uEnv_rpmsg.txt` → SD の FAT 側 `uEnv.txt`。bootargs に `clk_ignore_unused` と
  `zynqmp_ipi_mailbox.tx_poll_period=1` を足してある (理由は下の CNN の節)。`ext4load` で `/home/petalinux/rpmsg.dtb` が読めればそれで、
  読めなければ従来どおり U-Boot の DT で起動する
- `linux/r5_start.sh` → `/usr/local/bin/` (名前 `ffe00000.r5f` で R5_0 を探して start。R5 のノードが無ければ何もしない)
- `linux/r5-rpmsg.service` → `/etc/systemd/system/` (`systemctl enable r5-rpmsg.service`)
```
# KV260 (送ったファイルの行末 CR を取ってから)
B=/run/media/boot-mmcblk1p1
sudo cp $B/uEnv.txt $B/uEnv.txt.before_rpmsg      # 控え
sudo cp uEnv_rpmsg.txt $B/uEnv.txt; sync
sudo mkdir -p /usr/local/bin                       # PetaLinux には無い
sudo install -m 755 r5_start.sh /usr/local/bin/
sudo install -m 644 r5-rpmsg.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable r5-rpmsg.service
```
戻すとき: `sudo cp $B/uEnv.txt.before_rpmsg $B/uEnv.txt` と `sudo systemctl disable r5-rpmsg.service`
(または `rpmsg.dtb` の名前を変えるだけで従来の DT に戻る)。BOOT.BIN を作り直して U-Boot の DT が変わったら
`rpmsg.dtb` も作り直す。

起動直後の dmesg で `reserved mem: ... vdev0vring0@3ed00000` と
`zynqmp-ipi-mbox mailbox@ff990400: Registered` が出ていれば dtb が効いている。

はまった所・理由:
- **リソーステーブルの置き場所** — XIP にすると `.resource_table` が ATCM (R5 からは読み取り専用) に置かれる。
  Linux がここに vring の番地を書き、R5 側も状態を書き戻すことがあるので、`rsc_table.ld` で BTCM に置き直した。
  その際「置き場所 = 読み込み先」にして、起動時の ROM→RAM コピーの対象から外す (コピーされると Linux が書いた内容が消える)
- **MPU の境界** — ARMv7-R の MPU は先頭番地が大きさの倍数でないと黙って下位ビットを捨てる。
  `zephyr,ipc_shm` (vdev0buffer) は Zephyr が自動で MPU 登録するので 256KB 境界 (0x3ED40000) に置いた
- **UART の表示が遅さの原因** — 受信ごとに 1 行 (約 30 文字) 表示すると 115200bps で約 2.6ms かかり、
  往復の中央値が 2679us になった。最初の 3 通と 1000 通ごとだけにして 357us
- ドライバ (`xlnx_r5_remoteproc.c`, 6.12) は memory-region をノード名で区別し、`vdev0buffer` だけを DMA プールにする
  (`shared-dma-pool` 必須)。memory-region[0] は動作中の R5 へ後から接続 (attach) するときだけ読まれる
- R5_1 に memory-region を付けていないので `ffe90000.r5f: failed to get memory region dev node` が出るが、使わないので無害
- Linux に `rpmsg_tty` は無い (`rpmsg_char` はモジュール)。なので名前を `rpmsg-raw` にして `/dev/rpmsgN` で読み書きする

## R5 の Zephyr の shell を Linux から使う (段2の続き, 2026-10-31)
カーネルを作り直さずに、Linux (SSH でも Tera Term でも) から R5 の shell を対話で使う。
```
sudo /usr/local/bin/r5_shell.sh                    # ipc:~$ が出る。抜けるのは Ctrl+]
sudo /usr/local/bin/r5_shell.sh "kernel uptime"    # コマンドを送って応答を表示 (確認用)
```
- Zephyr の RPMsg 用 shell (`CONFIG_SHELL_BACKEND_RPMSG`) の名前を `rpmsg-raw`、番号を 0x440 にした。
  エコー (0x400) と合わせて Linux に `/dev/rpmsg0` (エコー) と `/dev/rpmsg1` (shell) ができる。
  `r5_shell.sh` は sysfs の `virtio0.rpmsg-raw.-1.1088` (= 0x440) で shell の方を探す
- 対話は自作の `linux/r5_term.py` (キーをそのまま書き、返事は別スレッドで読む)
- 置き場所: KV260 の `/usr/local/bin/` に `r5_start.sh` `r5_shell.sh` `r5_term.py` (sudo の検索パスに入っていないのでフルパスで呼ぶ)

はまった所:
- **Zephyr が UART1 の割り込みを止める** — Zephyr の UART ドライバ (`uart_xlnx_ps.c`) は初期化で割り込み禁止レジスタに
  全ビットを書く。UART1 は Linux のコンソールと共用なので、R5 が起動した瞬間から Tera Term で入力できなくなる
  (段1の hello から同じだった。R5 起動後に入力していなかったので気づかなかった)。`r5_start.sh` が起動の 1 秒後に
  Linux のドライバと同じ値 `CDNS_UART_RX_IRQS` = 0x161 を IER (0xFF010008) に書き戻す。
  手で戻すなら `sudo devmem 0xFF010008 32 0x161` (IMR 0xFF010010 が 0x161 になれば OK)
- **R5 側の窓口の番号は 0x400〜0x47F だけ** — OpenAMP は予約 1024 + 管理表 128 ビット。0x500 にしたら作成失敗した
- **コードが 32KB を超えると ATCM があふれる** — リンカスクリプトの `MPU_ALIGN` がコード領域を 2 のべき乗に切り上げ、
  shell 入りの 52KB は 64KB 扱いになって初期値の置き場がなくなった (372 バイトあふれ。機能を削っても変わらない)。
  `apps/rpmsg_r5/linker.ld` (Zephyr の Cortex-R 用の写しに 3 行足しただけ) で初期値を BTCM に直接置いた
- **socat ではキーが届かない** — `socat -,raw /dev/rpmsg1` は開くが 1 バイトも書かず (IPI の回数が増えない)、
  Ctrl+] も効かず固まった。`r5_term.py` に替えた
- UART の shell は外した (`CONFIG_SHELL_BACKEND_SERIAL=n`)。残すと Linux への入力を Zephyr も読む

## Linux から RPMsg で PL の CNN 推論を頼む (段2の続き, 2026-11-01)
Linux の Python が画像を RPMsg で R5 に送り、R5 が PL の CNN で推論して答え・スコアを返す。
段3 (A53 ベアメタル + IPI) を、Linux の普通のプログラムから使える形にしたもの。

**結果: 1000 枚 不一致 0、往復 中央 2396us (最大 2461us)、411 枚/秒。** PL の推論そのもの (1991us) に約 0.4ms 足しただけ。

```
Linux (linux/cnn_rpmsg.py)              R5 (apps/rpmsg_r5/src/cnn_rpmsg.c)        PL (CNN)
  画像 784 バイトを 392 バイト × 2 通で ─> 受信: 1 枚分ためる
                                          推論スレッド: 画素を PL へ 784 回 ───>   推論 1991us
  答え・スコア 10 個・推論時間       <─   1 通で返す
```
- 窓口は 3 本目の `rpmsg-raw`、番号 0x410 (`virtio0.rpmsg-raw.-1.1040`、いまは `/dev/rpmsg2`)。形式は `cnn_rpmsg.c` の冒頭
- RPMsg の 1 通は最大 496 バイトなので画像は 2 通に分ける
- R5 は電源投入で自動起動するが PL は空。空の PL の番地を読むと止まるおそれがあるので、**R5 は依頼が来るまで PL に触らない**。
  `cnn_rpmsg.py` は fpga_manager が `operating` か確かめてから送る
- PL の番地 (0xA0000000) の MPU 登録は `rpmsg.overlay` に入れた (build.sh に `;` で 2 つ渡すと WSL 側で `;` がコマンドの区切りになり、2 つ目が落ちる)
- R5 の shell の `cnn stats` で件数と内訳 (起床・画素・推論・読出・送信) が見える

```
# PC → KV260
scp kv260_cnn/vivado/cnn_mnist.runs/impl_1/design_1_wrapper.bit kv260_cnn/sim/test_images.hex \
    kv260_cnn/sim/test_scores.hex kv260_zephyr/linux/cnn_rpmsg.py petalinux@192.168.0.8:~/
# KV260 (電源を入れるたびに。R5 は自動で動いている)
sudo fpgautil -b ~/design_1_wrapper.bit
sudo devmem 0xFF5E00C0 32 0x01010A00         # PL クロック 100MHz (IOPLL 1000MHz / 10)
sudo python3 cnn_rpmsg.py 1000               # 1000 枚 / 不一致 0 / 411 枚/秒
sudo /usr/local/bin/r5_shell.sh "cnn stats"
```

### 速くするまで (1 枚の往復、中央値)
| 段階 | 往復 | 枚/秒 | R5 側の内訳 |
|---|---|---|---|
| 最初 | 4413us | 222 | 起床 125 / 画素 976 / 推論 2128 / 読出 50 / 送信 88 us |
| `clk_ignore_unused` 後 | 7316us | 136 | 起床 6 / 画素 213 / 推論 2007 / 読出 6 / 送信 4 us |
| `tx_poll_period=1` 後 | **2396us** | **411** | (同上) |

- **R5 のクロックが止められていた** — Linux は起動の終わりに「Linux が使っていないクロック」を止める。RPLL は R5 にしか
  使われていないので止められ、R5 は RPLL を通らない 33.33MHz ÷ 2 = **約 16.7MHz** で動いていた (本来 750MHz ÷ 2)。
  `RPLL_CTRL` (0xFF5E0030) の下位が 0x09 (RESET と BYPASS)、`/sys/kernel/debug/clk/clk_summary` の `rpll_int` が N で確認。
  bootargs に `clk_ignore_unused` を足して止めないようにした (直ると 0x00012D00)。段1からずっとこの状態だった
- **Linux の IPI は通知を 5ms に 1 回しか送れない** — `zynqmp-ipi-mailbox.c` は送った通知が受け取られたかを割り込みでなく
  見回り (`tx_poll_period` = 5ms) で確かめ、確認が済むまで次の通知を待たせる。画像を 2 通に分けると 2 通目の通知が待たされ、
  R5 が速くなった途端に往復が 7.3ms に悪化した (遅かった頃は 1 通目の処理中に 2 通目が届いていて見えなかった)。
  Linux 側を「送信 2 通 / 返事の受信」に分けて測ると、受信だけが 7.3ms だった。bootargs に
  `zynqmp_ipi_mailbox.tx_poll_period=1` (組み込みドライバなので起動時に指定) で直った。エコーは通知 1 回なので当たらない
- PL への窓口の幅 (AFI_FS 0xFD615000) は Linux では 128 ビット (0xA00)。CNN は 32 ビットで作ってあるが、32 ビット (0x800) に
  しても画素の時間は変わらなかった (原因ではない)。音楽プロジェクトの「AXI のレジスタは 0x10 刻みでないと読めない」はおそらくこの食い違い

## R5 で音声を途切れず流す (段2の続き, 2026-11-01)

R5 を「時間に正確な処理」の担当にする。音楽プロジェクト (`kv260_i2s2`) の stream 設計の PL を使い、
**R5 が 5ms ごとに FIFO の残量を見て、空いた分を DDR から書き足す**。Linux は音源を DDR に置いて指示を出すだけ。
段5 の `play.c` は Linux が自分で FIFO を満たしていたので、Linux が忙しいと切れるおそれがあった。

```
Linux (linux/r5play.py)                R5 (apps/rpmsg_r5/src/audio_rpmsg.c)        PL (kv260_i2s2 stream 設計)
  音源を /dev/mem で 0x60000000 に置く
  「再生 番地 長さ」 ── RPMsg 0x420 ──> 5ms ごと (k_timer、優先度 2 のスレッド) ──> 0x00 DATA → FIFO 8192 段
  音量・エコー・停止・状態  <────────>   残量を読み (0x10)、空き分を DDR から書く       → 音量・エコー → I2S → DAC
```

- PL 専用 DDR (0x60000000〜512MB、起動引数 `mem=1536M` で Linux 管理外) を `rpmsg.overlay` の `pl_ddr` で
  キャッシュなしとして MPU に登録。Linux は `/dev/mem` を O_SYNC (キャッシュなし) で書くので食い違わない
- 音源の並びは `play.c` / `dmaplay` と同じ生 PCM。1 語 = 1 組をそのまま渡す
- 空の PL に触らないよう、再生の命令が来るまで PL を読まない。来たら 0x00 が 0xDEADBEEF かを確かめる
- 止めるときは書き足しをやめ、FIFO を鳴らし切ってから CTRL を 0 にする (FIFO を空にするレジスタがないので、
  次の再生に前の曲の残りが混ざらないように)
- 命令と返事の形は `audio_rpmsg.c` の冒頭。shell では `audio stats`

### 使い方 (KV260)

```bash
sudo fpgautil -b ~/stream.bit                 # kv260_i2s2/vivado_stream/.../design_1_wrapper.bit と同じもの
sudo devmem 0xFF5E00C0 32 0x01010A00          # PL のクロック
sudo python3 ~/r5play.py ~/song.raw           # +/- 音量  e エコー  r 統計を消す  q 停止
sudo python3 ~/r5play.py ~/song.raw 30        # 30 秒鳴らして統計を出す (SSH から測る用)
```

### 実測

| 状態 | 最小残量 (8192 段中) | 空になった回数 | 1 回の書き足し最長 |
|---|---|---|---|
| 普段 (20 秒、見回り 3999 回) | 7898 | 0 | 378 us |
| 重い負荷 (30 秒。`yes` 8 本 + `dd` で SD に 2GB 書き込み。CPU 空き 0%、平均負荷 4.5) | 7898 | 0 | 378 us |

- FIFO の減りは最大 294 段 (約 6ms 分) で、Linux の負荷にまったく左右されない。書き足しは 5ms のうち最長 378us (約 8%)
- 音源 314MB を DDR に置くのは 1 回目 19.7 秒 (2 回目以降はファイルがキャッシュに乗って 0.8 秒)
- 実機で正しい速さで鳴ることを耳で確認

### Linux だけで流す場合との比較 (2026-11-04)

`linux/linplay.c` は段5 の `play.c` と同じ流し方 (満杯でなければ 1 組書く、満杯なら usleep(500)) に計測を足したもの。
書くのはこのプログラムだけなので、空のビットは次に書くまで立ったまま残り、止められている間に空になっても見落とさない。
両方に「上限 N 段」(残量を N までしか満たさない) を付け、FIFO を浅く使う = 遅延の小さい再生を真似た。
`linux/audio_cmp.sh N` で 4 通り (Linux/R5 × 普段/重い負荷) を続けて測る。負荷は前の表と同じ。

| 上限 | 流し方 | 普段: 最小残量 / 空 | 重い負荷: 最小残量 / 空 | 負荷時に止められていた最長 |
|---|---|---|---|---|
| 8192 (約 168ms) | Linux | 8065 / 0 | 7587 / 0 | 12.4 ms |
| 8192 | R5 | 7898 / 0 | 7898 / 0 | (5ms 周期で一定) |
| 512 (約 10ms) | Linux | 478 / 0 | 18 / 0 | 10.1 ms |
| 512 | R5 | 219 / 0 | 219 / 0 | |
| 384 (約 7.9ms) | Linux | 213 / 0 | **0 / 191 回** | 10.9 ms |
| 384 | R5 | 90 / 0 | 91 / 0 | |

- FIFO が深い (168ms) と、Linux だけでも途切れない。差は「負荷で減り方が変わるか」だけ
- Linux は負荷で 10〜12ms 止められるので、FIFO を 8ms 分しか使わないと空になる (音が途切れる)。
  R5 は負荷と関係なく最小残量が同じで、途切れ 0 回。遅延を小さくしたい用途ほど R5 に任せる意味がある

## R5 で音を作る (シンセ, 2026-11-04)

音源ファイルを使わず、**Linux は音の高さ・長さ・強さだけを送り、R5 が波形を計算して FIFO に書く**。
上の比較で R5 の強みが出た「FIFO を浅く使う (遅れが小さい)」用途そのもの。PL は同じ stream 設計。

```
Linux (linux/r5synth.py)                  R5 (audio_rpmsg.c 命令 8〜12 + synth.c)          PL
  キー a〜l / 楽譜 / 実測用の音 ─ RPMsg 0x420 ─> 1ms ごとに上限 (既定 256 段) まで ──────> FIFO → I2S
                                               8 音を計算して足し合わせて書く
```

- 同時 8 音 (空きがなければ一番小さくなった音を奪う)。波形は 正弦 / 矩形 / のこぎり / 三角
- 高さは 32 ビットの位相に毎標本 inc を足すだけ。inc は C9〜B9 の 12 個を起動時に作り、低い音は右シフト
- 正弦の表 (256 点) は起動時に単位円を回して作り、BTCM に置く (sin を使わず、ATCM のコードも増やさない)
- 音の形: 2ms で立ち上がる → 長さの間は時定数約 168ms で減る → 長さの後は約 5ms で消える。
  端末ではキーを離したことが取れないので、音符は長さ付き
- 楽譜: (時刻, 音) を最大 256 個ためておき、**標本の数で時刻を数えて鳴らす**。テンポは Linux の負荷に左右されない
- 遅れ = 命令を受けてから書き始めるまで + 書いた時点の FIFO の残量 ÷ 48828。Linux から R5 に届くまで (約 30us) は含まない
- コードは ATCM の 0xEB60 まで (残り約 5.3KB)

### 使い方 (KV260。PL は stream.bit + devmem 0xFF5E00C0 32 0x01010A00 を先に)

```bash
sudo python3 ~/r5synth.py               # キー演奏: 白鍵 a s d f g h j k l / 黒鍵 w e t y u o
                                        #   z/x オクターブ  1〜4 波形  q 終わり
sudo python3 ~/r5synth.py twinkle       # きらきら星の最初の 1 節 (+ 低音、三角波、約 5 秒) を R5 の時計で
sudo python3 ~/r5synth.py notes 30 128  # 30 秒間 0.1 秒ごとに音を頼んで測る (上限 128 段)
sh ~/synth_cmp.sh 128                   # 普段と重い負荷 (audio_cmp.sh と同じ) で続けて測る
```

### 実測 (30 秒間、0.1 秒ごとに 1 音)

| 上限 | 状態 | 遅れ 平均 / 最長 | 最小残量 | 空 | 1ms の処理 最長 |
|---|---|---|---|---|---|
| 256 段 (5.2ms) | 普段 | 4.70 / 5.16 ms | 206 | 0 | 329 us |
| 256 段 | 重い負荷 | 4.71 / 5.16 ms | 206 | 0 | 329 us |
| 128 段 (2.6ms) | 普段 | 2.09 / 2.54 ms | 78 | 0 | 165 us |
| 128 段 | 重い負荷 | 2.10 / 2.54 ms | 78 | 0 | 165 us |

- 遅れはほぼ FIFO の上限の分だけ。負荷をかけても変わらない
- 処理時間の大半は PL への書き込み (1 語 約 1.3us、12.5MHz の AXI)。波形の計算は軽い
- きらきら星は正しい高さとテンポで鳴ることを耳で確認
- 2026-11-04 に 2 つの誤りを直した (段5 で残響を足して気付いた)。
  三角波が `ph >> 15` (正しくは `>> 16`) で約 5 倍に振れて割れていた。
  楽譜を入れた順に鳴らしていたため、メロディの後に入れた低音 12 音が最後に一斉に鳴っていた (今は開始時に時刻順に並べる)。
  PC で synth.c をそのままコンパイルしてきらきら星を流し、割れ 4080 標本 → 0 を確認

## R5_1 (2 コア目) も Linux から動かす (2026-11-04)

R5_0 は音・CNN など PL を使う時間に正確な仕事、**R5_1 は重い計算**を受け持つ。どちらも電源投入で自動起動。

```
Linux ── virtio0 (IPI ch1, 0x3ED00000〜) ── R5_0 (apps/rpmsg_r5)   0x400 エコー 0x440 shell 0x410 CNN 0x420 音
      └─ virtio1 (IPI ch2, 0x3EE00000〜) ── R5_1 (apps/rpmsg_r5_1) 0x401 エコー 0x441 shell 0x450 計算 0x460 音の分業
```

### 2 つの Zephyr でぶつかる所

- **割り込みコントローラ (GIC) は 2 コアで共用**。普通の Zephyr は初期化で全部の割り込みの行き先を自分にするので、
  R5_1 が自分のタイマー割り込みを有効にすると行き先が両方になり、R5_0 に知らない割り込みが届いて止まる。
  → 両方とも `CONFIG_GIC_SAFE_CONFIG=y`。行き先を最初は空にし、先に起動した側だけが初期化、各自が自分の割り込みだけを足す
- **タイマー**: R5_0 は TTC0、R5_1 は TTC1 (`rpmsg_r5_1.overlay`)。Linux は TTC1 を使っていない (DT で disabled)
- **UART1**: R5_1 は使わない (Zephyr の UART ドライバが初期化で Linux のコンソール入力を止めるため)。表示は shell (RPMsg) だけ
- TCM は R5_1 自身からも 0x0 / 0x20000 に見えるので、リンカは R5_0 と同じもの (`apps/rpmsg_r5/linker.ld` を共用)。
  Linux からは 0xFFE90000 / 0xFFEB0000
- IPI: R5_1 は RPU1 (0xFF320000、割り込み 34) の `rpu1_apu_mailbox`。Linux 側は mailbox@ff990440 (`xlnx,ipi-id = <2>`)
- 窓口の番号は R5_0 と重ならないようにする (Linux のスクリプトは番号で /dev/rpmsgN を探すため)

### 入れ方 (KV260)

```bash
# r5_rpmsg.dtso に R5_1 の分 (予約 3 つ・IPI・r5f@1 の memory-region と mboxes) を足して作り直し、再起動
dtc -@ -I dts -O dtb -o r5_rpmsg.dtbo r5_rpmsg.dtso
sudo cat boot_now.dtb > /tmp/base.dtb
fdtoverlay -i /tmp/base.dtb -o rpmsg.dtb r5_rpmsg.dtbo
sudo cp rpmsg_r5.elf rpmsg_r5_1.elf /lib/firmware/
sudo cp r5_start.sh r5_shell.sh /usr/local/bin/
sudo systemctl reboot
```

### 使い方と実測

```bash
sudo python3 rpmsg_rtt.py 1000 32 1        # R5_1 のエコー (最後の 1 = R5_1)
sudo python3 r5_1_calc.py 200000           # R5_1 に計算を頼む (20 万以下の素数を割り算で数える)
sudo /usr/local/bin/r5_shell.sh -1         # R5_1 の shell (r51 stats)
sh core_cmp.sh 128                         # R5_1 が計算し続ける間の R5_0 のシンセを測る (PL は stream.bit)
```

- エコー往復 (1000 回、32 バイト): R5_0 中央 62us / R5_1 中央 61us
- R5_1 の計算: 20 万以下の素数 17984 個、1 回 134.5ms
- R5_0 のシンセ (上限 128 段、30 秒、0.1 秒ごとに 1 音):

| 状態 | 遅れ 平均 / 最長 | 最小残量 | 空 | R5_1 の計算 1 回 |
|---|---|---|---|---|
| シンセだけ | 2.11 / 2.54 ms | 78 | 0 | |
| R5_1 が計算し続ける間 (99.9%) | 2.09 / 2.56 ms | 78 | 0 | 134.5 ms |
| 上 + Linux に重い負荷 | 2.09 / 2.56 ms | 78 | 0 | 134.5 ms |

- R5_1 が 100% 動いても、Linux が重くても、R5_0 の音は変わらない。R5_1 の計算時間も Linux の負荷に左右されない
- GIC の設定を変えた R5_0 で CNN も再確認 (1000 枚不一致 0、往復中央 2397us)

## R5_0 と R5_1 が Linux を通さず直接話す (段5, 2026-11-04)

R5 どうしの IPI (`rpu0_rpu1_mailbox` / `rpu1_rpu0_mailbox`) で合図を送り、データは共有 DDR に置く。
伝言の形と共有メモリの形は `apps/common/r2r_shm.h`。

```
段A  R5_0 (r2r.c、shell の r2r ping) ── IPI ──> R5_1 (main.c の r2r_cb) ── そのまま返す ──> R5_0

段B  Linux (r5synth.py --r51) ─ 0x460 音の命令 ─> R5_1 (r51_audio.c)
                                                  シンセ (synth.c を共用) + 残響 → 輪バッファ (DDR 0x7F000000、4096 標本)
     Linux ─ 0x420 命令 13 ─> R5_0 (audio_rpmsg.c)                                     │
                              1ms ごとに 輪バッファ → PL の FIFO ────────────────────┘
                              移したら R5_1 に KICK の IPI (「足して」) → R5_1 が 256 標本まで作り足す
```

- 引っぱる側 (R5_0) が PL の音の時計に合わせて合図するので、R5_1 は自分で時間を測らなくてよい
- 共有メモリは OCM ではなく DDR 0x7F000000 (1MB、キャッシュなし)。OCM は FSBL/ATF が使っていて空きが分からないため。
  0x7FF00000 からは予約 (pmu) なので避けた
- 残響は Freeverb の形 (櫛形 4 本 + 全域通過 2 本、遅延は 48.8kHz 用)。帰還 0.93、量 0〜255 (既定 64)。
  量 0 のときは残響の計算ごと飛ばす
- コードの終わり: R5_0 は ATCM の 0xF180 (残り約 3.7KB)、R5_1 は 0xDEA0

### はまった所

- **前回の R5 が残した IPI の合図で起動が止まる**。GIC は共有なので、前回の R5_1 が有効にした IPI の割り込みは止めても残る。
  止めた時に IPI の ISR にビットが残っていると、次の R5_1 は割り込み解禁の瞬間に割り込みが鳴りっぱなしになり、
  IPI ドライバ (POST_KERNEL) が消す前なので main に届かない。
  → `apps/common/ipi_early_clear.h`: 割り込みがまだ禁止されている PRE_KERNEL_1 で自分の IPI の IDR と ISR に全部 1 を書く
- **Zephyr の IPI ドライバが別の合図まで消す**。ISR のビットを「読んで OR して書き戻す」(`sys_set_bit`) で消すので、
  1 を書くと消えるレジスタでは、R5_0 の KICK (1ms ごと) を消す時に同時に来ていた Linux の合図も消える。
  Linux の命令が 15 個目で返事待ちのまま止まった。
  → R5 どうしの合図を処理するたびに main に受信リングを見に行かせる (何も無ければ空振り)。Zephyr 本体は変えていない
- 調べ方: R5_1 は UART が無いので、Linux から `/dev/mem` で BTCM (0xFFEB0000 = R5_1 の 0x20000) の変数を読み、
  xsdb で PC とレジスタを見た (割り込み番号 66 = IPI で回り続けていた)

### 使い方 (KV260)

```bash
sudo /usr/local/bin/r5_shell.sh           # R5_0 の shell で  r2r ping 1000   (段A)
sudo python3 ~/r5synth.py --r51 notes 30 128           # 段B: 30 秒間 0.1 秒ごとに音を頼んで測る (残響 64)
sudo python3 ~/r5synth.py --r51 --rev 0 notes 30 128   # 残響なし
sudo python3 ~/r5synth.py --r51 twinkle                # 聞き取り (キー演奏なら r で残響 0 → 64 → 128)
```

### 実測

- 段A: R5_0 → R5_1 → R5_0 の往復 1000 回で 最小・中央・平均 17.71us、最長 18.28us
  (Linux を通すエコーは約 61us)
- 段B (FIFO の上限 128 段、30 秒、0.1 秒ごとに 1 音、300 音):

| 残響 | 遅れ 平均 / 最長 | R5_1 が 1 回に作る時間 平均 / 最長 | R5_0 の 1ms の処理 最長 | FIFO 最小残量 | 空 | 輪バッファ不足 |
|---|---|---|---|---|---|---|
| 64 | 7.34 / 7.79 ms | 69 / 339 us | 166 us | 79 | 0 | 0 |
| 0 | 7.35 / 7.83 ms | 20 / 68 us | 166 us | 79 | 0 | 0 |

- 残響の重さは 1 回あたり平均約 49us (1ms の約 5%)。R5_1 が受け持つので R5_0 の処理時間は変わらない
- 遅れは 輪バッファの目標 256 標本 (5.2ms) + FIFO 128 段 (2.6ms) の分。R5_0 だけのシンセ (2.1ms) より大きい
- きらきら星で残響が付くこと、割れ・爆発音がないことを耳で確認

## R5 の音を HDMI モニターから出す (段6, 2026-11-05)

段5 までの音は Pmod I2S2 (イヤホン) に出ていた。PL を kv260_i2s2 の `stream_hdmi.bit` に替え、
同じ FIFO の出口を PS の HDMI 出力の音声入力 (live audio) につなぐ。Linux の ALSA は通らない。

```
R5_0 (または R5_1 + R5_0 の分業) ─ 1ms ごと ─> PL の FIFO ─ xlive_audio ─> PS の HDMI 音声入力 (PL から, 48kHz) ─> モニター
```

- 標本の速さが変わる: I2S は 12.5MHz/256 = 48828Hz、HDMI は 48000Hz。音の高さがずれないよう
  命令 15 (R5_0 は `audio_rpmsg.c`、R5_1 は `r51_audio.c`) で `synth_set_fs()` を呼び、位相の増分と楽譜の時間を作り直す。
  `r5synth.py` は PL の OUT_SEL (0xA0000140) を読んで、HDMI なら 48000 を送る。PC で MIDI 69 = 440.000Hz (両方の速さ)、割れ 0 を確認
- PL の中身 (xlive_audio、OUT_SEL / HDMI_EMPTY レジスタ、合成) は kv260_i2s2 の README「HDMI モニターから出す」

### HDMI 側 (PS) の切り替え: `linux/hdmi_audio.sh`

| レジスタ | on にした値 | 意味 (Vitis の avbuf / dppsu ドライバのヘッダで確認) |
|---|---|---|
| 0xFD4AB070 | bit5:4 = 00 (0x04) | 音声の入力元を PL (live) に。Linux の ALSA は 01 (メモリ) で 0x54 |
| 0xFD4AB120 | bit1 = 0 (0x05) | 音声クロックを PL の 24.576MHz に。Linux は PS (0x07) |
| 0xFD4ACC00 | 1 → 0 | 音声のリセット |
| 0xFD4A0304 / 0300 | 1 / 1 | 2ch、送信の音声を有効 |
| 0xFD4AC000 | 0x20002000 | 音量 等倍 |

`sudo sh hdmi_audio.sh off` で Linux の ALSA が使う形に戻す、`status` で表示。

### はまった所

- **Linux の HDMI ドライバが起動していなかった** (`zynqmp-dpsub` が -22)。Linux 6.12 のドライバは音声の番地を
  reg-names "aud" で探すが、KV260 の元の DT は古い `xlnx,dpaud-reg` で持っていた。
  → `linux/dp_audio.dtso` (reg に 0xFD4AC000 "aud"、dmas に DPDMA 4・5 番 aud0/aud1) を rpmsg.dtb に重ねた。
  これで ALSA の「DisplayPort Monitor」が現れ、まず Linux の aplay で 440Hz がモニターから鳴ることを確かめた
- **1 回目は FIFO が 256 段のまま減らず、楽譜が進まなかった**。起動直後、`on` の後で Linux が 070 と 120 を
  元の値 (0x54 / 0x07) に書き戻していた (きっかけは未特定。その後 1 分見張っても戻らなかった)。
  戻ると HDMI 側は PL の音を取りに来ない。→ `on` をやり直したら鳴った。`r5synth.py` は鳴らす前に 2 つを読み、
  戻っていれば止まって知らせる
- **音量が 0 (消音)**。0xFD4AC000 は Linux が一度鳴らすまで 0。→ `on` で 0x20002000 を書く

### 使い方 (KV260)

```bash
sudo fpgautil -b ~/stream_hdmi.bit
sudo devmem 0xFF5E00C0 32 0x01010A00
sudo devmem 0xA0000000 32                     # 0xDEADBEEF
sudo sh ~/hdmi_audio.sh on
sudo sh ~/hdmi_audio.sh status                # 0xFD4AB070=0x04、0xFD4AB120=0x05 を確認
sudo python3 ~/r5synth.py twinkle             # R5_0 だけ
sudo python3 ~/r5synth.py --r51 twinkle       # R5_1 が作って残響、R5_0 が流す
```

### 実測 (きらきら星の最初の 1 節、FIFO の上限 256 段)

| 形 | 音 | FIFO 最小残量 | 鳴っている間の HDMI_EMPTY 増加 | その他 |
|---|---|---|---|---|
| R5_0 だけ | 11 | 205 | 0 | R5_0 の 1ms の処理 最長 330us |
| R5_1 + R5_0 (残響 64) | 11 | 205 | 0 | R5_1 が 1 回に作る時間 平均 69us / 最長 365us、輪バッファ不足 0 |

- HDMI_EMPTY は合計 130 回前後あるが、増えるのは鳴らし始め (FIFO が溜まる前) と終わり (出し切った後) だけ。
  中身は 0 なので無音
- 両方ともモニターから鳴ること、残響が付くことを耳で確認

## 止まったとき
- `xsdb debug_r5.tcl` → CPSR のモードが 0x17 ならアボート。DFSR/DFAR で原因と番地がわかる
- PC は WSL で `arm-zephyr-eabi-addr2line -f -e build_<名前>/zephyr/zephyr.elf <PC>`
- 何も出ないのに `Cannot halt processor core` なら、R5 がロックステップのまま (手順 2 が効いていない)
