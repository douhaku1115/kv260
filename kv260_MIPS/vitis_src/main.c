// ============================================================
// main.c — KV260 MIPS プロセッサ 動作確認テスト
// ============================================================
//
// 【概要】
//   PS(ARM) から AXI 経由で PL(FPGA) 上の MIPS コアを制御し、
//   命令セットの動作を段階的に確認する。
//
// 【AXI レジスタマップ (ベース: 0xA0000000)】
//
//   オフセット | 名前       | 方向  | 内容
//   ----------+------------+-------+---------------------------
//   0x00      | CTRL       | R/W   | bit0=reset, bit1=run
//   0x04      | PC         | R     | 現在のプログラムカウンタ
//   0x08      | DBG_ADDR   | R/W   | 読み出すレジスタ番号 (0-31)
//   0x0C      | DBG_DATA   | R     | DBG_ADDR で指定したレジスタ値
//   0x10      | IMEM_ADDR  | W     | 命令メモリ書き込みアドレス (ワード単位)
//   0x14      | IMEM_DATA  | W     | 命令メモリ書き込みデータ (書き込みトリガ)
//
// 【テスト手順】
//   1. mips_reset()       — PC を 0 に戻す (レジスタは保持される)
//   2. mips_load_program()— IMEM_ADDR/DATA 経由で命令をロード
//   3. mips_run_cycles()  — CTRL=run にして指定時間だけ実行
//   4. mips_read_reg()    — DBG_ADDR/DATA でレジスタ値を確認
//
// 【注意: imem のアドレス循環】
//   imem は 256ワード (1KB) しかないため、PC が 0x400 を超えると
//   アドレスが循環して命令が再実行される。テストプログラムの末尾には
//   必ず無限ループ (j 自身) を入れて PC を停止させること。

#include "xil_printf.h"
#include "xil_io.h"
#include "sleep.h"

#define MIPS_BASE 0xA0000000

#define REG_CTRL       (MIPS_BASE + 0x00)
#define REG_PC         (MIPS_BASE + 0x04)
#define REG_DBG_ADDR   (MIPS_BASE + 0x08)
#define REG_DBG_DATA   (MIPS_BASE + 0x0C)
#define REG_IMEM_ADDR  (MIPS_BASE + 0x10)
#define REG_IMEM_DATA  (MIPS_BASE + 0x14)

#define CTRL_RESET  (1 << 0)   // PC を 0 にリセット (レジスタは保持)
#define CTRL_RUN    (1 << 1)   // MIPS 実行開始 (0 にすると halt)

// PC を 0 にリセットする
static void mips_reset(void)
{
    Xil_Out32(REG_CTRL, CTRL_RESET);
    usleep(10);
}

// 命令配列を imem にロードする (ワードアドレス 0 から順番に書き込む)
static void mips_load_program(const u32 *prog, int count)
{
    for (int i = 0; i < count; i++) {
        Xil_Out32(REG_IMEM_ADDR, i);
        Xil_Out32(REG_IMEM_DATA, prog[i]);
    }
}

// MIPS を実行して指定マイクロ秒後に halt する
static void mips_run_cycles(int usec)
{
    Xil_Out32(REG_CTRL, CTRL_RUN);
    usleep(usec);
    Xil_Out32(REG_CTRL, 0);
}

static u32 mips_read_pc(void)
{
    return Xil_In32(REG_PC);
}

// 指定したレジスタ番号の値を読み出す ($0〜$31)
static u32 mips_read_reg(int regnum)
{
    Xil_Out32(REG_DBG_ADDR, regnum);
    return Xil_In32(REG_DBG_DATA);
}

// 指定範囲のレジスタ値を一覧表示する
static void mips_dump_regs(int from, int to)
{
    for (int i = from; i <= to; i++) {
        u32 val = mips_read_reg(i);
        xil_printf("  $%d = 0x%08x (%d)\r\n", i, val, val);
    }
}

// ============================================================
// Test 1: addi + R型命令 (Step 1)
// ============================================================
// addi, add, sub, and, or, slt の動作確認
static const u32 test1_program[] = {
    0x20010005, // addi $1, $0, 5       | $1 = 5
    0x20020003, // addi $2, $0, 3       | $2 = 3
    0x00221820, // add  $3, $1, $2      | $3 = 8
    0x00222022, // sub  $4, $1, $2      | $4 = 2
    0x00222824, // and  $5, $1, $2      | $5 = 1 (5 & 3 = 0b101 & 0b011)
    0x00223025, // or   $6, $1, $2      | $6 = 7 (5 | 3 = 0b101 | 0b011)
    0x0041382A, // slt  $7, $2, $1      | $7 = 1 ($2=3 < $1=5 なので 1)
    0x08000007, // j    0x1C            | 無限ループ (PC が循環しないよう停止)
};
#define TEST1_COUNT  (sizeof(test1_program) / sizeof(test1_program[0]))

