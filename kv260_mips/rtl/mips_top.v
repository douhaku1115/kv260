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
// 【実装済み命令セット (Step 1〜7)】
//
//  Step 1: addi, add, sub, and, or, slt
//  Step 2: lw, sw, beq
//  Step 3: j, jal, jr
//  Step 4: bne, lui, ori
//  Step 5: andi, xori, slti, addiu, sll, srl, sra
//  Step 6: addu, subu, sltu, sltiu, nor, sllv, srlv, srav
//  Step 7: mult, multu, div, divu, mfhi, mflo
//
// 【外部インターフェース】
//   - PS(ARM)側から AXI 経由でプログラムロード・実行制御・デバッグ読み出し
//   - imem_we/waddr/wdata でプログラムを命令メモリに書き込む
//   - halt=1 の間は PC が停止し、レジスタ値を安全に読み出せる

module mips_top (
    input         clk,
    input         reset,
    input         halt,

    // 命令メモリ書き込みポート (PS側からプログラムをロードする)
    input         imem_we,
    input  [11:0] imem_waddr,
    input  [31:0] imem_wdata,

    // デバッグ出力 (AXI経由でPS側から読み出す)
    output [31:0] pc,
    input  [4:0]  dbg_reg_addr,
    output [31:0] dbg_reg_data
);

    wire [31:0] instr;

    // 制御信号 (control → datapath)
    wire        reg_write;   // レジスタ書き込み許可
    wire        reg_dst;     // 書き込み先レジスタ: 1=rd (R型), 0=rt (I型)
    wire        alu_src;     // ALU入力B: 1=即値, 0=レジスタ
    wire        branch;      // beq 分岐命令
    wire        branch_ne;   // bne 分岐命令
    wire        mem_write;   // データメモリ書き込み許可 (sw)
    wire        mem_to_reg;  // レジスタ書き戻し元: 1=メモリ, 0=ALU結果
    wire        jump;        // j/jal ジャンプ命令
    wire        jr;          // jr ジャンプレジスタ命令
    wire        imm_zero;    // ゼロ拡張即値選択 (ori用)
    wire [3:0]  alu_control; // ALU演算種別
    wire        hilo_write;  // HI/LO書き込み許可 (mult/multu/div/divu)
    wire [1:0]  hilo_op;     // HI/LO演算種別
    wire        mfhilo;      // mfhi/mflo フラグ
    wire        sel_hi;      // 1=mfhi, 0=mflo

    // 命令メモリ (256ワード x 32bit デュアルポートRAM)
    imem imem_inst (
        .addr_a(pc),
        .instr(instr),
        .clk_b(clk),
        .we_b(imem_we),
        .addr_b(imem_waddr),
        .din_b(imem_wdata)
    );

    // 制御ユニット (opcode/funct → 制御信号)
    control ctrl (
        .opcode(instr[31:26]),
        .funct(instr[5:0]),
        .reg_write(reg_write),
        .reg_dst(reg_dst),
        .alu_src(alu_src),
        .branch(branch),
        .branch_ne(branch_ne),
        .mem_write(mem_write),
        .mem_to_reg(mem_to_reg),
        .jump(jump),
        .jr(jr),
        .imm_zero(imm_zero),
        .alu_control(alu_control),
        .hilo_write(hilo_write),
        .hilo_op(hilo_op),
        .mfhilo(mfhilo),
        .sel_hi(sel_hi)
    );

    // データパス (レジスタ・ALU・メモリ・PC更新)
    datapath dp (
        .clk(clk),
        .reset(reset),
        .halt(halt),
        .reg_write(reg_write),
        .reg_dst(reg_dst),
        .alu_src(alu_src),
        .branch(branch),
        .branch_ne(branch_ne),
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
        .pc(pc),
        .instr(instr),
        .dbg_reg_addr(dbg_reg_addr),
        .dbg_reg_data(dbg_reg_data)
    );

endmodule
