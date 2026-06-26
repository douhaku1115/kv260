# ============================================================
# RISC-V on KV260 - VIO version (complete, one script)
# Usage: vivado -mode batch -source create_vio_full.tcl
# ============================================================

set project_name "riscv_kv260_vio2"
set project_dir  [file dirname [file normalize [info script]]]
set src_dir      "${project_dir}/src"
set proj_dir     "${project_dir}/vivado/${project_name}"

# Delete old project if exists
file delete -force ${proj_dir}

# Create project
create_project ${project_name} ${proj_dir} -part xck26-sfvc784-2LV-c
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]

# Add source files
add_files -norecurse ${src_dir}/main_vio.v
add_files -norecurse ${src_dir}/asm.txt
set_property file_type "Verilog Header" [get_files asm.txt]

# ============================================================
# Create Block Design (Zynq PS for clock only)
# ============================================================
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

# Generate wrapper
make_wrapper -files [get_files clk_bd.bd] -top
set wrapper_file [file normalize ${proj_dir}/${project_name}.gen/sources_1/bd/clk_bd/hdl/clk_bd_wrapper.v]
add_files -norecurse ${wrapper_file}

# ============================================================
# Create VIO IP
# ============================================================
create_ip -name vio -vendor xilinx.com -library ip -version 3.0 -module_name vio_0
set_property -dict [list \
  CONFIG.C_PROBE_IN0_WIDTH {32} \
  CONFIG.C_NUM_PROBE_OUT {0} \
  CONFIG.C_NUM_PROBE_IN {1} \
] [get_ips vio_0]
generate_target all [get_ips vio_0]

# Set top module
set_property top m_top_kv260 [current_fileset]
update_compile_order -fileset sources_1

puts "============================================================"
puts " Project: ${proj_dir}/${project_name}.xpr"
puts " 1. Generate Bitstream"
puts " 2. Open Hardware Manager -> Program Device"
puts " 3. VIO window: expect 0x13BA (5050)"
puts "============================================================"
