# 画素クロック (DP Video Ref Clk) の宣言
#   13.468 ns = 74.25 MHz = 1280x720@60 の画素クロック
create_clock -period 13.468 -name clk_video -waveform {0.000 6.734} [get_pins design_1_i/zynq_ultra_ps_e_0/inst/PS8_i/DPVIDEOREFCLK]

# 画素クロックと clk_wiz_0 (PL 内部クロック) は非同期。CDC は cdc_synchronizer / shift_register で受ける
set_clock_groups -asynchronous -group [get_clocks clk_video] -group [get_clocks -of_objects [get_pins design_1_i/clk_wiz_0/clk_out1]]
