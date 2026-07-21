# =============================================================================
# build_win.tcl -- 段1 I2S2 トーン: プロジェクト生成 + 合成/実装/ビットストリーム
#   Windows 用。実行: vivado -mode batch -source build_win.tcl
#   生成物: vivado/i2s2_tone.runs/impl_1/design_1_wrapper.bit
#   接続: Pmod I2S2 を J2 に直挿し。DAC出力ジャックにイヤホンを挿す。
#   書込後: sudo devmem 0xFF5E00C0 32 0x01010A00 (PLクロック有効化)
# =============================================================================
set origin_dir [file normalize [file dirname [info script]]]

# プロジェクト生成 (create_i2s2_project.tcl と同内容)
source $origin_dir/create_i2s2_project.tcl

# 合成 -> 実装 -> ビットストリーム
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

set pr [get_property PROGRESS [get_runs impl_1]]
if {$pr ne "100%"} { puts "BUILD FAILED (progress=$pr)"; exit 1 }
set bitdir [get_property DIRECTORY [get_runs impl_1]]
puts "==============================================================="
puts " i2s2_tone ビルド完了"
puts "  bit: $bitdir/design_1_wrapper.bit"
puts "==============================================================="
exit
