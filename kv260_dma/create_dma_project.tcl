# =============================================================================
# create_dma_project.tcl -- 段15: PL の DMA で DDR の帯域を測る
#
#   構成:
#     PS ──HPM0(AXI4-Lite)──> axi_ic ─┬─> AXI DMA の設定窓口  0xA0000000
#                                      └─> AXI GPIO(mode 1本) 0xA0010000
#     AXI DMA(SGなし, 128bit, バースト256)
#        M_AXI_MM2S(読む) ─┐
#        M_AXI_S2MM(書く) ─┴─> SmartConnect ──> PS の S_AXI_HP0_FPD ──> DDR
#        M_AXIS_MM2S ──> axis_route ──> S_AXIS_S2MM
#                          mode=0: 複写  mode=1: 読み捨て
#   クロックは全部 pl_clk0 = 250MHz（128bit × 250MHz = 片方向 4.0 GB/s が上限）
#
#   IP の設定名は Vivado 2025.2 に問い合わせて確かめたもの
#     axi_dma 7.1 / axi_gpio 2.0 / zynq_ultra_ps_e 3.5 / smartconnect 1.0
#     S_AXI_HP0_FPD は PSU__USE__S_AXI_GP2、クロックピンは saxihp0_fpd_aclk
#
#   実行:
#     E:\vivado\2025.2\Vivado\bin\vivado.bat -mode batch \
#       -source E:/fpga/kria260/kv260_dma/create_dma_project.tcl
#   出力: vivado/dma_bw.runs/impl_1/design_1_wrapper.bit
# =============================================================================
set origin_dir [file normalize [file dirname [info script]]]
set proj_name  dma_bw
set proj_dir   $origin_dir/vivado
set part       xck26-sfvc784-2LV-c
set board      xilinx.com:kv260_som:part0:1.4

create_project $proj_name $proj_dir -part $part -force
set_property board_part $board [current_project]

add_files -norecurse [list $origin_dir/rtl/axis_route.v]
update_compile_order -fileset sources_1

create_bd_design design_1

set ps_vlnv   [lindex [lsort [get_ipdefs -all *:ip:zynq_ultra_ps_e:*]] end]
set dma_vlnv  [lindex [lsort [get_ipdefs -all *:ip:axi_dma:*]] end]
set gpio_vlnv [lindex [lsort [get_ipdefs -all *:ip:axi_gpio:*]] end]
set sc_vlnv   [lindex [lsort [get_ipdefs -all *:ip:smartconnect:*]] end]
puts "Using: $ps_vlnv $dma_vlnv $gpio_vlnv $sc_vlnv"

# ---- PS ----
create_bd_cell -type ip -vlnv $ps_vlnv ps
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset 1} [get_bd_cells ps]
set_property -dict [list \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {250} \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__SAXIGP2__DATA_WIDTH {128} \
] [get_bd_cells ps]

# ---- リセット ----
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 one
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] [get_bd_cells one]

# ---- AXI DMA（単純モード）----
#   c_sg_length_width=26 → 1 回で最大 64MB-1 バイト
#   c_addr_width=32 で足りる（使うのは 0x60000000〜0x67FFFFFF）
create_bd_cell -type ip -vlnv $dma_vlnv dma
set_property -dict [list \
  CONFIG.c_include_sg {0} \
  CONFIG.c_sg_length_width {26} \
  CONFIG.c_addr_width {32} \
  CONFIG.c_m_axi_mm2s_data_width {128} \
  CONFIG.c_m_axis_mm2s_tdata_width {128} \
  CONFIG.c_m_axi_s2mm_data_width {128} \
  CONFIG.c_s_axis_s2mm_tdata_width {128} \
  CONFIG.c_mm2s_burst_size {256} \
  CONFIG.c_s2mm_burst_size {256} \
] [get_bd_cells dma]

# ---- AXI GPIO（mode を 1 ビット出す）----
create_bd_cell -type ip -vlnv $gpio_vlnv gpio
set_property -dict [list CONFIG.C_GPIO_WIDTH {1} CONFIG.C_ALL_OUTPUTS {1}] [get_bd_cells gpio]

