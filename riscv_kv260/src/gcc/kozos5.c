/* KOZOS 第5段-5: メッセージング (send / recv)
   各スレッドにメールボックス(リングバッファ)。recv は戻り値(a0)で受信値を返す。
   send(dst,v): dst が recv 待ちなら直接 dst の a0 に届けて起こす、でなければキューに積む。
   recv():      自メールボックスに在れば取り出して継続、空なら BLOCK。
   デモ(ランデブー): producer が値1,2,3を送り毎回 ack を待つ / consumer が受信して
   seq に積み ack を返す → send/recv のブロック・起床・データ転送で seq=123。
   タイマ不使用(ecallのみ)。kentry.S/コアは無変更で流用。 */
#define SYS_EXIT 1
#define SYS_SEND 5
#define SYS_RECV 6
#define CTXW  32
#define NREAL 2
#define MBSZ  4                /* メールボックス段数(2の冪) */
#define ST_READY 0
#define ST_BLOCK 1
#define ST_DEAD  2
#define RESULT ((volatile unsigned*)0x00020000)

typedef struct {
  unsigned *sp; int state;
  int mbox[MBSZ]; unsigned mh, mt;   /* リングバッファ head/tail */
} tcb_t;
extern void trap_entry(void);
extern void dispatch(unsigned *sp);

tcb_t tcbs[2];
int   cur;
volatile unsigned seq;
static unsigned stackA[256], stackB[256];

static inline void sys_send(int dst, int v){
  register int a0 __asm__("a0")=dst; register int a1 __asm__("a1")=v;
  register int a7 __asm__("a7")=SYS_SEND;
  __asm__ volatile("ecall" :: "r"(a0),"r"(a1),"r"(a7) : "memory");
}
static inline int sys_recv(void){
  register int a0 __asm__("a0"); register int a7 __asm__("a7")=SYS_RECV;
  __asm__ volatile("ecall" : "=r"(a0) : "r"(a7) : "memory");
  return a0;                  /* カーネルが a0 に受信値をセット */
}
static inline void sys_exit(void){
  register int a7 __asm__("a7")=SYS_EXIT;
  __asm__ volatile("ecall" :: "r"(a7) : "memory");
}

/* producer: 値1,2,3 を送り、毎回 ack を待つ */
void threadP(void){ int v; for(v=1;v<=3;v++){ sys_send(1, v); sys_recv(); } sys_exit(); }
/* consumer: 受信して seq に積み、ack を返す */
void threadC(void){ int i,v; for(i=0;i<3;i++){ v=sys_recv(); seq=seq*10+v; sys_send(0,0); } sys_exit(); }

void thread_create(tcb_t *t, void (*f)(void), unsigned *sptop){
  unsigned *fr=sptop-CTXW; int i; for(i=0;i<CTXW;i++) fr[i]=0;
  fr[0]=(unsigned)f; t->sp=fr; t->state=ST_READY; t->mh=0; t->mt=0;
}

unsigned* ksched(unsigned *frame, int sc, unsigned mcause){
  tcbs[cur].sp = frame;
  if (sc==SYS_SEND){
    int dst=frame[10], v=frame[11];        /* a0=dst, a1=value */
    if (tcbs[dst].state==ST_BLOCK){         /* 受信待ち→直接 a0 に届けて起こす */
      tcbs[dst].sp[10]=v; tcbs[dst].state=ST_READY;
    } else {                                /* でなければキューへ */
      tcbs[dst].mbox[tcbs[dst].mt & (MBSZ-1)]=v; tcbs[dst].mt++;
    }
  } else if (sc==SYS_RECV){
    if (tcbs[cur].mh != tcbs[cur].mt){       /* 在れば取り出して継続 */
      frame[10]=tcbs[cur].mbox[tcbs[cur].mh & (MBSZ-1)]; tcbs[cur].mh++;
    } else {                                /* 空→ブロック(sendがa0をセットして起こす) */
      tcbs[cur].state=ST_BLOCK;
    }
  } else if (sc==SYS_EXIT){
    tcbs[cur].state=ST_DEAD;
  }
  if (tcbs[0].state==ST_DEAD && tcbs[1].state==ST_DEAD){ *RESULT=seq; for(;;); }
  if (tcbs[cur].state==ST_READY) return tcbs[cur].sp;   /* 現スレッド継続 */
  int n=-1,i;
  for(i=1;i<=NREAL;i++){ int c=(cur+i)%NREAL; if(tcbs[c].state==ST_READY){ n=c; break; } }
  if (n<0){ *RESULT=0xDEAD; for(;;); }
  cur=n; return tcbs[n].sp;
}

int main(void){
  cur=0; seq=0;
  thread_create(&tcbs[0], threadP, stackA+256);   /* 0=producer */
  thread_create(&tcbs[1], threadC, stackB+256);   /* 1=consumer */
  __asm__ volatile("csrw mtvec, %0" :: "r"((unsigned)(unsigned long)trap_entry));
  dispatch(tcbs[0].sp);
  return 0;
}
