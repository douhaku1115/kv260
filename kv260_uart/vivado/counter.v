/*
 * 可変速カウンタモジュール (案3から流用)
 *
 * speed値が大きいほどカウンタの増分が大きく、変化が速くなる。
 * PSからAXI GPIO経由でspeedを設定し、count_outを読み取る。
 */
module counter (
    input  wire        clk,
    input  wire        resetn,
    input  wire [31:0] speed,
    output wire [31:0] count_out
);

    reg [31:0] count;

    always @(posedge clk) begin
        if (!resetn)
            count <= 32'd0;
        else
            count <= count + speed;
    end

    assign count_out = count;

endmodule
