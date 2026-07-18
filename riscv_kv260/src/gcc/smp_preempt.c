/* 2コアSMP プリエンプティブ・スケジューラ: yieldしない暴走スレッドを
   タイマ割込みで強制的に切り替える。
   PREEMPT定義時: 3スレッドが時分割で全部動く(全COUNTER>0)。
   非定義時    : 割込み無し→2スレッドが2コアを占有、3番目は餓死(COUNTER(2)=0)。 */
#define HARTID    (*(volatile unsigned*)0x00030008)
#define LOCK      (*(volatile unsigned*)0x00030000)
#define MTIMECMPL (*(volatile unsigned*)0x00060000)
#define MTIMECMPH (*(volatile unsigned*)0x00060004)
#define MTIMEL    (*(volatile unsigned*)0x00060008)
#define NT 3
#define READY 1
#define RUN   2
#define INTERVAL 500
#define TCB_SP(t)  (*(volatile unsigned*)(0x00040800+(t)*4))
#define TCB_ST(t)  (*(volatile unsigned*)(0x00040810+(t)*4))
#define CURR(h)    (*(volatile unsigned*)(0x00040820+(h)*4))
#define SCHSP(h)   (*(volatile unsigned*)(0x00040828+(h)*4))
#define TCBSP_A(t) ((unsigned*)(0x00040800+(t)*4))
#define SCHSP_A(h) ((unsigned*)(0x00040828+(h)*4))
#define COUNTER(t) (*(volatile unsigned*)(0x00040840+(t)*4))
#define INITDONE   (*(volatile unsigned*)0x00040860)
#define RR         (*(volatile unsigned*)0x00040864)   /* ラウンドロビン共有ポインタ */
#define STKTOP(t)  (0x00040000+((t)+1)*512)

extern void swtch(unsigned* save, unsigned newsp);
static void set_mie(void){ __asm__ volatile("csrs mstatus,%0"::"r"(8)); }
static void lock(void){ while(LOCK); }
static void unlock(void){ LOCK=0; }

void preempt(void){ unsigned h=HARTID; swtch(TCBSP_A(CURR(h)), SCHSP(h)); }

__attribute__((interrupt("machine")))
void timer_trap(void){ preempt(); }   /* 強制リスケジュール(caller-save/mretは属性が処理) */

void thread_body(void){
    unsigned h=HARTID, t=CURR(h);
    set_mie();                         /* 実行中は割込み可=プリエンプト可能 */
    for(;;) COUNTER(t) = COUNTER(t) + 1;   /* yieldしない暴走ループ */
}
static void setup_thread(int t){
    unsigned sp=STKTOP(t)-52; volatile unsigned* c=(volatile unsigned*)sp;
    int i; for(i=0;i<12;i++) c[i]=0; c[12]=(unsigned)(&thread_body);
    TCB_SP(t)=sp; TCB_ST(t)=READY; COUNTER(t)=0;
}
void sched(void){
    for(;;){
        unsigned h=HARTID;
        lock();
        int t=-1,i,r; for(i=0;i<NT;i++){ r=(RR+i)%NT; if(TCB_ST(r)==READY){t=r;break;} }
        if(t<0){ unlock(); continue; }
        RR=(t+1)%NT; TCB_ST(t)=RUN; CURR(h)=t; unlock();
        MTIMECMPH=0; MTIMECMPL = MTIMEL + INTERVAL;   /* 新スライス(MTIP解除) */
        swtch(SCHSP_A(h), TCB_SP(t));                  /* 実行。プリエンプトで戻る */
        lock(); if(TCB_ST(t)==RUN) TCB_ST(t)=READY; unlock();
    }
}
int main(void){
    unsigned h=HARTID;
    __asm__ volatile("csrw mtvec,%0"::"r"(&timer_trap));
#ifdef PREEMPT
    __asm__ volatile("csrw mie,%0"::"r"(0x80));   /* MTIE=bit7 */
#endif
    if(h==0){ int t; RR=0; for(t=0;t<NT;t++) setup_thread(t); INITDONE=1; }
    else { while(INITDONE==0); }
    sched();
    for(;;);
}
