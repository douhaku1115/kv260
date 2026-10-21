# Pmod I2S2 を KV260 の J2 に直挿し (kv260_i2s2/constraints/pmod_i2s2.xdc と同じ)
#   J2-1 mclk / J2-2 lrck / J2-3 sclk / J2-4 sdin (DAC 側)
set_property -dict {PACKAGE_PIN H12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports pmod_mclk]
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports pmod_lrck]
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports pmod_sclk]
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports pmod_sdin]
