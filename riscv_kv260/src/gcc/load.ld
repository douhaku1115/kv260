/* ブートローダ用: プログラムを 0x13000 に固定リンク(グローバル変数=絶対番地対応)。
   .text -> .data -> .bss を連続配置。prog を先頭(=エントリ 0x13000)に置く。
   mkload.sh が .text+.data をバイナリ化し、.bss サイズ分のゼロ語を後ろに付ける。 */
OUTPUT_ARCH(riscv)
ENTRY(prog)
SECTIONS {
  . = 0x00013000;
  .text : {
    *(.text.prog)                 /* prog を先頭に固定(0x13000) */
    *(.text .text.*)
    *(.rodata .rodata.*)
  }
  . = ALIGN(4);
  .data : {
    *(.data .data.* .sdata .sdata.*)
  }
  . = ALIGN(4);
  _bss_start = .;
  .bss  : {
    *(.bss .bss.* .sbss .sbss.* COMMON)
  }
  . = ALIGN(4);
  _bss_end = .;
  /DISCARD/ : { *(.comment) *(.note*) *(.riscv.attributes) }
}
