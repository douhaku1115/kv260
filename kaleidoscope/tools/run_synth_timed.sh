#!/bin/bash
# -----------------------------------------------------------------------------
# 合成を時刻つきで走らせる。
#   「だいたい○分」ではなく実測を残すためのもの。
#   終わると simbuild/synth_time.txt に開始・終了・所要分が出る。
# -----------------------------------------------------------------------------
ROOT=E:/fpga/kria260/kaleidoscope
OUT=$ROOT/simbuild/synth_time.txt
LOG=$ROOT/simbuild/synth.log

mkdir -p "$ROOT/simbuild"
START=$(date +%s)
echo "開始 $(date '+%Y-%m-%d %H:%M:%S')" | tee "$OUT"

"E:/vivado/2025.2/Vivado/bin/vivado.bat" -mode batch -source "$ROOT/vivado.tcl" > "$LOG" 2>&1
RC=$?

END=$(date +%s)
echo "終了 $(date '+%Y-%m-%d %H:%M:%S')" | tee -a "$OUT"
echo "所要 $(( (END-START)/60 )) 分 $(( (END-START)%60 )) 秒   終了コード $RC" | tee -a "$OUT"
exit $RC
