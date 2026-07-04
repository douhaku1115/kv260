/* RV32I 網羅テスト(最適化バリアで全命令を強制発行)
   OPQ() は値をレジスタに固定しgccの定数畳み込みを阻止(ホスト/ターゲット共通)。
   → ホストは同じ演算を実行時に行い基準値を与え、ターゲットは実命令を発行する。
   乗除算(M拡張)は使わない。 */
#define OPQ(x) ({ int _t=(x); __asm__ volatile("":"+r"(_t)); _t; })

int compute(void)
{
    int a = OPQ(0x0F0F0F0F), c = OPQ(0x00FF00FF);
    int r = 0;
    r += a & c;                                    /* and  */
    r += a | c;                                    /* or   */
    r += a ^ c;                                    /* xor  */
    r += a - c;                                    /* sub  */
    r ^= (int)((unsigned)OPQ(0x80000000) >> OPQ(4)); /* srl */
    r += (OPQ((int)0x80000000) >> OPQ(4));         /* sra  */
    r += (OPQ(1) << OPQ(7));                       /* sll  */
    r += ((unsigned)OPQ(-1) > (unsigned)OPQ(0));   /* sltu =1 */
    r += (OPQ(-5) < OPQ(3));                       /* slt  =1 */
    r += (OPQ(10) >= OPQ(10));                     /* =1 */
    r += (OPQ(2) != OPQ(3));                       /* bne-cond =1 */

    /* バイト sb/lb(符号拡張) */
    signed char b[4]; int i;
    for (i = 0; i < 4; i++) b[i] = (signed char)OPQ(i - 2);  /* -2,-1,0,1 */
    for (i = 0; i < 4; i++) r += b[i];                        /* = -2 */

    /* ハーフ sh/lhu(ゼロ拡張) */
    unsigned short h[2];
    h[0] = (unsigned short)OPQ(0xABCD);
    h[1] = (unsigned short)OPQ(0x1234);
    r += (int)h[0] + (int)h[1];                              /* 0xABCD+0x1234 */

    return r;
}

int main(void) { return compute(); }
