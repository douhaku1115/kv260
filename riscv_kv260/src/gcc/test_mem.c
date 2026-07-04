/* バイト/ハーフ メモリ ld-st 検証: 不透明インデックスで実メモリアクセスを強制。 */
#define OPQ(x) ({ int _t=(x); __asm__ volatile("":"+r"(_t)); _t; })
int compute(void){
  int k = OPQ(0); int i, r = 0;
  signed char sb_[8];
  for(i=0;i<8;i++) sb_[(i+k)&7] = (signed char)OPQ(i-3);
  for(i=0;i<8;i++) r += (int)sb_[(i+k)&7];        /* lb  符号 */
  unsigned char ub_[4];
  for(i=0;i<4;i++) ub_[(i+k)&3] = (unsigned char)OPQ(0xF0+i);
  for(i=0;i<4;i++) r += (int)ub_[(i+k)&3];        /* lbu ゼロ */
  short sh_[4];
  for(i=0;i<4;i++) sh_[(i+k)&3] = (short)OPQ(-1000-i);
  for(i=0;i<4;i++) r += (int)sh_[(i+k)&3];        /* lh  符号 */
  unsigned short uh_[4];
  for(i=0;i<4;i++) uh_[(i+k)&3] = (unsigned short)OPQ(0xC000+i);
  for(i=0;i<4;i++) r += (int)uh_[(i+k)&3];        /* lhu ゼロ */
  return r;
}
int main(void){ return compute(); }
