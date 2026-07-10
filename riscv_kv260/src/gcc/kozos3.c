/* KOZOS 第5段-3: sleep(n) サービス
   スレッドは sleep(n)=ecall で n ティック休止し、その間 他スレッド(や idle)にCPUを譲る。
   タイマ割込み=システムティック。満了した SLEEPING スレッドを READY に起こす。
   全realスレッドが SLEEPING なら idle スレッドが回り(MIE=1)、ティックを進める。
   デモ: A は sleep(2)で4回、B は sleep(4)で2回、各回 seq に桁追加(A=1,B=2)。
   A は B の2倍の頻度で起きる → seq に 1 が 2 より多く並ぶ = sleep 駆動スケジューリング。 */
#define SYS_EXIT  1
#define SYS_SLEEP 2
#define CTXW      32
#define INTERVAL  1000          /* 1システムティック=1000サイクル(割込みハンドラ~130cyより十分大) */
#define NREAL     2             /* 実スレッド数(0,1) */
#define IDLE      2             /* idle スレッドのindex */
#define ST_READY  0
#define ST_SLEEP  1
#define ST_DEAD   2
#define RESULT      ((volatile unsigned*)0x00020000)
#define MTIMECMP_LO ((volatile unsigned*)0x00030000)
#define MTIMECMP_HI ((volatile unsigned*)0x00030004)
#define MTIME_LO    ((volatile unsigned*)0x00030008)
#define MTIME_HI    ((volatile unsigned*)0x0003000C)

typedef struct { unsigned *sp; int state; unsigned wake; } tcb_t;
extern void trap_entry(void);
extern void dispatch(unsigned *sp);

tcb_t tcbs[3];                  /* 0,1=real / 2=idle */
int cur;
unsigned ticks;
volatile unsigned seq;
static unsigned stackA[256], stackB[256], stackI[64];

static unsigned long long get_mtime(void){
  unsigned h,l; do{h=*MTIME_HI;l=*MTIME_LO;}while(h!=*MTIME_HI);
  return ((unsigned long long)h<<32)|l;
}
static void set_cmp(unsigned long long t){
  *MTIMECMP_HI=0xFFFFFFFF; *MTIMECMP_LO=(unsigned)t; *MTIMECMP_HI=(unsigned)(t>>32);
}

static inline void sys_sleep(int n){
  register int a0 __asm__("a0")=n; register int a7 __asm__("a7")=SYS_SLEEP;
  __asm__ volatile("ecall" :: "r"(a0),"r"(a7) : "memory");
}
static inline void sys_exit(void){
  register int a7 __asm__("a7")=SYS_EXIT;
  __asm__ volatile("ecall" :: "r"(a7) : "memory");
}

void threadA(void){ int i; for(i=0;i<4;i++){ seq=seq*10+1; sys_sleep(2);} sys_exit(); }
void threadB(void){ int i; for(i=0;i<2;i++){ seq=seq*10+2; sys_sleep(4);} sys_exit(); }
void idle_thread(void){ for(;;); }

void thread_create(tcb_t *t, void (*f)(void), unsigned *sptop){
  unsigned *fr=sptop-CTXW; int i; for(i=0;i<CTXW;i++) fr[i]=0;
  fr[0]=(unsigned)f; t->sp=fr; t->state=ST_READY; t->wake=0;
}

unsigned* ksched(unsigned *frame, int sc, unsigned mcause){
  tcbs[cur].sp = frame;
  if ((int)mcause < 0){                 /* タイマ=システムティック */
    set_cmp(get_mtime()+INTERVAL);
    ticks++;
    int i; for(i=0;i<NREAL;i++)
      if (tcbs[i].state==ST_SLEEP && ticks>=tcbs[i].wake) tcbs[i].state=ST_READY;
  } else if (sc==SYS_SLEEP){
    tcbs[cur].state=ST_SLEEP; tcbs[cur].wake=ticks + frame[10];  /* a0=n */
  } else if (sc==SYS_EXIT){
    tcbs[cur].state=ST_DEAD;
  }
  if (tcbs[0].state==ST_DEAD && tcbs[1].state==ST_DEAD){ *RESULT=seq; for(;;); }
  int n=-1,i;                            /* real を round-robin, 無ければ idle */
  for(i=1;i<=NREAL;i++){ int c=(cur+i)%NREAL; if(tcbs[c].state==ST_READY){ n=c; break; } }
  if (n<0) n=IDLE;
  cur=n; return tcbs[n].sp;
}

int main(void){
  cur=0; ticks=0; seq=0;
  thread_create(&tcbs[0], threadA, stackA+256);
  thread_create(&tcbs[1], threadB, stackB+256);
  thread_create(&tcbs[2], idle_thread, stackI+64);
  __asm__ volatile("csrw mtvec, %0"   :: "r"((unsigned)(unsigned long)trap_entry));
  set_cmp(get_mtime()+INTERVAL);
  __asm__ volatile("csrs mie, %0"     :: "r"(0x80));   /* MTIE */
  __asm__ volatile("csrw mstatus, %0" :: "r"(0x80));   /* MPIE=1 -> mretでMIE=1 */
  dispatch(tcbs[0].sp);
  return 0;
}
