#!/usr/bin/env bash
# 第3段 gccフロー: C/crt0 -> RV32I ELF -> .text バイナリ -> asm_gcc.txt(命令メモリinclude)
#   生成物 asm_gcc.txt は ../asm_gcc.txt に置き、main_vio_rv32i.v が include する。
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
TC=/tools/Xilinx/2025.1/Vitis/gnu/riscv/lin/riscv64-unknown-elf/bin
GCC=$TC/riscv64-unknown-elf-gcc
OBJCOPY=$TC/riscv64-unknown-elf-objcopy
OBJDUMP=$TC/riscv64-unknown-elf-objdump
OUT=${1:-$HERE/../asm_gcc.txt}
CSRC=${CSRC:-main.c}

cd "$HERE"
# RV32I / ilp32 / 圧縮命令なし。標準ライブラリ・スタートアップ不使用。
$GCC -march=rv32i_zicsr -mabi=ilp32 -O2 -nostdlib -nostartfiles \
     -ffreestanding -Wl,--build-id=none -Wl,-T,link.ld \
     crt0.S $CSRC -lgcc -o prog.elf   # -lgcc: RV32Iの soft div/mul(__udivsi3等)

# 逆アセンブル(確認用)
$OBJDUMP -d prog.elf > prog.dis

# .text を生バイナリへ(rodata含む .text セクション群)
$OBJCOPY -O binary --only-section=.text prog.elf text.bin

# little-endian 32bit語 -> `MM[i]=32'hXXXXXXXX; 形式
python3 - "$OUT" <<'PY'
import sys, struct
data = open("text.bin","rb").read()
# 4バイト境界にパディング
if len(data) % 4: data += b'\x00'*(4-len(data)%4)
words = struct.unpack("<%dI"%(len(data)//4), data)
with open(sys.argv[1],"w") as f:
    f.write("// 自動生成(build_gcc.sh): gcc RV32I .text -> 命令メモリ\n")
    for i,w in enumerate(words):
        f.write("`MM[%d]=32'h%08x;\n"%(i,w))
print("words=%d -> %s"%(len(words), sys.argv[1]))
PY
echo "OK: $(wc -l < "$OUT") lines"
