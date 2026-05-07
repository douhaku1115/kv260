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
//   命令  | opcode   | IZ RW RD AS BR MW MR BN JP | alu_op | jr
//   ------+----------+-----------------------------+--------+----
//   R型   | 000000   |  0  1  1  0  0  0  0  0  0 | 010    |  0  (*funct で演算決定)
//   jr    | 000000   |  0  0  x  x  0  0  x  0  0 | 010    |  1  (funct=001000)
//   addi  | 001000   |  0  1  0  1  0  0  0  0  0 | 000    |  0
//   addiu | 001001   |  0  1  0  1  0  0  0  0  0 | 000    |  0  (addi と同じ、オーバーフロー無視)
//   slti  | 001010   |  0  1  0  1  0  0  0  0  0 | 110    |  0  (SLT: 符号付き比較)
//   andi  | 001100   |  1  1  0  1  0  0  0  0  0 | 100    |  0  (IZ=1: ゼロ拡張即値)
//   ori   | 001101   |  1  1  0  1  0  0  0  0  0 | 011    |  0  (IZ=1: ゼロ拡張即値)
//   xori  | 001110   |  1  1  0  1  0  0  0  0  0 | 101    |  0  (IZ=1: ゼロ拡張即値)
//   lui   | 001111   |  0  1  0  1  0  0  0  0  0 | 000    |  0  (datapath 側で特別処理)
//   lw    | 100011   |  0  1  0  1  0  0  1  0  0 | 000    |  0
//   sw    | 101011   |  0  0  x  1  0  1  x  0  0 | 000    |  0
//   beq   | 000100   |  0  0  x  0  1  0  x  0  0 | 001    |  0
//   bne   | 000101   |  0  0  x  0  0  0  x  1  0 | 001    |  0  (BN=1 で beq と区別)
//   j     | 000010   |  0  0  x  x  0  0  x  0  1 | 000    |  0
//   jal   | 000011   |  0  1  x  x  0  0  x  0  1 | 000    |  0  (RW=1 で jal 識別)
//
//   IZ=imm_zero(ゼロ拡張選択), RW=reg_write, RD=reg_dst, AS=alu_src,
//   BR=branch(beq), MW=mem_write, MR=mem_to_reg, BN=branch_ne(bne), JP=jump
//
// 【ALUデコーダ (3bit alu_op)】
//   alu_op=000 → ADD (addi, addiu, lw, sw, lui)
//   alu_op=001 → SUB (beq/bne: a-b=0 なら分岐)
//   alu_op=010 → funct フィールドで演算を決定 (R型)
//   alu_op=011 → OR  (ori: ゼロ拡張即値との OR)
//   alu_op=100 → AND (andi: ゼロ拡張即値との AND)
//   alu_op=101 → XOR (xori: ゼロ拡張即値との XOR)
//   alu_op=110 → SLT (slti: 符号付き比較)
//
// 【controls ビット割り当て (9bit)】
//   [8] imm_zero  [7] reg_write  [6] reg_dst  [5] alu_src  [4] branch
//   [3] mem_write  [2] mem_to_reg  [1] branch_ne  [0] jump

