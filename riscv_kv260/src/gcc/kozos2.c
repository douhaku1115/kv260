/* KOZOS 第5段-2: プリエンプティブ・マルチタスク (タイマ割込みで強制切替)
   スレッドは yield しない無限ループ。タイマ割込みだけがコンテキストスイッチを起こす。
   ksched は「割込まれていたスレッド」を sched_seq に記録(A=1,B=2)。
   6回のプリエンプションで A,B,A,B,A,B=121212 になれば「タイマ駆動の
   ラウンドロビン・プリエンプション成立」。両スレッドが実際に走った証拠に
   cntA/cntB>0 も確認して出力。 */
#define SYS_EXIT 1
#define CTXW     32
#define INTERVAL 150
#define RESULT      ((volatile unsigned*)0x00020000)
#define MTIMECMP_LO ((volatile unsigned*)0x00030000)
#define MTIMECMP_HI ((volatile unsigned*)0x00030004)
#define MTIME_LO    ((volatile unsigned*)0x00030008)
#define MTIME_HI    ((volatile unsigned*)0x0003000C)

typedef struct { unsigned *sp; int alive; } tcb_t;
extern void trap_entry(void);
extern void dispatch(unsigned *sp);

tcb_t tcbs[2];
int   cur, nsw;
volatile unsigned cntA, cntB, sched_seq;
static unsigned stackA[256], stackB[256];

static unsigned long long get_mtime(void){
  unsigned h, l;
  do { h = *MTIME_HI; l = *MTIME_LO; } while (h != *MTIME_HI);
  return ((unsigned long long)h << 32) | l;
}
static void set_cmp(unsigned long long t){
  *MTIMECMP_HI = 0xFFFFFFFF;
  *MTIMECMP_LO = (unsigned)t;
  *MTIMECMP_HI = (unsigned)(t >> 32);
}

/* スレッドは yield しない(=自発的にCPUを手放さない) */
void threadA(void){ for(;;) cntA++; }
void threadB(void){ for(;;) cntB++; }

void thread_create(tcb_t *t, void (*f)(void), unsigned *sptop){
  unsigned *frame = sptop - CTXW;
  int i; for(i=0;i<CTXW;i++) frame[i] = 0;
  frame[0] = (unsigned)f;                  /* mepc -> スレッド関数 */
  t->sp = frame; t->alive = 1;
}

/* trap_entry から: mcause で割込み(プリエンプト)か例外(syscall)を判定 */
unsigned* ksched(unsigned *frame, int sc, unsigned mcause){
  tcbs[cur].sp = frame;
  if ((int)mcause < 0){                     /* タイマ割込み=プリエンプション */
    set_cmp(get_mtime() + INTERVAL);        /* 次のプリエンプションを予約 */
    sched_seq = sched_seq*10 + (cur + 1);   /* 走っていたスレッドを記録 */
    nsw++;
    if (nsw >= 6){                          /* 6回で判定・出力・停止 */
      *RESULT = (cntA && cntB) ? sched_seq : 0xBAD;
      for(;;);
    }
  } else if (sc == SYS_EXIT){
    tcbs[cur].alive = 0;
  }
  int n = cur, i;                            /* ラウンドロビンで次 */
  for (i = 0; i < 2; i++){ n = (n+1)&1; if (tcbs[n].alive){ cur = n; return tcbs[n].sp; } }
  *RESULT = sched_seq; for(;;);
}

int main(void){
  cur = 0; nsw = 0; sched_seq = 0; cntA = 0; cntB = 0;
  thread_create(&tcbs[0], threadA, stackA + 256);
  thread_create(&tcbs[1], threadB, stackB + 256);
  __asm__ volatile("csrw mtvec, %0"   :: "r"((unsigned)(unsigned long)trap_entry));
  set_cmp(get_mtime() + INTERVAL);
  __asm__ volatile("csrs mie, %0"     :: "r"(0x80));   /* MTIE */
  __asm__ volatile("csrw mstatus, %0" :: "r"(0x80));   /* MPIE=1 -> 最初のmretでMIE=1 */
  dispatch(tcbs[0].sp);                                 /* 最初のスレッドへ(戻らない) */
  return 0;
}
