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
//   imem は 4096ワード (16KB) あるため、PC が 0x4000 を超えると
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

// ============================================================
// Test 4: lui, ori, bne (Step 4)
// ============================================================
// lui + ori で 32bit 即値をレジスタにロードし、
// bne を使ったカウントアップループで動作を確認する。
//
// 実行順序:
//   0x00: lui  $1, 0xCAFE       → $1 = 0xCAFE0000
//   0x04: ori  $1, $1, 0xBABE   → $1 = 0xCAFEBABE
//   0x08: lui  $2, 0x1234       → $2 = 0x12340000
//   0x0C: ori  $2, $2, 0x5678   → $2 = 0x12345678
//   0x10: addi $3, $0, 0        → $3 = 0  (ループカウンタ)
//   0x14: addi $4, $0, 5        → $4 = 5  (ループ終了値)
//   0x18: addi $3, $3, 1        → $3++    ← ループ先頭
//   0x1C: bne  $3, $4, -2       → $3≠$4 なら 0x18 へ戻る
//   0x20: j    0x20             → 無限ループ (停止)
//
// 期待値: $1=0xCAFEBABE, $2=0x12345678, $3=5, $4=5
static const u32 test4_program[] = {
    0x3C01CAFE,  // lui  $1, 0xCAFE
    0x3421BABE,  // ori  $1, $1, 0xBABE   → $1 = 0xCAFEBABE
    0x3C021234,  // lui  $2, 0x1234
    0x34425678,  // ori  $2, $2, 0x5678   → $2 = 0x12345678
    0x20030000,  // addi $3, $0, 0         → $3 = 0 (カウンタ初期化)
    0x20040005,  // addi $4, $0, 5         → $4 = 5 (ループ回数)
    0x20630001,  // addi $3, $3, 1         ← ループ先頭 (PC=0x18)
    0x1464FFFE,  // bne  $3, $4, -2        → $3≠$4 なら PC=0x18 に戻る
    0x08000008,  // j    0x20              → 無限ループ
};
#define TEST4_COUNT  (sizeof(test4_program) / sizeof(test4_program[0]))

static void run_test4(void)
{
    xil_printf("=== Test 4: lui, ori, bne ===\r\n");

    mips_reset();
    mips_load_program(test4_program, TEST4_COUNT);
    mips_run_cycles(100);

    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $1=0xCAFEBABE, $2=0x12345678, $3=5, $4=5\r\n");
    mips_dump_regs(1, 4);
}

// ============================================================
// Test 5: andi, xori, slti, addiu, sll, srl, sra (Step 5)
// ============================================================
// 即値論理演算 (ゼロ拡張)、符号付き比較即値、シフト命令の動作確認。
//
// 実行順序:
//   0x00: addi  $1, $0, 0xFF    → $1 = 0xFF
//   0x04: andi  $1, $1, 0x0F   → $1 = 0x0F  (0xFF & 0x0F)
//   0x08: addi  $2, $0, 0xFF    → $2 = 0xFF
//   0x0C: xori  $2, $2, 0xFF   → $2 = 0x00  (0xFF ^ 0xFF)
//   0x10: addi  $3, $0, 5       → $3 = 5
//   0x14: slti  $3, $3, 10     → $3 = 1  (5 < 10 → true)
//   0x18: addiu $4, $0, 42     → $4 = 42
//   0x1C: addi  $5, $0, 1       → $5 = 1
//   0x20: sll   $5, $5, 4      → $5 = 16  (1 << 4)
//   0x24: lui   $6, 0x8000     → $6 = 0x80000000
//   0x28: srl   $6, $6, 1      → $6 = 0x40000000 (論理シフト)
//   0x2C: lui   $7, 0x8000     → $7 = 0x80000000
//   0x30: sra   $7, $7, 1      → $7 = 0xC0000000 (算術シフト: 符号bit保持)
//   0x34: j     0x34           → 無限ループ
//
// 期待値: $1=0x0F, $2=0, $3=1, $4=42, $5=16, $6=0x40000000, $7=0xC0000000
static const u32 test5_program[] = {
    0x200100FF,  // addi  $1, $0, 0xFF
    0x3021000F,  // andi  $1, $1, 0x0F   → $1 = 0x0F
    0x200200FF,  // addi  $2, $0, 0xFF
    0x384200FF,  // xori  $2, $2, 0xFF   → $2 = 0x00
    0x20030005,  // addi  $3, $0, 5
    0x2863000A,  // slti  $3, $3, 10     → $3 = 1
    0x2404002A,  // addiu $4, $0, 42     → $4 = 42
    0x20050001,  // addi  $5, $0, 1
    0x00052900,  // sll   $5, $5, 4      → $5 = 16
    0x3C068000,  // lui   $6, 0x8000     → $6 = 0x80000000
    0x00063042,  // srl   $6, $6, 1      → $6 = 0x40000000
    0x3C078000,  // lui   $7, 0x8000     → $7 = 0x80000000
    0x00073843,  // sra   $7, $7, 1      → $7 = 0xC0000000
    0x0800000D,  // j     0x34           → 無限ループ
};
#define TEST5_COUNT  (sizeof(test5_program) / sizeof(test5_program[0]))

