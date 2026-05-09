// crt0.S — MIPS ベアメタル スタートアップ
//
// 役割:
//   - スタックポインタを dmem の末尾に初期化
//   - main() を呼び出す
//   - 戻り後は無限ループ
//
// dmem: 256 ワード × 4 バイト = 1KB (0x000〜0x3FF)
// $sp 初期値: 0x3FC (dmem 最終ワード)
//
// ディレイスロット注意:
//   本プロセッサはディレイスロット非実装。
//   jal/j の直後に明示的に nop を置く (.set noreorder)。
//   nop は本ハードウェアでは実行されないが無害。
//   $ra = jal の nop アドレスとなり、jr $ra で nop→次命令と流れる。

    .section .text.startup, "ax"
    .global _start
    .type   _start, @function
    .set    noreorder

_start:
    lui  $sp, 0x0000
    ori  $sp, $sp, 0x03FC   // $sp = 0x3FC (dmem top)
    move $fp, $sp
    jal  main
    nop                      // delay slot (skipped on this HW, but harmless)
_halt:
    j    _halt
    nop                      // delay slot
