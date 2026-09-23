# ============================================================
#  演算器 1 レーンだけを単体で合成して、面積を実測する。
#
#  ピース描画の演算器を何個並べられるかを決めるための測定。
#  見積もりで決めると外すので、実際に合成して LUT / FF / DSP / BRAM を数える。
#
#    E:\vivado\2025.2\Vivado\bin\vivado.bat -mode batch \
#        -source E:/fpga/kria260/kaleidoscope/tools/ooc_lane.tcl
# ============================================================

set root E:/fpga/kria260/kaleidoscope
set part xck26-sfvc784-2LV-c

create_project -in_memory -part $part

read_verilog [list \
  $root/rtl/pcordic.v \
  $root/rtl/ptrans.v \
  $root/rtl/pshade_lane.v \
]
foreach h {log2_lut.hex exp2_lut.hex atan_lut.hex} {
  add_files $root/rtl/$h
  set_property file_type {Memory Initialization Files} [get_files $root/rtl/$h]
}

read_xdc $root/tools/ooc_lane.xdc

synth_design -top pshade_lane -mode out_of_context -part $part

puts "\n================ 演算器 1 レーンの面積 ================"
report_utilization -hierarchical
puts "\n================ タイミング ================"
report_timing_summary -max_paths 1
exit
