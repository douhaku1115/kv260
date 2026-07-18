/* KOZOS SMP (段B2): カーネル自体のSMP化。
   - TCB/スレッドスタックは共有RAM(0x0007_xxxx, 16KB)に置き、両コアがkschedを実行。
   - カーネルはハードウェアTASロック(0x60000)で保護(トラップ中=MIE0で取得→デッドロック無し)。
   - shellはhart0固定(UART RX/MEIEがcore0のみ)。worker(1..4)は両コアを移動(マイグレーション)。
   - idleはhartごとに1本(5=hart0, 6=hart1)。ticksはhart0のタイマのみが進める。
   - psに h列(最後に走ったhart)を表示。UART出力はshell(hart0)のみ=ロック不要。
   ※Cグローバルは私有DMEM(shell専用のline/hist等のみ可)。共有状態は必ず固定番地マクロで。 */
#define UART_TX ((volatile unsigned*)0x00040000)
#define UART_ST ((volatile unsigned*)0x00040004)
#define UART_RX ((volatile unsigned*)0x00040008)
#define MTIMECMP_LO ((volatile unsigned*)0x00030000)
#define MTIMECMP_HI ((volatile unsigned*)0x00030004)
#define MTIME_LO    ((volatile unsigned*)0x00030008)
#define MTIME_HI    ((volatile unsigned*)0x0003000C)
#define HARTID   (*(volatile unsigned*)0x00060008)
#define KLOCK    (*(volatile unsigned*)0x00060000)   /* 読=TAS / 書=解放 */

#define SYS_EXIT   1
#define SYS_SLEEP  2
#define SYS_WAITRX 7
#define CTXW     32
#define INTERVAL 1000
#define NTHREAD  7            /* 0=shell(h0固定), 1..4=worker(移動可), 5=idle_h0, 6=idle_h1 */
#define NREAL    5            /* スケジュール対象 0..4 */
#define ST_FREE   0
#define ST_READY  1
#define ST_SLEEP  2
#define ST_DEAD   3
#define ST_WAITRX 4
#define ST_RUN    5           /* SMP: 他hartが実行中(選んではいけない) */

/* ---- 共有RAM上のカーネル状態(固定番地) ----
   スタック: 0x70000 + t*0x400 (各1KB) / 管理変数: 0x73E00- */
#define STKTOP(t)  (0x00070000 + ((t)+1)*0x400)
#define T_SP(t)    (*(volatile unsigned*)(0x00073E00+((t)<<2)))
#define T_ST(t)    (*(volatile unsigned*)(0x00073E20+((t)<<2)))
#define T_WAKE(t)  (*(volatile unsigned*)(0x00073E40+((t)<<2)))
#define T_PRIO(t)  (*(volatile int*)    (0x00073E60+((t)<<2)))
#define T_HART(t)  (*(volatile unsigned*)(0x00073E80+((t)<<2)))
#define CNT(t)     (*(volatile unsigned*)(0x00073EA0+((t)<<2)))
#define TICKS      (*(volatile unsigned*)0x00073EC0)
#define CURH(h)    (*(volatile unsigned*)(0x00073EC4+((h)<<2)))
#define INITDONE   (*(volatile unsigned*)0x00073ECC)

extern void trap_entry(void);
extern void dispatch(unsigned *sp);

/* ---- カーネルロック(ハードTAS)。必ず MIE=0 の文脈で使う ---- */
static void klock(void){ while(KLOCK) ; }
static void kunlock(void){ KLOCK = 0; }

/* ---- UART(shell/hart0のみが使う) ---- */
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

/* ---- timer(per-core) ---- */
static unsigned long long get_mtime(void){ unsigned h,l;
  do{ h=*MTIME_HI; l=*MTIME_LO; }while(h!=*MTIME_HI); return ((unsigned long long)h<<32)|l; }
