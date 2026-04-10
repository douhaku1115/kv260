// データパス (単一サイクル MIPS)
//
// 信号の流れ:
//   PC → imem → 命令デコード → レジスタ読み出し → ALU → レジスタ書き戻し
//
// PC更新:
//   - 通常: PC + 4
//   - beq:  PC + 4 + sign_extend(imm16) << 2 (branch_taken 時)
//   - j/jal: {PC[31:28], addr26, 2'b00}
//
// halt=1 の間は PC が停止し、AXI 経由でレジスタ値を安全に読める

module datapath (
    input         clk,
    input         reset,
    input         halt,

    // 制御信号
    input         reg_write,
    input         reg_dst,
    input         alu_src,
    input         branch,
    input         mem_write,
    input         mem_to_reg,
    input         jump,
    input  [3:0]  alu_control,

    // 命令メモリ
    output [31:0] pc,
    input  [31:0] instr,

    // デバッグ用
    input  [4:0]  dbg_reg_addr,
    output [31:0] dbg_reg_data
);

    // PC
    reg [31:0] pc_reg;
    wire [31:0] pc_next, pc_plus4, pc_branch, pc_jump;

    assign pc = pc_reg;
    assign pc_plus4 = pc_reg + 32'd4;

    // 命令フィールド分解
    wire [4:0]  rs    = instr[25:21];
    wire [4:0]  rt    = instr[20:16];
    wire [4:0]  rd    = instr[15:11];
    wire [15:0] imm16 = instr[15:0];
    wire [25:0] addr26 = instr[25:0];

    // 符号拡張
    wire [31:0] sign_imm = {{16{imm16[15]}}, imm16};

    // レジスタファイル
    wire [4:0]  write_reg = reg_dst ? rd : rt;
    wire [31:0] rd1, rd2, dbg_rd3;
    wire [31:0] write_data;

    regfile rf (
        .clk(clk),
        .we3(reg_write),
        .ra1(rs),
        .ra2(rt),
        .ra3(dbg_reg_addr),
        .wa3(write_reg),
        .wd3(write_data),
        .rd1(rd1),
        .rd2(rd2),
        .rd3(dbg_rd3)
    );

    assign dbg_reg_data = dbg_rd3;

    // ALU
    wire [31:0] alu_b = alu_src ? sign_imm : rd2;
    wire [31:0] alu_result;
    wire        alu_zero;

    alu alu_inst (
        .a(rd1),
        .b(alu_b),
        .alu_control(alu_control),
        .result(alu_result),
        .zero(alu_zero)
    );

    // データメモリ (lw/sw 命令用)
    // - addr: ALU結果 = ベースレジスタ + オフセット (バイトアドレス)
    // - write_data: rt レジスタ値 (sw 時)
    // - halt 中は書き込み禁止 (AXIデバッグ時の誤書き込み防止)
    wire [31:0] mem_read_data;

    dmem dmem_inst (
        .clk(clk),
        .mem_write(mem_write & ~halt),
        .addr(alu_result),
        .write_data(rd2),
        .read_data(mem_read_data)
    );

    // 書き戻しデータ
    assign write_data = mem_to_reg ? mem_read_data : alu_result;

    // ブランチ・ジャンプ
    assign pc_branch = pc_plus4 + (sign_imm << 2);
    assign pc_jump = {pc_plus4[31:28], addr26, 2'b00};

    wire branch_taken = branch & alu_zero;
    wire [31:0] pc_branch_mux = branch_taken ? pc_branch : pc_plus4;
    assign pc_next = jump ? pc_jump : pc_branch_mux;

    // PC更新
    always @(posedge clk) begin
        if (reset)
            pc_reg <= 32'b0;
        else if (!halt)
            pc_reg <= pc_next;
    end

endmodule
