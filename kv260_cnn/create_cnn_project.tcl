# =============================================================================
# create_cnn_project.tcl -- 段13 段階C: MNIST CNN の Vivado プロジェクトを作り、
#                           ビットストリームまで一気に生成する
#
#   構成: Zynq PS ──AXI4-Lite(0xA0000000)──> cnn_axi ──> cnn_core
#         外部ピンは使わない（画像も結果も AXI 経由でやり取りする）
#
#   実行:
#     E:\vivado\2025.2\Vivado\bin\vivado.bat -mode batch \
#       -source E:/fpga/kria260/kv260_cnn/create_cnn_project.tcl
#   （-source には必ずフルパスを渡すこと）
#
#   出力: vivado/cnn_mnist.runs/impl_1/design_1_wrapper.bit
#         これを KV260 へ scp し、fpgautil で書き込む。
# =============================================================================
set origin_dir [file normalize [file dirname [info script]]]
set proj_name  cnn_mnist
set proj_dir   $origin_dir/vivado
set part       xck26-sfvc784-2LV-c
set board      xilinx.com:kv260_som:part0:1.4

create_project $proj_name $proj_dir -part $part -force
set_property board_part $board [current_project]

# ---- ソース ----
add_files -norecurse [list \
    $origin_dir/rtl/conv3x3.v \
    $origin_dir/rtl/maxpool2.v \
    $origin_dir/rtl/fc.v \
    $origin_dir/rtl/cnn_core.v \
    $origin_dir/rtl/cnn_axi.v \
    $origin_dir/rtl/cnn_param.vh \
    $origin_dir/rtl/conv1_w.hex $origin_dir/rtl/conv1_b.hex \
    $origin_dir/rtl/conv2_w.hex $origin_dir/rtl/conv2_b.hex \
    $origin_dir/rtl/fc_w.hex    $origin_dir/rtl/fc_b.hex ]

# 係数は $readmemh で読むので「メモリ初期化ファイル」と教える
foreach h {conv1_w conv1_b conv2_w conv2_b fc_w fc_b} {
    set_property file_type {Memory Initialization Files} [get_files $h.hex]
}

# cnn_core.v が `include "cnn_param.vh"` するので探し場所を教える
#   プロジェクトに追加したうえで「Verilog Header」と教える。
#   追加していないと create_bd_cell（RTL をブロックデザインに載せる段）で弾かれる。
set_property file_type {Verilog Header} [get_files cnn_param.vh]
set_property include_dirs [list $origin_dir/rtl] [get_filesets sources_1]

add_files -fileset sim_1 -norecurse [list \
    $origin_dir/sim/tb_cnn_core.v $origin_dir/sim/tb_cnn_axi.v]
update_compile_order -fileset sources_1

# =============================================================================
# ブロックデザイン
# =============================================================================
create_bd_design design_1

# IP のバージョンは入っているものを自動で拾う（版ずれで落ちないように）
set ps_vlnv [lindex [lsort [get_ipdefs -all *:ip:zynq_ultra_ps_e:*]] end]
puts "Using PS VLNV : $ps_vlnv"

# ---- PS ----
#   PL0 を 100MHz で出し、AXI マスタ GP0（M_AXI_HPM0_FPD）を有効にする。
#   データ幅は 32 ビット。レジスタを 0x10 刻みに整列させてあるのはこのため。
create_bd_cell -type ip -vlnv $ps_vlnv ps
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset 1} [get_bd_cells ps]
set_property -dict [list \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
] [get_bd_cells ps]

# ---- リセット生成 ----
#   段11 と違い clk_wiz を使わず PL0(100MHz) をそのまま使うので、
#   dcm_locked は定数 1 を与える（未接続だと 0 と見なされて解除されない）。
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst
create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 one
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {1}] [get_bd_cells one]

# ---- AXI Interconnect ----
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic
set_property CONFIG.NUM_MI {1} [get_bd_cells axi_ic]

# ---- 自作モジュール ----
create_bd_cell -type module -reference cnn_axi cnn

# ---- クロック（全部 100MHz の単一クロック）----
set aclk [get_bd_pins ps/pl_clk0]

connect_bd_net $aclk                       [get_bd_pins rst/slowest_sync_clk]
connect_bd_net [get_bd_pins one/dout]      [get_bd_pins rst/dcm_locked]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins rst/ext_reset_in]

connect_bd_net $aclk [get_bd_pins axi_ic/ACLK]
connect_bd_net $aclk [get_bd_pins axi_ic/S00_ACLK]
connect_bd_net $aclk [get_bd_pins axi_ic/M00_ACLK]
connect_bd_net [get_bd_pins rst/interconnect_aresetn] [get_bd_pins axi_ic/ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn]   [get_bd_pins axi_ic/S00_ARESETN]
connect_bd_net [get_bd_pins rst/peripheral_aresetn]   [get_bd_pins axi_ic/M00_ARESETN]

# ---- PS の AXI マスタ → Interconnect ----
connect_bd_net $aclk [get_bd_pins ps/maxihpm0_fpd_aclk]
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins axi_ic/S00_AXI]

# ---- Interconnect → 自作モジュール ----
#   ★クロック・リセットを先に繋ぎ、インターフェースを後に繋ぐ。
#     段11 でこの順序を崩したら実機で動かなくなった。順序を変えないこと。
connect_bd_net $aclk [get_bd_pins cnn/S_AXI_ACLK]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins cnn/S_AXI_ARESETN]
connect_bd_intf_net [get_bd_intf_pins axi_ic/M00_AXI] [get_bd_intf_pins cnn/S_AXI]

# ---- アドレス割り当て: 0xA000_0000 ----
assign_bd_address -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs cnn/S_AXI/reg0] -range 4K -offset 0xA0000000

regenerate_bd_layout
validate_bd_design
save_bd_design

# ---- ラッパ生成 ----
make_wrapper -files [get_files $proj_dir/$proj_name.srcs/sources_1/bd/design_1/design_1.bd] -top
add_files -norecurse $proj_dir/$proj_name.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

# =============================================================================
# 合成・実装・ビットストリーム
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

# ---- 結果の報告 ----
open_run impl_1
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts "=========================================="
puts "  タイミング余裕 WNS = $wns ns （負なら不合格）"
report_utilization -hierarchical -file $origin_dir/vivado/utilization.txt
puts "  資源の使用量: vivado/utilization.txt"
set bit $proj_dir/$proj_name.runs/impl_1/design_1_wrapper.bit
puts "  ビットストリーム: $bit"
puts "=========================================="
