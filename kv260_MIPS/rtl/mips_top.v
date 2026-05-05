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
// 【実装済み命令セット (Step 1〜3)】
//
//  Step 1: addi, add, sub, and, or, slt
//  Step 2: lw, sw, beq
//  Step 3: j, jal, jr
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
    input  [7:0]  imem_waddr,
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
    wire        mem_write;   // データメモリ書き込み許可 (sw)
    wire        mem_to_reg;  // レジスタ書き戻し元: 1=メモリ, 0=ALU結果
    wire        jump;        // j/jal ジャンプ命令
    wire        jr;          // jr ジャンプレジスタ命令
    wire [3:0]  alu_control; // ALU演算種別

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
        .mem_write(mem_write),
        .mem_to_reg(mem_to_reg),
        .jump(jump),
        .jr(jr),
        .alu_control(alu_control)
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
        .mem_write(mem_write),
        .mem_to_reg(mem_to_reg),
        .jump(jump),
        .jr(jr),
        .alu_control(alu_control),
        .pc(pc),
        .instr(instr),
        .dbg_reg_addr(dbg_reg_addr),
        .dbg_reg_data(dbg_reg_data)
    );

endmodule
