# KV260 LED PL Bare-metal Project
# AXI GPIO -> PMOD connector (external LED)
# gpio_rtl_0[0..3] -> PMOD pins 1..4

set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

# PMOD pin 1 (LED0)
set_property PACKAGE_PIN B11 [get_ports {gpio_rtl_0_tri_o[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_rtl_0_tri_o[0]}]

# PMOD pin 2 (LED1)
set_property PACKAGE_PIN D11 [get_ports {gpio_rtl_0_tri_o[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_rtl_0_tri_o[1]}]

# PMOD pin 3 (LED2)
set_property PACKAGE_PIN E12 [get_ports {gpio_rtl_0_tri_o[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_rtl_0_tri_o[2]}]

# PMOD pin 4 (LED3)
set_property PACKAGE_PIN B10 [get_ports {gpio_rtl_0_tri_o[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {gpio_rtl_0_tri_o[3]}]
