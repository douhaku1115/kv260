#!/bin/bash
# build.sh — test10 のビルドスクリプト
#
# 使い方 (WSL から):
#   cd /mnt/e/fpga/kria260/kv260_mips/step10
#   bash build.sh
#
# 成果物:
#   test10.elf   — ELF バイナリ
#   test10.bin   — フラットバイナリ（imem ロード用）
#   test10.dump  — 逆アセンブル（ディレイスロット確認用）
#   test10_array.h — uint32 配列（main.c に貼り付け用）

set -e

CC=mips-linux-gnu-gcc
OBJCOPY=mips-linux-gnu-objcopy
OBJDUMP=mips-linux-gnu-objdump

# -O0: ディレイスロットを NOP で埋める（本ハードウェア必須）
# -mips1 -EB: MIPS1 ビッグエンディアン
# -fno-pic -mno-abicalls: GOT/PIC 無効（ベアメタル用）
CFLAGS="-mips1 -mfp32 -EB -O0 -ffreestanding -nostdlib -nostartfiles -fno-pic -mno-abicalls"

echo "=== Compiling ==="
$CC $CFLAGS -Wl,-T,mips.ld -o test10.elf crt0.S test10.c

echo "=== Extracting binary ==="
$OBJCOPY -O binary test10.elf test10.bin

echo "=== Disassembly ==="
$OBJDUMP -d test10.elf | tee test10.dump

echo ""
echo "=== Generating C array ==="
python3 bin2array.py test10.bin | tee test10_array.h

echo ""
echo "=== Done ==="
echo "Binary size: $(wc -c < test10.bin) bytes ($(( $(wc -c < test10.bin) / 4 )) words)"
