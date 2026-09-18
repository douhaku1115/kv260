#!/bin/bash
# -----------------------------------------------------------------------------
# 段13 CNN のシミュレーション（xsim）
#
#   使い方:  bash sim/run_sim.sh [conv1|pool1|conv2|fc|core|all]
#
#   simbuild/ で動かす。$readmemh は相対パスなので、係数(rtl/*.hex)と
#   期待値(sim/*.hex)を作業ディレクトリへコピーしてから走らせる。
# -----------------------------------------------------------------------------
set -e

VIV=E:/vivado/2025.2/Vivado/bin
ROOT=E:/fpga/kria260/kv260_cnn
WORK=$ROOT/simbuild
TARGET=${1:-all}

mkdir -p "$WORK"
cp "$ROOT"/rtl/*.hex "$WORK/"
cp "$ROOT"/sim/*.hex "$WORK/"
cd "$WORK"

echo "=== コンパイル ==="
"$VIV/xvlog.bat" -i "$ROOT/rtl" \
    "$ROOT/rtl/conv3x3.v" \
    "$ROOT/rtl/maxpool2.v" \
    "$ROOT/rtl/fc.v" \
    "$ROOT/rtl/cnn_core.v" \
    "$ROOT/rtl/cnn_axi.v" \
    "$ROOT/sim/tb_conv1.v" \
    "$ROOT/sim/tb_pool1.v" \
    "$ROOT/sim/tb_conv2.v" \
    "$ROOT/sim/tb_fc.v" \
    "$ROOT/sim/tb_cnn_core.v" \
    "$ROOT/sim/tb_cnn_axi.v"

run_one () {
    echo
    echo "=== $1 ==="
    "$VIV/xelab.bat" -debug off "$1" -s "snap_$1"
    "$VIV/xsim.bat" "snap_$1" -runall
}

case "$TARGET" in
    conv1) run_one tb_conv1 ;;
    pool1) run_one tb_pool1 ;;
    conv2) run_one tb_conv2 ;;
    fc)    run_one tb_fc ;;
    core)  run_one tb_cnn_core ;;
    axi)   run_one tb_cnn_axi ;;
    *)     run_one tb_conv1; run_one tb_pool1; run_one tb_conv2; run_one tb_fc; run_one tb_cnn_core; run_one tb_cnn_axi ;;
esac
