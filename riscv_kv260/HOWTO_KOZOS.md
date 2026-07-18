# KOZOS (自作RISC-V + 自作OS) 実機操作 手順書

自作RISC-VコアをKV260のPL(FPGA)に載せ、自作OS KOZOS の対話シェルを使う手順。

## 0. 用語・接続の全体像

- **RISC-V + KOZOS** … KV260の **PL(FPGA)** の中で動く。ビットストリーム(`m_top_kv260.bit`)に回路とプログラムが焼き込まれている。
- **Linux(PetaLinux)** … KV260の **PS(ARM)** で動く。`fpgautil`/`devmem` はここで実行。RISC-Vとは別。
- 3つの画面(ターミナル)を区別する:

| プロンプト | どこ | 用途 |
|-----------|------|------|
| `dou@ubuntu:~$` | **ホストPC** | scp/ssh/ビルド/送信スクリプトを打つ |
| `petalinux@...` / `xilinx-kv260...:~$` | **KV260のLinux** | fpgautil/devmem を打つ(ssh経由 or シリアル) |
| `KOZOS>` | **KV260のRISC-V** | KOZOSシェル。tio でのみ見える |

## 1. 配線 (FT232R USB-シリアルアダプタ ↔ KV260 PMOD J2)

| 線 | KV260側 | アダプタ側 |
|----|---------|-----------|
| 緑 | B11 = J2-10 | RXD |
| 白 | D11 = J2-9  | TXD |
| 黒 | GND (J2-5等) | GND |

※アダプタをUSBに挿し直すと線が緩みやすい。無反応時はまず**緑線とGNDを挿し直す**。

## 2. 接続情報

- KV260: `192.168.0.8` (ssh別名 `kv260`)、ユーザ `petalinux` / パスワード `petalinux`
- ビットストリーム: `/mnt/data/fpga/RISC-V/kv260/vivado/riscv_kv260_shell/riscv_kv260_shell.runs/impl_1/m_top_kv260.bit`
- FT232R のデバイス番号は挿す度に変わる。特定コマンド:
  ```
  for d in /dev/ttyUSB*; do echo -n "$d : "; udevadm info -q property -n $d 2>/dev/null | grep -m1 ID_MODEL=; done
  ```
  `ID_MODEL=FT232R` の行の番号(例 `/dev/ttyUSB4`)を使う。`ML_Carrier_Card` はKV260本体なので違う。

## 3. 起動手順

### 3a. SD自動起動 (2026-07-18完成・推奨)

**RISC-V自動起動SDカード**(kv260_audioプロジェクトでビルド)を挿して電源ONするだけ。
- 電源ON → SDからLinux起動 → riscv-load.service が自動で fpgautil+pl_clk0 → KOZOS稼働
- あとは 2. の tio で接続すれば `KOZOS>`(手順4へ)
- 確認: KV260にsshして `systemctl status riscv-load` が SUCCESS
- 仕組み: SDのbootパーティションの uEnv.txt が「カーネル単体+SD ext4 root」で起動
  (root=/dev/mmcblk1p2 rootwait。image.ub/巨大initramfsのRAM起動はハングするので使わない)
- **QSPI純正Linuxに戻すには SDを抜いて電源ON**(従来のQSPI起動になる)
- SDを作り直す時の注意は memory の project_riscv_kozos 5-11 参照
  (IMAGE_BOOT_FILESにimage.ub / rootfs.ext4の鮮度 / uEnv.txt)

### 3b. 手動ロード (QSPI起動時・従来の方法)

QSPI起動(SD無し)のLinuxはRAM rootfsで再起動するとbitが消えるので、毎回このscp→ロードが要る。

```
# ホストPCで:
# (1) bit転送
scp /mnt/data/fpga/RISC-V/kv260/vivado/riscv_kv260_shell/riscv_kv260_shell.runs/impl_1/m_top_kv260.bit petalinux@kv260:/home/petalinux/

# (2) PLへロード + pl_clk0(100MHz)有効化   ※これがKOZOS起動
ssh -t petalinux@kv260 "sudo fpgautil -b /home/petalinux/m_top_kv260.bit && sudo devmem 0xFF5E00C0 32 0x01010A00"

# (3) tioで接続 (番号は2.で特定した値)
/usr/bin/tio -b 115200 /dev/ttyUSB4
```

`KOZOS console...` `KOZOS>` が出れば成功。出ない時は 2.のfpgautilをtioを開いたまま再実行するとバナーが出る。それでも無反応なら配線(1.)。

## 4. KOZOSシェルの主なコマンド

```
help              コマンド一覧
sum / sum n       1+..+100 / 1+..+n
calc a op b       四則演算 (calc 6 * 7)
ps                スレッド一覧
run / kill id     ワーカー起動 / 終了
peek/poke/dump    メモリ読み書き/ダンプ
tick              システムtick
load n            n語の機械語を受信し 0x13000 で実行(=ブートローダ)
```

## 5. 任意のCプログラムを実行 (ブートローダ)

`int prog(void){ ... return 値; }` を書けば、再合成なしで実行できる。
乗除算(`* / %`)・グローバル変数・配列・関数呼出し・ループOK。像は0x13000..0x13FFFの1024語まで。

**確実な送信 = ホストの sendprog.py (エコー同期・雑音耐性)**。tioを閉じてから実行:

```
# tioを ctrl-t q で終了 → ポートを解放
python3 /mnt/data/fpga/RISC-V/kv260/src/gcc/sendprog.py /dev/ttyUSB4 myprog.c
# 例: ret=1010 と 一致18/18 が出れば成功
```

`mkload.sh` は貼り付け用hexを表示するだけ(手貼りは取りこぼしやすいので sendprog.py 推奨):
```
bash /mnt/data/fpga/RISC-V/kv260/src/gcc/mkload.sh myprog.c
```

## 6. リセット / 再ロード

- KOZOSがおかしくなったら(load途中で止まった等)、2.のfpgautilを再実行すれば最初から起動し直す。
- tioを閉じてもKOZOSは動き続ける(tioはPC側の窓なだけ)。再度tioで開けば `KOZOS>` に戻る(Enterでプロンプト表示)。

## 7. 再ビルド (RTL/シェルを変えた時のみ)

```
# シェル(kozos_sh.c)を変えたら asm_gcc.txt 再生成:
cd /mnt/data/fpga/RISC-V/kv260/src/gcc && CSRC="kozos_sh.c kentry.S" bash build_gcc.sh
# ビットストリーム生成(約10-15分):
cd /mnt/data/fpga/RISC-V/kv260 && vivado -mode batch -source create_shell.tcl
# 生成物: vivado/riscv_kv260_shell/riscv_kv260_shell.runs/impl_1/m_top_kv260.bit → 3.でロード
```
