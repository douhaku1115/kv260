# -----------------------------------------------------------------------------
# Pmod I2S2 on KV260 carrier J2  -- 段1: TX(DAC)のみ
#   ピン対応は公式(som240/part0_pins)とDigilent I2S2物理配置で確定済み
# -----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN H12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports pmod_mclk]   ;# J2-1
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports pmod_lrck]   ;# J2-2
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports pmod_sclk]   ;# J2-3
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports pmod_sdin]   ;# J2-4

# 12.5MHz生成クロックのタイミング(参考)。実際のclk名はclk_wiz出力に合わせる。
# create_generated_clock は clk_wiz が自動生成するため通常追加不要。
