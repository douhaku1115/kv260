// ============================================================
// control.v — 制御ユニット (メインデコーダ + ALUデコーダ)
// ============================================================
//
// 【役割】
//   命令の opcode (31:26) と funct (5:0) を見て、データパスへの
//   制御信号を生成する。2段構成:
//     1. メインデコーダ: opcode → 制御信号ベクタ + alu_op
//     2. ALUデコーダ:   alu_op + funct → alu_control
//
// 【メインデコーダ 真理値表】
//
//   命令  | opcode   | RW RD AS BR MW MR JP | alu_op | jr
//   ------+----------+----------------------+--------+----
//   R型   | 000000   |  1  1  0  0  0  0  0 |  10    |  0  (*funct で演算決定)
//   jr    | 000000   |  0  x  x  0  0  x  0 |  10    |  1  (funct=001000)
//   addi  | 001000   |  1  0  1  0  0  0  0 |  00    |  0
//   lw    | 100011   |  1  0  1  0  0  1  0 |  00    |  0
//   sw    | 101011   |  0  x  1  0  1  x  0 |  00    |  0
//   beq   | 000100   |  0  x  0  1  0  x  0 |  01    |  0
//   j     | 000010   |  0  x  x  0  0  x  1 |  00    |  0
//   jal   | 000011   |  1  x  x  0  0  x  1 |  00    |  0  (RW=1 で jal 識別)
//
//   RW=reg_write, RD=reg_dst, AS=alu_src, BR=branch,
//   MW=mem_write, MR=mem_to_reg, JP=jump
//
// 【ALUデコーダ】
//   alu_op=00 → ADD (addi, lw, sw用)
//   alu_op=01 → SUB (beq: a-b=0 なら分岐)
//   alu_op=10 → funct フィールドで演算を決定 (R型)
//
// 【controls ビット割り当て (8bit)】
//   [7] reg_write  [6] reg_dst  [5] alu_src  [4] branch
//   [3] mem_write  [2] mem_to_reg  [1] (未使用)  [0] jump

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
    output       jr,          // jr 専用フラグ (jump とは独立)
    output [3:0] alu_control
);

    reg [7:0] controls;
    reg [1:0] alu_op;

    // メインデコーダ
    always @(*) begin
        case (opcode)
            6'b000000: begin
                // R型命令: funct=001000 のみ jr (reg_write=0, jump=0)
                // それ以外は通常R型 (reg_write=1, reg_dst=1)
                if (funct == 6'b001000) controls = 8'b00000000; // jr
                else                    controls = 8'b11000000; // R型
                alu_op = 2'b10;
            end
            6'b001000: begin controls = 8'b10100000; alu_op = 2'b00; end // addi
            6'b100011: begin controls = 8'b10100100; alu_op = 2'b00; end // lw
            6'b101011: begin controls = 8'b00101000; alu_op = 2'b00; end // sw
            6'b000100: begin controls = 8'b00010000; alu_op = 2'b01; end // beq
            6'b000010: begin controls = 8'b00000001; alu_op = 2'b00; end // j
            6'b000011: begin controls = 8'b10000001; alu_op = 2'b00; end // jal (reg_write=1 で jal と識別)
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

    // jr は opcode=000000 かつ funct=001000 の組み合わせで判定
    // jump 信号(j/jal共用)とは独立させ、datapath 側でPC=rsを実現する
    assign jr = (opcode == 6'b000000) && (funct == 6'b001000);

    // ALUデコーダ
    reg [3:0] alu_ctrl_r;
    always @(*) begin
        case (alu_op)
            2'b00: alu_ctrl_r = 4'b0010; // ADD (addi, lw, sw)
            2'b01: alu_ctrl_r = 4'b0110; // SUB (beq: 差がゼロなら分岐)
            2'b10: begin
                // R型: funct フィールドで演算を選択
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
