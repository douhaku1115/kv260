# ============================================================
#  万華鏡 (kaleidoscope) — Vivado プロジェクト生成スクリプト
#
#  KV260 の PL でピクセルを生成し、PS の DisplayPort に
#  Live Video として流す (HDMI 出力)。kv260_rect を土台にしている。
#
#  使い方:
#    E:\vivado\2025.2\Vivado\bin\vivado.bat -mode batch \
#        -source E:/fpga/kria260/kaleidoscope/vivado.tcl
# ============================================================

set script_dir [file dirname [file normalize [info script]]]

set board_type      kv260
set rtl_top_name    rtl_top
set rtl_files [list \
  $script_dir/rtl/rtl_top.v \
  $script_dir/rtl/cdc_synchronizer.v \
  $script_dir/rtl/shift_register.v \
  $script_dir/rtl/vga_iface.v \
  $script_dir/rtl/divq.v \
  $script_dir/rtl/scope_stage.v \
  $script_dir/rtl/scope_pipe.v \
  $script_dir/rtl/cell_mem.v \
  $script_dir/rtl/kaleido_axi_slave.v \
  $script_dir/rtl/font_rom.v \
  $script_dir/rtl/pcordic.v \
  $script_dir/rtl/ptrans.v \
  $script_dir/rtl/pshade_lane.v \
  $script_dir/rtl/ppixgen.v \
  $script_dir/rtl/pshade_seq.v \
  $script_dir/rtl/pdriver.v \
]
# $readmemh が読む表。tools/gen_hex.py が作る
set hex_files [list \
  $script_dir/rtl/recip_lut.hex \
  $script_dir/rtl/loss_lut.hex \
  $script_dir/rtl/seam_lut.hex \
  $script_dir/rtl/cell_back_init.hex \
  $script_dir/rtl/cell_front_init.hex \
  $script_dir/rtl/font_rom.hex \
  $script_dir/rtl/log2_lut.hex \
  $script_dir/rtl/exp2_lut.hex \
  $script_dir/rtl/atan_lut.hex \
  $script_dir/rtl/pprog.hex \
  $script_dir/rtl/pprog_base.hex \
  $script_dir/rtl/pprog_len.hex \
  $script_dir/rtl/pprog_pre.hex \
  $script_dir/rtl/pparts.hex \
  $script_dir/rtl/cell_oil.hex \
]
set pin_xdc_file    $script_dir/pins.xdc
set timing_xdc_file $script_dir/timings.xdc
set project_name    project_1
set project_dir     $script_dir/project_1
set design_name     design_1
set ps_ip           xilinx.com:ip:zynq_ultra_ps_e
set ps_name         zynq_ultra_ps_e_0
set init_rule       xilinx.com:bd_rule:zynq_ultra_ps_e
set rtl_top_instance ${rtl_top_name}_0
set axi_slave_name   kaleido_axi_slave
set axi_slave_instance ${axi_slave_name}_0

set board_parts [get_board_parts "*:kv260_som:*" -latest_file_version]
set som_connection {som240_1_connector xilinx.com:kv260_carrier:som240_1_connector:1.3}

create_project -name $project_name -force -dir $project_dir -part [get_property PART_NAME $board_parts]
set_property board_part $board_parts [current_project]

add_files -fileset constrs_1 -norecurse $pin_xdc_file
add_files -fileset constrs_1 -norecurse $timing_xdc_file
# timings.xdc は配置配線でだけ使う (合成時はブロックデザインの階層名がまだ無い)
set_property used_in_synthesis false [get_files $timing_xdc_file]
add_files -fileset sources_1 -norecurse $rtl_files
add_files -fileset sources_1 -norecurse $hex_files
foreach h $hex_files {
  set_property file_type {Memory Initialization Files} [get_files $h]
}

set_property board_connections $som_connection [current_project]

create_bd_design $design_name
current_bd_design $design_name
set top_instance [get_bd_cells /]
current_bd_instance $top_instance

# ---- PS ----
create_bd_cell -type ip -vlnv $ps_ip $ps_name
apply_bd_automation -rule $init_rule -config {apply_board_preset "1"} [get_bd_cells $ps_name]

set_property -dict [list \
CONFIG.PSU__USE__M_AXI_GP0  {1} \
CONFIG.PSU__USE__M_AXI_GP1  {0} \
CONFIG.PSU__USE__IRQ0 {0} \
CONFIG.PSU__FPGA_PL1_ENABLE {0} \
CONFIG.PSU__USE__AUDIO {0} \
CONFIG.PSU__USE__VIDEO {1} \
] [get_bd_cells $ps_name]

# ---- PL 内部クロック (pl_clk0 から生成) ----
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property -dict [list \
CONFIG.PRIM_SOURCE {Global_buffer} \
CONFIG.RESET_TYPE {ACTIVE_LOW} \
] [get_bd_cells clk_wiz_0]

# ---- 自作 RTL ----
create_bd_cell -type module -reference $rtl_top_name $rtl_top_instance
create_bd_cell -type module -reference $axi_slave_name $axi_slave_instance

# ---- AXI 周り (リセット同期 + インターコネクト) ----
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0
set_property CONFIG.NUM_MI {1} [get_bd_cells axi_interconnect_0]

