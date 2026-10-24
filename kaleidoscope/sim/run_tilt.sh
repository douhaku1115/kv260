#!/bin/bash
# -----------------------------------------------------------------------------
# 視線の傾き (段9) の scope_pipe 照合
#   使い方:  bash sim/run_tilt.sh <傾き> <方向 度> <間引き>
#   例:      bash sim/run_tilt.sh 0.9 90 4
# -----------------------------------------------------------------------------
set -e

VIV=E:/vivado/2025.2/Vivado/bin
ROOT=E:/fpga/kria260/kaleidoscope
WORK=$ROOT/simbuild

mkdir -p "$WORK"
cp "$ROOT"/rtl/*.hex "$WORK/"
cd "$ROOT"
python tools/tilt_tb.py gen "$@"
cd "$WORK"

"$VIV/xvlog.bat" -i "$ROOT/rtl" \
    "$ROOT/rtl/divq.v" \
    "$ROOT/rtl/scope_stage.v" \
    "$ROOT/rtl/scope_pipe.v" \
    "$ROOT/sim/tb_scope_pipe.v" > xvlog_tilt.log
"$VIV/xelab.bat" -debug off -timescale 1ns/1ps tb_scope_pipe -s snap_tilt > xelab_tilt.log
"$VIV/xsim.bat" snap_tilt -runall | grep -v "^INFO\|^#\|^$" || true

cd "$ROOT"
python tools/tilt_tb.py cmp "$@"
