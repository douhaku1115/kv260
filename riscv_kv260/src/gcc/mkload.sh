#!/usr/bin/env bash
# mkload.sh prog.c : `int prog(void){...}` をコンパイルし、モニタの load コマンド+hex を出力。
#   出力をそのまま tio に貼り付ければ、再合成せずに実機で実行できる。
#   制約: 位置独立(グローバル変数・絶対番地・他関数呼び出しは不可。レジスタ演算とローカルのみ)。
#   -march=rv32im: コアがRV32M(乗除算)対応なので * / % がハード命令に(関数呼び出し不要)。
set -e
TC=/tools/Xilinx/2025.1/Vitis/gnu/riscv/lin/riscv64-unknown-elf/bin
$TC/riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2 -ffreestanding -c "$1" -o /tmp/mkload.o
$TC/riscv64-unknown-elf-objcopy -O binary -j .text /tmp/mkload.o /tmp/mkload.bin
python3 - "$1" <<'PY'
import struct,sys
d=open('/tmp/mkload.bin','rb').read(); d+=b'\0'*((4-len(d)%4)%4)
w=struct.unpack('<%dI'%(len(d)//4),d)
print("load %d"%len(w))
print(' '.join('%08x'%x for x in w))
PY
