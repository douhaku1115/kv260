# 映像クロック (PS の DP video ref, 74.25MHz)
create_clock -period 13.468 -name clk_video -waveform {0.000 6.734} [get_pins design_1_i/zynq_ultra_ps_e_0/inst/PS8_i/DPVIDEOREFCLK]

# 映像 / 100MHz (AXI・NES) / 12.5MHz (I2S) は互いに非同期
#   映像⇔100MHz は画面バッファ (2 クロック RAM) と vsync の同期器で受け渡す
#   12.5MHz は段A では独立 (固定トーン)
set_clock_groups -asynchronous \
    -group [get_clocks clk_video] \
    -group [get_clocks -of_objects [get_pins design_1_i/clk_wiz_0/clk_out1]] \
    -group [get_clocks -of_objects [get_pins design_1_i/clk_wiz_0/clk_out2]]