# ---- 配線 ----
connect_bd_net [get_bd_pins ${ps_name}/pl_clk0]    [get_bd_pins clk_wiz_0/clk_in1]
connect_bd_net [get_bd_pins ${ps_name}/pl_resetn0] [get_bd_pins clk_wiz_0/resetn]
connect_bd_net [get_bd_pins ${rtl_top_instance}/clk]    [get_bd_pins clk_wiz_0/clk_out1]
connect_bd_net [get_bd_pins ${rtl_top_instance}/resetn] [get_bd_pins clk_wiz_0/locked]

# 画素クロック: DP の video ref clk を折り返して PL の画素クロックとして使う
# AXI スレーブも同じ画素クロックを受ける (フレーム先頭でパラメータを取り込むため)
connect_bd_net [get_bd_pins ${rtl_top_instance}/clkv] \
               [get_bd_pins ${axi_slave_instance}/clkv] \
               [get_bd_pins ${ps_name}/dp_video_in_clk] \
               [get_bd_pins ${ps_name}/dp_video_ref_clk]

# Live Video 入力 (36bit = 12bit/ch)
connect_bd_net [get_bd_pins ${rtl_top_instance}/video_color]   [get_bd_pins ${ps_name}/dp_live_video_in_pixel1]
connect_bd_net [get_bd_pins ${rtl_top_instance}/video_de]      [get_bd_pins ${ps_name}/dp_live_video_in_de]
connect_bd_net [get_bd_pins ${rtl_top_instance}/video_hsyncn]  [get_bd_pins ${ps_name}/dp_live_video_in_hsync]
connect_bd_net [get_bd_pins ${rtl_top_instance}/video_vsyncn]  [get_bd_pins ${ps_name}/dp_live_video_in_vsync]

# ---- AXI: PS マスタ → Interconnect → kaleido_axi_slave ----
set axi_clk [get_bd_pins clk_wiz_0/clk_out1]
connect_bd_net $axi_clk [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked]     [get_bd_pins proc_sys_reset_0/dcm_locked]
connect_bd_net [get_bd_pins ${ps_name}/pl_resetn0] [get_bd_pins proc_sys_reset_0/ext_reset_in]

connect_bd_net $axi_clk [get_bd_pins axi_interconnect_0/ACLK]
connect_bd_net $axi_clk [get_bd_pins axi_interconnect_0/S00_ACLK]
connect_bd_net $axi_clk [get_bd_pins axi_interconnect_0/M00_ACLK]
connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] [get_bd_pins axi_interconnect_0/ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn]   [get_bd_pins axi_interconnect_0/S00_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn]   [get_bd_pins axi_interconnect_0/M00_ARESETN]

connect_bd_net $axi_clk [get_bd_pins ${ps_name}/maxihpm0_fpd_aclk]
connect_bd_intf_net [get_bd_intf_pins ${ps_name}/M_AXI_HPM0_FPD] [get_bd_intf_pins axi_interconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI] [get_bd_intf_pins ${axi_slave_instance}/S_AXI]
connect_bd_net $axi_clk [get_bd_pins ${axi_slave_instance}/S_AXI_ACLK]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins ${axi_slave_instance}/S_AXI_ARESETN]

# ---- AXI スレーブ ↔ rtl_top (映像クロック領域で確定したパラメータ) ----
connect_bd_net [get_bd_pins ${rtl_top_instance}/frame_start] [get_bd_pins ${axi_slave_instance}/frame_start]
foreach sig {kx z_mirror remain0 inv_tr cos_t sin_t nx0 ny0 wd0 nx1 ny1 wd1 nx2 ny2 wd2 vx0 vy0 vx1 vy1 vx2 vy2 mirror2 text_on} {
  connect_bd_net [get_bd_pins ${axi_slave_instance}/v_$sig] [get_bd_pins ${rtl_top_instance}/p_$sig]
}
# 画面に出す文字: rtl_top がアドレスを出し、AXI スレーブの中の RAM が返す
connect_bd_net [get_bd_pins ${rtl_top_instance}/text_addr] [get_bd_pins ${axi_slave_instance}/text_addr]
connect_bd_net [get_bd_pins ${axi_slave_instance}/text_ch] [get_bd_pins ${rtl_top_instance}/text_ch]

# ---- アドレス割当: 0xA0000000 (2KB。0x400 以降に文字を置くため) ----
assign_bd_address -target_address_space [get_bd_addr_spaces ${ps_name}/Data]     [get_bd_addr_segs ${axi_slave_instance}/S_AXI/reg0]     -range 2K -offset 0xA0000000

# ---- ラッパ ----
current_bd_instance $top_instance
make_wrapper -files [get_files $project_dir/${project_name}.srcs/sources_1/bd/$design_name/${design_name}.bd] -top
add_files -norecurse $project_dir/${project_name}.gen/sources_1/bd/$design_name/hdl/${design_name}_wrapper.v
set_property top ${design_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1
validate_bd_design
regenerate_bd_layout
save_bd_design

# ---- 合成 → 配置配線 → ビットストリーム → XSA ----
launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

write_hw_platform -fixed -force -include_bit $project_dir/${design_name}_wrapper.xsa
exit
