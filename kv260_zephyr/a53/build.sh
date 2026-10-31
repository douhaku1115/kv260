#!/bin/bash
# A53 のアプリを Vitis の画面を使わずにビルドする (Git Bash で実行)。
# BSP は万華鏡の Vitis プラットフォームのもの (PS 設定は run_zephyr.tcl の psu_init と同じ)。
# コンパイル・リンクのオプションは Vitis が kaleido_app に使ったものと同じ。
set -e
cd "$(dirname "$0")"
BSP=E:/Xilinx/project_vitis/kv260_kaleido/kaleido_plat/export/kaleido_plat/sw/standalone_psu_cortexa53_0
BIN=/e/vivado/2025.2/Vitis/gnu/aarch64/nt/aarch64-none/bin
$BIN/aarch64-none-elf-gcc.exe -O2 -Wall -Wextra -DSDT -specs=$BSP/Xilinx.spec -I$BSP/include \
    main.c -Wl,-T,lscript.ld -L$BSP/lib \
    -Wl,--start-group,-lxilstandalone,-lxiltimer,-lxil,-lgcc,-lc,-lm -Wl,--end-group \
    -o ../a53_amp.elf
$BIN/aarch64-none-elf-readelf.exe -lW ../a53_amp.elf | grep -E "Entry|LOAD"
