# swtch(unsigned* save_sp_addr /*a0*/, unsigned new_sp /*a1*/)
#   現在のcallee-saved(s0-s11,ra)をスタックに退避し、sp を *a0 に保存、
#   sp <- a1 して復元。スレッド文脈は共有RAM上のスタックに載る=別コアで再開可。
  .text
  .globl swtch
swtch:
  addi sp, sp, -52
  sw s0,0(sp); sw s1,4(sp); sw s2,8(sp); sw s3,12(sp)
  sw s4,16(sp); sw s5,20(sp); sw s6,24(sp); sw s7,28(sp)
  sw s8,32(sp); sw s9,36(sp); sw s10,40(sp); sw s11,44(sp)
  sw ra,48(sp)
  sw sp, 0(a0)          # *save_sp_addr = 現在のsp
  mv sp, a1             # sp = new_sp
  lw s0,0(sp); lw s1,4(sp); lw s2,8(sp); lw s3,12(sp)
  lw s4,16(sp); lw s5,20(sp); lw s6,24(sp); lw s7,28(sp)
  lw s8,32(sp); lw s9,36(sp); lw s10,40(sp); lw s11,44(sp)
  lw ra,48(sp)
  addi sp, sp, 52
  ret
