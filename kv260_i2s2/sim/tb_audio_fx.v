`timescale 1ns/1ps
// audio_fx 単体テスト: 左右とも出力が出るか確認
module tb_audio_fx;
    reg clk = 0, rst_n = 0, tick = 0;
    reg signed [15:0] in_l, in_r;
    reg [7:0] gain, echo;
    wire signed [15:0] out_l, out_r;

    audio_fx dut (
        .clk(clk), .rst_n(rst_n), .tick(tick),
        .in_l(in_l), .in_r(in_r),
        .gain(gain), .echo(echo),
        .out_l(out_l), .out_r(out_r)
    );

    always #5 clk = ~clk;          // 100MHz

    integer k = 0;
    always @(posedge clk) begin
        k <= k + 1;
        tick <= (k % 16 == 0);     // 16クロックごとに1サンプル
    end

    initial begin
        in_l = 16'sd100;
        in_r = 16'sd200;
        gain = 8'd64;              // 等倍
        echo = 8'd0;               // エコー無効
        rst_n = 0;
        #100 rst_n = 1;

        #2000;                     // 数サンプル処理させる
        $display("gain=64 echo=0  in_l=100 in_r=200  ->  out_l=%0d out_r=%0d",
                 out_l, out_r);
        if (out_l == 100 && out_r == 200)
            $display("PASS: 左右とも正しい");
        else
            $display("FAIL: 左右のどちらかが違う (out_l=%0d out_r=%0d)", out_l, out_r);
        $finish;
    end
endmodule
