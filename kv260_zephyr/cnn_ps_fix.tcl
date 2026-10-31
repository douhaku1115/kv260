# CNN (kv260_cnn) の PL を動かすための PS 後設定。run_zephyr.tcl の第 3 引数で渡す。
# PS 全体は万華鏡の psu_init (UART1 あり) で初期化し、CNN の設計と違うところだけ合わせる。
# 値は kv260_cnn/vivado/.../design_1_ps_0/psu_init.tcl から取った。

# AFI_FS: HPM0_FPD のデータ幅を 32 ビット (bit[9:8]=0) に。万華鏡は 128 ビット (0x200)
mwr -force 0xFD615000 [expr {[mrd -force -value 0xFD615000] & ~0x300}]

# ★ PL0 クロック (0xFF5E00C0) は触らない。CNN は 100MHz 前提 (WNS 2.28ns → 上限 約 130MHz)。
#   万華鏡の psu_init は IOPLL 1500MHz / 15 = 100MHz で、すでに合っている。
#   Linux 手順の devmem 0x01010A00 (/10) は CNN 設計の IOPLL 1000MHz 用なので、ここで書くと
#   150MHz になってしまう (2026-10-31 に一度やって 1328us/枚 = 150MHz で走らせた)。
