# KOZOS トラップ入口 = コンテキストスイッチ (RV32I)
#   trap_entry: 現スレッドの全GPR+mepcをスタックへ退避 → ksched(C)で次を選択
#               → 次スレッドのコンテキストを復元 → mret
#   dispatch  : 最初のスレッドを起動(退避なしで復元のみ)
#   フレーム(128B=32語): [0]=mepc, [i]=xi (i=1,3..31), [2]=未使用(x2/sp)
    .section .text
    .globl trap_entry
    .globl dispatch
    .align 2
trap_entry:
    addi sp, sp, -128
    sw x1,  1*4(sp)
    sw x3,  3*4(sp)
    sw x4,  4*4(sp)
    sw x5,  5*4(sp)
    sw x6,  6*4(sp)
    sw x7,  7*4(sp)
    sw x8,  8*4(sp)
    sw x9,  9*4(sp)
    sw x10, 10*4(sp)
    sw x11, 11*4(sp)
    sw x12, 12*4(sp)
    sw x13, 13*4(sp)
    sw x14, 14*4(sp)
    sw x15, 15*4(sp)
    sw x16, 16*4(sp)
    sw x17, 17*4(sp)
    sw x18, 18*4(sp)
    sw x19, 19*4(sp)
    sw x20, 20*4(sp)
    sw x21, 21*4(sp)
    sw x22, 22*4(sp)
    sw x23, 23*4(sp)
    sw x24, 24*4(sp)
    sw x25, 25*4(sp)
    sw x26, 26*4(sp)
    sw x27, 27*4(sp)
    sw x28, 28*4(sp)
    sw x29, 29*4(sp)
    sw x30, 30*4(sp)
    sw x31, 31*4(sp)
    csrr t0, mepc              # t0=x5 は退避済み
    csrr t1, mcause            # t1=x6 は退避済み
    bltz t1, 1f               # 割込み(mcause[31]=1<0)なら mepc+4 しない(再実行)
    addi t0, t0, 4            # 例外(ecall)は次命令へ復帰
1:
    sw t0, 0*4(sp)
    mv  a0, sp                # a0 = 現フレーム
    lw  a1, 17*4(sp)         # a1 = syscall番号(退避したa7, 例外用)
    mv  a2, t1                # a2 = mcause (割込み/例外の判定用)
    call ksched               # a0 = 次フレーム
    mv  sp, a0
restore_ctx:
    lw  t0, 0*4(sp)
    csrw mepc, t0
    lw x1,  1*4(sp)
    lw x3,  3*4(sp)
    lw x4,  4*4(sp)
    lw x5,  5*4(sp)
    lw x6,  6*4(sp)
    lw x7,  7*4(sp)
    lw x8,  8*4(sp)
    lw x9,  9*4(sp)
    lw x10, 10*4(sp)
    lw x11, 11*4(sp)
    lw x12, 12*4(sp)
    lw x13, 13*4(sp)
    lw x14, 14*4(sp)
    lw x15, 15*4(sp)
    lw x16, 16*4(sp)
    lw x17, 17*4(sp)
    lw x18, 18*4(sp)
    lw x19, 19*4(sp)
    lw x20, 20*4(sp)
    lw x21, 21*4(sp)
    lw x22, 22*4(sp)
    lw x23, 23*4(sp)
    lw x24, 24*4(sp)
    lw x25, 25*4(sp)
    lw x26, 26*4(sp)
    lw x27, 27*4(sp)
    lw x28, 28*4(sp)
    lw x29, 29*4(sp)
    lw x30, 30*4(sp)
    lw x31, 31*4(sp)
    addi sp, sp, 128
    mret

dispatch:                     # a0 = 最初のスレッドのフレーム
    mv  sp, a0
    j   restore_ctx
