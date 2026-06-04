# =============================================================================
# create_i2s2_loop_project.tcl  -- 段2 I2S2 ループバック プロジェクト生成
#   ADC(CS5343) → PL → DAC(CS4344) のマイク→スピーカー ループバック。
#   実行: Vivado 2025.1 の Tcl Console で
#         cd /mnt/data/fpga/projects/kv260_audio/i2s2
#         source create_i2s2_loop_project.tcl
#   または: vivado -mode batch -source create_i2s2_loop_project.tcl
#   生成後、合成/実装/ビットストリームは GUI で各自実行する。
# =============================================================================
set origin_dir [file normalize [file dirname [info script]]]
set proj_name  i2s2_loop
set proj_dir   $origin_dir/vivado_loop
set part       xck26-sfvc784-2LV-c
set board      xilinx.com:kv260_som:part0:1.4

create_project $proj_name $proj_dir -part $part -force
set_property board_part $board [current_project]

# ---- ソース追加 ----
add_files -norecurse [list $origin_dir/rtl/i2s_loop.v]
add_files -fileset constrs_1 -norecurse $origin_dir/constraints/pmod_i2s2_loop.xdc
update_compile_order -fileset sources_1

# ---- ブロックデザイン ----
create_bd_design design_1

# IP VLNVはインストール済みの最新版を自動取得(バージョン差で落ちないように)
set ps_vlnv  [lindex [lsort [get_ipdefs -all *:ip:zynq_ultra_ps_e:*]] end]
set clk_vlnv [lindex [lsort [get_ipdefs -all *:ip:clk_wiz:*]] end]
puts "Using PS VLNV : $ps_vlnv"
puts "Using CLK VLNV: $clk_vlnv"

create_bd_cell -type ip -vlnv $ps_vlnv ps
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset 1} [get_bd_cells ps]
set_property -dict [list CONFIG.PSU__FPGA_PL0_ENABLE {1} CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} CONFIG.PSU__USE__M_AXI_GP0 {0} CONFIG.PSU__USE__M_AXI_GP1 {0}] [get_bd_cells ps]

create_bd_cell -type ip -vlnv $clk_vlnv clk
set_property -dict [list CONFIG.PRIM_SOURCE {No_buffer} CONFIG.PRIM_IN_FREQ {99.999001} CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {12.500} CONFIG.USE_LOCKED {true} CONFIG.USE_RESET {false}] [get_bd_cells clk]

create_bd_cell -type module -reference i2s_loop i2s

connect_bd_net [get_bd_pins ps/pl_clk0]   [get_bd_pins clk/clk_in1]
connect_bd_net [get_bd_pins clk/clk_out1] [get_bd_pins i2s/mclk]
connect_bd_net [get_bd_pins clk/locked]   [get_bd_pins i2s/rst_n]

# ---- 外部ポート (XDC のポート名と一致させる) ----
# DAC (出力)
create_bd_port -dir O -type clk dac_mclk
connect_bd_net [get_bd_pins i2s/dac_mclk] [get_bd_port dac_mclk]
create_bd_port -dir O dac_sclk
connect_bd_net [get_bd_pins i2s/dac_sclk] [get_bd_port dac_sclk]
create_bd_port -dir O dac_lrck
connect_bd_net [get_bd_pins i2s/dac_lrck] [get_bd_port dac_lrck]
create_bd_port -dir O dac_sdin
connect_bd_net [get_bd_pins i2s/dac_sdin] [get_bd_port dac_sdin]
# ADC (クロックは出力、SDOUTは入力)
create_bd_port -dir O -type clk adc_mclk
connect_bd_net [get_bd_pins i2s/adc_mclk] [get_bd_port adc_mclk]
create_bd_port -dir O adc_sclk
connect_bd_net [get_bd_pins i2s/adc_sclk] [get_bd_port adc_sclk]
create_bd_port -dir O adc_lrck
connect_bd_net [get_bd_pins i2s/adc_lrck] [get_bd_port adc_lrck]
create_bd_port -dir I adc_sdout
connect_bd_net [get_bd_port adc_sdout] [get_bd_pins i2s/adc_sdout]

regenerate_bd_layout
validate_bd_design
save_bd_design

# ---- ラッパ生成 & トップ設定 ----
make_wrapper -files [get_files $proj_dir/$proj_name.srcs/sources_1/bd/design_1/design_1.bd] -top
add_files -norecurse $proj_dir/$proj_name.gen/sources_1/bd/design_1/hdl/design_1_wrapper.v
set_property top design_1_wrapper [current_fileset]
update_compile_order -fileset sources_1

puts "==============================================================="
puts " i2s2_loop プロジェクト生成完了"
puts "  - トップ: design_1_wrapper"
puts "  - 外部ポート: dac_mclk/sclk/lrck/sdin, adc_mclk/sclk/lrck/sdout"
puts " 次: Generate Bitstream(各自) → JTAG書込 → devmemでPL0クロック有効化"
puts "==============================================================="