# ---- 流れの切り替え（自作）----
create_bd_cell -type module -reference axis_route route

# ---- 設定用 Interconnect（HPM0 → DMA 窓口 / GPIO）----
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic
set_property CONFIG.NUM_MI {2} [get_bd_cells axi_ic]

# ---- データ用 SmartConnect（DMA の読み・書き → HP0）----
create_bd_cell -type ip -vlnv $sc_vlnv sc
set_property -dict [list CONFIG.NUM_SI {2} CONFIG.NUM_MI {1}] [get_bd_cells sc]

# ---- クロック・リセット（先に全部つなぐ）----
set aclk [get_bd_pins ps/pl_clk0]
set prst [get_bd_pins rst/peripheral_aresetn]

connect_bd_net $aclk                       [get_bd_pins rst/slowest_sync_clk]
connect_bd_net [get_bd_pins one/dout]      [get_bd_pins rst/dcm_locked]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins rst/ext_reset_in]

foreach p {ps/maxihpm0_fpd_aclk ps/saxihp0_fpd_aclk \
           axi_ic/ACLK axi_ic/S00_ACLK axi_ic/M00_ACLK axi_ic/M01_ACLK \
           sc/aclk \
           dma/s_axi_lite_aclk dma/m_axi_mm2s_aclk dma/m_axi_s2mm_aclk \
           gpio/s_axi_aclk route/aclk} {
    connect_bd_net $aclk [get_bd_pins $p]
}
connect_bd_net [get_bd_pins rst/interconnect_aresetn] [get_bd_pins axi_ic/ARESETN]
foreach p {axi_ic/S00_ARESETN axi_ic/M00_ARESETN axi_ic/M01_ARESETN \
           sc/aresetn dma/axi_resetn gpio/s_axi_aresetn route/aresetn} {
    connect_bd_net $prst [get_bd_pins $p]
}

# ---- インターフェース ----
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins axi_ic/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_ic/M00_AXI]    [get_bd_intf_pins dma/S_AXI_LITE]
connect_bd_intf_net [get_bd_intf_pins axi_ic/M01_AXI]    [get_bd_intf_pins gpio/S_AXI]

connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_MM2S] [get_bd_intf_pins sc/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins dma/M_AXI_S2MM] [get_bd_intf_pins sc/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins sc/M00_AXI]     [get_bd_intf_pins ps/S_AXI_HP0_FPD]

connect_bd_intf_net [get_bd_intf_pins dma/M_AXIS_MM2S]   [get_bd_intf_pins route/s_axis]
connect_bd_intf_net [get_bd_intf_pins route/m_axis]      [get_bd_intf_pins dma/S_AXIS_S2MM]
connect_bd_net [get_bd_pins gpio/gpio_io_o] [get_bd_pins route/mode]

# ---- アドレス ----
assign_bd_address -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs dma/S_AXI_LITE/Reg] -range 64K -offset 0xA0000000
assign_bd_address -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs gpio/S_AXI/Reg] -range 64K -offset 0xA0010000
# DMA から見た DDR などは自動で割り当てる
assign_bd_address
puts "---- アドレス割り当て ----"
foreach s [get_bd_addr_segs -excluded false] { puts "  $s" }

regenerate_bd_layout
validate_bd_design
save_bd_design

make_wrapper -files [get_files $proj_dir/$proj_name.srcs/sources_1/bd/design_1/design_1.bd] -top
add_files -norecurse $proj_dir/$proj_name.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

# =============================================================================
launch_runs synth_1 -jobs 8
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "ERROR: 合成に失敗した"
    exit 1
}
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
    puts "ERROR: 実装/ビットストリーム生成に失敗した"
    exit 1
}

open_run impl_1
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts "=========================================="
puts "  タイミング余裕 WNS = $wns ns （負なら不合格）"
report_utilization -file $origin_dir/vivado/utilization.txt
puts "  ビットストリーム: $proj_dir/$proj_name.runs/impl_1/design_1_wrapper.bit"
puts "=========================================="
