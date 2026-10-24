# =============================================================================
# vivado.tcl -- KV260 NES: プロジェクト生成 + ビルド + XSA 出力
#   実行: E:\vivado\2025.2\Vivado\bin\vivado.bat -mode batch -source E:/fpga/kria260/kv260_nes/vivado.tcl
#   生成物: project_1/design_1_wrapper.xsa (ビットストリーム込み)
#   CHIP-8 (kv260_chip8/vivado.tcl) が元。変更点:
#     - clk_wiz を 2 出力 (clk_out1=100MHz: AXI/NES, clk_out2=12.5MHz: I2S の mclk)
#     - Pmod I2S2 の 4 端子 (J2) を外へ出す
#     - AXI の範囲 256KB (画面バッファ・ROM 窓のため)
# =============================================================================
set origin_dir [file normalize [file dirname [info script]]]
cd $origin_dir

set rtl_top_name rtl_top
set rtl_files [list \
    rtl/rtl_top.v rtl/nes_axi_slave.v rtl/nes_fb.v rtl/nes_palette.v \
    rtl/cdc_synchronizer.v rtl/shift_register.v rtl/vga_iface.v \
    rtl/nes_core.v rtl/cpu6502.v rtl/ppu.v rtl/apu.v rtl/mapper.v \
    rtl/i2s_tx.v rtl/apu_pulse.hex rtl/apu_tnd.hex]
set project_name project_1
set project_dir  project_1
set design_name  design_1
set ps_ip   xilinx.com:ip:zynq_ultra_ps_e
set ps_name zynq_ultra_ps_e_0
set init_rule xilinx.com:bd_rule:zynq_ultra_ps_e
set rtl_top_instance ${rtl_top_name}_0
set axi_slave_name nes_axi_slave
set axi_slave_instance ${axi_slave_name}_0

set board_parts [get_board_parts "*:kv260_som:*" -latest_file_version]
set som_connection {som240_1_connector xilinx.com:kv260_carrier:som240_1_connector:1.3}

create_project -name $project_name -force -dir $project_dir -part [get_property PART_NAME $board_parts]
set_property board_part $board_parts [current_project]

add_files -fileset constrs_1 -norecurse pins.xdc
add_files -fileset constrs_1 -norecurse timings.xdc
set_property used_in_synthesis false [get_files timings.xdc]
add_files -fileset sources_1 -norecurse $rtl_files
set_property file_type {Memory Initialization Files} [get_files {apu_pulse.hex apu_tnd.hex}]

set_property board_connections $som_connection [current_project]

create_bd_design $design_name
current_bd_design $design_name
set top_instance [get_bd_cells /]
current_bd_instance $top_instance

# PS — M_AXI_GP0 有効、HDMI(DP) Live Video
create_bd_cell -type ip -vlnv $ps_ip $ps_name
apply_bd_automation -rule $init_rule -config {apply_board_preset "1"} [get_bd_cells $ps_name]

set_property -dict [list \
CONFIG.PSU__USE__M_AXI_GP0  {1} \
CONFIG.PSU__USE__M_AXI_GP1  {0} \
CONFIG.PSU__USE__IRQ0 {0} \
CONFIG.PSU__FPGA_PL1_ENABLE {0} \
CONFIG.PSU__USE__AUDIO {0} \
CONFIG.PSU__USE__VIDEO {1} \
CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
] [get_bd_cells $ps_name]

# Clock wizard: 100MHz + 12.5MHz
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property -dict [list \
CONFIG.PRIM_SOURCE {Global_buffer} \
CONFIG.RESET_TYPE {ACTIVE_LOW} \
CONFIG.CLKOUT2_USED {true} \
CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {12.500} \
] [get_bd_cells clk_wiz_0]

create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0

create_bd_cell -type module -reference $rtl_top_name $rtl_top_instance
create_bd_cell -type module -reference $axi_slave_name $axi_slave_instance

create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0
set_property CONFIG.NUM_MI {1} [get_bd_cells axi_interconnect_0]

# クロック
connect_bd_net [get_bd_pins ${ps_name}/pl_clk0] [get_bd_pins clk_wiz_0/clk_in1]
connect_bd_net [get_bd_pins ${ps_name}/pl_resetn0] [get_bd_pins clk_wiz_0/resetn]

set axi_clk [get_bd_pins clk_wiz_0/clk_out1]

# リセット
connect_bd_net $axi_clk [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins proc_sys_reset_0/dcm_locked]
connect_bd_net [get_bd_pins ${ps_name}/pl_resetn0] [get_bd_pins proc_sys_reset_0/ext_reset_in]

