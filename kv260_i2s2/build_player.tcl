# =============================================================================
# build_player.tcl -- 段4 音声ファイル再生: プロジェクト生成 + ビルド
#   実行: vivado -mode batch -source build_player.tcl
#   生成物: vivado_player/i2s2_player.runs/impl_1/design_1_wrapper.bit
#   音源  : audio/audio_rom.hex (4秒, 48828Hz, 16ビット単音)
#   書込  : scp -O <bit> petalinux@<IP>:~/player.bit
#           sudo fpgautil -b ~/player.bit
#           sudo devmem 0xFF5E00C0 32 0x01010A00
# =============================================================================
set origin_dir [file normalize [file dirname [info script]]]
set proj_name  i2s2_player
set proj_dir   $origin_dir/vivado_player
set part       xck26-sfvc784-2LV-c
set board      xilinx.com:kv260_som:part0:1.4

create_project $proj_name $proj_dir -part $part -force
set_property board_part $board [current_project]

# ---- ソース追加 (再生回路 + 音声データ) ----
add_files -norecurse [list $origin_dir/rtl/i2s_player.v $origin_dir/audio/audio_rom.hex]
set_property file_type {Memory Initialization Files} [get_files audio_rom.hex]
add_files -fileset constrs_1 -norecurse $origin_dir/constraints/pmod_i2s2.xdc
update_compile_order -fileset sources_1

# ---- ブロックデザイン (動作実績のあるトーン版と同一構成) ----
create_bd_design design_1

set ps_vlnv  [lindex [lsort [get_ipdefs -all *:ip:zynq_ultra_ps_e:*]] end]
set clk_vlnv [lindex [lsort [get_ipdefs -all *:ip:clk_wiz:*]] end]

create_bd_cell -type ip -vlnv $ps_vlnv ps
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset 1} [get_bd_cells ps]
set_property -dict [list CONFIG.PSU__FPGA_PL0_ENABLE {1} CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} CONFIG.PSU__USE__M_AXI_GP0 {0} CONFIG.PSU__USE__M_AXI_GP1 {0}] [get_bd_cells ps]

create_bd_cell -type ip -vlnv $clk_vlnv clk
set_property -dict [list CONFIG.PRIM_SOURCE {No_buffer} CONFIG.PRIM_IN_FREQ {99.999001} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {12.500} CONFIG.USE_LOCKED {true} CONFIG.USE_RESET {false}] [get_bd_cells clk]

create_bd_cell -type module -reference i2s_player i2s

connect_bd_net [get_bd_pins ps/pl_clk0]   [get_bd_pins clk/clk_in1]
connect_bd_net [get_bd_pins clk/clk_out1] [get_bd_pins i2s/mclk]
connect_bd_net [get_bd_pins clk/locked]   [get_bd_pins i2s/rst_n]

create_bd_port -dir O -type clk pmod_mclk
connect_bd_net [get_bd_pins i2s/mclk_o] [get_bd_port pmod_mclk]
create_bd_port -dir O pmod_sclk
connect_bd_net [get_bd_pins i2s/sclk] [get_bd_port pmod_sclk]
create_bd_port -dir O pmod_lrck
connect_bd_net [get_bd_pins i2s/lrck] [get_bd_port pmod_lrck]
create_bd_port -dir O pmod_sdin
connect_bd_net [get_bd_pins i2s/sdout] [get_bd_port pmod_sdin]

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
puts " i2s2_player ビルド完了"
puts "  bit: $proj_dir/$proj_name.runs/impl_1/design_1_wrapper.bit"
puts "==============================================================="
exit
