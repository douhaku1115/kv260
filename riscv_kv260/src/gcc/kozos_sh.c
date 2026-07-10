/* KOZOS 第5段-7: 対話シェル + プリエンプティブ・カーネル統合
   シェルを1つのKOZOSスレッドとして走らせ、タイマ・プリエンプションで
   ワーカースレッドと並行動作。コマンドで生きたOSを操作する。
     help / echo <text> / sum / tick(システムtick) / ps(スレッド一覧) / run(ワーカー起動)
   コア=m_proc_console(UART+timer+CSR+RV32I), kentry.S 流用。
   ※コアが正しく実装するCSR命令は csrrw/csrrs のみ。割込み禁止は csrr+csrw で手動。 */
#define UART_TX ((volatile unsigned*)0x00040000)
#define UART_ST ((volatile unsigned*)0x00040004)
#define UART_RX ((volatile unsigned*)0x00040008)
#define MTIMECMP_LO ((volatile unsigned*)0x00030000)
#define MTIMECMP_HI ((volatile unsigned*)0x00030004)
#define MTIME_LO    ((volatile unsigned*)0x00030008)
#define MTIME_HI    ((volatile unsigned*)0x0003000C)

#define SYS_EXIT  1
#define SYS_SLEEP 2
#define CTXW     32
#define INTERVAL 1000
#define NTHREAD  6            /* 0=shell, 1..4=worker, 5=idle */
#define IDLE     (NTHREAD-1)
#define STK      256          /* 1スレッドのスタック語数 */
#define ST_FREE  0
#define ST_READY 1
#define ST_SLEEP 2
#define ST_DEAD  3

typedef struct { unsigned *sp; int state; unsigned wake; } tcb_t;
extern void trap_entry(void);
extern void dispatch(unsigned *sp);

tcb_t tcbs[NTHREAD];
int   cur;
unsigned ticks;
volatile unsigned cnt[NTHREAD];
static unsigned stk[NTHREAD][STK];

/* ---- UART ---- */
static void put_c(char c){ while(*UART_ST & 2); *UART_TX=(unsigned char)c; }
static void put_s(const char*s){ while(*s) put_c(*s++); }
static void put_dec(unsigned v){ char b[12]; int i=0;
  if(!v){ put_c('0'); return; } while(v){ b[i++]='0'+v%10; v/=10; } while(i) put_c(b[--i]); }
static int  str_eq(const char*a,const char*b){ while(*a&&*b){ if(*a!=*b) return 0; a++;b++; } return *a==*b; }
static int  has_pfx(const char*s,const char*p){ while(*p){ if(*s!=*p) return 0; s++;p++; } return 1; }

/* ---- timer ---- */
static unsigned long long get_mtime(void){ unsigned h,l;
  do{ h=*MTIME_HI; l=*MTIME_LO; }while(h!=*MTIME_HI); return ((unsigned long long)h<<32)|l; }
static void set_cmp(unsigned long long t){ *MTIMECMP_HI=0xFFFFFFFF; *MTIMECMP_LO=(unsigned)t; *MTIMECMP_HI=(unsigned)(t>>32); }

/* ---- syscall / 割込み制御(csrr/csrw で手動) ---- */
static inline void sys_sleep(int n){ register int a0 __asm__("a0")=n,a7 __asm__("a7")=SYS_SLEEP;
  __asm__ volatile("ecall"::"r"(a0),"r"(a7):"memory"); }
static inline unsigned int_off(void){ unsigned m;
  __asm__ volatile("csrr %0, mstatus":"=r"(m));
  __asm__ volatile("csrw mstatus, %0"::"r"(m & ~8u));   /* MIE(bit3) クリア */
  return m; }
static inline void int_on(unsigned m){ __asm__ volatile("csrw mstatus, %0"::"r"(m)); }

/* 入力が無ければ sleep して他スレッドに譲る */
static int get_c(void){ while(!(*UART_ST & 1)) sys_sleep(1); return (int)(*UART_RX & 0xff); }

/* ---- threads ---- */
void worker(int id){ for(;;){ cnt[id]++; sys_sleep(3); } }
void idle_thread(void){ for(;;); }

