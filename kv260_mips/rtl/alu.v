// ============================================================
// alu.v — 算術論理演算ユニット (ALU)
// ============================================================
//
// 【alu_control と演算の対応】
//
//   alu_control | 演算      | 使用命令
//   ------------+-----------+---------------------------
//   4'b0000     | AND       | and, andi
//   4'b0001     | OR        | or, ori
//   4'b0010     | ADD       | add, addu, addi, addiu, lw, sw
//   4'b0110     | SUB       | sub, subu, beq, bne
//   4'b0111     | SLT       | slt, slti  (符号付き比較)
//   4'b1000     | XOR       | xori
//   4'b1001     | SLL       | sll, sllv  (a << b[4:0])
//   4'b1010     | SRL       | srl, srlv  (a >> b[4:0] 論理)
//   4'b1011     | SRA       | sra, srav  (a >>> b[4:0] 算術)
//   4'b1100     | SLTU      | sltu, sltiu (符号なし比較)
//   4'b1101     | NOR       | nor        (~(a | b))
//
// 【zero 出力】
//   result == 0 のとき 1 を出力する。
//   beq/bne 命令で rs==rt を判定するために使用 (rs-rt=0 なら分岐)
//
// 【シフト命令の入力】
//   sll/srl/sra: datapath 側で a=rt, b={27'b0, shamt} に切り替えて渡す
//   sllv/srlv/srav: datapath 側で a=rt, b=rs(レジスタ値) に切り替えて渡す

module alu (
    input  [31:0] a,
    input  [31:0] b,
    input  [3:0]  alu_control,
    output reg [31:0] result,
    output        zero
);

    assign zero = (result == 32'b0);

    always @(*) begin
        case (alu_control)
            4'b0000: result = a & b;                              // AND
            4'b0001: result = a | b;                              // OR
            4'b0010: result = a + b;                              // ADD
            4'b0110: result = a - b;                              // SUB
            4'b0111: result = {31'b0, $signed(a) < $signed(b)};  // SLT
            4'b1000: result = a ^ b;                              // XOR
            4'b1001: result = a << b[4:0];                        // SLL / SLLV
            4'b1010: result = a >> b[4:0];                        // SRL / SRLV (論理)
            4'b1011: result = $signed(a) >>> b[4:0];              // SRA / SRAV (算術)
            4'b1100: result = {31'b0, a < b};                     // SLTU (符号なし比較)
            4'b1101: result = ~(a | b);                           // NOR
            default: result = 32'b0;
        endcase
    end

endmodule
