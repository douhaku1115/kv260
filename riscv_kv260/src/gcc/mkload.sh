#!/usr/bin/env bash
# mkload.sh prog.c : `int prog(void){...}` をコンパイル・0x13000固定リンクし、モニタの load+hex を出力。
#   出力をそのまま tio に貼り付ければ、再合成せずに実機で実行できる。
#   -march=rv32im: コアがRV32M(乗除算)対応なので * / % がハード命令に。
#   グローバル変数対応: 0x13000固定リンクで .text->.data->.bss を連続配置。
#     .text+.data をhex化し、.bss サイズ分のゼロ語を後付け(ゼロ初期化)。RTL変更不要。
#   制約: 位置は固定(0x13000)。他関数呼び出しは可(相対jal)。文字列/配列/グローバルOK。
#         プログラム像(text+data+bss)は 0x13000..0x13FFF の 1024語(4KB)に収めること。
set -e
TC=/tools/Xilinx/2025.1/Vitis/gnu/riscv/lin/riscv64-unknown-elf/bin
HERE="$(cd "$(dirname "$0")" && pwd)"
$TC/riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2 -ffreestanding \
    -ffunction-sections -fdata-sections -c "$1" -o /tmp/mkload.o
$TC/riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -nostartfiles -nostdlib \
    -Wl,--build-id=none -Wl,-T,"$HERE/load.ld" /tmp/mkload.o -o /tmp/mkload.elf -lgcc
$TC/riscv64-unknown-elf-objcopy -O binary /tmp/mkload.elf /tmp/mkload.bin   # .text+.data(.bssはNOBITS=除外)
BE=$($TC/riscv64-unknown-elf-nm /tmp/mkload.elf | awk '$3=="_bss_end"{print $1}')
python3 - "$BE" <<'PY'
import struct,sys
BASE=0x00013000
end=int(sys.argv[1],16) if len(sys.argv)>1 and sys.argv[1] else BASE
d=open('/tmp/mkload.bin','rb').read(); d+=b'\0'*((4-len(d)%4)%4)   # .text+.data
w=list(struct.unpack('<%dI'%(len(d)//4),d))
total=(end-BASE+3)//4                                              # 0x13000.._bss_end 全体
if total>len(w): w+=[0]*(total-len(w))                             # .bss(+隙間) をゼロ語で埋める
print("load %d"%len(w))
print(' '.join('%08x'%x for x in w))
PY
