#!/bin/bash
# xsim で段ごとのテストベンチを回す
#   使い方: bash sim/run_sim.sh tb_stageA
# 作業場は sim/simbuild (git に入れない)
set -e
TB=${1:-tb_stageA}
VIV=/e/vivado/2025.2/Vivado/bin
ROOT=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$ROOT/sim/simbuild"
cd "$ROOT/sim/simbuild"
cp "$ROOT"/rtl/*.hex .
$VIV/xvlog.bat "$ROOT"/rtl/*.v "$ROOT/sim/$TB.v" /e/vivado/2025.2/data/verilog/src/glbl.v > xvlog.txt 2>&1 || { tail -20 xvlog.txt; exit 1; }
$VIV/xelab.bat $TB glbl -s snap_$TB -L unisims_ver --timescale 1ns/1ps > xelab.txt 2>&1 || { tail -20 xelab.txt; exit 1; }
# 表示は全部 xsim_run.txt に残す (止まったときに位置が分かるように)
$VIV/xsim.bat snap_$TB -R < /dev/null > xsim_run.txt 2>&1 || true
grep -v '^#' xsim_run.txt | grep -E 'OK|NG|PASS|FAIL|checked|written|FRAME|Error|ERROR|error'
