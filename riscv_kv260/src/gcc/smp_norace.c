#define COUNT  (*(volatile unsigned*)0x00030004)
#define HARTID (*(volatile unsigned*)0x00030008)
#define DONE   (*(volatile unsigned*)0x0003000C)
int main(void){
    int i;
    for(i=0;i<100;i++) COUNT = COUNT + 1;   /* ロック無し=競合 */
    DONE = (1u << HARTID);
    for(;;) ;
}
