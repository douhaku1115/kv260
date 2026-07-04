/* gccのCからCSR/例外を使う検証(KOZOS流): mtvec設定→ecall→ハンドラ→mret→mcause取得。
   ハンドラは naked 関数(asmのみ)。csrw/csrr は csrrw/csrrs に展開される。 */
__attribute__((naked)) void trap_handler(void){
  __asm__ volatile(
    "csrr t0, mepc\n"    /* t0 = mepc(=ecall PC) */
    "addi t0, t0, 4\n"   /* ecall をスキップ */
    "csrw mepc, t0\n"
    "mret\n"
  );
}
int main(void){
  __asm__ volatile("csrw mtvec, %0" :: "r"((unsigned)(unsigned long)&trap_handler));
  __asm__ volatile("ecall");
  unsigned c;
  __asm__ volatile("csrr %0, mcause" : "=r"(c));
  return (int)c;   /* Environment call from M-mode = 11 */
}