static void set_cmp(unsigned long long t){ *MTIMECMP_HI=0xFFFFFFFF; *MTIMECMP_LO=(unsigned)t; *MTIMECMP_HI=(unsigned)(t>>32); }

/* ---- syscall / 割込み制御 ---- */
static inline void sys_sleep(int n){ register int a0 __asm__("a0")=n,a7 __asm__("a7")=SYS_SLEEP;
  __asm__ volatile("ecall"::"r"(a0),"r"(a7):"memory"); }
static inline void sys_waitrx(void){ register int a7 __asm__("a7")=SYS_WAITRX;
  __asm__ volatile("ecall"::"r"(a7):"memory"); }
static inline unsigned int_off(void){ unsigned m;
  __asm__ volatile("csrr %0, mstatus":"=r"(m));
  __asm__ volatile("csrw mstatus, %0"::"r"(m & ~8u));
  return m; }
static inline void int_on(unsigned m){ __asm__ volatile("csrw mstatus, %0"::"r"(m)); }
static inline void meie_on(void){ __asm__ volatile("csrs mie, %0"::"r"(1<<11)); }
static inline void meie_off(void){ unsigned m; __asm__ volatile("csrr %0, mie":"=r"(m));
  __asm__ volatile("csrw mie, %0"::"r"(m & ~(1u<<11))); }

static int rx_read(void){ unsigned m=int_off(); int c=(int)(*UART_RX & 0xff); int_on(m); return c; }
static int get_c(void){
  if(*UART_ST & 1) return rx_read();
  sys_waitrx();
  return rx_read();
}

/* ---- threads ---- */
void worker(int id){ for(;;){ CNT(id)=CNT(id)+1; sys_sleep(3); } }
void idle_thread(void){ for(;;); }

static void tstart(int i, void *f, int arg, int prio){
  unsigned *fr = (unsigned*)STKTOP(i) - CTXW; int k;
  for(k=0;k<CTXW;k++) fr[k]=0;
  fr[0]=(unsigned)f; fr[10]=(unsigned)arg;   /* mepc=f, a0=arg */
  CNT(i)=0; T_SP(i)=(unsigned)fr; T_PRIO(i)=prio; T_WAKE(i)=0; T_HART(i)=9; T_ST(i)=ST_READY;
}

