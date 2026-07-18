# SD自動起動 (電源ONだけで RISC-V + KOZOS が立ち上がる)

PetaLinux プロジェクト(例: kv260_audio)に本ディレクトリの部品を組み込み、
SDカードから「Linux 起動 → systemd が fpgautil + pl_clk0 を自動実行 → KOZOS 稼働」まで全自動にする。

```
電源ON → U-Boot(QSPI) → SDの boot.scr → uEnv.txt
  → 自ビルドカーネル + SD ext4 rootfs → systemd
  → riscv-load.service → fpgautil + devmem → KOZOS> (FT232R tio)
```

SDを抜いて電源ONすれば従来の純正QSPI Linuxに戻る(使い分け可能)。

## 部品

| ファイル | 置き場所(プロジェクト内) |
|---|---|
| `riscv-autoload/riscv-autoload.bb` | `project-spec/meta-user/recipes-core/riscv-autoload/` |
| `riscv-autoload/files/riscv-load.sh` | 同 `files/` |
| `riscv-autoload/files/riscv-load.service` | 同 `files/` |
| (ビットストリーム) | 同 `files/m_top_kv260.bit` に**自分でコピー**(ビルド生成物なのでgit非管理。`vivado/riscv_kv260_shell/*.runs/impl_1/m_top_kv260.bit`) |
| `uEnv.txt` | ビルド後、**SDのbootパーティション直下**に置く |
| `petalinuxbsp.conf` | `project-spec/meta-user/conf/`(参照用。要点は下記 IMAGE_BOOT_FILES) |

さらに `project-spec/meta-user/recipes-core/images/petalinux-image-minimal.bbappend` の
`IMAGE_INSTALL:append` に ` riscv-autoload` を足す。

## ビルド〜SD作成

```sh
source /mnt/data/petalinux/2025.1/settings.sh
cd <プロジェクト>
petalinux-build
petalinux-package --wic --bootfiles "BOOT.BIN boot.scr Image image.ub"
sudo dd if=images/linux/petalinux-sdimage.wic of=/dev/sdX bs=4M status=progress conv=fsync
# bootパーティションをマウントして uEnv.txt をコピー
cp uEnv.txt /media/*/boot/ && sync
```

## ハマりどころ (2026-07-18 に実際に踏んだ罠)

1. **pmu-firmware が `undefined reference to outbyte` でビルド失敗**
   - 原因: SDTフローが ZynqMP の PMU multiconfig に誤って `-DVERSAL_PLM=1` を付け、
     standalone BSP `common/outbyte.c` の outbyte 定義が `#if !defined(VERSAL_PLM)` で除外される。
   - 修正: `build/conf/multiconfig/xilinx-k26-kv-microblaze-pmu.conf` に
     `TARGET_CFLAGS:remove = "-DVERSAL_PLM=1"` を追加(既存の += 行はコメントアウト)。
   - 注意: このconfは**自動生成**なので `petalinux-config` 再実行後は再適用が要る。
   - LTO を外す対処は不可(PMU_RAM overflow でリンク失敗する。LTOはサイズ圧縮に必須)。

2. **カーネルpanic: `unknown-block(0,0)`**
   - 原因: `IMAGE_BOOT_FILES:zynqmp` に image.ub が無く、boot.scr がカーネル単体
     (ramdisk無し・root=無し)で起動していた。
   - 修正: `IMAGE_BOOT_FILES:zynqmp = "BOOT.BIN boot.scr Image image.ub"`。

3. **image.ub 起動だと `Starting kernel ...` 後に完全無反応**
   - 原因: 476MB の巨大 initramfs の RAM 起動(ロード先が CMA/予約領域と衝突)。
     DT 指定や cma 縮小では解決しない。
   - 解決: **RAMルートをやめ、SD第2パーティション(ext4)を root にする**(uEnv.txt 方式)。
     boot.scr は uEnv.txt があれば優先するので再ビルド不要:
     ```
     bootargs=earlycon console=ttyPS1,115200 root=/dev/mmcblk1p2 rw rootwait cma=256M
     uenvcmd=fatload ${devtype} ${devnum}:${distro_bootpart} 0x00200000 Image; booti 0x00200000 - ${fdtcontroladdr}
     ```
     `rootwait` 必須(SD認識は非同期。無いと mmcblk が見つからず panic)。

4. **SD の rootfs に riscv-load.sh が入っていない**
   - 原因: `petalinux-package --wic` が使う `images/linux/rootfs.ext4` が古いままだった
     (最新は `build/tmp/deploy/images/*/petalinux-image-minimal-*-<日付>.ext4`)。
   - 修正: deploy の最新 ext4 を `images/linux/rootfs.ext4` に cp してから wic を作る。
     (SD書き込み済みなら `sudo dd if=<最新ext4> of=/dev/sdX2` で第2パーティションだけ差し替え可)

## 動作確認

```sh
# KV260 にログインして
df -h /                      # /dev/root (SD ext4) が / にマウント
systemctl status riscv-load  # active (exited) / SUCCESS
# ホストPCから FT232R で
/usr/bin/tio -b 115200 /dev/ttyUSBn   # KOZOS> sum → 5050
```
