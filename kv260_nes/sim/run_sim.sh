#!/bin/bash
# xsim で段ごとのテストベンチを回す
#   使い方: bash sim/run_sim.sh tb_stageA
# 作業場は sim/simbuild (git に入れない)
#   並べて回すとき: SIMDIR=作業場の名前 (sim/ の下)、HEXDIR=hex の取り込み元 (既定 roms/)
set -e
TB=${1:-tb_stageA}
VIV=/e/vivado/2025.2/Vivado/bin
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SIMDIR=${SIMDIR:-simbuild}
mkdir -p "$ROOT/sim/$SIMDIR"
cd "$ROOT/sim/$SIMDIR"
cp "$ROOT"/rtl/*.hex .
# テスト ROM 由来の hex (tools/nestest_prep.py が作る。無ければ飛ばす)
cp "${HEXDIR:-$ROOT/roms}"/*.hex . 2>/dev/null || true
$VIV/xvlog.bat "$ROOT"/rtl/*.v "$ROOT/sim/$TB.v" /e/vivado/2025.2/data/verilog/src/glbl.v > xvlog.txt 2>&1 || { tail -20 xvlog.txt; exit 1; }
$VIV/xelab.bat $TB glbl -s snap_$TB -L unisims_ver --timescale 1ns/1ps > xelab.txt 2>&1 || { tail -20 xelab.txt; exit 1; }
# 表示は全部 xsim_run.txt に残す (止まったときに位置が分かるように)
$VIV/xsim.bat snap_$TB -R < /dev/null > xsim_run.txt 2>&1 || true
grep -v -E '^#|^ *\*\*|^source |^run |^exit|^INFO|^\$finish|^$' xsim_run.txt
