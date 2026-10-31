#!/bin/bash
# 使い方: build.sh <サンプルのパス> <出力名> [cmake の追加引数...]
set -e
source ~/zephyrproject/.venv/bin/activate
cd ~/zephyrproject
T0=$(date +%s)
west build -p always -b kv260_r5 "$1" -d build_$2 -- "${@:3}" 2>&1 | tail -15
echo "BUILD_SEC $(( $(date +%s) - T0 ))"
cp build_$2/zephyr/zephyr.elf /mnt/e/fpga/kria260/kv260_zephyr/$2.elf
~/zephyr-sdk-1.0.1/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-readelf -h build_$2/zephyr/zephyr.elf | grep -E "Machine|Entry"
~/zephyr-sdk-1.0.1/gnu/arm-zephyr-eabi/bin/arm-zephyr-eabi-readelf -lW build_$2/zephyr/zephyr.elf | grep LOAD
