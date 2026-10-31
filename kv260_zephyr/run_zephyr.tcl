# KV260 の R5 #0 で Zephyr を起動する。FSBL の代わりに USB を外した psu_init で PS を初期化する。
# (Zephyr 公式 boards/amd/kv260_r5/support/xsdb.cfg の流れを、FSBL→psu_init に置き換えたもの)
# 使い方: xsdb run_zephyr.tcl <zephyr.elf> [PL のビットファイル] [PS の後設定 tcl]
#   PL を使うときはビットファイルを渡す。その PL が万華鏡と違う PS 設定 (PL クロック・
#   HPM の幅など) を前提にしているなら、差分だけを書いた後設定 tcl も渡す (例: cnn_ps_fix.tcl)
set DIR [file dirname [file normalize [info script]]]
set ELF [lindex $argv 0]
set BIT [lindex $argv 1]
set FIX [lindex $argv 2]

connect
source E:/vivado/2025.2/Vitis/scripts/vitis/util/zynqmp_utils.tcl

# ---- 1. 起動モードを JTAG にしてリセット ----
targets -set -nocase -filter {name =~ "PSU"}
catch {stop}
mwr 0xffca0010 0x0
mwr 0xff5e0200 0x0100
rst -system
after 1000
catch {con}
puts "1. JTAG mode reset"

# ---- 2. PL を書き (渡されたときだけ)、PS を初期化 (USB を外した psu_init) ----
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 3000
if {$BIT ne ""} {
    targets -set -nocase -filter {name =~ "PL"}
    fpga -file $BIT
    puts "   PL programmed: [file tail $BIT]"
}
targets -set -nocase -filter {name =~ "PSU"}
catch {disable_pmu_gate}
targets -set -nocase -filter {name =~ "APU*"}
source $DIR/psu_init_nousb.tcl
# psu_init と同じ順番。ただし SERDES (DP/USB3 用) の PLL ロック待ちが電源直後に
# タイムアウトすることがあるので、その段だけ失敗しても続ける (Zephyr は SERDES を使わない)
set saved_mode [configparams force-mem-accesses]
configparams force-mem-accesses 1
init_ps [subst {$psu_mio_init_data $psu_peripherals_pre_init_data $psu_pll_init_data $psu_clock_init_data $psu_ddr_init_data }]
psu_ddr_phybringup_data
init_ps [subst {$psu_peripherals_init_data $psu_resetin_init_data }]
if {[catch {init_serdes; init_ps [subst {$psu_serdes_init_data}]} err]} {
    puts "   SERDES skipped: [lindex [split $err \n] 0]"
}
# resetout の最後は lane1/lane2 の PLL ロック待ち。lane2 (USB3/DP 系) は基準クロックが
# 来ずタイムアウトするが、リセット解除の書き込みはその前に済んでいるので続ける
if {[catch {init_ps [subst {$psu_resetout_init_data }]} err]} {
    puts "   resetout: [lindex [split $err \n] 0] (continue)"
}
init_peripheral
init_ps [subst {$psu_peripherals_powerdwn_data }]
init_ps [subst {$psu_afi_config }]
init_ps [subst {$psu_ddr_qos_init_data}]
configparams force-mem-accesses $saved_mode
if {$FIX ne ""} {
    source $FIX
    puts "   PS fix applied: [file tail $FIX]"
}
after 1000
psu_ps_pl_isolation_removal
after 1000
psu_ps_pl_reset_config
catch {psu_protection}
puts "2. psu_init done"

# ---- 3. R5 #0 に Zephyr を流し込んで走らせる ----
# Vitis と同じく分割モードにして RPU のリセットを解く (zynqmp_utils.tcl)
targets -set -nocase -filter {name =~ "RPU*"}
enable_split_mode
clear_rpu_reset
# Zephyr はベクタを 0x0 (TCM) に置くので VINITHI=0 (低位ベクタ) にしてから R5 をリセットする
targets -set -nocase -filter {name =~ "PSU"}
mwr -force 0xff9a0100 [expr {[mrd -force -value 0xff9a0100] & ~0x4}]
# TCM は ECC 付き。未初期化のままバイト書き込みすると ECC エラーでアボートするので、
# FSBL (XFsbl_TcmEccInit) と同じく R5_0 の ATCM/BTCM 全域をワード単位で 0 埋めする
mwr -force 0xffe00000 0 16384
mwr -force 0xffe20000 0 16384
targets -set -nocase -filter {name =~ "*R5*#0"}
rst -processor -clear-registers
dow $ELF
con
after 2000
puts "3. zephyr started"

# ---- 確認用: RPU の設定と UART1 の状態 ----
targets -set -nocase -filter {name =~ "PSU"}
foreach {n a} {RPU_GLBL_CNTL 0xFF9A0000 RPU_0_CFG 0xFF9A0100 UART1_CR 0xFF010000 UART1_SR 0xFF01002C UART1_REF 0xFF5E0078 PL0_REF 0xFF5E00C0 AFI_FS 0xFD615000} {
    puts [format "   %-13s = 0x%08x" $n [mrd -force -value $a]]
}
puts [targets]
disconnect
