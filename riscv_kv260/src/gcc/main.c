/* 第3段 検証用C: Σ0..100 = 5050 (0x13BA)
   n を inline asm で不透明化し、gcc の定数畳み込みを防いで
   実際にループ(加算・比較分岐)を回させる。 */
int main(void)
{
    int s = 0, i, n;
    __asm__ volatile ("li %0, 100" : "=r"(n));  /* n=100 だが gcc からは不透明 */
    for (i = 1; i <= n; i++)
        s += i;
    return s;   /* 5050 */
}
