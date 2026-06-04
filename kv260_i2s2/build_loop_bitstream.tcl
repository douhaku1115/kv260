# 段2 合成→実装→ビットストリーム生成
open_project /mnt/data/fpga/projects/kv260_audio/i2s2/vivado_loop/i2s2_loop.xpr
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1
set st [get_property STATUS [get_runs impl_1]]
set pr [get_property PROGRESS [get_runs impl_1]]
puts "IMPL STATUS: $st  PROGRESS: $pr"
if {$pr ne "100%"} { puts "BUILD FAILED"; exit 1 }
set bitdir [get_property DIRECTORY [get_runs impl_1]]
puts "BITSTREAM: $bitdir/design_1_wrapper.bit"
open_run impl_1
report_utilization -file $bitdir/util_seg2.rpt
report_timing_summary -file $bitdir/timing_seg2.rpt
set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
puts "WNS(setup slack): $wns"
puts "BUILD OK"
