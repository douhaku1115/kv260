#!/bin/bash
# vitis_src/main.c を CHIP-8 の BSP (PS 設定は NES と同じ) でビルドする。Vitis GUI を使わない版。
#   bash tools/build_elf.sh   → E:/Xilinx/project_vitis/kv260_nes/nes.elf
set -e
PF=E:/Xilinx/project_vitis/kv260_chip8/kv260_chip8_pf/export/kv260_chip8_pf/sw/standalone_psu_cortexa53_0
APPSRC=E:/Xilinx/project_vitis/kv260_chip8/kv260_chip8_app/src
GCC=E:/vivado/2025.2/gnu/aarch64/nt/aarch64-none/bin/aarch64-none-elf-gcc.exe
OUT=E:/Xilinx/project_vitis/kv260_nes
SRC=$(cd "$(dirname "$0")/.." && pwd)/vitis_src
mkdir -p $OUT
$GCC -DSDT -specs=$PF/Xilinx.spec -I$PF/include -Wall -Wextra -O0 -g3 -U__clang__ \
     -c $SRC/main.c -o $OUT/main.o
$GCC -specs=$PF/Xilinx.spec -Wl,-T -Wl,$APPSRC/lscript.ld -L$APPSRC -L$PF/lib \
     $OUT/main.o -o $OUT/nes.elf \
     -Wl,--start-group,-lxilstandalone,-lxiltimer,-lxil,-lgcc,-lc,-lm -Wl,--end-group
echo "OK $OUT/nes.elf"
