# FSBL を使わず、USB の 4 行を外した psu_init.tcl で PS を初期化して起動する。
# (Vitis の Board Initialization = TCL と同じ流れ。最初に起動モードを JTAG にしてリセット)
# ★★ USB を使うようにしたらこの方式は使えない (README「実機の起動 (xsdb)」)。
# 使い方: E:/vivado/2025.2/Vitis/bin/xsdb.bat tools/xsdb_run.tcl <bit> <elf> <psu_nousb.tcl>  (kaleidoscope 版の複製)
#   psu_nousb.tcl は tools/make_psu_nousb.py で作る
set BIT [lindex $argv 0]
set ELF [lindex $argv 1]
set PSU [lindex $argv 2]

connect -url tcp:127.0.0.1:3121
source E:/vivado/2025.2/Vitis/scripts/vitis/util/zynqmp_utils.tcl

# ---- 1. 起動モードを JTAG にしてリセット (jtag_reg.tcl の set_bootmode と同じ) ----
targets -set -nocase -filter {name =~ "PSU"}
catch {stop}
mwr 0xffca0010 0x0
mwr 0xff5e0200 0x0100
rst -system
after 1000
catch {con}
puts "1. JTAG mode reset  BOOT_MODE_USER=[mrd -force -value 0xff5e0200]"

# ---- 2. PL を書く ----
targets -set -nocase -filter {name =~ "APU*"}
rst -system
after 3000
targets -set -nocase -filter {name =~ "PL"}
fpga -file $BIT
puts "2. PL programmed"

# ---- 3. PS の初期化 (USB を外した psu_init) ----
targets -set -nocase -filter {name =~ "PSU"}
catch {disable_pmu_gate}
targets -set -nocase -filter {name =~ "APU*"}
source $PSU
psu_init
after 1000
psu_ps_pl_isolation_removal
after 1000
psu_ps_pl_reset_config
catch {psu_protection}
puts "3. psu_init done"

# ---- 4. アプリ ----
targets -set -nocase -filter {name =~ "*A53*#0"}
rst -processor
dow $ELF
con
puts "4. app started"
after 1000
disconnect
