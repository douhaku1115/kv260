// レジスタファイル (32本 x 32bit)
// MIPS の汎用レジスタ $0-$31 を保持する
//
// - 読み出し (rd1, rd2): 組み合わせ回路 (非同期)
// - 書き込み (wd3 → wa3): クロック立ち上がりで書き込み
// - $0 は常にゼロを返す (ハードワイヤード)
// - rd3: AXI 経由でのデバッグ用第3読み出しポート

module regfile (
    input         clk,
    input         we3,
    input  [4:0]  ra1,
    input  [4:0]  ra2,
    input  [4:0]  ra3,      // デバッグ用第3読み出しポート
    input  [4:0]  wa3,
    input  [31:0] wd3,
    output [31:0] rd1,
    output [31:0] rd2,
    output [31:0] rd3       // デバッグ用第3読み出し
);

    reg [31:0] rf [0:31];

    integer i;
    initial begin
        for (i = 0; i < 32; i = i + 1)
            rf[i] = 32'b0;
    end

    always @(posedge clk) begin
        if (we3 && wa3 != 5'b0)
            rf[wa3] <= wd3;
    end

    assign rd1 = (ra1 == 5'b0) ? 32'b0 : rf[ra1];
    assign rd2 = (ra2 == 5'b0) ? 32'b0 : rf[ra2];
    assign rd3 = (ra3 == 5'b0) ? 32'b0 : rf[ra3];

endmodule
