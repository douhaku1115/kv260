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

#define SYS_EXIT   1
#define SYS_SLEEP  2
#define SYS_WAITRX 7          /* UART受信待ち(割込み駆動) */
#define CTXW     32
#define INTERVAL 1000
#define NTHREAD  6            /* 0=shell, 1..4=worker, 5=idle */
#define IDLE     (NTHREAD-1)
#define STK      256          /* 1スレッドのスタック語数 */
#define ST_FREE   0
#define ST_READY  1
#define ST_SLEEP  2
#define ST_DEAD   3
#define ST_WAITRX 4          /* UART RX 待ちでブロック中 */

typedef struct { unsigned *sp; int state; unsigned wake; int prio; } tcb_t;
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
static void put_hex(unsigned v){ int i; put_s("0x"); for(i=28;i>=0;i-=4){ int d=(v>>i)&0xf; put_c(d<10?'0'+d:'a'+d-10); } }
static void put_sdec(int v){ if(v<0){ put_c('-'); v=-v; } put_dec((unsigned)v); }
static int  str_eq(const char*a,const char*b){ while(*a&&*b){ if(*a!=*b) return 0; a++;b++; } return *a==*b; }
static int  has_pfx(const char*s,const char*p){ while(*p){ if(*s!=*p) return 0; s++;p++; } return 1; }
static int  a_dec(const char*s){ int v=0; while(*s>='0'&&*s<='9'){ v=v*10+(*s-'0'); s++; } return v; }
static unsigned a_hex(const char*s){ unsigned v=0; int d;
  for(;;){ char c=*s++;
    if(c>='0'&&c<='9') d=c-'0'; else if(c>='a'&&c<='f') d=c-'a'+10; else if(c>='A'&&c<='F') d=c-'A'+10; else break;
    v=(v<<4)|d; } return v; }

/* ---- timer ---- */
static unsigned long long get_mtime(void){ unsigned h,l;
  do{ h=*MTIME_HI; l=*MTIME_LO; }while(h!=*MTIME_HI); return ((unsigned long long)h<<32)|l; }
static void set_cmp(unsigned long long t){ *MTIMECMP_HI=0xFFFFFFFF; *MTIMECMP_LO=(unsigned)t; *MTIMECMP_HI=(unsigned)(t>>32); }

/* ---- syscall / 割込み制御(csrr/csrw で手動) ---- */
static inline void sys_sleep(int n){ register int a0 __asm__("a0")=n,a7 __asm__("a7")=SYS_SLEEP;
  __asm__ volatile("ecall"::"r"(a0),"r"(a7):"memory"); }
static inline void sys_waitrx(void){ register int a7 __asm__("a7")=SYS_WAITRX;
  __asm__ volatile("ecall"::"r"(a7):"memory"); }
static inline unsigned int_off(void){ unsigned m;
  __asm__ volatile("csrr %0, mstatus":"=r"(m));
  __asm__ volatile("csrw mstatus, %0"::"r"(m & ~8u));   /* MIE(bit3) クリア */
  return m; }
static inline void int_on(unsigned m){ __asm__ volatile("csrw mstatus, %0"::"r"(m)); }
/* MEIE(mie bit11 = UART RX割込み許可) の arm/mask。csrrc非対応なので clear は csrr+csrw */
static inline void meie_on(void){ __asm__ volatile("csrs mie, %0"::"r"(1<<11)); }
static inline void meie_off(void){ unsigned m; __asm__ volatile("csrr %0, mie":"=r"(m));
  __asm__ volatile("csrw mie, %0"::"r"(m & ~(1u<<11))); }

/* RX読みはFIFOをpopする副作用があるので割込み禁止で保護(非冪等ロード対策)。
   保護しないと読み中にタイマ割込みが入り lw が再実行され、2度popして取りこぼす。 */
static int rx_read(void){ unsigned m=int_off(); int c=(int)(*UART_RX & 0xff); int_on(m); return c; }
/* 割込み駆動: 入力が無ければ ST_WAITRX でブロック→UART割込みで起床 */
static int get_c(void){
  if(*UART_ST & 1) return rx_read();                /* 即読める */
  sys_waitrx();                                     /* ブロック(kernelがMEIE arm) */
  return rx_read();
}

/* ---- threads ---- */
void worker(int id){ for(;;){ cnt[id]++; sys_sleep(3); } }
void idle_thread(void){ for(;;); }

static void tstart(int i, void *f, int arg, int prio){
  unsigned *fr = &stk[i][STK] - CTXW; int k;
  for(k=0;k<CTXW;k++) fr[k]=0;
  fr[0]=(unsigned)f; fr[10]=(unsigned)arg;   /* mepc=f, a0=arg */
  cnt[i]=0; tcbs[i].sp=fr; tcbs[i].prio=prio; tcbs[i].state=ST_READY;
}

