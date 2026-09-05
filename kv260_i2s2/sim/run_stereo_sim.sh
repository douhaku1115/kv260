#!/bin/bash
# FM ステレオ復調のシミュレーション（xsim）
#
#   使い方:  bash sim/run_stereo_sim.sh [pll|stereo|all]
#
#   simbuild_stereo/ で動かす。既存の simbuild/ は触らない。
#   $readmemh は相対パスなので、表(.hex)を作業ディレクトリにコピーしてから走らせる。
set -e

VIV=E:/vivado/2025.2/Vivado/bin
ROOT=E:/fpga/kria260/kv260_i2s2
WORK=$ROOT/simbuild_stereo
TARGET=${1:-all}

mkdir -p "$WORK"
cp "$ROOT/rtl/nco_sin.hex" "$ROOT/rtl/fir15k.hex" "$WORK/"
cd "$WORK"

echo "=== コンパイル ==="
"$VIV/xvlog.bat" \
    "$ROOT/rtl/stereo_pll.v" \
    "$ROOT/rtl/audio_backend.v" \
    "$ROOT/rtl/fm_demod_stereo.v" \
    "$ROOT/sim/tb_stereo_pll.v" \
    "$ROOT/sim/tb_fm_stereo.v"

run_one () {
    echo
    echo "=== $1 ==="
    "$VIV/xelab.bat" -debug off "$1" -s "snap_$1"
    "$VIV/xsim.bat" "snap_$1" -runall
}

case "$TARGET" in
    pll)    run_one tb_stereo_pll ;;
    stereo) run_one tb_fm_stereo ;;
    *)      run_one tb_stereo_pll; run_one tb_fm_stereo ;;
esac
