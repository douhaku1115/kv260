/* mips.ld — ベアメタル MIPS リンカスクリプト
 *
 * imem: 4096 ワード × 4 バイト = 16KB
 * 命令は 0x0000 から配置。
 * .text.startup (crt0) を先頭に置いて _start が 0x0000 になるようにする。
 */

ENTRY(_start)

SECTIONS
{
    /* 命令メモリに不要なセクションを破棄 */
    /DISCARD/ : {
        *(.note.*)
        *(.comment)
        *(.gnu.attributes)
        *(.MIPS.abiflags)
        *(.reginfo)
        *(.mdebug*)
        *(.pdr)
    }

    . = 0x00000000;

    .text : {
        *(.text.startup)
        *(.text .text.*)
        *(.gnu.linkonce.t.*)
    }

    . = ALIGN(4);
    .rodata : {
        *(.rodata .rodata.*)
    }

    . = ALIGN(4);
    .data : {
        *(.data .data.*)
    }

    . = ALIGN(4);
    .bss : {
        *(.bss .bss.*)
        *(COMMON)
    }
}