static void tstart(int i, void *f, int arg){
  unsigned *fr = &stk[i][STK] - CTXW; int k;
  for(k=0;k<CTXW;k++) fr[k]=0;
  fr[0]=(unsigned)f; fr[10]=(unsigned)arg;   /* mepc=f, a0=arg */
  cnt[i]=0; tcbs[i].sp=fr; tcbs[i].state=ST_READY;
}

static const char* stname(int s){
  return s==ST_READY?"READY":s==ST_SLEEP?"SLEEP":s==ST_DEAD?"DEAD ":"FREE ";
}
static void cmd_ps(void){
  int i;
  for(i=0;i<NTHREAD;i++){
    if(tcbs[i].state==ST_FREE && i!=cur) continue;
    put_s(" t"); put_dec(i); put_c(' ');
    put_s(i==cur?"RUN  ":stname(tcbs[i].state));
    put_s(" cnt="); put_dec(cnt[i]); put_s("\r\n");
  }
}
static void cmd_run(void){
  unsigned m=int_off();
  int i; for(i=1;i<IDLE;i++) if(tcbs[i].state==ST_FREE || tcbs[i].state==ST_DEAD){
    tstart(i, (void*)worker, i);
    int_on(m);
    put_s("spawned t"); put_dec(i); put_s("\r\n"); return;
  }
  int_on(m); put_s("no free slot\r\n");
}

void shell(int id){
  char line[40]; (void)id;
  put_s("\r\nKOZOS shell (help/echo/sum/tick/ps/run)\r\n");
  for(;;){
    put_s("KOZOS> ");
    int n=0;
    for(;;){ int c=get_c();
      if(c=='\r'||c=='\n'){ put_s("\r\n"); break; }
      if(c==8||c==127){ if(n){ n--; put_s("\b \b"); } continue; }
      if(n<39){ line[n++]=(char)c; put_c((char)c); }
    }
    line[n]=0;
    if(str_eq(line,"help"))        put_s("cmds: help echo sum tick ps run\r\n");
    else if(has_pfx(line,"echo ")) { put_s(line+5); put_s("\r\n"); }
    else if(str_eq(line,"sum"))    { unsigned s=0,i; for(i=1;i<=100;i++) s+=i; put_dec(s); put_s("\r\n"); }
    else if(str_eq(line,"tick"))   { put_s("ticks="); put_dec(ticks); put_s("\r\n"); }
    else if(str_eq(line,"ps"))     cmd_ps();
    else if(str_eq(line,"run"))    cmd_run();
    else if(n)                     put_s("?\r\n");
  }
}

/* ---- scheduler ---- */
unsigned* ksched(unsigned *frame, int sc, unsigned mcause){
  tcbs[cur].sp = frame;
  if ((int)mcause < 0){                    /* タイマ=システムティック */
    set_cmp(get_mtime()+INTERVAL); ticks++;
    int i; for(i=0;i<IDLE;i++)
      if(tcbs[i].state==ST_SLEEP && ticks>=tcbs[i].wake) tcbs[i].state=ST_READY;
  } else if (sc==SYS_SLEEP){ tcbs[cur].state=ST_SLEEP; tcbs[cur].wake=ticks+frame[10]; }
  else if (sc==SYS_EXIT){ tcbs[cur].state=ST_DEAD; }
  int n=-1,i;                              /* real(0..IDLE-1) round-robin, 無ければidle */
  for(i=1;i<=IDLE;i++){ int c=(cur+i)%IDLE; if(tcbs[c].state==ST_READY){ n=c; break; } }
  if(n<0) n=IDLE;
  cur=n; return tcbs[n].sp;
}

int main(void){
  cur=0; ticks=0;
  int i; for(i=0;i<NTHREAD;i++){ tcbs[i].state=ST_FREE; cnt[i]=0; }
  tstart(0, (void*)shell, 0);              /* shell */
  tstart(IDLE, (void*)idle_thread, 0);     /* idle */
  __asm__ volatile("csrw mtvec, %0"   :: "r"((unsigned)(unsigned long)trap_entry));
  set_cmp(get_mtime()+INTERVAL);
  __asm__ volatile("csrs mie, %0"     :: "r"(0x80));   /* MTIE */
  __asm__ volatile("csrw mstatus, %0" :: "r"(0x80));   /* MPIE=1 -> mretでMIE=1 */
  dispatch(tcbs[0].sp);
  return 0;
}