static const char* stname(int s){
  return s==ST_READY?"READY":s==ST_SLEEP?"SLEEP":s==ST_DEAD?"DEAD ":s==ST_WAITRX?"WAITR":"FREE ";
}
static void cmd_ps(void){
  int i;
  for(i=0;i<NTHREAD;i++){
    if(tcbs[i].state==ST_FREE && i!=cur) continue;
    put_s(" t"); put_dec(i); put_c(' ');
    put_s(i==cur?"RUN  ":stname(tcbs[i].state));
    put_s(" pri="); put_dec(tcbs[i].prio);
    put_s(" cnt="); put_dec(cnt[i]); put_s("\r\n");
  }
}
static void cmd_dump(unsigned a, int n){
  int i; if(n>16) n=16;
  for(i=0;i<n;i++){
    if((i&3)==0){ if(i) put_s("\r\n"); put_hex(a+i*4); put_c(':'); }
    put_c(' '); put_hex(*(volatile unsigned*)(a+i*4));
  }
  put_s("\r\n");
}
static void cmd_run(void){
  unsigned m=int_off();
  int i; for(i=1;i<IDLE;i++) if(tcbs[i].state==ST_FREE || tcbs[i].state==ST_DEAD){
    tstart(i, (void*)worker, i, 1);       /* ワーカーは優先度1 */
    int_on(m);
    put_s("spawned t"); put_dec(i); put_s("\r\n"); return;
  }
  int_on(m); put_s("no free slot\r\n");
}
static void cmd_kill(int id){
  if(id<1 || id>=IDLE){ put_s("bad id (1.."); put_dec(IDLE-1); put_s(")\r\n"); return; }
  unsigned m=int_off();
  if(tcbs[id].state==ST_FREE){ int_on(m); put_s("no such thread\r\n"); return; }
  tcbs[id].state=ST_FREE;                 /* スロット解放 */
  int_on(m); put_s("killed t"); put_dec(id); put_s("\r\n");
}

static void cmd_calc(const char* p){          /* calc <a> <op> <b> : 四則演算 */
  int a=a_dec(p); while(*p>='0'&&*p<='9')p++; while(*p==' ')p++;
  char op=*p; if(op)p++; while(*p==' ')p++;
  int b=a_dec(p), r;
  switch(op){
    case '+': r=a+b; break;
    case '-': r=a-b; break;
    case '*': r=a*b; break;
    case '/': if(b==0){ put_s("div0\r\n"); return; } r=a/b; break;
    default:  put_s("op? (+ - * /)\r\n"); return;
  }
  put_sdec(r); put_s("\r\n");
}
static void cmd_nice(int id, int pr){
  if(id<0 || id>=NTHREAD){ put_s("bad id\r\n"); return; }
  unsigned m=int_off(); tcbs[id].prio=pr; int_on(m);
  put_s("t"); put_dec(id); put_s(" prio="); put_dec(pr); put_s("\r\n");
}

/* ---- コマンド履歴 ---- */
#define HISTN 4
static char hist[HISTN][40];
static int  histn=0, histw=0;         /* 件数 / 次の書込み位置 */
static void s_cpy(char*d,const char*s){ while((*d++=*s++)); }

