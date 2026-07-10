/* KOZOS UARTコンソール(最小シェル): help / echo <text> / sum
   メモリマップドUART: TX=0x40000(w) STAT=0x40004(r,bit0=rx有/bit1=tx満杯) RX=0x40008(r)
   単一ループ(スケジューラ不要)。1行読んでエコー→コマンド解釈→応答。 */
#define UART_TX ((volatile unsigned*)0x00040000)
#define UART_ST ((volatile unsigned*)0x00040004)
#define UART_RX ((volatile unsigned*)0x00040008)

static void put_c(char c){ while(*UART_ST & 2); *UART_TX=(unsigned char)c; }
static void put_s(const char*s){ while(*s) put_c(*s++); }
static int  get_c(void){ while(!(*UART_ST & 1)); return (int)(*UART_RX & 0xff); }

static void put_dec(unsigned v){
  char b[12]; int i=0;
  if(v==0){ put_c('0'); return; }
  while(v){ b[i++]='0'+(v%10); v/=10; }
  while(i) put_c(b[--i]);
}
static int str_eq(const char*a,const char*b){
  while(*a && *b){ if(*a!=*b) return 0; a++; b++; }
  return *a==*b;
}
static int has_pfx(const char*s,const char*p){
  while(*p){ if(*s!=*p) return 0; s++; p++; }
  return 1;
}

int main(void){
  char line[40];
  put_s("\r\nKOZOS console (help/echo/sum)\r\n");
  for(;;){
    put_s("KOZOS> ");
    int n=0;
    for(;;){
      int c=get_c();
      if(c=='\r'||c=='\n'){ put_s("\r\n"); break; }
      if(c==8||c==127){ if(n>0){ n--; put_s("\b \b"); } continue; }  /* BS */
      if(n<39){ line[n++]=(char)c; put_c((char)c); }                 /* エコー */
    }
    line[n]=0;
    if(str_eq(line,"help"))        put_s("cmds: help echo sum\r\n");
    else if(has_pfx(line,"echo ")) { put_s(line+5); put_s("\r\n"); }
    else if(str_eq(line,"sum"))    { unsigned s=0,i; for(i=1;i<=100;i++) s+=i; put_dec(s); put_s("\r\n"); }
    else if(n>0)                   put_s("?\r\n");
  }
  return 0;
}
