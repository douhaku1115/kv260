#!/bin/bash
# 起動時に RISC-V(KOZOS) ビットストリームを PL へロードし pl_clk0 を有効化。
# 手動時の 2 コマンド(fpgautil + devmem)と同一。
BIT=/lib/firmware/riscv/m_top_kv260.bit

fpgautil -b "$BIT" || { echo "riscv-load: fpgautil failed" >&2; exit 1; }
# pl_clk0 = IOPLL / 10 = 100MHz (CRL_APB PL0_REF_CTRL)
devmem 0xFF5E00C0 32 0x01010A00
echo "riscv-load: PL configured, pl_clk0=100MHz"
