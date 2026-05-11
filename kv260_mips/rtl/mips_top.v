// ============================================================
// mips_top.v — 単一サイクル MIPS プロセッサ トップモジュール
// ============================================================
//
// 【アーキテクチャ概要】
//
//         ┌──────────┐   instr   ┌───────────┐
//   PC───►│  imem    │──────────►│  control  │──► 制御信号群
//         └──────────┘           └───────────┘
//                                      │
//         ┌──────────────────────────────────────────┐
//         │              datapath                    │
//         │  regfile ──► ALU ──► dmem ──► regfile    │
//         │      │                           ▲        │
//         │      └──── jal: $31 ← PC+4 ─────┘        │
//         └──────────────────────────────────────────┘
//
// 【実装済み命令セット (Step 1〜11)】
//
//  Step 1: addi, add, sub, and, or, slt
//  Step 2: lw, sw, beq
//  Step 3: j, jal, jr
//  Step 4: bne, lui, ori
//  Step 5: andi, xori, slti, addiu, sll, srl, sra
//  Step 6: addu, subu, sltu, sltiu, nor, sllv, srlv, srav
//  Step 7: mult, multu, div, divu, mfhi, mflo
//  Step 8: lb, lbu, lh, lhu, sb, sh (バイト/ハーフワードアクセス, ビッグエンディアン)
//  Step 9: blez, bgtz, bltz, bgez (rs と 0 の比較分岐)
//  Step 10: C言語実行 (mips-linux-gnu-gcc クロスコンパイル)
//  Step 11: 例外処理 (CP0: SR/Cause/EPC, syscall, overflow, mfc0/mtc0/eret)
//
// 【外部インターフェース】
//   - PS(ARM)側から AXI 経由でプログラムロード・実行制御・デバッグ読み出し
//   - imem_we/waddr/wdata でプログラムを命令メモリに書き込む
//   - halt=1 の間は PC が停止し、レジスタ値を安全に読み出せる

module mips_top (
    input         clk,
    input         reset,
    input         halt,

    // 命令メモリ書き込みポート
    input         imem_we,
    input  [11:0] imem_waddr,
    input  [31:0] imem_wdata,

    // デバッグ出力
    output [31:0] pc,
    input  [4:0]  dbg_reg_addr,
    output [31:0] dbg_reg_data
);

    wire [31:0] instr;

    // 制御信号
    wire        reg_write;
    wire        reg_dst;
    wire        alu_src;
    wire        branch;
    wire        branch_ne;
    wire        branch_ltz;
    wire        branch_gez;
    wire        branch_lez;
    wire        branch_gtz;
    wire        mem_write;
    wire        mem_to_reg;
    wire        jump;
    wire        jr;
    wire        imm_zero;
    wire [3:0]  alu_control;
    wire        hilo_write;
    wire [1:0]  hilo_op;
    wire        mfhilo;
    wire        sel_hi;
    wire [1:0]  mem_size;      // 00=byte, 01=halfword, 10=word
    wire        mem_unsigned;  // 1=ゼロ拡張ロード (lbu/lhu)
    // 例外処理 (Step 11)
    wire        is_mfc0;
    wire        is_mtc0;
    wire        is_syscall;
    wire        is_eret;
    wire        exc_on_ov;

    // 命令メモリ
    imem imem_inst (
        .addr_a(pc),
        .instr(instr),
        .clk_b(clk),
        .we_b(imem_we),
        .addr_b(imem_waddr),
        .din_b(imem_wdata)
    );

    // 制御ユニット
    control ctrl (
        .opcode(instr[31:26]),
        .funct(instr[5:0]),
        .rs(instr[25:21]),
        .rt(instr[20:16]),
        .reg_write(reg_write),
        .reg_dst(reg_dst),
        .alu_src(alu_src),
        .branch(branch),
        .branch_ne(branch_ne),
        .branch_ltz(branch_ltz),
        .branch_gez(branch_gez),
        .branch_lez(branch_lez),
        .branch_gtz(branch_gtz),
        .mem_write(mem_write),
        .mem_to_reg(mem_to_reg),
        .jump(jump),
        .jr(jr),
        .imm_zero(imm_zero),
        .alu_control(alu_control),
        .hilo_write(hilo_write),
        .hilo_op(hilo_op),
        .mfhilo(mfhilo),
        .sel_hi(sel_hi),
        .mem_size(mem_size),
        .mem_unsigned(mem_unsigned),
        .is_mfc0(is_mfc0),
        .is_mtc0(is_mtc0),
        .is_syscall(is_syscall),
        .is_eret(is_eret),
        .exc_on_ov(exc_on_ov)
    );

    // データパス
    datapath dp (
        .clk(clk),
        .reset(reset),
        .halt(halt),
        .reg_write(reg_write),
        .reg_dst(reg_dst),
        .alu_src(alu_src),
        .branch(branch),
        .branch_ne(branch_ne),
        .branch_ltz(branch_ltz),
        .branch_gez(branch_gez),
        .branch_lez(branch_lez),
        .branch_gtz(branch_gtz),
        .mem_write(mem_write),
        .mem_to_reg(mem_to_reg),
        .jump(jump),
        .jr(jr),
        .imm_zero(imm_zero),
        .alu_control(alu_control),
        .hilo_write(hilo_write),
        .hilo_op(hilo_op),
        .mfhilo(mfhilo),
        .sel_hi(sel_hi),
        .mem_size(mem_size),
        .mem_unsigned(mem_unsigned),
        .is_mfc0(is_mfc0),
        .is_mtc0(is_mtc0),
        .is_syscall(is_syscall),
        .is_eret(is_eret),
        .exc_on_ov(exc_on_ov),
        .pc(pc),
        .instr(instr),
        .dbg_reg_addr(dbg_reg_addr),
        .dbg_reg_data(dbg_reg_data)
    );

endmodule