static void run_test5(void)
{
    xil_printf("=== Test 5: andi, xori, slti, addiu, sll, srl, sra ===\r\n");

    mips_reset();
    mips_load_program(test5_program, TEST5_COUNT);
    mips_run_cycles(100);

    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $1=0x0F, $2=0, $3=1, $4=42, $5=16, $6=0x40000000, $7=0xC0000000\r\n");
    mips_dump_regs(1, 7);
}

// ============================================================
// Test 6: addu, subu, sltu, sltiu, nor, sllv, srlv, srav (Step 6)
// ============================================================
// 符号なし演算、NOR、可変シフト命令の動作確認。
//
// 実行順序:
//   0x00: addi  $1, $0, 5        → $1 = 5
//   0x04: addi  $2, $0, 3        → $2 = 3
//   0x08: addu  $3, $1, $2       → $3 = 8   (5+3)
//   0x0C: subu  $4, $1, $2       → $4 = 2   (5-3)
//   0x10: sltu  $5, $2, $1       → $5 = 1   (3 < 5 符号なし → 1)
//   0x14: sltiu $6, $1, 10       → $6 = 1   (5 < 10 符号なし → 1)
//   0x18: nor   $7, $1, $2       → $7 = ~(5|3) = 0xFFFFFFF8
//   0x1C: addi  $8, $0, 4        → $8 = 4   (シフト量)
//   0x20: sllv  $9, $1, $8       → $9 = 5 << 4 = 80 = 0x50
//   0x24: srlv  $10, $7, $8      → $10 = 0xFFFFFFF8 >> 4 = 0x0FFFFFFF (論理)
//   0x28: srav  $11, $7, $8      → $11 = 0xFFFFFFF8 >>> 4 = 0xFFFFFFFF (算術)
//   0x2C: j     0x2C             → 無限ループ
//
// 期待値: $3=8, $4=2, $5=1, $6=1, $7=0xFFFFFFF8, $8=4, $9=0x50,
//         $10=0x0FFFFFFF, $11=0xFFFFFFFF
static const u32 test6_program[] = {
    0x20010005,  // addi  $1, $0, 5
    0x20020003,  // addi  $2, $0, 3
    0x00221821,  // addu  $3, $1, $2       → $3 = 8
    0x00222023,  // subu  $4, $1, $2       → $4 = 2
    0x0041282B,  // sltu  $5, $2, $1       → $5 = 1  (3 < 5 符号なし)
    0x2C26000A,  // sltiu $6, $1, 10       → $6 = 1  (5 < 10 符号なし)
    0x00223827,  // nor   $7, $1, $2       → $7 = 0xFFFFFFF8
    0x20080004,  // addi  $8, $0, 4        → $8 = 4  (シフト量)
    0x01014804,  // sllv  $9, $1, $8       → $9 = 5 << 4 = 0x50
    0x01075006,  // srlv  $10, $7, $8      → $10 = 0x0FFFFFFF
    0x01075807,  // srav  $11, $7, $8      → $11 = 0xFFFFFFFF
    0x0800000B,  // j     0x2C             → 無限ループ
};
#define TEST6_COUNT  (sizeof(test6_program) / sizeof(test6_program[0]))

