/* 2コア並列ワークキュー: 共有キュー(next_task)から両コアがタスクを取り、
   計算(sum 1..10(k+1))を並列実行、結果を共有resultに加算。
   全20タスク → result=144550, cnt0+cnt1=20(両方>0), done=3。 */
#define LOCK   (*(volatile unsigned*)0x00030000)
#define HARTID (*(volatile unsigned*)0x00030008)
#define DONE   (*(volatile unsigned*)0x0003000C)
#define NEXT   (*(volatile unsigned*)0x00030020)   /* 次タスク番号 */
#define RESULT (*(volatile unsigned*)0x00030004)   /* 結果アキュムレータ */
#define CNT0   (*(volatile unsigned*)0x00030028)   /* hart0の処理数 */
#define CNT1   (*(volatile unsigned*)0x0003002C)   /* hart1の処理数 */
#define NTASK 20
int main(void){
    unsigned h = HARTID;
    for(;;){
        while(LOCK) ;                   /* キューをロックしてタスク取得 */
        unsigned k = NEXT;
        if(k >= NTASK){ LOCK = 0; break; }
        NEXT = k + 1;
        LOCK = 0;
        unsigned partial=0, i, n=(k+1)*10;   /* ここは並列(ロック無し) */
        for(i=1;i<=n;i++) partial += i;
        while(LOCK) ;                   /* 結果を排他加算 */
        RESULT = RESULT + partial;
        if(h==0) CNT0 = CNT0 + 1; else CNT1 = CNT1 + 1;
        LOCK = 0;
    }
    DONE = (1u << h);
    for(;;) ;
}
