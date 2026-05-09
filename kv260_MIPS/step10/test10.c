// test10.c — Step10: C言語実行テスト
//
// 【テスト内容】
//   mips-linux-gnu-gcc でコンパイルした C プログラムを MIPS コアで実行する。
//   関数呼び出し (jal/jr)、スタック操作 (addiu $sp/$fp)、
//   レジスタ渡し ($a0/$a1/$v0) を検証する。
//
// 【コンパイル条件】
//   -O0: ディレイスロットを NOP で埋める（本ハードウェア対応）
//   -mips1 -EB: ビッグエンディアン MIPS1
//
// 【期待結果】
//   main() の戻り値 ($v0 = $2) = 60

static int add(int a, int b)
{
    return a + b;
}

int main(void)
{
    int x = add(10, 20);   // x = 30
    int y = add(x, x);     // y = 60
    return y;
}