static void run_test6(void)
{
    xil_printf("=== Test 6: addu, subu, sltu, sltiu, nor, sllv, srlv, srav ===\r\n");

    mips_reset();
    mips_load_program(test6_program, TEST6_COUNT);
    mips_run_cycles(100);

    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $3=8, $4=2, $5=1, $6=1, $7=0xFFFFFFF8\r\n");
    xil_printf("          $8=4, $9=0x50, $10=0x0FFFFFFF, $11=0xFFFFFFFF\r\n");
    mips_dump_regs(1, 11);
}

// ============================================================
// Test 7: mult, multu, div, divu, mfhi, mflo (Step 7)
// ============================================================
// HI/LOレジスタを使う乗除算命令の動作確認。
//
// 実行順序:
//   0x00: addi  $1, $0, 10          → $1 = 10
//   0x04: addi  $2, $0, 3           → $2 = 3
//   0x08: mult  $1, $2              → {HI,LO} = 10*3 = 30 → HI=0, LO=30
//   0x0C: mflo  $3                  → $3 = 30
//   0x10: mfhi  $4                  → $4 = 0
//   0x14: div   $1, $2              → LO=10/3=3, HI=10%3=1
//   0x18: mflo  $5                  → $5 = 3
//   0x1C: mfhi  $6                  → $6 = 1
//   0x20: lui   $7, 0x8000          → $7 = 0x80000000
//   0x24: multu $7, $2              → {HI,LO} = 0x80000000*3 = 0x180000000
//                                       HI=1, LO=0x80000000
//   0x28: mflo  $8                  → $8 = 0x80000000
//   0x2C: mfhi  $9                  → $9 = 1
//   0x30: divu  $7, $2              → LO=0x80000000/3=0x2AAAAAAA, HI=2
//   0x34: mflo  $10                 → $10 = 0x2AAAAAAA
//   0x38: mfhi  $11                 → $11 = 2
//   0x3C: j     0x3C                → 無限ループ
//
// 期待値: $3=30, $4=0, $5=3, $6=1, $7=0x80000000,
//         $8=0x80000000, $9=1, $10=0x2AAAAAAA, $11=2
static const u32 test7_program[] = {
    0x2001000A,  // addi  $1, $0, 10
    0x20020003,  // addi  $2, $0, 3
    0x00220018,  // mult  $1, $2         → {HI,LO} = 30
    0x00001812,  // mflo  $3             → $3 = 30
    0x00002010,  // mfhi  $4             → $4 = 0
    0x0022001A,  // div   $1, $2         → LO=3, HI=1
    0x00002812,  // mflo  $5             → $5 = 3
    0x00003010,  // mfhi  $6             → $6 = 1
    0x3C078000,  // lui   $7, 0x8000     → $7 = 0x80000000
    0x00E20019,  // multu $7, $2         → {HI,LO} = 0x180000000
    0x00004012,  // mflo  $8             → $8 = 0x80000000
    0x00004810,  // mfhi  $9             → $9 = 1
    0x00E2001B,  // divu  $7, $2         → LO=0x2AAAAAAA, HI=2
    0x00005012,  // mflo  $10            → $10 = 0x2AAAAAAA
    0x00005810,  // mfhi  $11            → $11 = 2
    0x0800000F,  // j     0x3C           → 無限ループ
};
#define TEST7_COUNT  (sizeof(test7_program) / sizeof(test7_program[0]))

static void run_test7(void)
{
    xil_printf("=== Test 7: mult, multu, div, divu, mfhi, mflo ===\r\n");

    mips_reset();
    mips_load_program(test7_program, TEST7_COUNT);
    mips_run_cycles(100);

    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $3=30, $4=0, $5=3, $6=1, $7=0x80000000\r\n");
    xil_printf("          $8=0x80000000, $9=1, $10=0x2AAAAAAA, $11=2\r\n");
    mips_dump_regs(1, 11);
}

int main(void)
{
    xil_printf("\r\n==== MIPS Processor Test ====\r\n\r\n");
    run_test1();
    xil_printf("\r\n");
    run_test2();
    xil_printf("\r\n");
    run_test3();
    xil_printf("\r\n");
    run_test4();
    xil_printf("\r\n");
    run_test5();
    xil_printf("\r\n");
    run_test6();
    xil_printf("\r\n");
    run_test7();
    xil_printf("\r\n==== Done ====\r\n");
    return 0;
}
