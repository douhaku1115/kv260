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

// 制御ビット
#define CTRL_RESET  (1 << 0)
#define CTRL_RUN    (1 << 1)
#define CTRL_STEP   (1 << 2)

static void mips_reset(void)
{
    Xil_Out32(REG_CTRL, CTRL_RESET);
    usleep(10);
}

static void mips_load_program(const u32 *prog, int count)
{
    for (int i = 0; i < count; i++) {
        Xil_Out32(REG_IMEM_ADDR, i);
        Xil_Out32(REG_IMEM_DATA, prog[i]);
    }
}

static void mips_run_cycles(int cycles)
{
    Xil_Out32(REG_CTRL, CTRL_RUN);
    usleep(cycles);
    Xil_Out32(REG_CTRL, 0);
}

static u32 mips_read_pc(void)
{
    return Xil_In32(REG_PC);
}

static u32 mips_read_reg(int regnum)
{
    Xil_Out32(REG_DBG_ADDR, regnum);
    return Xil_In32(REG_DBG_DATA);
}

static void mips_dump_regs(int from, int to)
{
    for (int i = from; i <= to; i++) {
        u32 val = mips_read_reg(i);
        xil_printf("  $%d = 0x%08x (%d)\r\n", i, val, val);
    }
}

// ========== テストプログラム ==========

static const u32 test1_program[] = {
    0x20010005, // addi $1, $0, 5       | $1 = 5
    0x20020003, // addi $2, $0, 3       | $2 = 3
    0x00221820, // add  $3, $1, $2      | $3 = 8
    0x00222022, // sub  $4, $1, $2      | $4 = 2
    0x00222824, // and  $5, $1, $2      | $5 = 1
    0x00223025, // or   $6, $1, $2      | $6 = 7
    0x0041382A, // slt  $7, $2, $1      | $7 = 1
};
#define TEST1_COUNT  (sizeof(test1_program) / sizeof(test1_program[0]))

// AXI接続テスト
static int test_axi(void)
{
    xil_printf("--- AXI connectivity test ---\r\n");

    xil_printf("  Write CTRL...");
    Xil_Out32(REG_CTRL, 0x1);
    xil_printf("OK\r\n");

    xil_printf("  Read CTRL...");
    u32 val = Xil_In32(REG_CTRL);
    xil_printf("0x%08x\r\n", val);

    xil_printf("  Read PC...");
    val = Xil_In32(REG_PC);
    xil_printf("0x%08x\r\n", val);

    xil_printf("  Write/Read DBG_ADDR...");
    Xil_Out32(REG_DBG_ADDR, 0);
    val = Xil_In32(REG_DBG_ADDR);
    xil_printf("0x%08x\r\n", val);

    xil_printf("--- AXI test done ---\r\n");
    return 0;
}

static void run_test1(void)
{
    xil_printf("=== Test 1: addi + R-type ===\r\n");

    xil_printf("  resetting...\r\n");
    mips_reset();

    xil_printf("  loading program (%d words)...\r\n", TEST1_COUNT);
    mips_load_program(test1_program, TEST1_COUNT);

    xil_printf("  running...\r\n");
    mips_run_cycles(100);

    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $1=5, $2=3, $3=8, $4=2, $5=1, $6=7, $7=1\r\n");
    mips_dump_regs(1, 7);
}

// Step 2: lw, sw, beq
static const u32 test2_program[] = {
    0x20010005, // addi $1, $0, 5       | $1 = 5
    0x20020003, // addi $2, $0, 3       | $2 = 3
    0x00221820, // add  $3, $1, $2      | $3 = 8
    0xAC030000, // sw   $3, 0($0)       | mem[0] = 8
    0x8C040000, // lw   $4, 0($0)       | $4 = 8 (mem[0])
    0x10830001, // beq  $4, $3, +1      | $4==$3 → skip next
    0x20050063, // addi $5, $0, 99      | skipped
    0x20060001, // addi $6, $0, 1       | $6 = 1 (beqで分岐成功)
    0x14810001, // bne  $0, $1, +1      | not implemented yet, falls through
    0x20070002, // addi $7, $0, 2       | $7 = 2
};
#define TEST2_COUNT  (sizeof(test2_program) / sizeof(test2_program[0]))

static void run_test2(void)
{
    xil_printf("=== Test 2: lw, sw, beq ===\r\n");

    mips_reset();
    mips_load_program(test2_program, TEST2_COUNT);
    mips_run_cycles(100);

    xil_printf("PC = 0x%08x\r\n", mips_read_pc());
    xil_printf("Expected: $1=5, $2=3, $3=8, $4=8, $5=0(skipped), $6=1, $7=2\r\n");
    mips_dump_regs(1, 7);
}

int main(void)
{
    xil_printf("\r\n==== MIPS Processor Test ====\r\n\r\n");
    run_test1();
    xil_printf("\r\n");
    run_test2();
    xil_printf("\r\n==== Done ====\r\n");
    return 0;
}
