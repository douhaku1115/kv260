#!/bin/bash
# HDMI 音声 (i2s_stream_axi の OUT_SEL=1) のシミュレーション (xsim)
#   使い方:  bash sim/run_hdmi_sim.sh
#   simbuild_hdmi/ で動かす。$readmemh は相対パスなので、表 (.hex) を作業ディレクトリにコピーしてから走らせる。
set -e

VIV=E:/vivado/2025.2/Vivado/bin
ROOT=E:/fpga/kria260/kv260_i2s2
WORK=$ROOT/simbuild_hdmi

mkdir -p "$WORK"
cp "$ROOT"/rtl/*.hex "$WORK/"
cd "$WORK"

"$VIV/xvlog.bat" \
    "$ROOT/rtl/xlive/xlive_audio.v" "$ROOT/rtl/xlive/cdc_fifo.v" "$ROOT/rtl/xlive/cdc_synchronizer.v" \
    "$ROOT/rtl/xlive/dual_clk_ram.v" "$ROOT/rtl/xlive/shift_register.v" \
    "$ROOT/rtl/xlive/shift_register_factory.v" "$ROOT/rtl/xlive/shift_register_vector.v" \
    "$ROOT/rtl/audio_fifo.v" "$ROOT/rtl/audio_fx.v" "$ROOT/rtl/stereo_pll.v" "$ROOT/rtl/audio_backend.v" \
    "$ROOT/rtl/fm_demod_stereo.v" "$ROOT/rtl/axi_reader.v" "$ROOT/rtl/fft512.v" \
    "$ROOT/rtl/i2s_stream_axi.v" "$ROOT/sim/tb_hdmi_audio.v" E:/vivado/2025.2/Vivado/data/verilog/src/glbl.v
"$VIV/xelab.bat" -debug off --timescale 1ns/1ps -L unisims_ver tb_hdmi_audio glbl -s snap_hdmi
"$VIV/xsim.bat" snap_hdmi -runall
