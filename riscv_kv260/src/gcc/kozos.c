/* KOZOS 第5段-1: 協調マルチタスク (yield/ecall によるコンテキストスイッチ)
   2スレッドA/Bをラウンドロビン。各スレッドは共有seqに桁を交互追加しyield。
   A,B,A,B,A,B と切替われば seq=121212 → コンテキストスイッチ成立の証拠。
   全スレッド終了で seq を結果ポート(0x20000)へ出力。 */
#define SYS_YIELD 0
#define SYS_EXIT  1
#define CTXW      32                       /* コンテキスト語数(128B) */
#define RESULT ((volatile unsigned*)0x00020000)

typedef struct { unsigned *sp; int alive; } tcb_t;

extern void trap_entry(void);              /* kentry.S */
extern void dispatch(unsigned *sp);        /* kentry.S: 最初のスレッド起動 */

tcb_t tcbs[2];
int   cur;
volatile int seq;
static unsigned stackA[256], stackB[256];  /* 各1KB(.bss=DMEM, 0クリア) */

/* システムコール = a7 に番号を入れて ecall */
static inline void yield(void){
  register int a7 __asm__("a7") = SYS_YIELD;
  __asm__ volatile("ecall" :: "r"(a7) : "memory");
}
static inline void sys_exit(void){
  register int a7 __asm__("a7") = SYS_EXIT;
  __asm__ volatile("ecall" :: "r"(a7) : "memory");
}

void threadA(void){ int i; for(i=0;i<3;i++){ seq = seq*10 + 1; yield(); } sys_exit(); }
void threadB(void){ int i; for(i=0;i<3;i++){ seq = seq*10 + 2; yield(); } sys_exit(); }

/* スレッド生成: スタックに偽の初期コンテキストを作る(初回復元で関数へ飛ぶ) */
void thread_create(tcb_t *t, void (*f)(void), unsigned *sptop){
  unsigned *frame = sptop - CTXW;
  int i; for(i=0;i<CTXW;i++) frame[i] = 0;
  frame[0] = (unsigned)f;                  /* mepc -> スレッド関数 */
  frame[1] = (unsigned)sys_exit;           /* x1(ra) 落ち先(保険) */
  t->sp = frame;
  t->alive = 1;
}

/* trap_entry から呼ばれる: 現コンテキストを保存し次スレッドを選ぶ */
unsigned* ksched(unsigned *frame, int sc){
  tcbs[cur].sp = frame;                    /* 現スレッドのコンテキスト保存 */
  if (sc == SYS_EXIT) tcbs[cur].alive = 0;
  int n = cur, i;
  for (i = 0; i < 2; i++){                  /* ラウンドロビンで次のalive */
    n = (n + 1) & 1;
    if (tcbs[n].alive){ cur = n; return tcbs[n].sp; }
  }
  *RESULT = (unsigned)seq;                  /* 全終了 -> 結果出力 */
  for(;;);
}

int main(void){
  seq = 0; cur = 0;
  thread_create(&tcbs[0], threadA, stackA + 256);
  thread_create(&tcbs[1], threadB, stackB + 256);
  __asm__ volatile("csrw mtvec, %0" :: "r"((unsigned)(unsigned long)trap_entry));
  dispatch(tcbs[0].sp);                     /* 最初のスレッドへ(戻らない) */
  return 0;
}
