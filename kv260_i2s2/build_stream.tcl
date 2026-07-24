# =============================================================================
# build_stream.tcl -- 段5 長時間再生: プロジェクト生成 + ビルド
#   実行: vivado -mode batch -source build_stream.tcl
#   生成物: vivado_stream/i2s2_stream.runs/impl_1/design_1_wrapper.bit
#
#   構成: Zynq PS ─AXI4-Lite─> i2s_stream_axi ─I2S─> Pmod I2S2
#         PS(Linux)が音声標本をFIFOに流し込み、PLが取り出して送出する
#   ベースアドレス: 0xA000_0000
# =============================================================================
set origin_dir [file normalize [file dirname [info script]]]
set proj_name  i2s2_stream
set proj_dir   $origin_dir/vivado_stream
set part       xck26-sfvc784-2LV-c
set board      xilinx.com:kv260_som:part0:1.4

create_project $proj_name $proj_dir -part $part -force
set_property board_part $board [current_project]

# ---- ソース追加 ----
add_files -norecurse [list $origin_dir/rtl/i2s_stream_axi.v $origin_dir/rtl/audio_fifo.v $origin_dir/rtl/audio_fx.v]
add_files -fileset constrs_1 -norecurse $origin_dir/constraints/pmod_i2s2.xdc
update_compile_order -fileset sources_1

# ---- ブロックデザイン ----
create_bd_design design_1

set ps_vlnv  [lindex [lsort [get_ipdefs -all *:ip:zynq_ultra_ps_e:*]] end]
set clk_vlnv [lindex [lsort [get_ipdefs -all *:ip:clk_wiz:*]] end]

# PS: AXI マスタ(GP0)を有効化
create_bd_cell -type ip -vlnv $ps_vlnv ps
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset 1} [get_bd_cells ps]
set_property -dict [list \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
  CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
] [get_bd_cells ps]

# clk_wiz: 12.5MHz (I2S用 mclk)
create_bd_cell -type ip -vlnv $clk_vlnv clk
set_property -dict [list CONFIG.PRIM_SOURCE {No_buffer} CONFIG.PRIM_IN_FREQ {99.999001} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {12.500} CONFIG.USE_LOCKED {true} CONFIG.USE_RESET {false}] [get_bd_cells clk]

# Processor System Reset (AXI用のリセット生成)
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 rst
# AXI Interconnect (PSのAXI4 と 自作のAXI4-Lite を仲介する)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic
set_property CONFIG.NUM_MI {1} [get_bd_cells axi_ic]

# 自作モジュール
create_bd_cell -type module -reference i2s_stream_axi i2s

# ---- クロック接続（単一クロック構成: すべて 12.5MHz） ----
#   AXI と I2S を同じクロックで動かし、クロック間の受け渡しを無くす
#   （異クロックだと標本を取りこぼす。12.5MHz でも AXI は十分な速さ）
#   ※ 合成時に出る「Port ACLK is either unconnected」警告は無害。
#      動作実績のある kv260_mips でも同じ警告が出る。これを消そうとして
#      接続順序を変えると音が出なくなる。
connect_bd_net [get_bd_pins ps/pl_clk0]   [get_bd_pins clk/clk_in1]
set aclk [get_bd_pins clk/clk_out1]

# ---- リセット生成 ----
connect_bd_net $aclk                       [get_bd_pins rst/slowest_sync_clk]
connect_bd_net [get_bd_pins clk/locked]    [get_bd_pins rst/dcm_locked]
connect_bd_net [get_bd_pins ps/pl_resetn0] [get_bd_pins rst/ext_reset_in]

# ---- AXI Interconnect のクロック・リセット ----
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
#   ★この順序（クロック・リセットを先、インターフェースを後）が実機で音が出た構成。
#     kv260_mips に合わせて逆順にしたところ音が出なくなった。順序を変えないこと。
connect_bd_net $aclk [get_bd_pins i2s/S_AXI_ACLK]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins i2s/S_AXI_ARESETN]
connect_bd_intf_net [get_bd_intf_pins axi_ic/M00_AXI] [get_bd_intf_pins i2s/S_AXI]

# ---- I2S 出力ポート ----
create_bd_port -dir O -type clk pmod_mclk
connect_bd_net [get_bd_pins i2s/mclk_o] [get_bd_port pmod_mclk]
create_bd_port -dir O pmod_sclk
connect_bd_net [get_bd_pins i2s/sclk] [get_bd_port pmod_sclk]
create_bd_port -dir O pmod_lrck
connect_bd_net [get_bd_pins i2s/lrck] [get_bd_port pmod_lrck]
create_bd_port -dir O pmod_sdin
connect_bd_net [get_bd_pins i2s/sdout] [get_bd_port pmod_sdin]

# ---- アドレス割り当て: 0xA000_0000 ----
assign_bd_address -target_address_space [get_bd_addr_spaces ps/Data] \
    [get_bd_addr_segs i2s/S_AXI/reg0] -range 4K -offset 0xA0000000

regenerate_bd_layout
validate_bd_design
save_bd_design

make_wrapper -files [get_files $proj_dir/$proj_name.srcs/sources_1/bd/design_1/design_1.bd] -top
add_files -norecurse $proj_dir/$proj_name.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

# ---- 合成 -> 実装 -> ビットストリーム ----
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set pr [get_property PROGRESS [get_runs impl_1]]
if {$pr ne "100%"} { puts "BUILD FAILED (progress=$pr)"; exit 1 }
puts "==============================================================="
puts " i2s2_stream ビルド完了"
puts "  bit: $proj_dir/$proj_name.runs/impl_1/design_1_wrapper.bit"
puts "==============================================================="
exit
