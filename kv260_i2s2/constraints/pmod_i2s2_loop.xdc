# -----------------------------------------------------------------------------
# Pmod I2S2 on KV260 carrier J2  -- 段2: ループバック (DAC=TX + ADC=RX)
#   ピン対応は公式(som240/part0_pins)とDigilent I2S2物理配置で確定済み。
#   J2 上段(1-4)=DAC, 下段(7-10)=ADC。VCCO 3.3V → LVCMOS33。
# -----------------------------------------------------------------------------
# ---- DAC (TX) : J2-1..4 ----
set_property -dict {PACKAGE_PIN H12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports dac_mclk]   ;# J2-1
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports dac_lrck]   ;# J2-2
set_property -dict {PACKAGE_PIN D10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports dac_sclk]   ;# J2-3
set_property -dict {PACKAGE_PIN C11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports dac_sdin]   ;# J2-4

# ---- ADC (RX) : J2-7..10 ----
set_property -dict {PACKAGE_PIN B10 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports adc_mclk]   ;# J2-7
set_property -dict {PACKAGE_PIN E12 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports adc_lrck]   ;# J2-8
set_property -dict {PACKAGE_PIN D11 IOSTANDARD LVCMOS33 SLEW SLOW DRIVE 4} [get_ports adc_sclk]   ;# J2-9
set_property -dict {PACKAGE_PIN B11 IOSTANDARD LVCMOS33} [get_ports adc_sdout]                    ;# J2-10 (入力)