module control (
    input  [5:0] opcode,
    input  [5:0] funct,
    output       reg_write,
    output       reg_dst,
    output       alu_src,
    output       branch,
    output       branch_ne,   // bne 専用フラグ (beq とは独立)
    output       mem_write,
    output       mem_to_reg,
    output       jump,
    output       jr,          // jr 専用フラグ (jump とは独立)
    output       imm_zero,    // 1=ゼロ拡張即値 (ori用), 0=符号拡張即値
    output [3:0] alu_control
);

    reg [8:0] controls;
    reg [2:0] alu_op;

    // メインデコーダ
    always @(*) begin
        case (opcode)
            6'b000000: begin
                // R型命令: funct=001000 のみ jr (reg_write=0, jump=0)
                // それ以外は通常R型 (reg_write=1, reg_dst=1)
                if (funct == 6'b001000) controls = 9'b000000000; // jr
                else                    controls = 9'b011000000; // R型
                alu_op = 3'b010;
            end
            6'b001000: begin controls = 9'b010100000; alu_op = 3'b000; end // addi
            6'b001001: begin controls = 9'b010100000; alu_op = 3'b000; end // addiu (addi と同じ動作)
            6'b001010: begin controls = 9'b010100000; alu_op = 3'b110; end // slti  (SLT演算)
            6'b001100: begin controls = 9'b110100000; alu_op = 3'b100; end // andi  (imm_zero=1, AND演算)
            6'b001101: begin controls = 9'b110100000; alu_op = 3'b011; end // ori   (imm_zero=1, OR演算)
            6'b001110: begin controls = 9'b110100000; alu_op = 3'b101; end // xori  (imm_zero=1, XOR演算)
            6'b001111: begin controls = 9'b010100000; alu_op = 3'b000; end // lui   (datapath 側で {imm,16'b0} に書き戻し)
            6'b100011: begin controls = 9'b010100100; alu_op = 3'b000; end // lw
            6'b101011: begin controls = 9'b000101000; alu_op = 3'b000; end // sw
            6'b000100: begin controls = 9'b000010000; alu_op = 3'b001; end // beq
            6'b000101: begin controls = 9'b000000010; alu_op = 3'b001; end // bne  (branch_ne=1, SUB)
            6'b000010: begin controls = 9'b000000001; alu_op = 3'b000; end // j
            6'b000011: begin controls = 9'b010000001; alu_op = 3'b000; end // jal  (reg_write=1 で jal と識別)
            default:   begin controls = 9'b000000000; alu_op = 3'b000; end
        endcase
    end

    assign imm_zero   = controls[8];
    assign reg_write  = controls[7];
    assign reg_dst    = controls[6];
    assign alu_src    = controls[5];
    assign branch     = controls[4];
    assign mem_write  = controls[3];
    assign mem_to_reg = controls[2];
    assign branch_ne  = controls[1];
    assign jump       = controls[0];

    // jr は opcode=000000 かつ funct=001000 の組み合わせで判定
    // jump 信号(j/jal共用)とは独立させ、datapath 側でPC=rsを実現する
    assign jr = (opcode == 6'b000000) && (funct == 6'b001000);

    // ALUデコーダ
    reg [3:0] alu_ctrl_r;
    always @(*) begin
        case (alu_op)
            3'b000: alu_ctrl_r = 4'b0010; // ADD (addi, addiu, lw, sw, lui)
            3'b001: alu_ctrl_r = 4'b0110; // SUB (beq/bne: 差がゼロか否かで分岐)
            3'b010: begin
                // R型: funct フィールドで演算を選択
                case (funct)
                    6'b100000: alu_ctrl_r = 4'b0010; // add
                    6'b100010: alu_ctrl_r = 4'b0110; // sub
                    6'b100100: alu_ctrl_r = 4'b0000; // and
                    6'b100101: alu_ctrl_r = 4'b0001; // or
                    6'b101010: alu_ctrl_r = 4'b0111; // slt
                    6'b000000: alu_ctrl_r = 4'b1001; // sll (shamt使用)
                    6'b000010: alu_ctrl_r = 4'b1010; // srl (shamt使用)
                    6'b000011: alu_ctrl_r = 4'b1011; // sra (shamt使用)
                    default:   alu_ctrl_r = 4'b0000;
                endcase
            end
            3'b011: alu_ctrl_r = 4'b0001; // OR  (ori)
            3'b100: alu_ctrl_r = 4'b0000; // AND (andi)
            3'b101: alu_ctrl_r = 4'b1000; // XOR (xori)
            3'b110: alu_ctrl_r = 4'b0111; // SLT (slti)
            default: alu_ctrl_r = 4'b0010;
        endcase
    end

    assign alu_control = alu_ctrl_r;

endmodule
