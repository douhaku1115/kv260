// ============================================================
// alu.v — 算術論理演算ユニット (ALU)
// ============================================================
//
// 【alu_control と演算の対応】
//
//   alu_control | 演算      | 使用命令
//   ------------+-----------+------------------
//   4'b0000     | AND       | and
//   4'b0001     | OR        | or
//   4'b0010     | ADD       | add, addi, lw, sw
//   4'b0110     | SUB       | sub, beq
//   4'b0111     | SLT       | slt (符号付き比較)
//
// 【zero 出力】
//   result == 0 のとき 1 を出力する。
//   beq 命令で rs==rt を判定するために使用 (rs-rt=0 なら分岐)

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
            4'b0111: result = {31'b0, $signed(a) < $signed(b)};  // SLT: a<b なら 1
            default: result = 32'b0;
        endcase
    end

endmodule
