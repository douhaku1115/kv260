/* KOZOS 第5段-4: セマフォ (wait/signal による同期)
   BLOCKED 状態を導入。バイナリセマフォ2つで ping-pong を強制し、
   タイミングに依らず A,B,A,B と厳密交互実行させる → seq=121212。
   タイマは使わず ecall(wait/signal/exit) だけで駆動。kentry.S/コアは無変更で流用。 */
#define SYS_EXIT   1
#define SYS_WAIT   3
#define SYS_SIGNAL 4
#define CTXW  32
#define NREAL 2
#define ST_READY 0
#define ST_BLOCK 1
#define ST_DEAD  2
#define RESULT ((volatile unsigned*)0x00020000)

typedef struct { unsigned *sp; int state; int block_sem; } tcb_t;
extern void trap_entry(void);
extern void dispatch(unsigned *sp);

tcb_t tcbs[2];
int   cur;
int   sem[2];                  /* sem[0]=semA, sem[1]=semB */
volatile unsigned seq;
static unsigned stackA[256], stackB[256];

static inline void sys_wait(int s){
  register int a0 __asm__("a0")=s; register int a7 __asm__("a7")=SYS_WAIT;
  __asm__ volatile("ecall" :: "r"(a0),"r"(a7) : "memory");
}
static inline void sys_signal(int s){
  register int a0 __asm__("a0")=s; register int a7 __asm__("a7")=SYS_SIGNAL;
  __asm__ volatile("ecall" :: "r"(a0),"r"(a7) : "memory");
}
static inline void sys_exit(void){
  register int a7 __asm__("a7")=SYS_EXIT;
  __asm__ volatile("ecall" :: "r"(a7) : "memory");
}

/* semA=1,semB=0 の ping-pong: 自分のsemを待ち→追加→相手のsemを起こす */
void threadA(void){ int i; for(i=0;i<3;i++){ sys_wait(0); seq=seq*10+1; sys_signal(1); } sys_exit(); }
void threadB(void){ int i; for(i=0;i<3;i++){ sys_wait(1); seq=seq*10+2; sys_signal(0); } sys_exit(); }

void thread_create(tcb_t *t, void (*f)(void), unsigned *sptop){
  unsigned *fr=sptop-CTXW; int i; for(i=0;i<CTXW;i++) fr[i]=0;
  fr[0]=(unsigned)f; t->sp=fr; t->state=ST_READY; t->block_sem=-1;
}

unsigned* ksched(unsigned *frame, int sc, unsigned mcause){
  tcbs[cur].sp = frame;
  int s = frame[10];                       /* a0 = セマフォ番号 */
  if (sc==SYS_WAIT){
    if (sem[s] > 0) sem[s]--;              /* 資源あり→継続 */
    else { tcbs[cur].state=ST_BLOCK; tcbs[cur].block_sem=s; }  /* 無し→ブロック */
  } else if (sc==SYS_SIGNAL){
    int i, woke=0;
    for(i=0;i<NREAL;i++)
      if (tcbs[i].state==ST_BLOCK && tcbs[i].block_sem==s){
        tcbs[i].state=ST_READY; tcbs[i].block_sem=-1; woke=1; break;  /* 待機者を起こす(ハンドオフ) */
      }
    if (!woke) sem[s]++;                    /* 待機者なし→カウンタ増 */
  } else if (sc==SYS_EXIT){
    tcbs[cur].state=ST_DEAD;
  }
  if (tcbs[0].state==ST_DEAD && tcbs[1].state==ST_DEAD){ *RESULT=seq; for(;;); }
  if (tcbs[cur].state==ST_READY) return tcbs[cur].sp;   /* 現スレッド継続(ブロックしていない) */
  int n=-1,i;                              /* 現がブロック/終了 → 次のREADYへ */
  for(i=1;i<=NREAL;i++){ int c=(cur+i)%NREAL; if(tcbs[c].state==ST_READY){ n=c; break; } }
  if (n<0){ *RESULT=0xDEAD; for(;;); }     /* 全ブロック=デッドロック(想定外) */
  cur=n; return tcbs[n].sp;
}

int main(void){
  cur=0; seq=0; sem[0]=1; sem[1]=0;        /* semA=1, semB=0 */
  thread_create(&tcbs[0], threadA, stackA+256);
  thread_create(&tcbs[1], threadB, stackB+256);
  __asm__ volatile("csrw mtvec, %0" :: "r"((unsigned)(unsigned long)trap_entry));
  dispatch(tcbs[0].sp);                     /* タイマ不要(ecallのみ) */
  return 0;
}
