/* 2コアIPIデモ: core0がcore1へIPIを50回送信、core1はハンドラで受信+ack。
   ハンドシェイク(受信カウンタ)で1件ずつ確実に配送 → IPICNT=50, done=3。 */
#define HARTID   (*(volatile unsigned*)0x00030008)
#define IPICNT   (*(volatile unsigned*)0x00030004)   /* 受信IPI数(共有) */
#define IPI_SEND (*(volatile unsigned*)0x00030010)
#define IPI_ACK  (*(volatile unsigned*)0x00030014)
#define DONE     (*(volatile unsigned*)0x0003000C)

__attribute__((interrupt("machine")))
void handler(void){
    IPI_ACK = 1;              /* ack(自コアpendingクリア) */
    IPICNT  = IPICNT + 1;     /* 受信カウント */
}

int main(void){
    if (HARTID == 1) {
        /* 受信側: mtvec設定, MSIE+MIE許可, 待機 */
        __asm__ volatile("csrw mtvec, %0"  :: "r"(handler));
        __asm__ volatile("csrw mie,   %0"  :: "r"(8));    /* MSIE=bit3 */
        __asm__ volatile("csrs mstatus,%0" :: "r"(8));    /* MIE =bit3 */
        DONE = 2;
        for(;;) ;                /* idle; IPIでハンドラが走る */
    } else {
        /* 送信側: 50回IPI送信, 受信カウンタで1件ずつハンドシェイク */
        int i, last = 0;
        for (i=0;i<50;i++){
            IPI_SEND = 2;              /* core1宛(bit1) */
            while (IPICNT == last) ;   /* ハンドラ処理完了を待つ */
            last = IPICNT;
        }
        DONE = 1;
        for(;;) ;
    }
}
