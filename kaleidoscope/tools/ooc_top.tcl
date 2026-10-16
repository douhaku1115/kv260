# ============================================================
#  rtl_top だけを単体で合成して、資源を実測する（配置配線はしない）。
#
#  本合成は 45〜55 分かかる。LUT が入るかどうかだけ知りたいときに、
#  これを先に回せば **数分**で分かる。入らない設計のまま本合成を回して
#  36 分を捨てたことがある（段5d-5 で LUT 99.99%、配置できず）。
#
#    E:\vivado\2025.2\Vivado\bin\vivado.bat -mode batch \
#        -source E:/fpga/kria260/kaleidoscope/tools/ooc_top.tcl
#
#  ★ ここで出る数字は目安。本合成ではブロックデザイン（PS・AXI・clk_wiz）の
#    ぶんが上乗せされる。段5d-4 の実測では rtl_top 単体 86339 に対し
#    全体 86339（ほぼ同じ）だったので、差は小さい。
# ============================================================

set root E:/fpga/kria260/kaleidoscope
set part xck26-sfvc784-2LV-c

create_project -in_memory -part $part

read_verilog [list \
  $root/rtl/rtl_top.v \
  $root/rtl/cdc_synchronizer.v \
  $root/rtl/shift_register.v \
  $root/rtl/vga_iface.v \
  $root/rtl/divq.v \
  $root/rtl/scope_stage.v \
  $root/rtl/scope_pipe.v \
  $root/rtl/cell_mem.v \
  $root/rtl/cell_uram.v \
  $root/rtl/cell_dbuf.v \
  $root/rtl/font_rom.v \
  $root/rtl/pcordic.v \
  $root/rtl/ptrans.v \
  $root/rtl/pshade_lane.v \
  $root/rtl/ppixgen.v \
  $root/rtl/pshade_seq.v \
  $root/rtl/pdriver.v \
]
foreach h {recip_lut.hex loss_lut.hex seam_lut.hex font_rom.hex \
           log2_lut.hex exp2_lut.hex atan_lut.hex \
           pprog.hex pprog_base.hex pprog_len.hex pprog_pre.hex pparts.hex \
           cell_oil.hex} {
  add_files $root/rtl/$h
  set_property file_type {Memory Initialization Files} [get_files $root/rtl/$h]
}

synth_design -top rtl_top -mode out_of_context -part $part

puts "\n================ rtl_top の資源 ================"
report_utilization

puts "\n================ 大きいものから ================"
report_utilization -hierarchical -hierarchical_depth 2
exit