static const char* stname(unsigned s){
  return s==ST_READY?"READY":s==ST_SLEEP?"SLEEP":s==ST_DEAD?"DEAD ":
         s==ST_WAITRX?"WAITR":s==ST_RUN?"RUN  ":"FREE ";
}
static void cmd_ps(void){
  int i;
  for(i=0;i<NTHREAD;i++){
    if(T_ST(i)==ST_FREE) continue;
    put_s(" t"); put_dec(i); put_c(' ');
    put_s(stname(T_ST(i)));
    put_s(" pri="); put_dec((unsigned)T_PRIO(i));
    put_s(" h=");   if(T_HART(i)==9) put_c('-'); else put_dec(T_HART(i));
    put_s(" cnt="); put_dec(CNT(i)); put_s("\r\n");
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
  unsigned m=int_off(); klock();
  int i; for(i=1;i<NREAL;i++) if(T_ST(i)==ST_FREE || T_ST(i)==ST_DEAD){
    tstart(i, (void*)worker, i, 1);
    kunlock(); int_on(m);
    put_s("spawned t"); put_dec(i); put_s("\r\n"); return;
  }
  kunlock(); int_on(m); put_s("no free slot\r\n");
}
static void cmd_kill(int id){
  if(id<1 || id>=NREAL){ put_s("bad id\r\n"); return; }
  unsigned m=int_off(); klock();
  if(T_ST(id)==ST_FREE){ kunlock(); int_on(m); put_s("no such thread\r\n"); return; }
  T_ST(id)=ST_FREE;
  kunlock(); int_on(m); put_s("killed t"); put_dec(id); put_s("\r\n");
}
static void cmd_nice(int id, int pr){
  if(id<0 || id>=NTHREAD){ put_s("bad id\r\n"); return; }
  unsigned m=int_off(); klock(); T_PRIO(id)=pr; kunlock(); int_on(m);
  put_s("t"); put_dec(id); put_s(" prio="); put_dec(pr); put_s("\r\n");
}

/* ---- load(ブートローダ, hart0/私有DMEM) ---- */
static int is_hex(int c){ return (c>='0'&&c<='9') || ((c|0x20)>='a'&&(c|0x20)<='f'); }
static unsigned read_hex_word(void){
  int c; unsigned v=0;
  do{ c=get_c(); }while(!is_hex(c));
  for(;;){ int d;
    if(c>='0'&&c<='9') d=c-'0';
    else if((c|0x20)>='a'&&(c|0x20)<='f') d=(c|0x20)-'a'+10;
    else break;
    v=(v<<4)|d; c=get_c(); }
  return v;
}
#define LOADADDR 0x00013000
static void cmd_load(int n){
  volatile unsigned* dst = (volatile unsigned*)LOADADDR;
  int i;
  put_s("send "); put_dec(n); put_s(" hex words:\r\n");
  for(i=0;i<n;i++){ dst[i]=read_hex_word(); put_hex(dst[i]); put_c(' '); }
  put_s("\r\nrun @13000...\r\n");
  int r = ((int(*)(void))LOADADDR)();
  put_s("ret="); put_sdec(r); put_s("\r\n");
}
static void cmd_calc(const char* p){
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

/* ---- コマンド履歴(私有DMEM=shellはhart0固定なので可) ---- */
#define HISTN 4
static char hist[HISTN][40];
static int  histn=0, histw=0;
static void s_cpy(char*d,const char*s){ while((*d++=*s++)); }

void shell(int id){
  char line[40]; (void)id;
  put_s("\r\nKOZOS SMP shell (help)\r\n");
  for(;;){
    put_s("KOZOS> ");
    int n=0, hp=0;
    for(;;){ int c=get_c();
      if(c==0x1b){
        int a=get_c(), b=get_c();
        if(a=='['&&(b=='A'||b=='B')){
          if(b=='A'){ if(hp<histn) hp++; }
          else      { if(hp>0)    hp--; }
          if(hp==0) line[0]=0;
          else s_cpy(line, hist[(histw-hp+HISTN)%HISTN]);
          n=0; while(line[n]) n++;
          put_c('\r'); put_s("KOZOS> "); put_s(line); put_s("\033[K");
        }
        continue;
      }
      if(c=='\r'||c=='\n'){ put_s("\r\n"); break; }
      if(c==8||c==127){ if(n){ n--; put_s("\b \b"); } continue; }
      if(c>=32 && c<127 && n<39){ line[n++]=(char)c; put_c((char)c); }
    }
    line[n]=0;
    if(n>0){ s_cpy(hist[histw], line); histw=(histw+1)%HISTN; if(histn<HISTN) histn++; }
    if(str_eq(line,"help"))        put_s("cmds: help echo sum[ n] calc tick ps run kill peek poke dump nice load smp\r\n");
    else if(str_eq(line,"smp"))    { put_s("hart0: t"); put_dec(CURH(0));
                                     put_s("  hart1: t"); put_dec(CURH(1)); put_s("\r\n"); }
    else if(has_pfx(line,"echo ")) { put_s(line+5); put_s("\r\n"); }
    else if(has_pfx(line,"sum "))  { unsigned n=a_dec(line+4),s=0,i; for(i=1;i<=n;i++) s+=i; put_dec(s); put_s("\r\n"); }
    else if(str_eq(line,"sum"))    { unsigned s=0,i; for(i=1;i<=100;i++) s+=i; put_dec(s); put_s("\r\n"); }
    else if(has_pfx(line,"calc ")) cmd_calc(line+5);
    else if(str_eq(line,"tick"))   { put_s("ticks="); put_dec(TICKS); put_s("\r\n"); }
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
    else if(has_pfx(line,"load ")) cmd_load(a_dec(line+5));
    else if(n)                     put_s("?\r\n");
  }
}

/* ---- SMPスケジューラ(トラップ文脈=MIE0で実行, カーネルロックで直列化) ---- */
unsigned* ksched(unsigned *frame, int sc, unsigned mcause){
  unsigned h = HARTID;
  klock();
  int t = (int)CURH(h);
  T_SP(t)=(unsigned)frame; T_HART(t)=h;
  if (T_ST(t)==ST_RUN) T_ST(t)=ST_READY;    /* まだ走れる状態ならREADYへ戻す */
  int i;
  if ((int)mcause < 0){                     /* 割込み */
    unsigned code = mcause & 0xff;
    if (code == 7){                          /* タイマ(プリエンプション) */
      set_cmp(get_mtime() + (h ? INTERVAL+300 : INTERVAL));  /* hartで位相をずらす */
      if (h==0){                             /* ticksはhart0のみ進める */
        TICKS = TICKS + 1;
        for(i=0;i<NREAL;i++)
          if(T_ST(i)==ST_SLEEP && TICKS>=T_WAKE(i)) T_ST(i)=ST_READY;
      }
    } else if (code == 11){                  /* UART RX(hart0のみ配線) */
      meie_off();
      for(i=0;i<NREAL;i++) if(T_ST(i)==ST_WAITRX) T_ST(i)=ST_READY;
    }
  } else if (sc==SYS_SLEEP){ T_ST(t)=ST_SLEEP; T_WAKE(t)=TICKS+frame[10]; }
  else if (sc==SYS_WAITRX){ T_ST(t)=ST_WAITRX; meie_on(); }  /* shell=hart0のみ発行 */
  else if (sc==SYS_EXIT){ T_ST(t)=ST_DEAD; }
  /* 選択: 0..4のREADYから最高prio(同prioはRR)。shell(t0)はhart0のみ。無ければ自hartのidle */
  int best=-1, bestp=-1;
  for(i=1;i<=NREAL;i++){ int c=(t+i)%NREAL;
    if(c==0 && h!=0) continue;               /* shellはhart0固定 */
    if(T_ST(c)==ST_READY && T_PRIO(c)>bestp){ bestp=T_PRIO(c); best=c; } }
  if(best<0) best = NREAL + (int)h;          /* idle(5=h0, 6=h1) */
  T_ST(best)=ST_RUN; CURH(h)=(unsigned)best;
  kunlock();
  return (unsigned*)T_SP(best);
}

int main(void){
  unsigned h = HARTID;
  if (h==0){
    int t; for(t=0;t<NTHREAD;t++){ T_ST(t)=ST_FREE; CNT(t)=0; }
    TICKS=0; KLOCK=0;
    tstart(0, (void*)shell, 0, 2);            /* shell(hart0固定, prio2) */
    tstart(5, (void*)idle_thread, 0, 0);      /* idle hart0 */
    tstart(6, (void*)idle_thread, 0, 0);      /* idle hart1 */
    T_ST(0)=ST_RUN; CURH(0)=0;                /* hart0はshellから */
    T_ST(6)=ST_RUN; CURH(1)=6;                /* hart1はidle1から */
    INITDONE=1;
  } else {
    while(INITDONE==0) ;
  }
  __asm__ volatile("csrw mtvec, %0"   :: "r"((unsigned)(unsigned long)trap_entry));
  set_cmp(get_mtime()+INTERVAL);
  __asm__ volatile("csrs mie, %0"     :: "r"(0x80));   /* MTIE */
  __asm__ volatile("csrw mstatus, %0" :: "r"(0x80));   /* MPIE=1 -> mretでMIE=1 */
  dispatch((unsigned*)T_SP(h==0 ? 0 : 6));
  return 0;
}
