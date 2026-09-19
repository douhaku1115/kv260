#!/bin/bash
# -----------------------------------------------------------------------------
# 万華鏡のシミュレーション (xsim)
#
#   使い方:  bash sim/run_sim.sh
#
#   simbuild/ で動かす。$readmemh は相対パスなので rtl/*.hex を作業ディレクトリへ
#   コピーしてから走らせる。結果は simbuild/frame.txt に出るので
#   python tools/txt2png.py simbuild/frame.txt sim/rtl_scope.png で絵にする。
# -----------------------------------------------------------------------------
set -e

VIV=E:/vivado/2025.2/Vivado/bin
ROOT=E:/fpga/kria260/kaleidoscope
WORK=$ROOT/simbuild

mkdir -p "$WORK"
cp "$ROOT"/rtl/*.hex "$WORK/"
cd "$WORK"

echo "=== コンパイル ==="
"$VIV/xvlog.bat" -i "$ROOT/rtl" \
    "$ROOT/rtl/shift_register.v" \
    "$ROOT/rtl/cdc_synchronizer.v" \
    "$ROOT/rtl/vga_iface.v" \
    "$ROOT/rtl/divq.v" \
    "$ROOT/rtl/scope_stage.v" \
    "$ROOT/rtl/scope_pipe.v" \
    "$ROOT/rtl/cell_mem.v" \
    "$ROOT/rtl/kaleido_axi_slave.v" \
    "$ROOT/rtl/rtl_top.v" \
    "$ROOT/sim/tb_scope.v"

echo "=== エラボレート ==="
"$VIV/xelab.bat" -debug off -timescale 1ns/1ps tb_scope -s snap_scope

echo "=== 実行 ==="
"$VIV/xsim.bat" snap_scope -runall
