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
// Test Pipe A: パイプライン基本動作確認 (Step 12a)
// ============================================================
// データ依存のない addi 命令のみで、5段パイプラインが動作することを確認する。
// フォワーディング未実装のため、依存命令を含めない (Step 12b で対応予定)。
// 分岐/ジャンプ未実装のため、無限ループも入れない (PC は NOP を走り続ける)。
static const u32 test_pipe_a_program[] = {
    0x20010005, // addi $1, $0, 5    | $1 = 5
    0x2002000A, // addi $2, $0, 10   | $2 = 10
    0x2003000F, // addi $3, $0, 15   | $3 = 15
    0x20040014, // addi $4, $0, 20   | $4 = 20
    0x20050019, // addi $5, $0, 25   | $5 = 25
    0x2006001E, // addi $6, $0, 30   | $6 = 30
    0x20070023, // addi $7, $0, 35   | $7 = 35
};
#define TEST_PIPE_A_COUNT (sizeof(test_pipe_a_program) / sizeof(test_pipe_a_program[0]))

static void run_test_pipe_a(void)
{
    xil_printf("--- Test Pipe A: パイプライン基本動作 (Step 12a) ---\r\n");
    mips_reset();
    mips_load_program(test_pipe_a_program, TEST_PIPE_A_COUNT);
    mips_run_cycles(500);
    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $1=5, $2=10, $3=15, $4=20, $5=25, $6=30, $7=35\r\n");
    mips_dump_regs(1, 7);
}

// ============================================================
// Test Pipe C: lw/sw + ロードユースハザード (Step 12c)
// ============================================================
// sw 直後の lw、lw 直後の使用 (ロードユース) で正しく動作するか確認する。
static const u32 test_pipe_c_program[] = {
    0x20010005, // addi $1, $0, 5    | $1 = 5
    0xAC010000, // sw   $1, 0($0)    | mem[0] = 5
    0x8C020000, // lw   $2, 0($0)    | $2 = 5
    0x00422020, // add  $4, $2, $2   | $4 = 10  ← ロードユース (stall 1cycle + forwarding)
    0x20030007, // addi $3, $0, 7    | $3 = 7
    0x00832820, // add  $5, $4, $3   | $5 = 17  ← フォワーディング (EX/MEM → EX)
};
#define TEST_PIPE_C_COUNT (sizeof(test_pipe_c_program) / sizeof(test_pipe_c_program[0]))

