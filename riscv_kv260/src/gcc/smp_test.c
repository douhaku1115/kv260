/* 2コアSMPテスト: 両コアが同じプログラムを実行。
   ロックで排他しながら共有カウンタを各100回加算 → 最終200。
   終了時に done bit(1<<hartid)を立てる → done=3。 */
#define LOCK   (*(volatile unsigned*)0x00030000)
#define COUNT  (*(volatile unsigned*)0x00030004)
#define HARTID (*(volatile unsigned*)0x00030008)
#define DONE   (*(volatile unsigned*)0x0003000C)
int main(void){
    int i;
    for(i=0;i<100;i++){
        while(LOCK) ;          /* spin-acquire (TAS: 0が返れば取得) */
        COUNT = COUNT + 1;     /* クリティカルセクション */
        LOCK = 0;              /* 解放 */
    }
    DONE = (1u << HARTID);     /* 完了通知 */
    for(;;) ;                  /* halt */
}
