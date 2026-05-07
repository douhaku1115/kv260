open_project E:/fpga/kria260/kv260_mips/project_1/project_1.xpr

# インクリメンタル合成の設定を無効化
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]
set_property INCREMENTAL_CHECKPOINT {} [get_runs synth_1]

# BD ファイル経由で IP 出力を再生成（Nested sub-design エラーを回避）
set bd_file [get_files design_1.bd]
generate_target all $bd_file

# 全合成ランをリセット（OOC合成ランを含む）
# synth_1 だけでなく mips_axi の OOC ランも強制的にリセットする
foreach run [get_runs -filter {IS_SYNTHESIS == 1}] {
    reset_run $run
}

# 合成 → 配置配線 → ビットストリーム生成
launch_runs synth_1 -jobs 4
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 4
wait_on_run impl_1

# XSA エクスポート
write_hw_platform -fixed -force -include_bit E:/fpga/kria260/kv260_mips/project_1/design_1_wrapper.xsa
exit
