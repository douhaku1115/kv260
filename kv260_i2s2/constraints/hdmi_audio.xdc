# hdmi_audio.xdc -- build_stream_hdmi.tcl 用 (2026-11-05)
# 12.5MHz (clk: AXI・FIFO) と 24.576MHz (clk_aud: HDMI 音声) は同じ pl_clk0 から作るが、受け渡しは
# xlive_audio の cdc_fifo (グレイ符号 + 同期 FF) で行うので、互いに非同期として時間検査しない
# (miya4649 さんのひな型の timings.xdc と同じ扱い)
set_clock_groups -asynchronous \
    -group [get_clocks -of_objects [get_pins design_1_i/clk/clk_out1]] \
    -group [get_clocks -of_objects [get_pins design_1_i/clk_aud/clk_out1]]
