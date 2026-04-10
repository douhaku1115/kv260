// MIPS プロセッサ トップモジュール
//
// 単一サイクル MIPS32 サブセットプロセッサ
// imem (命令メモリ) + control (制御) + datapath (データパス) を統合
//
// 外部インターフェース:
//   - clk/reset/halt: 制御
//   - imem_we/waddr/wdata: PS側から命令メモリへのプログラムロード
//   - pc, dbg_reg_addr/data: デバッグ用レジスタ読み出し

module mips_top (
    input         clk,
    input         reset,
    input         halt,

    // 命令メモリ書き込みポート (PS側)
    input         imem_we,
    input  [7:0]  imem_waddr,
    input  [31:0] imem_wdata,

    // デバッグ出力
    output [31:0] pc,
    input  [4:0]  dbg_reg_addr,
    output [31:0] dbg_reg_data
);

    wire [31:0] instr;

    // 制御信号
    wire        reg_write, reg_dst, alu_src;
    wire        branch, mem_write, mem_to_reg, jump;
    wire [3:0]  alu_control;

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
        .reg_write(reg_write),
        .reg_dst(reg_dst),
        .alu_src(alu_src),
        .branch(branch),
        .mem_write(mem_write),
        .mem_to_reg(mem_to_reg),
        .jump(jump),
        .alu_control(alu_control)
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
        .mem_write(mem_write),
        .mem_to_reg(mem_to_reg),
        .jump(jump),
        .alu_control(alu_control),
        .pc(pc),
        .instr(instr),
        .dbg_reg_addr(dbg_reg_addr),
        .dbg_reg_data(dbg_reg_data)
    );

endmodule
