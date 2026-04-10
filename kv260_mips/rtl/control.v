// 制御ユニット (メインデコーダ + ALUデコーダ)
//
// メインデコーダ: opcode から制御信号を生成
//   | 命令   | RegWrite | RegDst | ALUSrc | Branch | MemWrite | MemtoReg | Jump |
//   |--------|----------|--------|--------|--------|----------|----------|------|
//   | R型    |    1     |   1    |   0    |   0    |    0     |    0     |  0   |
//   | addi   |    1     |   0    |   1    |   0    |    0     |    0     |  0   |
//   | lw     |    1     |   0    |   1    |   0    |    0     |    1     |  0   |
//   | sw     |    0     |   x    |   1    |   0    |    1     |    x     |  0   |
//   | beq    |    0     |   x    |   0    |   1    |    0     |    x     |  0   |
//   | j      |    0     |   x    |   x    |   0    |    0     |    x     |  1   |
//   | jal    |    1     |   x    |   x    |   0    |    0     |    x     |  1   |
//
// ALUデコーダ: alu_op + funct から alu_control を生成
//   alu_op=00 → ADD (addi/lw/sw)
//   alu_op=01 → SUB (beq)
//   alu_op=10 → funct フィールドで決定 (R型命令)

module control (
    input  [5:0] opcode,
    input  [5:0] funct,
    output       reg_write,
    output       reg_dst,
    output       alu_src,
    output       branch,
    output       mem_write,
    output       mem_to_reg,
    output       jump,
    output [3:0] alu_control
);

    // メインデコーダ
    reg [7:0] controls;
    // {reg_write, reg_dst, alu_src, branch, mem_write, mem_to_reg, jump, alu_op[1]}
    // alu_op: 00=add, 01=sub(beq), 1x=funct参照

    reg [1:0] alu_op;

    // controls ビット割り当て:
    //   [7] reg_write  - レジスタ書き込み有効
    //   [6] reg_dst    - 書き込み先: 1=rd, 0=rt
    //   [5] alu_src    - ALU入力B: 1=即値, 0=レジスタ
    //   [4] branch     - 分岐命令
    //   [3] mem_write  - データメモリ書き込み有効
    //   [2] mem_to_reg - レジスタ書き戻し: 1=メモリ読出値, 0=ALU結果
    //   [0] jump       - ジャンプ命令
    always @(*) begin
        case (opcode)
            //                          76543210
            6'b000000: begin controls = 8'b11000000; alu_op = 2'b10; end // R型
            6'b001000: begin controls = 8'b10100000; alu_op = 2'b00; end // addi
            6'b100011: begin controls = 8'b10100100; alu_op = 2'b00; end // lw
            6'b101011: begin controls = 8'b00101000; alu_op = 2'b00; end // sw
            6'b000100: begin controls = 8'b00010000; alu_op = 2'b01; end // beq
            6'b000010: begin controls = 8'b00000001; alu_op = 2'b00; end // j
            6'b000011: begin controls = 8'b10000001; alu_op = 2'b00; end // jal
            default:   begin controls = 8'b00000000; alu_op = 2'b00; end
        endcase
    end

    assign reg_write  = controls[7];
    assign reg_dst    = controls[6];
    assign alu_src    = controls[5];
    assign branch     = controls[4];
    assign mem_write  = controls[3];
    assign mem_to_reg = controls[2];
    assign jump       = controls[0];

    // ALUデコーダ
    reg [3:0] alu_ctrl_r;
    always @(*) begin
        case (alu_op)
            2'b00: alu_ctrl_r = 4'b0010; // add (addi, lw, sw)
            2'b01: alu_ctrl_r = 4'b0110; // sub (beq)
            2'b10: begin
                case (funct)
                    6'b100000: alu_ctrl_r = 4'b0010; // add
                    6'b100010: alu_ctrl_r = 4'b0110; // sub
                    6'b100100: alu_ctrl_r = 4'b0000; // and
                    6'b100101: alu_ctrl_r = 4'b0001; // or
                    6'b101010: alu_ctrl_r = 4'b0111; // slt
                    default:   alu_ctrl_r = 4'b0000;
                endcase
            end
            default: alu_ctrl_r = 4'b0010;
        endcase
    end

    assign alu_control = alu_ctrl_r;

endmodule
