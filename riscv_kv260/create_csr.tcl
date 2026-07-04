# ============================================================
# RISC-V on KV260 - 第2段 CSR/例外版 (5段 m_proc_csr) VIO project
#   ecall/mret + csrrw/csrrs + CSR(mtvec/mepc/mcause/mscratch)。
#   結果は VIO で読む: probe0=x30(=mcause=0xB=11), probe1=trapcnt(=1)。
#   外部ピン無し(VIOのみ)。
# Usage: vivado -mode batch -source create_csr.tcl
# ============================================================

set project_name "riscv_kv260_csr"
set project_dir  [file dirname [file normalize [info script]]]
set src_dir      "${project_dir}/src"
set proj_dir     "${project_dir}/vivado/${project_name}"

file delete -force ${proj_dir}

create_project ${project_name} ${proj_dir} -part xck26-sfvc784-2LV-c
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]

# 設計ファイル(CSR版) + プログラム
add_files -norecurse ${src_dir}/main_vio_csr.v
add_files -norecurse ${src_dir}/asm_csr.txt
set_property file_type "Verilog Header" [get_files asm_csr.txt]

# ---- clk BD (Zynq PS で pl_clk0 100MHz だけ取り出す) ----
create_bd_design "clk_bd"
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ultra_ps_e_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
  -config {apply_board_preset "1"} [get_bd_cells zynq_ultra_ps_e_0]
set_property -dict [list \
  CONFIG.PSU__USE__M_AXI_GP0 {0} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__M_AXI_GP2 {0} \
  CONFIG.PSU__FPGA_PL0_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
] [get_bd_cells zynq_ultra_ps_e_0]
create_bd_port -dir O -type clk pl_clk0
connect_bd_net [get_bd_pins zynq_ultra_ps_e_0/pl_clk0] [get_bd_ports pl_clk0]
validate_bd_design
save_bd_design

make_wrapper -files [get_files clk_bd.bd] -top
set wrapper_file [file normalize ${proj_dir}/${project_name}.gen/sources_1/bd/clk_bd/hdl/clk_bd_wrapper.v]
add_files -norecurse ${wrapper_file}

# ---- VIO IP (32bit入力2本: probe0=x30結果, probe1=トラップ回数) ----
create_ip -name vio -vendor xilinx.com -library ip -version 3.0 -module_name vio_0
set_property -dict [list \
  CONFIG.C_PROBE_IN0_WIDTH {32} \
  CONFIG.C_PROBE_IN1_WIDTH {32} \
  CONFIG.C_NUM_PROBE_OUT {0} \
  CONFIG.C_NUM_PROBE_IN {2} \
] [get_ips vio_0]
generate_target all [get_ips vio_0]

set_property top m_top_kv260 [current_fileset]
update_compile_order -fileset sources_1

# ---- 合成→実装→ビットストリーム ----
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set pr [get_property PROGRESS [get_runs impl_1]]
puts "IMPL PROGRESS: $pr"
if {$pr ne "100%"} { puts "BUILD FAILED"; exit 1 }
open_run impl_1
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "WNS(setup): $wns"
set bit [glob -nocomplain ${proj_dir}/${project_name}.runs/impl_1/*.bit]
set ltx [glob -nocomplain ${proj_dir}/${project_name}.runs/impl_1/*.ltx]
puts "BIT: $bit"
puts "LTX: $ltx"
puts "BUILD OK (csr: m_proc_csr + CSR/exception -> VIO)"