void shell(int id){
  char line[40]; (void)id;
  put_s("\r\nKOZOS shell (help)  history:up/down\r\n");
  for(;;){
    put_s("KOZOS> ");
    int n=0, hp=0;                     /* hp=履歴ナビ位置(0=新規行) */
    for(;;){ int c=get_c();
      if(c==0x1b){                     /* ESC: 矢印キー(ESC [ A/B) */
        int a=get_c(), b=get_c();
        if(a=='['&&(b=='A'||b=='B')){
          if(b=='A'){ if(hp<histn) hp++; }          /* ↑ 古い方へ */
          else      { if(hp>0)    hp--; }           /* ↓ 新しい方へ */
          if(hp==0) line[0]=0;
          else s_cpy(line, hist[(histw-hp+HISTN)%HISTN]);
          n=0; while(line[n]) n++;
          put_c('\r'); put_s("KOZOS> "); put_s(line); put_s("\033[K");  /* 行を書き直し */
        }
        continue;
      }
      if(c=='\r'||c=='\n'){ put_s("\r\n"); break; }
      if(c==8||c==127){ if(n){ n--; put_s("\b \b"); } continue; }
      if(c>=32 && c<127 && n<39){ line[n++]=(char)c; put_c((char)c); }
    }
    line[n]=0;
    if(n>0){ s_cpy(hist[histw], line); histw=(histw+1)%HISTN; if(histn<HISTN) histn++; }
    if(str_eq(line,"help"))        put_s("cmds: help echo sum[ n] calc tick ps run kill peek poke dump nice\r\n");
    else if(has_pfx(line,"echo ")) { put_s(line+5); put_s("\r\n"); }
    else if(has_pfx(line,"sum "))  { unsigned n=a_dec(line+4),s=0,i; for(i=1;i<=n;i++) s+=i; put_dec(s); put_s("\r\n"); }
    else if(str_eq(line,"sum"))    { unsigned s=0,i; for(i=1;i<=100;i++) s+=i; put_dec(s); put_s("\r\n"); }
    else if(has_pfx(line,"calc ")) cmd_calc(line+5);
    else if(str_eq(line,"tick"))   { put_s("ticks="); put_dec(ticks); put_s("\r\n"); }
    else if(str_eq(line,"ps"))     cmd_ps();
    else if(str_eq(line,"run"))    cmd_run();
    else if(has_pfx(line,"kill ")) cmd_kill(a_dec(line+5));
    else if(has_pfx(line,"peek ")) { unsigned a=a_hex(line+5); put_hex(*(volatile unsigned*)a); put_s("\r\n"); }
    else if(has_pfx(line,"poke ")) { const char*p=line+5; unsigned a=a_hex(p);
                                     while(*p&&*p!=' ')p++; while(*p==' ')p++; unsigned v=a_hex(p);
                                     *(volatile unsigned*)a=v; put_s("ok\r\n"); }
    else if(has_pfx(line,"dump ")) { const char*p=line+5; unsigned a=a_hex(p);
                                     while(*p&&*p!=' ')p++; while(*p==' ')p++; int nn=a_dec(p);
                                     cmd_dump(a, nn?nn:4); }
    else if(has_pfx(line,"nice ")) { const char*p=line+5; int id=a_dec(p);
                                     while(*p&&*p!=' ')p++; while(*p==' ')p++; int pr=a_dec(p);
                                     cmd_nice(id, pr); }
    else if(n)                     put_s("?\r\n");
  }
}

/* ---- scheduler ---- */
unsigned* ksched(unsigned *frame, int sc, unsigned mcause){
  tcbs[cur].sp = frame;
  int i;
  if ((int)mcause < 0){                    /* 割込み */
    unsigned code = mcause & 0xff;
    if (code == 7){                         /* タイマ=システムティック */
      set_cmp(get_mtime()+INTERVAL); ticks++;
      for(i=0;i<IDLE;i++)
        if(tcbs[i].state==ST_SLEEP && ticks>=tcbs[i].wake) tcbs[i].state=ST_READY;
    } else if (code == 11){                 /* 外部=UART RX。maskして待ちスレッドを起こす */
      meie_off();
      for(i=0;i<IDLE;i++) if(tcbs[i].state==ST_WAITRX) tcbs[i].state=ST_READY;
    }
  } else if (sc==SYS_SLEEP){ tcbs[cur].state=ST_SLEEP; tcbs[cur].wake=ticks+frame[10]; }
  else if (sc==SYS_WAITRX){ tcbs[cur].state=ST_WAITRX; meie_on(); }  /* UART割込みをarm */
  else if (sc==SYS_EXIT){ tcbs[cur].state=ST_DEAD; }
  /* 優先度スケジューリング: READYの中で最高prioを選ぶ(同prioはround-robin) */
  int best=-1, bestp=-1;
  for(i=1;i<=IDLE;i++){ int c=(cur+i)%IDLE;
    if(tcbs[c].state==ST_READY && tcbs[c].prio>bestp){ bestp=tcbs[c].prio; best=c; } }
  if(best<0) best=IDLE;
  cur=best; return tcbs[best].sp;
}

int main(void){
  cur=0; ticks=0;
  int i; for(i=0;i<NTHREAD;i++){ tcbs[i].state=ST_FREE; cnt[i]=0; }
  tstart(0, (void*)shell, 0, 2);           /* shell 優先度2(最高) */
  tstart(IDLE, (void*)idle_thread, 0, 0);  /* idle 優先度0 */
  __asm__ volatile("csrw mtvec, %0"   :: "r"((unsigned)(unsigned long)trap_entry));
  set_cmp(get_mtime()+INTERVAL);
  __asm__ volatile("csrs mie, %0"     :: "r"(0x80));   /* MTIE */
  __asm__ volatile("csrw mstatus, %0" :: "r"(0x80));   /* MPIE=1 -> mretでMIE=1 */
  dispatch(tcbs[0].sp);
  return 0;
}