static void run_test1(void)
{
    xil_printf("=== Test 1: addi + R-type ===\r\n");

    mips_reset();
    mips_load_program(test1_program, TEST1_COUNT);
    mips_run_cycles(100);

    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $1=5, $2=3, $3=8, $4=2, $5=1, $6=7, $7=1\r\n");
    mips_dump_regs(1, 7);
}

// ============================================================
// Test 2: lw, sw, beq (Step 2)
// ============================================================
// メモリアクセス命令と条件分岐の動作確認。
// beq が成立した場合、次の addi がスキップされることを確認する。
static const u32 test2_program[] = {
    0x20010005, // addi $1, $0, 5       | $1 = 5
    0x20020003, // addi $2, $0, 3       | $2 = 3
    0x00221820, // add  $3, $1, $2      | $3 = 8
    0xAC030000, // sw   $3, 0($0)       | mem[0] = 8
    0x8C040000, // lw   $4, 0($0)       | $4 = mem[0] = 8
    0x10830001, // beq  $4, $3, +1      | $4==$3(8==8) → 1命令スキップ
    0x20050063, // addi $5, $0, 99      | スキップされる ($5 は変化なし)
    0x20060001, // addi $6, $0, 1       | $6 = 1 (beq 成立の証拠)
    0x08000008, // j    0x20            | 無限ループ
};
#define TEST2_COUNT  (sizeof(test2_program) / sizeof(test2_program[0]))

static void run_test2(void)
{
    xil_printf("=== Test 2: lw, sw, beq ===\r\n");

    mips_reset();
    mips_load_program(test2_program, TEST2_COUNT);
    mips_run_cycles(100);

    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $1=5, $2=3, $3=8, $4=8, $5=0(skipped), $6=1\r\n");
    mips_dump_regs(1, 6);
}

// ============================================================
// Test 3: j, jal, jr (Step 3)
// ============================================================
// ジャンプ命令の動作確認。実行順序:
//
//   0x00: addi $1, $0, 10   → $1 = 10
//   0x04: jal  0x0C         → $31 = 0x08 (リターンアドレス保存), PC = 0x0C
//   0x08: j    0x14         → (jr の戻り先) PC = 0x14
//   0x0C: addi $2, $0, 42   → $2 = 42  [func の中]
//   0x10: jr   $31          → PC = $31 = 0x08
//   0x14: addi $3, $0, 7    → $3 = 7   [jal の呼び出し元に戻った後]
//   0x18: j    0x18         → 無限ループ (停止)
//
// 期待値: $1=10, $2=42, $3=7, $31=0x00000008
static const u32 test3_program[] = {
    0x2001000A,  // addi $1, $0, 10
    0x0C000003,  // jal  0x0C  (addr26 = 0x0C/4 = 3)
    0x08000005,  // j    0x14  (addr26 = 0x14/4 = 5)
    0x2002002A,  // addi $2, $0, 42  [func]
    0x03E00008,  // jr   $31
    0x20030007,  // addi $3, $0, 7   [done]
    0x08000006,  // j    0x18  (自分自身: 無限ループで停止)
};
#define TEST3_COUNT  (sizeof(test3_program) / sizeof(test3_program[0]))

static void run_test3(void)
{
    xil_printf("=== Test 3: j, jal, jr ===\r\n");

    mips_reset();
    mips_load_program(test3_program, TEST3_COUNT);
    mips_run_cycles(100);

    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $1=10, $2=42, $3=7, $31=0x00000008\r\n");
    mips_dump_regs(1, 3);
    xil_printf("  $31= 0x%08x\r\n", mips_read_reg(31));
}

int main(void)
{
    xil_printf("\r\n==== MIPS Processor Test ====\r\n\r\n");
    run_test1();
    xil_printf("\r\n");
    run_test2();
    xil_printf("\r\n");
    run_test3();
    xil_printf("\r\n==== Done ====\r\n");
    return 0;
}
