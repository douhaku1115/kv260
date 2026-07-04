/* 第4段 タイマ割込み検証(KOZOS流プリエンプション):
   mtvec=handler設定→mtimecmp設定→MTIE/MIE許可→ループ。
   タイマ割込みでハンドラが tick++ し次のmtimecmpを設定。5回tickしたら ticks を返す。 */
#define MTIMECMP_LO ((volatile unsigned*)0x00030000)
#define MTIMECMP_HI ((volatile unsigned*)0x00030004)
#define MTIME_LO    ((volatile unsigned*)0x00030008)
#define MTIME_HI    ((volatile unsigned*)0x0003000C)

volatile int ticks;      /* .bss(0初期化, DMEMは0クリア済) */

static unsigned long long get_mtime(void){
  unsigned hi, lo;
  do { hi = *MTIME_HI; lo = *MTIME_LO; } while (hi != *MTIME_HI);
  return ((unsigned long long)hi<<32) | lo;
}
static void set_cmp(unsigned long long t){
  *MTIMECMP_HI = 0xFFFFFFFF;          /* 先にhiを大きく(グリッチ防止) */
  *MTIMECMP_LO = (unsigned)t;
  *MTIMECMP_HI = (unsigned)(t>>32);
}
__attribute__((interrupt("machine")))
void handler(void){
  ticks++;
  set_cmp(get_mtime() + 100);        /* 次の割込み */
}
int main(void){
  ticks = 0;
  __asm__ volatile("csrw mtvec, %0" :: "r"((unsigned)(unsigned long)&handler));
  set_cmp(get_mtime() + 100);
  __asm__ volatile("csrs mie, %0"     :: "r"(0x80));   /* MTIE(bit7) */
  __asm__ volatile("csrs mstatus, %0" :: "r"(0x8));    /* MIE(bit3) */
  while (ticks < 5) { }
  return ticks;   /* 5 */
}
