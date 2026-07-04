/* 第3段 gccフロー用リンカスクリプト (Harvard, RV32I)
   IMEM(text) 0x0000_0000..  / DMEM(data,stack) 0x0001_0000..
   ※現状 rodata/data の DMEM 初期化(LMA→ロード時コピー)は未対応。
     まずは data/rodata を持たないプログラム(例: Σ0..100)専用。 */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY {
  IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 16K
  DMEM (rw) : ORIGIN = 0x00010000, LENGTH = 16K
}

SECTIONS {
  . = 0x00000000;
  .text 0x00000000 : {
    *(.text.init)      /* crt0 の _start を先頭(=リセットPC 0)に */
    *(.text .text.*)
    *(.rodata .rodata.*)
  } > IMEM

  .data : { *(.data .data.*) *(.sdata .sdata.*) } > DMEM
  .bss  : { *(.bss .bss.*) *(.sbss .sbss.*) *(COMMON) } > DMEM

  _estack = ORIGIN(DMEM) + LENGTH(DMEM);   /* 0x0001_4000 = スタック頂点 */
}