# rtl_top クロック・リセット
connect_bd_net $axi_clk [get_bd_pins ${rtl_top_instance}/clk]
connect_bd_net [get_bd_pins clk_wiz_0/clk_out2] [get_bd_pins ${rtl_top_instance}/mclk]
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins ${rtl_top_instance}/resetn]

# 映像クロック (DP video ref → rtl_top.clkv)
connect_bd_net [get_bd_pins ${rtl_top_instance}/clkv] [get_bd_pins ${ps_name}/dp_video_in_clk] [get_bd_pins ${ps_name}/dp_video_ref_clk]

# 映像 → PS の Live Video
connect_bd_net [get_bd_pins ${rtl_top_instance}/video_color] [get_bd_pins ${ps_name}/dp_live_video_in_pixel1]
connect_bd_net [get_bd_pins ${rtl_top_instance}/video_de] [get_bd_pins ${ps_name}/dp_live_video_in_de]
connect_bd_net [get_bd_pins ${rtl_top_instance}/video_hsyncn] [get_bd_pins ${ps_name}/dp_live_video_in_hsync]
connect_bd_net [get_bd_pins ${rtl_top_instance}/video_vsyncn] [get_bd_pins ${ps_name}/dp_live_video_in_vsync]

# Pmod I2S2 (J2) の端子
create_bd_port -dir O -type clk pmod_mclk
connect_bd_net [get_bd_pins ${rtl_top_instance}/pmod_mclk] [get_bd_port pmod_mclk]
create_bd_port -dir O pmod_sclk
connect_bd_net [get_bd_pins ${rtl_top_instance}/pmod_sclk] [get_bd_port pmod_sclk]
create_bd_port -dir O pmod_lrck
connect_bd_net [get_bd_pins ${rtl_top_instance}/pmod_lrck] [get_bd_port pmod_lrck]
create_bd_port -dir O pmod_sdin
connect_bd_net [get_bd_pins ${rtl_top_instance}/pmod_sdin] [get_bd_port pmod_sdin]

# AXI Interconnect のクロック・リセット
connect_bd_net $axi_clk [get_bd_pins axi_interconnect_0/ACLK]
connect_bd_net $axi_clk [get_bd_pins axi_interconnect_0/S00_ACLK]
connect_bd_net $axi_clk [get_bd_pins axi_interconnect_0/M00_ACLK]
connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] [get_bd_pins axi_interconnect_0/ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_interconnect_0/S00_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_interconnect_0/M00_ARESETN]

# PS → Interconnect → nes_axi_slave
connect_bd_net $axi_clk [get_bd_pins ${ps_name}/maxihpm0_fpd_aclk]
connect_bd_intf_net [get_bd_intf_pins ${ps_name}/M_AXI_HPM0_FPD] [get_bd_intf_pins axi_interconnect_0/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI] [get_bd_intf_pins ${axi_slave_instance}/S_AXI]
connect_bd_net $axi_clk [get_bd_pins ${axi_slave_instance}/S_AXI_ACLK]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins ${axi_slave_instance}/S_AXI_ARESETN]

# nes_axi_slave のバス ↔ rtl_top
foreach p {bus_wr_en bus_wr_addr bus_wr_data bus_rd_addr} {
    connect_bd_net [get_bd_pins ${axi_slave_instance}/$p] [get_bd_pins ${rtl_top_instance}/$p]
}
connect_bd_net [get_bd_pins ${rtl_top_instance}/bus_rd_data] [get_bd_pins ${axi_slave_instance}/bus_rd_data]

# アドレス: 0xA0000000 から 256KB
assign_bd_address -target_address_space [get_bd_addr_spaces ${ps_name}/Data] \
    [get_bd_addr_segs ${axi_slave_instance}/S_AXI/reg0] \
    -range 256K -offset 0xA0000000

current_bd_instance $top_instance
make_wrapper -files [get_files $project_dir/${project_name}.srcs/sources_1/bd/$design_name/${design_name}.bd] -top
add_files -norecurse $project_dir/${project_name}.gen/sources_1/bd/$design_name/hdl/${design_name}_wrapper.v
set_property top ${design_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1
validate_bd_design
regenerate_bd_layout
save_bd_design

# 合成 → 配置配線 → ビットストリーム → XSA
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set pr [get_property PROGRESS [get_runs impl_1]]
if {$pr ne "100%"} { puts "BUILD FAILED (progress=$pr)"; exit 1 }

open_run impl_1
report_timing_summary -file $origin_dir/project_1/timing_summary.txt
report_utilization    -file $origin_dir/project_1/utilization.txt
write_hw_platform -fixed -force -include_bit $origin_dir/project_1/design_1_wrapper.xsa
puts "BUILD OK"
exit