static void run_test_pipe_c(void)
{
    xil_printf("--- Test Pipe C: lw/sw + load-use (Step 12c) ---\r\n");
    mips_reset();
    mips_load_program(test_pipe_c_program, TEST_PIPE_C_COUNT);
    mips_run_cycles(500);
    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $1=5, $2=5, $3=7, $4=10, $5=17\r\n");
    mips_dump_regs(1, 5);
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

// ============================================================
// Test 8: lb, lbu, lh, lhu, sb, sh (Step 8)
// ============================================================
// バイト/ハーフワードアクセス命令の動作確認 (ビッグエンディアン)。
//
// 【ビッグエンディアンのメモリレイアウト】
//   sw $r(=0xDEADBEEF), 0($0) を実行すると:
//     byte addr 0 → 0xDE (MSB)  mem[0][31:24]
//     byte addr 1 → 0xAD        mem[0][23:16]
//     byte addr 2 → 0xBE        mem[0][15:8]
//     byte addr 3 → 0xEF (LSB)  mem[0][7:0]
//
// 実行順序:
//   0x00: lui   $9, 0xDEAD        → $9 = 0xDEAD0000
//   0x04: ori   $9, $9, 0xBEEF   → $9 = 0xDEADBEEF
//   0x08: sw    $9, 0($0)         → mem[0] = 0xDEADBEEF
//   0x0C: lb    $1, 0($0)         → byte0=0xDE → $1 = 0xFFFFFFDE (符号拡張)
//   0x10: lbu   $2, 0($0)         → byte0=0xDE → $2 = 0x000000DE (ゼロ拡張)
//   0x14: lh    $3, 0($0)         → half0=0xDEAD → $3 = 0xFFFFDEAD (符号拡張)
//   0x18: lhu   $4, 0($0)         → half0=0xDEAD → $4 = 0x0000DEAD (ゼロ拡張)
//   0x1C: lb    $5, 3($0)         → byte3=0xEF → $5 = 0xFFFFFFEF (符号拡張)
//
//   // sb で addr 4〜7 に 0x11/0x22/0x33/0x44 を1バイトずつ書き込む
//   0x20: addi  $10, $0, 0x11     → $10 = 0x11
//   0x24: sb    $10, 4($0)        → mem[1] byte0 (addr4) = 0x11
//   0x28: addi  $10, $0, 0x22     → $10 = 0x22
//   0x2C: sb    $10, 5($0)        → mem[1] byte1 (addr5) = 0x22
//   0x30: addi  $10, $0, 0x33     → $10 = 0x33
//   0x34: sb    $10, 6($0)        → mem[1] byte2 (addr6) = 0x33
//   0x38: addi  $10, $0, 0x44     → $10 = 0x44
//   0x3C: sb    $10, 7($0)        → mem[1] byte3 (addr7) = 0x44
//   0x40: lw    $6, 4($0)         → $6 = 0x11223344
//
//   // sh で addr 8〜11 に 0xABCD/0x1234 を書き込む
//   0x44: ori   $11, $0, 0xABCD   → $11 = 0x0000ABCD
//   0x48: sh    $11, 8($0)        → mem[2] upper half = 0xABCD
//   0x4C: ori   $12, $0, 0x1234   → $12 = 0x00001234
//   0x50: sh    $12, 10($0)       → mem[2] lower half = 0x1234
//   0x54: lw    $7, 8($0)         → $7 = 0xABCD1234
//   0x58: j     0x58              → 無限ループ
//
// 期待値:
//   $1 = 0xFFFFFFDE, $2 = 0x000000DE, $3 = 0xFFFFDEAD, $4 = 0x0000DEAD
//   $5 = 0xFFFFFFEF, $6 = 0x11223344, $7 = 0xABCD1234
static const u32 test8_program[] = {
    0x3C09DEAD,  // lui   $9, 0xDEAD        → $9 = 0xDEAD0000
    0x3529BEEF,  // ori   $9, $9, 0xBEEF   → $9 = 0xDEADBEEF
    0xAC090000,  // sw    $9, 0($0)         → mem[0] = 0xDEADBEEF
    0x80010000,  // lb    $1, 0($0)         → $1 = 0xFFFFFFDE
    0x90020000,  // lbu   $2, 0($0)         → $2 = 0x000000DE
    0x84030000,  // lh    $3, 0($0)         → $3 = 0xFFFFDEAD
    0x94040000,  // lhu   $4, 0($0)         → $4 = 0x0000DEAD
    0x80050003,  // lb    $5, 3($0)         → $5 = 0xFFFFFFEF
    0x200A0011,  // addi  $10, $0, 0x11
    0xA00A0004,  // sb    $10, 4($0)        → addr4 = 0x11
    0x200A0022,  // addi  $10, $0, 0x22
    0xA00A0005,  // sb    $10, 5($0)        → addr5 = 0x22
    0x200A0033,  // addi  $10, $0, 0x33
    0xA00A0006,  // sb    $10, 6($0)        → addr6 = 0x33
    0x200A0044,  // addi  $10, $0, 0x44
    0xA00A0007,  // sb    $10, 7($0)        → addr7 = 0x44
    0x8C060004,  // lw    $6, 4($0)         → $6 = 0x11223344
    0x340BABCD,  // ori   $11, $0, 0xABCD   → $11 = 0x0000ABCD
    0xA40B0008,  // sh    $11, 8($0)        → upper half = 0xABCD
    0x340C1234,  // ori   $12, $0, 0x1234   → $12 = 0x00001234
    0xA40C000A,  // sh    $12, 10($0)       → lower half = 0x1234
    0x8C070008,  // lw    $7, 8($0)         → $7 = 0xABCD1234
    0x08000016,  // j     0x58              → 無限ループ
};
#define TEST8_COUNT  (sizeof(test8_program) / sizeof(test8_program[0]))

static void run_test8(void)
{
    xil_printf("=== Test 8: lb, lbu, lh, lhu, sb, sh (big-endian) ===\r\n");

    mips_reset();
    mips_load_program(test8_program, TEST8_COUNT);
    mips_run_cycles(100);

    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $1=0xFFFFFFDE, $2=0x000000DE, $3=0xFFFFDEAD, $4=0x0000DEAD\r\n");
    xil_printf("          $5=0xFFFFFFEF, $6=0x11223344, $7=0xABCD1234\r\n");
    mips_dump_regs(1, 7);
}

// ============================================================
// Test 9: blez, bgtz, bltz, bgez (Step 9)
// ============================================================
// rs と 0 を比較する条件分岐命令の動作確認。
// 各命令について「分岐成立」と「分岐不成立」の両方を検証する。
//
// 実行順序:
//   0x00: addi $1, $0, -5   → $1 = -5  (負数)
//   0x04: addi $2, $0, 5    → $2 = 5   (正数)
//   0x08: addi $3, $0, 0    → $3 = 0   (ゼロ)
//
//   // bltz $1 (-5 < 0 → taken)
//   0x0C: bltz $1, +1       → taken, 0x10 をスキップ
//   0x10: addi $4, $0, 99   → SKIPPED
//   0x14: addi $4, $0, 1    → $4 = 1 (taken の証拠)
//
//   // bgez $2 (5 >= 0 → taken)
//   0x18: bgez $2, +1       → taken, 0x1C をスキップ
//   0x1C: addi $5, $0, 99   → SKIPPED
//   0x20: addi $5, $0, 2    → $5 = 2
//
//   // blez $3 (0 <= 0 → taken)
//   0x24: blez $3, +1       → taken, 0x28 をスキップ
//   0x28: addi $6, $0, 99   → SKIPPED
//   0x2C: addi $6, $0, 3    → $6 = 3
//
//   // bgtz $2 (5 > 0 → taken)
//   0x30: bgtz $2, +1       → taken, 0x34 をスキップ
//   0x34: addi $7, $0, 99   → SKIPPED
//   0x38: addi $7, $0, 4    → $7 = 4
//
//   // bltz $2 (5 < 0? NO → not taken)
//   0x3C: bltz $2, +1       → NOT taken
//   0x40: addi $8, $0, 5    → EXECUTED → $8 = 5
//
//   // blez $2 (5 <= 0? NO → not taken)
//   0x44: blez $2, +1       → NOT taken
//   0x48: addi $9, $0, 6    → EXECUTED → $9 = 6
//
//   0x4C: j 0x4C            → 無限ループ
//
// 期待値: $4=1, $5=2, $6=3, $7=4, $8=5, $9=6
static const u32 test9_program[] = {
    0x2001FFFB,  // addi  $1, $0, -5
    0x20020005,  // addi  $2, $0, 5
    0x20030000,  // addi  $3, $0, 0
    0x04200001,  // bltz  $1, +1       → taken (-5<0)
    0x20040063,  // addi  $4, $0, 99  → SKIPPED
    0x20040001,  // addi  $4, $0, 1   → $4 = 1
    0x04410001,  // bgez  $2, +1      → taken (5>=0)
    0x20050063,  // addi  $5, $0, 99  → SKIPPED
    0x20050002,  // addi  $5, $0, 2   → $5 = 2
    0x18600001,  // blez  $3, +1      → taken (0<=0)
    0x20060063,  // addi  $6, $0, 99  → SKIPPED
    0x20060003,  // addi  $6, $0, 3   → $6 = 3
    0x1C400001,  // bgtz  $2, +1      → taken (5>0)
    0x20070063,  // addi  $7, $0, 99  → SKIPPED
    0x20070004,  // addi  $7, $0, 4   → $7 = 4
    0x04400001,  // bltz  $2, +1      → NOT taken (5>=0)
    0x20080005,  // addi  $8, $0, 5   → EXECUTED → $8 = 5
    0x18400001,  // blez  $2, +1      → NOT taken (5>0)
    0x20090006,  // addi  $9, $0, 6   → EXECUTED → $9 = 6
    0x08000013,  // j     0x4C        → 無限ループ
};
#define TEST9_COUNT  (sizeof(test9_program) / sizeof(test9_program[0]))

static void run_test9(void)
{
    xil_printf("=== Test 9: blez, bgtz, bltz, bgez ===\r\n");

    mips_reset();
    mips_load_program(test9_program, TEST9_COUNT);
    mips_run_cycles(100);

    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $4=1, $5=2, $6=3, $7=4, $8=5, $9=6\r\n");
    mips_dump_regs(4, 9);
}

// ============================================================
// Test 10: C言語実行 (Step 10)
// ============================================================
// mips-linux-gnu-gcc でコンパイルした C プログラムを実行する。
//
// ソース (step10/test10.c):
//   static int add(int a, int b) { return a + b; }
//   int main(void) {
//       int x = add(10, 20);   // x = 30
//       int y = add(x, x);     // y = 60
//       return y;
//   }
//
// コンパイル: mips-linux-gnu-gcc -mips1 -mfp32 -EB -O0
//             -ffreestanding -nostdlib -nostartfiles -fno-pic -mno-abicalls
//             -Wl,-T,mips.ld -o test10.elf crt0.S test10.c
//
// 注: -O0 でコンパイルするとディレイスロットが NOP になり、
//     ディレイスロット非実装の本ハードウェアで正常動作する。
//
// 期待値: $2 ($v0) = 60 (0x3C)
static const u32 test10_program[] = {
    0x3C1D0000,  // [  0] 0x0000  _start: lui sp, 0x0
    0x37BD03FC,  // [  1] 0x0004          ori sp, sp, 0x3FC   ($sp = 0x3FC = dmem top)
    0x03A0F025,  // [  2] 0x0008          move s8, sp
    0x0C000016,  // [  3] 0x000C          jal 0x58 <main>
    0x00000000,  // [  4] 0x0010          nop                  (delay slot)
    0x08000005,  // [  5] 0x0014  _halt:  j _halt
    0x00000000,  // [  6] 0x0018          nop
    0x00000000,  // [  7] 0x001C          nop
    0x27BDFFF8,  // [  8] 0x0020  add:    addiu sp, sp, -8
    0xAFBE0004,  // [  9] 0x0024          sw s8, 4(sp)
    0x03A0F025,  // [ 10] 0x0028          move s8, sp
    0xAFC40008,  // [ 11] 0x002C          sw a0, 8(s8)
    0xAFC5000C,  // [ 12] 0x0030          sw a1, 12(s8)
    0x8FC30008,  // [ 13] 0x0034          lw v1, 8(s8)
    0x8FC2000C,  // [ 14] 0x0038          lw v0, 12(s8)
    0x00000000,  // [ 15] 0x003C          nop
    0x00621021,  // [ 16] 0x0040          addu v0, v1, v0      ($v0 = a + b)
    0x03C0E825,  // [ 17] 0x0044          move sp, s8
    0x8FBE0004,  // [ 18] 0x0048          lw s8, 4(sp)
    0x27BD0008,  // [ 19] 0x004C          addiu sp, sp, 8
    0x03E00008,  // [ 20] 0x0050          jr ra
    0x00000000,  // [ 21] 0x0054          nop                  (delay slot)
    0x27BDFFE0,  // [ 22] 0x0058  main:   addiu sp, sp, -32
    0xAFBF001C,  // [ 23] 0x005C          sw ra, 28(sp)
    0xAFBE0018,  // [ 24] 0x0060          sw s8, 24(sp)
    0x03A0F025,  // [ 25] 0x0064          move s8, sp
    0x24050014,  // [ 26] 0x0068          li a1, 20
    0x2404000A,  // [ 27] 0x006C          li a0, 10
    0x0C000008,  // [ 28] 0x0070          jal 0x20 <add>       (add(10,20) → $v0=30)
    0x00000000,  // [ 29] 0x0074          nop                  (delay slot)
    0xAFC20010,  // [ 30] 0x0078          sw v0, 16(s8)        (x = 30)
    0x8FC50010,  // [ 31] 0x007C          lw a1, 16(s8)        (a1 = x)
    0x8FC40010,  // [ 32] 0x0080          lw a0, 16(s8)        (a0 = x)
    0x0C000008,  // [ 33] 0x0084          jal 0x20 <add>       (add(x,x) → $v0=60)
    0x00000000,  // [ 34] 0x0088          nop                  (delay slot)
    0xAFC20014,  // [ 35] 0x008C          sw v0, 20(s8)        (y = 60)
    0x8FC20014,  // [ 36] 0x0090          lw v0, 20(s8)        (return y)
    0x03C0E825,  // [ 37] 0x0094          move sp, s8
    0x8FBF001C,  // [ 38] 0x0098          lw ra, 28(sp)
    0x8FBE0018,  // [ 39] 0x009C          lw s8, 24(sp)
    0x27BD0020,  // [ 40] 0x00A0          addiu sp, sp, 32
    0x03E00008,  // [ 41] 0x00A4          jr ra
    0x00000000,  // [ 42] 0x00A8          nop                  (delay slot)
    0x00000000,  // [ 43] 0x00AC          nop
};
#define TEST10_COUNT  (sizeof(test10_program) / sizeof(test10_program[0]))

static void run_test10(void)
{
    xil_printf("=== Test 10: C language (add(10,20)=30, add(30,30)=60) ===\r\n");

    mips_reset();
    mips_load_program(test10_program, TEST10_COUNT);
    mips_run_cycles(200);

    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $2(v0) = 60 (0x0000003C)\r\n");
    xil_printf("  $2(v0) = 0x%08x (%d)\r\n", mips_read_reg(2), mips_read_reg(2));
}

// ============================================================
// Test 11: 例外処理 — syscall, オーバーフロー, mfc0/mtc0/eret (Step 11)
// ============================================================
//
// 【例外ベクタ】 0x0000_0080 (imem word 32)
//
// 【CP0 レジスタ】
//   $12 = SR (Status):  bit0 = EXL (例外処理中)
//   $13 = Cause:        bits[6:2] = ExcCode  (8=syscall, 12=Overflow)
//   $14 = EPC:          例外発生命令のPC
//
// 【例外ハンドラ (word 32 = 0x80)】
//   addi  $1, $1, 1    → $1++ (呼び出し回数カウント)
//   mfc0  $26, $14     → $26 = EPC
//   addiu $26, $26, 4  → $26 = EPC+4 (次の命令へスキップ)
//   mtc0  $26, $14     → EPC ← EPC+4
//   eret               → PC ← EPC
//
// 【メインプログラム実行順序】
//   0x00: addi $1, $0, 0          → $1 = 0 (カウンタ初期化)
//   0x04: syscall                 → 例外! EPC=0x04, ExcCode=8
//         (ハンドラ: $1=1, EPC→0x08, eret)
//   0x08: mfc0 $2, $14            → $2 = 0x08 (ハンドラで EPC+4 された後の値)
//   0x0C: mfc0 $3, $13            → $3 = 0x20 (ExcCode=8 → 8<<2)
//   0x10: mfc0 $4, $12            → $4 = 0x00 (eret 後 EXL=0)
//   0x14: lui  $5, 0x7FFF         → $5 = 0x7FFF0000
//   0x18: ori  $5, $5, 0xFFFF     → $5 = 0x7FFFFFFF (INT_MAX)
//   0x1C: addi $5, $5, 1          → オーバーフロー! EPC=0x1C, ExcCode=12
//         (ハンドラ: $1=2, EPC→0x20, eret)  ※$5 は書き込み抑制 → 変化なし
//   0x20: mfc0 $6, $13            → $6 = 0x30 (ExcCode=12 → 12<<2)
//   0x24: j 0x24                  → 無限ループ
//
// 【期待値】
//   $1 = 2    (例外2回)
//   $2 = 0x00000008  (ハンドラで EPC+4 された後の値)
//   $3 = 0x00000020  (Cause: ExcCode=8 → 8<<2=32=0x20)
//   $4 = 0x00000000  (eret 後 SR.EXL=0)
//   $5 = 0x7FFFFFFF  (オーバーフロー: 書き込み抑制でそのまま)
//   $6 = 0x00000030  (Cause: ExcCode=12 → 12<<2=48=0x30)
static const u32 test11_program[] = {
    // ---- メインプログラム (word 0-9) ----
    0x20010000,  // [0]  0x00: addi $1, $0, 0      | $1 = 0 (カウンタ初期化)
    0x0000000C,  // [1]  0x04: syscall              | → 例外 (EPC=0x04, ExcCode=8)
    0x40027000,  // [2]  0x08: mfc0 $2, $14         | $2 = 更新後 EPC = 0x08
    0x40036800,  // [3]  0x0C: mfc0 $3, $13         | $3 = Cause = 0x20
    0x40046000,  // [4]  0x10: mfc0 $4, $12         | $4 = SR = 0x00 (EXL=0)
    0x3C057FFF,  // [5]  0x14: lui $5, 0x7FFF       | $5 = 0x7FFF0000
    0x34A5FFFF,  // [6]  0x18: ori $5, $5, 0xFFFF   | $5 = 0x7FFFFFFF (INT_MAX)
    0x20A50001,  // [7]  0x1C: addi $5, $5, 1       | → オーバーフロー! (EPC=0x1C, ExcCode=12)
    0x40066800,  // [8]  0x20: mfc0 $6, $13         | $6 = Cause = 0x30
    0x08000009,  // [9]  0x24: j 0x24               | 無限ループ
    // ---- NOP padding (word 10-31, 0x28-0x7C) ----
    0x00000000, 0x00000000, 0x00000000, 0x00000000, // [10-13]
    0x00000000, 0x00000000, 0x00000000, 0x00000000, // [14-17]
    0x00000000, 0x00000000, 0x00000000, 0x00000000, // [18-21]
    0x00000000, 0x00000000, 0x00000000, 0x00000000, // [22-25]
    0x00000000, 0x00000000, 0x00000000, 0x00000000, // [26-29]
    0x00000000, 0x00000000,                          // [30-31]
    // ---- 例外ハンドラ (word 32 = 0x80) ----
    0x20210001,  // [32] 0x80: addi $1, $1, 1       | $1++ (例外回数カウント)
    0x401A7000,  // [33] 0x84: mfc0 $26, $14        | $26(k0) = EPC
    0x275A0004,  // [34] 0x88: addiu $26, $26, 4    | $26 = EPC+4
    0x409A7000,  // [35] 0x8C: mtc0 $26, $14        | EPC ← EPC+4
    0x42000018,  // [36] 0x90: eret                 | PC ← EPC (次の命令へ)
};
#define TEST11_COUNT  (sizeof(test11_program) / sizeof(test11_program[0]))

static void run_test11(void)
{
    xil_printf("=== Test 11: Exception (syscall, overflow, mfc0/mtc0/eret) ===\r\n");

    mips_reset();
    mips_load_program(test11_program, TEST11_COUNT);
    mips_run_cycles(500);

    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $1=2, $2=0x08, $3=0x20, $4=0x00, $5=0x7FFFFFFF, $6=0x30\r\n");
    mips_dump_regs(1, 6);
}

// ---- test11b: mfc0/mtc0 単体診断テスト (例外なし) ----
// 期待値: $4=0x55 (EPC経由), $6=0x15 (SR経由)
// $4=$6=0 の場合: is_mfc0=0 でCP0パスが壊れている
static const u32 test11b_program[] = {
    0x20030055,  // [0] addi $3, $0, 0x55  → $3 = 0x55
    0x40837000,  // [1] mtc0 $3, $14       → cp0_epc = 0x55
    0x40047000,  // [2] mfc0 $4, $14       → $4 = cp0_epc (expected 0x55)
    0x20050015,  // [3] addi $5, $0, 0x15  → $5 = 0x15
    0x40856000,  // [4] mtc0 $5, $12       → cp0_sr = 0x15
    0x40066000,  // [5] mfc0 $6, $12       → $6 = cp0_sr (expected 0x15)
    0x08000006,  // [6] j 6               → 無限ループ (PC=0x18)
};
#define TEST11B_COUNT (sizeof(test11b_program) / sizeof(test11b_program[0]))

static void run_test11b(void)
{
    xil_printf("=== Test 11b: mfc0/mtc0 standalone (no exception) ===\r\n");

    mips_reset();
    mips_load_program(test11b_program, TEST11B_COUNT);
    mips_run_cycles(200);

    xil_printf("Expected: $4=0x55, $6=0x15\r\n");
    mips_dump_regs(4, 6);
}

// ==== AUTO-GENERATED C TESTS BEGIN (step10/build_all.sh) ====

// --------------------------------------------------------
// C: bubble_sort({5,3,1,4,2}) min   Expected: $v0 = 1
// --------------------------------------------------------
static const u32 prog_bubble_sort[] = {
    0x3C1D0000,  // [  0] 0x0000
    0x37BD03FC,  // [  1] 0x0004
    0x03A0F025,  // [  2] 0x0008
    0x0C00006A,  // [  3] 0x000C
    0x00000000,  // [  4] 0x0010
    0x08000005,  // [  5] 0x0014
    0x00000000,  // [  6] 0x0018
    0x00000000,  // [  7] 0x001C
    0x27BDFFE8,  // [  8] 0x0020
    0xAFBE0014,  // [  9] 0x0024
    0x03A0F025,  // [ 10] 0x0028
    0xAFC40018,  // [ 11] 0x002C
    0xAFC5001C,  // [ 12] 0x0030
    0xAFC00000,  // [ 13] 0x0034
    0x1000004C,  // [ 14] 0x0038
    0x00000000,  // [ 15] 0x003C
    0xAFC00004,  // [ 16] 0x0040
    0x1000003B,  // [ 17] 0x0044
    0x00000000,  // [ 18] 0x0048
    0x8FC20004,  // [ 19] 0x004C
    0x00000000,  // [ 20] 0x0050
    0x00021080,  // [ 21] 0x0054
    0x8FC30018,  // [ 22] 0x0058
    0x00000000,  // [ 23] 0x005C
    0x00621021,  // [ 24] 0x0060
    0x8C430000,  // [ 25] 0x0064
    0x8FC20004,  // [ 26] 0x0068
    0x00000000,  // [ 27] 0x006C
    0x24420001,  // [ 28] 0x0070
    0x00021080,  // [ 29] 0x0074
    0x8FC40018,  // [ 30] 0x0078
    0x00000000,  // [ 31] 0x007C
    0x00821021,  // [ 32] 0x0080
    0x8C420000,  // [ 33] 0x0084
    0x00000000,  // [ 34] 0x0088
    0x0043102A,  // [ 35] 0x008C
    0x10400024,  // [ 36] 0x0090
    0x00000000,  // [ 37] 0x0094
    0x8FC20004,  // [ 38] 0x0098
    0x00000000,  // [ 39] 0x009C
    0x00021080,  // [ 40] 0x00A0
    0x8FC30018,  // [ 41] 0x00A4
    0x00000000,  // [ 42] 0x00A8
    0x00621021,  // [ 43] 0x00AC
    0x8C420000,  // [ 44] 0x00B0
    0x00000000,  // [ 45] 0x00B4
    0xAFC20008,  // [ 46] 0x00B8
    0x8FC20004,  // [ 47] 0x00BC
    0x00000000,  // [ 48] 0x00C0
    0x24420001,  // [ 49] 0x00C4
    0x00021080,  // [ 50] 0x00C8
    0x8FC30018,  // [ 51] 0x00CC
    0x00000000,  // [ 52] 0x00D0
    0x00621821,  // [ 53] 0x00D4
    0x8FC20004,  // [ 54] 0x00D8
    0x00000000,  // [ 55] 0x00DC
    0x00021080,  // [ 56] 0x00E0
    0x8FC40018,  // [ 57] 0x00E4
    0x00000000,  // [ 58] 0x00E8
    0x00821021,  // [ 59] 0x00EC
    0x8C630000,  // [ 60] 0x00F0
    0x00000000,  // [ 61] 0x00F4
    0xAC430000,  // [ 62] 0x00F8
    0x8FC20004,  // [ 63] 0x00FC
    0x00000000,  // [ 64] 0x0100
    0x24420001,  // [ 65] 0x0104
    0x00021080,  // [ 66] 0x0108
    0x8FC30018,  // [ 67] 0x010C
    0x00000000,  // [ 68] 0x0110
    0x00621021,  // [ 69] 0x0114
    0x8FC30008,  // [ 70] 0x0118
    0x00000000,  // [ 71] 0x011C
    0xAC430000,  // [ 72] 0x0120
    0x8FC20004,  // [ 73] 0x0124
    0x00000000,  // [ 74] 0x0128
    0x24420001,  // [ 75] 0x012C
    0xAFC20004,  // [ 76] 0x0130
    0x8FC3001C,  // [ 77] 0x0134
    0x8FC20000,  // [ 78] 0x0138
    0x00000000,  // [ 79] 0x013C
    0x00621023,  // [ 80] 0x0140
    0x2442FFFF,  // [ 81] 0x0144
    0x8FC30004,  // [ 82] 0x0148
    0x00000000,  // [ 83] 0x014C
    0x0062102A,  // [ 84] 0x0150
    0x1440FFBD,  // [ 85] 0x0154
    0x00000000,  // [ 86] 0x0158
    0x8FC20000,  // [ 87] 0x015C
    0x00000000,  // [ 88] 0x0160
    0x24420001,  // [ 89] 0x0164
    0xAFC20000,  // [ 90] 0x0168
    0x8FC2001C,  // [ 91] 0x016C
    0x00000000,  // [ 92] 0x0170
    0x2442FFFF,  // [ 93] 0x0174
    0x8FC30000,  // [ 94] 0x0178
    0x00000000,  // [ 95] 0x017C
    0x0062102A,  // [ 96] 0x0180
    0x1440FFAE,  // [ 97] 0x0184
    0x00000000,  // [ 98] 0x0188
    0x00000000,  // [ 99] 0x018C
    0x00000000,  // [100] 0x0190
    0x03C0E825,  // [101] 0x0194
    0x8FBE0014,  // [102] 0x0198
    0x27BD0018,  // [103] 0x019C
    0x03E00008,  // [104] 0x01A0
    0x00000000,  // [105] 0x01A4
    0x27BDFFD0,  // [106] 0x01A8
    0xAFBF002C,  // [107] 0x01AC
    0xAFBE0028,  // [108] 0x01B0
    0x03A0F025,  // [109] 0x01B4
    0x24020005,  // [110] 0x01B8
    0xAFC20010,  // [111] 0x01BC
    0x24020003,  // [112] 0x01C0
    0xAFC20014,  // [113] 0x01C4
    0x24020001,  // [114] 0x01C8
    0xAFC20018,  // [115] 0x01CC
    0x24020004,  // [116] 0x01D0
    0xAFC2001C,  // [117] 0x01D4
    0x24020002,  // [118] 0x01D8
    0xAFC20020,  // [119] 0x01DC
    0x24050005,  // [120] 0x01E0
    0x27C20010,  // [121] 0x01E4
    0x00402025,  // [122] 0x01E8
    0x0C000008,  // [123] 0x01EC
    0x00000000,  // [124] 0x01F0
    0x8FC20010,  // [125] 0x01F4
    0x03C0E825,  // [126] 0x01F8
    0x8FBF002C,  // [127] 0x01FC
    0x8FBE0028,  // [128] 0x0200
    0x27BD0030,  // [129] 0x0204
    0x03E00008,  // [130] 0x0208
    0x00000000,  // [131] 0x020C
};
#define PROG_BUBBLE_SORT_COUNT  (sizeof(prog_bubble_sort) / sizeof(prog_bubble_sort[0]))

static void run_c_bubble_sort(void)
{
    xil_printf("--- C: bubble_sort({5,3,1,4,2}) min ---\r\n");
    mips_reset();
    mips_load_program(prog_bubble_sort, PROG_BUBBLE_SORT_COUNT);
    mips_run_cycles(500);
    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $v0 = 1\r\n");
    xil_printf("  $v0 = 0x%08x (%d)\r\n", mips_read_reg(2), mips_read_reg(2));
}

// --------------------------------------------------------
// C: factorial(7)   Expected: $v0 = 5040
// --------------------------------------------------------
static const u32 prog_factorial[] = {
    0x3C1D0000,  // [  0] 0x0000
    0x37BD03FC,  // [  1] 0x0004
    0x03A0F025,  // [  2] 0x0008
    0x0C000026,  // [  3] 0x000C
    0x00000000,  // [  4] 0x0010
    0x08000005,  // [  5] 0x0014
    0x00000000,  // [  6] 0x0018
    0x00000000,  // [  7] 0x001C
    0x27BDFFE8,  // [  8] 0x0020
    0xAFBF0014,  // [  9] 0x0024
    0xAFBE0010,  // [ 10] 0x0028
    0x03A0F025,  // [ 11] 0x002C
    0xAFC40018,  // [ 12] 0x0030
    0x8FC20018,  // [ 13] 0x0034
    0x00000000,  // [ 14] 0x0038
    0x28420002,  // [ 15] 0x003C
    0x10400004,  // [ 16] 0x0040
    0x00000000,  // [ 17] 0x0044
    0x24020001,  // [ 18] 0x0048
    0x1000000C,  // [ 19] 0x004C
    0x00000000,  // [ 20] 0x0050
    0x8FC20018,  // [ 21] 0x0054
    0x00000000,  // [ 22] 0x0058
    0x2442FFFF,  // [ 23] 0x005C
    0x00402025,  // [ 24] 0x0060
    0x0C000008,  // [ 25] 0x0064
    0x00000000,  // [ 26] 0x0068
    0x00401825,  // [ 27] 0x006C
    0x8FC20018,  // [ 28] 0x0070
    0x00000000,  // [ 29] 0x0074
    0x00620018,  // [ 30] 0x0078
    0x00001012,  // [ 31] 0x007C
    0x03C0E825,  // [ 32] 0x0080
    0x8FBF0014,  // [ 33] 0x0084
    0x8FBE0010,  // [ 34] 0x0088
    0x27BD0018,  // [ 35] 0x008C
    0x03E00008,  // [ 36] 0x0090
    0x00000000,  // [ 37] 0x0094
    0x27BDFFE8,  // [ 38] 0x0098
    0xAFBF0014,  // [ 39] 0x009C
    0xAFBE0010,  // [ 40] 0x00A0
    0x03A0F025,  // [ 41] 0x00A4
    0x24040007,  // [ 42] 0x00A8
    0x0C000008,  // [ 43] 0x00AC
    0x00000000,  // [ 44] 0x00B0
    0x03C0E825,  // [ 45] 0x00B4
    0x8FBF0014,  // [ 46] 0x00B8
    0x8FBE0010,  // [ 47] 0x00BC
    0x27BD0018,  // [ 48] 0x00C0
    0x03E00008,  // [ 49] 0x00C4
    0x00000000,  // [ 50] 0x00C8
    0x00000000,  // [ 51] 0x00CC
};
#define PROG_FACTORIAL_COUNT  (sizeof(prog_factorial) / sizeof(prog_factorial[0]))

static void run_c_factorial(void)
{
    xil_printf("--- C: factorial(7) ---\r\n");
    mips_reset();
    mips_load_program(prog_factorial, PROG_FACTORIAL_COUNT);
    mips_run_cycles(500);
    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $v0 = 5040\r\n");
    xil_printf("  $v0 = 0x%08x (%d)\r\n", mips_read_reg(2), mips_read_reg(2));
}

// --------------------------------------------------------
// C: fibonacci(10)   Expected: $v0 = 55
// --------------------------------------------------------
static const u32 prog_fibonacci[] = {
    0x3C1D0000,  // [  0] 0x0000
    0x37BD03FC,  // [  1] 0x0004
    0x03A0F025,  // [  2] 0x0008
    0x0C00002B,  // [  3] 0x000C
    0x00000000,  // [  4] 0x0010
    0x08000005,  // [  5] 0x0014
    0x00000000,  // [  6] 0x0018
    0x00000000,  // [  7] 0x001C
    0x27BDFFE0,  // [  8] 0x0020
    0xAFBF001C,  // [  9] 0x0024
    0xAFBE0018,  // [ 10] 0x0028
    0xAFB00014,  // [ 11] 0x002C
    0x03A0F025,  // [ 12] 0x0030
    0xAFC40020,  // [ 13] 0x0034
    0x8FC20020,  // [ 14] 0x0038
    0x00000000,  // [ 15] 0x003C
    0x28420002,  // [ 16] 0x0040
    0x10400004,  // [ 17] 0x0044
    0x00000000,  // [ 18] 0x0048
    0x8FC20020,  // [ 19] 0x004C
    0x1000000F,  // [ 20] 0x0050
    0x00000000,  // [ 21] 0x0054
    0x8FC20020,  // [ 22] 0x0058
    0x00000000,  // [ 23] 0x005C
    0x2442FFFF,  // [ 24] 0x0060
    0x00402025,  // [ 25] 0x0064
    0x0C000008,  // [ 26] 0x0068
    0x00000000,  // [ 27] 0x006C
    0x00408025,  // [ 28] 0x0070
    0x8FC20020,  // [ 29] 0x0074
    0x00000000,  // [ 30] 0x0078
    0x2442FFFE,  // [ 31] 0x007C
    0x00402025,  // [ 32] 0x0080
    0x0C000008,  // [ 33] 0x0084
    0x00000000,  // [ 34] 0x0088
    0x02021021,  // [ 35] 0x008C
    0x03C0E825,  // [ 36] 0x0090
    0x8FBF001C,  // [ 37] 0x0094
    0x8FBE0018,  // [ 38] 0x0098
    0x8FB00014,  // [ 39] 0x009C
    0x27BD0020,  // [ 40] 0x00A0
    0x03E00008,  // [ 41] 0x00A4
    0x00000000,  // [ 42] 0x00A8
    0x27BDFFE8,  // [ 43] 0x00AC
    0xAFBF0014,  // [ 44] 0x00B0
    0xAFBE0010,  // [ 45] 0x00B4
    0x03A0F025,  // [ 46] 0x00B8
    0x2404000A,  // [ 47] 0x00BC
    0x0C000008,  // [ 48] 0x00C0
    0x00000000,  // [ 49] 0x00C4
    0x03C0E825,  // [ 50] 0x00C8
    0x8FBF0014,  // [ 51] 0x00CC
    0x8FBE0010,  // [ 52] 0x00D0
    0x27BD0018,  // [ 53] 0x00D4
    0x03E00008,  // [ 54] 0x00D8
    0x00000000,  // [ 55] 0x00DC
};
#define PROG_FIBONACCI_COUNT  (sizeof(prog_fibonacci) / sizeof(prog_fibonacci[0]))

static void run_c_fibonacci(void)
{
    xil_printf("--- C: fibonacci(10) ---\r\n");
    mips_reset();
    mips_load_program(prog_fibonacci, PROG_FIBONACCI_COUNT);
    mips_run_cycles(500);
    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $v0 = 55\r\n");
    xil_printf("  $v0 = 0x%08x (%d)\r\n", mips_read_reg(2), mips_read_reg(2));
}

// --------------------------------------------------------
// C: gcd(48, 18)   Expected: $v0 = 6
// --------------------------------------------------------
static const u32 prog_gcd[] = {
    0x3C1D0000,  // [  0] 0x0000
    0x37BD03FC,  // [  1] 0x0004
    0x03A0F025,  // [  2] 0x0008
    0x0C000028,  // [  3] 0x000C
    0x00000000,  // [  4] 0x0010
    0x08000005,  // [  5] 0x0014
    0x00000000,  // [  6] 0x0018
    0x00000000,  // [  7] 0x001C
    0x27BDFFF0,  // [  8] 0x0020
    0xAFBE000C,  // [  9] 0x0024
    0x03A0F025,  // [ 10] 0x0028
    0xAFC40010,  // [ 11] 0x002C
    0xAFC50014,  // [ 12] 0x0030
    0x10000010,  // [ 13] 0x0034
    0x00000000,  // [ 14] 0x0038
    0x8FC20014,  // [ 15] 0x003C
    0x00000000,  // [ 16] 0x0040
    0xAFC20000,  // [ 17] 0x0044
    0x8FC30010,  // [ 18] 0x0048
    0x8FC20014,  // [ 19] 0x004C
    0x00000000,  // [ 20] 0x0050
    0x0062001A,  // [ 21] 0x0054
    0x14400002,  // [ 22] 0x0058
    0x00000000,  // [ 23] 0x005C
    0x0007000D,  // [ 24] 0x0060
    0x00001010,  // [ 25] 0x0064
    0xAFC20014,  // [ 26] 0x0068
    0x8FC20000,  // [ 27] 0x006C
    0x00000000,  // [ 28] 0x0070
    0xAFC20010,  // [ 29] 0x0074
    0x8FC20014,  // [ 30] 0x0078
    0x00000000,  // [ 31] 0x007C
    0x1440FFEE,  // [ 32] 0x0080
    0x00000000,  // [ 33] 0x0084
    0x8FC20010,  // [ 34] 0x0088
    0x03C0E825,  // [ 35] 0x008C
    0x8FBE000C,  // [ 36] 0x0090
    0x27BD0010,  // [ 37] 0x0094
    0x03E00008,  // [ 38] 0x0098
    0x00000000,  // [ 39] 0x009C
    0x27BDFFE8,  // [ 40] 0x00A0
    0xAFBF0014,  // [ 41] 0x00A4
    0xAFBE0010,  // [ 42] 0x00A8
    0x03A0F025,  // [ 43] 0x00AC
    0x24050012,  // [ 44] 0x00B0
    0x24040030,  // [ 45] 0x00B4
    0x0C000008,  // [ 46] 0x00B8
    0x00000000,  // [ 47] 0x00BC
    0x03C0E825,  // [ 48] 0x00C0
    0x8FBF0014,  // [ 49] 0x00C4
    0x8FBE0010,  // [ 50] 0x00C8
    0x27BD0018,  // [ 51] 0x00CC
    0x03E00008,  // [ 52] 0x00D0
    0x00000000,  // [ 53] 0x00D4
    0x00000000,  // [ 54] 0x00D8
    0x00000000,  // [ 55] 0x00DC
};
#define PROG_GCD_COUNT  (sizeof(prog_gcd) / sizeof(prog_gcd[0]))

static void run_c_gcd(void)
{
    xil_printf("--- C: gcd(48, 18) ---\r\n");
    mips_reset();
    mips_load_program(prog_gcd, PROG_GCD_COUNT);
    mips_run_cycles(500);
    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $v0 = 6\r\n");
    xil_printf("  $v0 = 0x%08x (%d)\r\n", mips_read_reg(2), mips_read_reg(2));
}

// --------------------------------------------------------
// C: sum 1+2+...+10   Expected: $v0 = 55
// --------------------------------------------------------
static const u32 prog_sum_loop[] = {
    0x3C1D0000,  // [  0] 0x0000
    0x37BD03FC,  // [  1] 0x0004
    0x03A0F025,  // [  2] 0x0008
    0x0C000008,  // [  3] 0x000C
    0x00000000,  // [  4] 0x0010
    0x08000005,  // [  5] 0x0014
    0x00000000,  // [  6] 0x0018
    0x00000000,  // [  7] 0x001C
    0x27BDFFF0,  // [  8] 0x0020
    0xAFBE000C,  // [  9] 0x0024
    0x03A0F025,  // [ 10] 0x0028
    0xAFC00000,  // [ 11] 0x002C
    0x24020001,  // [ 12] 0x0030
    0xAFC20004,  // [ 13] 0x0034
    0x1000000A,  // [ 14] 0x0038
    0x00000000,  // [ 15] 0x003C
    0x8FC30000,  // [ 16] 0x0040
    0x8FC20004,  // [ 17] 0x0044
    0x00000000,  // [ 18] 0x0048
    0x00621021,  // [ 19] 0x004C
    0xAFC20000,  // [ 20] 0x0050
    0x8FC20004,  // [ 21] 0x0054
    0x00000000,  // [ 22] 0x0058
    0x24420001,  // [ 23] 0x005C
    0xAFC20004,  // [ 24] 0x0060
    0x8FC20004,  // [ 25] 0x0064
    0x00000000,  // [ 26] 0x0068
    0x2842000B,  // [ 27] 0x006C
    0x1440FFF3,  // [ 28] 0x0070
    0x00000000,  // [ 29] 0x0074
    0x8FC20000,  // [ 30] 0x0078
    0x03C0E825,  // [ 31] 0x007C
    0x8FBE000C,  // [ 32] 0x0080
    0x27BD0010,  // [ 33] 0x0084
    0x03E00008,  // [ 34] 0x0088
    0x00000000,  // [ 35] 0x008C
};
#define PROG_SUM_LOOP_COUNT  (sizeof(prog_sum_loop) / sizeof(prog_sum_loop[0]))

static void run_c_sum_loop(void)
{
    xil_printf("--- C: sum 1+2+...+10 ---\r\n");
    mips_reset();
    mips_load_program(prog_sum_loop, PROG_SUM_LOOP_COUNT);
    mips_run_cycles(500);
    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $v0 = 55\r\n");
    xil_printf("  $v0 = 0x%08x (%d)\r\n", mips_read_reg(2), mips_read_reg(2));
}

static void run_all_c_tests(void)
{
    xil_printf("\r\n==== C Program Tests ====\r\n\r\n");
    run_c_bubble_sort();
    xil_printf("\r\n");
    run_c_factorial();
    xil_printf("\r\n");
    run_c_fibonacci();
    xil_printf("\r\n");
    run_c_gcd();
    xil_printf("\r\n");
    run_c_sum_loop();
    xil_printf("\r\n");
}

// ==== AUTO-GENERATED C TESTS END ====

int main(void)
{
    xil_printf("\r\n==== MIPS Pipeline Test (Step 12f) ====\r\n\r\n");
    run_test_pipe_a();
    xil_printf("\r\n");
    run_test1();
    xil_printf("\r\n");
    run_test_pipe_c();
    xil_printf("\r\n");
    run_test2();           // Step 12d: lw/sw + beq
    xil_printf("\r\n");
    run_test3();           // Step 12d: j, jal, jr
    xil_printf("\r\n");
    run_test4();           // Step 12e: lui, ori, bne (ループ)
    xil_printf("\r\n");
    run_test5();           // Step 12e: andi, xori, slti, addiu, sll, srl, sra
    xil_printf("\r\n");
    run_test6();           // Step 12e: addu, subu, sltu, sltiu, nor, sllv, srlv, srav
    xil_printf("\r\n");
    run_test9();           // Step 12e: bltz, bgez, blez, bgtz
    xil_printf("\r\n");
    run_test7();           // Step 12f: mult, multu, div, divu, mfhi, mflo
    xil_printf("\r\n");
    run_test8();           // Step 12f: lb, lbu, lh, lhu, sb, sh
    /* Step 12g 以降で順次再有効化する。
    run_test10();          // C言語実行
    run_all_c_tests();
    run_test11b();
    run_test11();          // 例外処理 (パイプライン例外は精密化が必要)
    */
    xil_printf("\r\n==== Done ====\r\n");
    return 0;
}
