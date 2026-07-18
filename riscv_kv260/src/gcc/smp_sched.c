/* 2コアSMPスケジューラ(段4): スレッドを共有RAMのスタックで動かし、両コアが
   共有レディキューから取り出して実行。yieldで別コアへ移送可能。
   共有データは全て固定共有RAMアドレス(Cグローバルは私有DMEMになるため不可)。 */
#define HARTID (*(volatile unsigned*)0x00030008)
#define LOCK   (*(volatile unsigned*)0x00030000)
#define DONEF  (*(volatile unsigned*)0x0003000C)
#define RESULT (*(volatile unsigned*)0x00030004)   /* VIO可視: 総カウント */

#define NT 3
#define M  5
#define READY 1
#define RUN   2
#define DEAD  3
/* 共有RAM上の管理データ(固定番地) */
#define TCB_SP(t)    (*(volatile unsigned*)(0x00040800 + (t)*4))
#define TCB_ST(t)    (*(volatile unsigned*)(0x00040810 + (t)*4))
#define CURR(h)      (*(volatile unsigned*)(0x00040820 + (h)*4))
#define SCHSP_A(h)   ((unsigned*)          (0x00040828 + (h)*4))  /* swtch保存先アドレス */
#define SCHSP(h)     (*(volatile unsigned*)(0x00040828 + (h)*4))
#define TCBSP_A(t)   ((unsigned*)          (0x00040800 + (t)*4))
#define COUNTER(t)   (*(volatile unsigned*)(0x00040840 + (t)*4))
#define RANMASK(t)   (*(volatile unsigned*)(0x00040850 + (t)*4))
#define INITDONE     (*(volatile unsigned*)0x00040860)
#define STKTOP(t)    (0x00040000 + ((t)+1)*512)

extern void swtch(unsigned* save_sp_addr, unsigned new_sp);

static void lock(void){ while(LOCK) ; }
static void unlock(void){ LOCK = 0; }

void yield(void){
    unsigned h = HARTID;
    unsigned t = CURR(h);
    swtch(TCBSP_A(t), SCHSP(h));   /* スレッド文脈を保存しスケジューラへ */
}

void thread_body(void){
    unsigned h = HARTID;
    unsigned t = CURR(h);          /* 自分のtid(スケジューラが設定) */
    int i;
    for(i=0;i<M;i++){
        COUNTER(t) = COUNTER(t) + 1;         /* このスレッドは1コアのみ実行=競合なし */
        RANMASK(t) = RANMASK(t) | (1u << HARTID);  /* 動いたコアを記録 */
        yield();
    }
    TCB_ST(t) = DEAD;
    for(;;) yield();               /* 終了: 以後スケジューラは選ばない */
}

static void setup_thread(int t){
    unsigned sp = STKTOP(t) - 52;              /* swtch文脈ぶん */
    volatile unsigned* ctx = (volatile unsigned*)sp;
    int i; for(i=0;i<12;i++) ctx[i] = 0;       /* s0-s11 = 0 */
    ctx[12] = (unsigned)(&thread_body);        /* ra = エントリ(offset48) */
    TCB_SP(t) = sp;
    TCB_ST(t) = READY;
    COUNTER(t) = 0; RANMASK(t) = 0;
}

static int all_dead(void){
    int i; for(i=0;i<NT;i++) if(TCB_ST(i)!=DEAD) return 0; return 1;
}

void sched(void){
    for(;;){
        unsigned h = HARTID;
        lock();
        int t=-1, i;
        for(i=0;i<NT;i++) if(TCB_ST(i)==READY){ t=i; break; }
        if(t<0){
            if(all_dead()){ unlock(); return; }
            unlock(); continue;
        }
        TCB_ST(t) = RUN;
        CURR(h)   = t;
        unlock();
        swtch(SCHSP_A(h), TCB_SP(t));   /* スレッド実行。yieldで戻る */
        lock();
        if(TCB_ST(t)==RUN) TCB_ST(t)=READY;   /* 実行中のまま戻った=まだREADYへ */
        unlock();
    }
}

int main(void){
    unsigned h = HARTID;
    if(h==0){
        int t; for(t=0;t<NT;t++) setup_thread(t);
        INITDONE = 1;
    } else {
        while(INITDONE==0) ;
    }
    sched();
    if(h==0) RESULT = COUNTER(0)+COUNTER(1)+COUNTER(2);  /* =15 のはず */
    DONEF = (1u << h);
    for(;;) ;
}
