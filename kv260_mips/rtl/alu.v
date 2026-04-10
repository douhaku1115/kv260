// ALU (Arithmetic Logic Unit)
// 単一サイクルMIPSプロセッサ用の算術論理演算ユニット
//
// alu_control による演算選択:
//   4'b0000 = AND
//   4'b0001 = OR
//   4'b0010 = ADD
//   4'b0110 = SUB
//   4'b0111 = SLT (符号付き比較)
//
// zero 出力は beq 命令のブランチ判定に使用

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
            4'b0000: result = a & b;           // AND
            4'b0001: result = a | b;           // OR
            4'b0010: result = a + b;           // ADD
            4'b0110: result = a - b;           // SUB
            4'b0111: result = {31'b0, $signed(a) < $signed(b)}; // SLT
            default: result = 32'b0;
        endcase
    end

endmodule
