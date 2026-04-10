set board_type kv260
set rtl_top_name mips_axi
set rtl_files {rtl/mips_axi.v rtl/mips_top.v rtl/datapath.v rtl/control.v rtl/alu.v rtl/regfile.v rtl/imem.v}
set timing_xdc_file {timings.xdc}
set project_name project_1
set project_dir project_1
set design_name design_1
set ps_ip xilinx.com:ip:zynq_ultra_ps_e
set ps_name zynq_ultra_ps_e_0
set init_rule xilinx.com:bd_rule:zynq_ultra_ps_e
set rtl_top_instance ${rtl_top_name}_0

set board_parts [get_board_parts "*:kv260_som:*" -latest_file_version]
set som_connection {som240_1_connector xilinx.com:kv260_carrier:som240_1_connector:1.3}

create_project -name $project_name -force -dir $project_dir -part [get_property PART_NAME $board_parts]
set_property board_part $board_parts [current_project]

add_files -fileset constrs_1 -norecurse $timing_xdc_file
set_property used_in_synthesis false [get_files $timing_xdc_file]
add_files -fileset sources_1 -norecurse $rtl_files

set_property board_connections $som_connection [current_project]

create_bd_design $design_name
current_bd_design $design_name
set top_instance [get_bd_cells /]
current_bd_instance $top_instance

# PS config
create_bd_cell -type ip -vlnv $ps_ip $ps_name
apply_bd_automation -rule $init_rule -config {apply_board_preset "1"} [get_bd_cells $ps_name]

set_property -dict [list \
CONFIG.PSU__USE__M_AXI_GP0  {1} \
CONFIG.PSU__USE__M_AXI_GP1  {0} \
CONFIG.PSU__USE__IRQ0 {0} \
CONFIG.PSU__FPGA_PL1_ENABLE {0} \
CONFIG.PSU__USE__AUDIO {0} \
CONFIG.PSU__USE__VIDEO {0} \
CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
] [get_bd_cells $ps_name]

# Clock wizard (pl_clk0 -> 50MHz for MIPS + AXI)
create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 clk_wiz_0
set_property -dict [list \
CONFIG.PRIM_SOURCE {Global_buffer} \
CONFIG.RESET_TYPE {ACTIVE_LOW} \
CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50} \
] [get_bd_cells clk_wiz_0]

# Processor System Reset
create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0

# RTL module (AXI slave)
create_bd_cell -type module -reference $rtl_top_name $rtl_top_instance

# Clock connections
connect_bd_net [get_bd_pins ${ps_name}/pl_clk0] [get_bd_pins clk_wiz_0/clk_in1]
connect_bd_net [get_bd_pins ${ps_name}/pl_resetn0] [get_bd_pins clk_wiz_0/resetn]

set axi_clk [get_bd_pins clk_wiz_0/clk_out1]

# Reset connections
connect_bd_net $axi_clk [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
connect_bd_net [get_bd_pins clk_wiz_0/locked] [get_bd_pins proc_sys_reset_0/dcm_locked]
connect_bd_net [get_bd_pins ${ps_name}/pl_resetn0] [get_bd_pins proc_sys_reset_0/ext_reset_in]

# AXI Interconnect
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0
set_property CONFIG.NUM_MI {1} [get_bd_cells axi_interconnect_0]

# AXI clock/reset for interconnect
connect_bd_net $axi_clk [get_bd_pins axi_interconnect_0/ACLK]
connect_bd_net $axi_clk [get_bd_pins axi_interconnect_0/S00_ACLK]
connect_bd_net $axi_clk [get_bd_pins axi_interconnect_0/M00_ACLK]
connect_bd_net [get_bd_pins proc_sys_reset_0/interconnect_aresetn] [get_bd_pins axi_interconnect_0/ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_interconnect_0/S00_ARESETN]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins axi_interconnect_0/M00_ARESETN]

# PS AXI master -> interconnect
connect_bd_net $axi_clk [get_bd_pins ${ps_name}/maxihpm0_fpd_aclk]
connect_bd_intf_net [get_bd_intf_pins ${ps_name}/M_AXI_HPM0_FPD] [get_bd_intf_pins axi_interconnect_0/S00_AXI]

# Interconnect -> MIPS AXI slave
connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI] [get_bd_intf_pins ${rtl_top_instance}/S_AXI]
connect_bd_net $axi_clk [get_bd_pins ${rtl_top_instance}/S_AXI_ACLK]
connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] [get_bd_pins ${rtl_top_instance}/S_AXI_ARESETN]

# Address mapping
assign_bd_address -target_address_space [get_bd_addr_spaces ${ps_name}/Data] \
    [get_bd_addr_segs ${rtl_top_instance}/S_AXI/reg0] \
    -range 4K -offset 0xA0000000

# Wrapper
current_bd_instance $top_instance
make_wrapper -files [get_files $project_dir/${project_name}.srcs/sources_1/bd/$design_name/${design_name}.bd] -top
add_files -norecurse $project_dir/${project_name}.gen/sources_1/bd/$design_name/hdl/${design_name}_wrapper.v
set_property top ${design_name}_wrapper [current_fileset]
update_compile_order -fileset sources_1
validate_bd_design
regenerate_bd_layout
save_bd_design
