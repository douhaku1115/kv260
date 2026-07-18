/* 共有RAMクロスコアテスト: core0が0x40000へ書く→core1がフラグ待ちで読む */
#define HARTID (*(volatile unsigned*)0x00030008)
#define DONE   (*(volatile unsigned*)0x0003000C)
#define FLAG   (*(volatile unsigned*)0x00030020)   /* rf[0] 同期フラグ */
#define RESULT (*(volatile unsigned*)0x00030004)   /* r_counter(VIO) */
#define SRAM   (*(volatile unsigned*)0x00040000)   /* 共有RAM word0 */
int main(void){
    unsigned h = HARTID;
    if (h==0){
        SRAM = 0x0000ABCD;   /* 共有RAMに書く */
        FLAG = 1;            /* 通知 */
        DONE = 1;
    } else {
        while (FLAG==0) ;    /* core0を待つ */
        RESULT = SRAM;       /* 共有RAMを読む(=0xABCD のはず) */
        DONE = 2;
    }
    for(;;) ;
}
