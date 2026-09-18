// -----------------------------------------------------------------------------
// tb_fc.v -- fc.v（全結合 400→10 と argmax）を検証する
//
//   入力は pool2 の出力（sim/test_pool2_out.hex）、
//   期待値は sim/test_scores.hex（1枚につき int32 が10個）。
//   スコア10個が1ビットも違わないこと、および argmax が一致することを見る。
//
//   使い方: bash sim/run_sim.sh fc
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_fc;

    localparam integer NIN  = 400;
    localparam integer NOUT = 10;
    localparam integer NIMG = 10;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg  [7:0]  xmem [0:NIN-1];
    wire [15:0] x_addr;
    reg  [7:0]  x_data;
    always @(posedge clk) x_data <= xmem[x_addr];

    reg          start = 1'b0;
    wire         busy, done;
    wire [3:0]   digit;
    reg  [3:0]   score_addr;
    wire signed [31:0] score_data;

    fc #(.NIN(NIN), .NOUT(NOUT), .SHIFT(0),
         .WFILE("fc_w.hex"), .BFILE("fc_b.hex")) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
        .x_addr(x_addr), .x_data(x_data),
        .digit(digit), .score_addr(score_addr), .score_data(score_data)
    );

    reg [7:0]  source   [0:NIMG*NIN-1];
    reg [31:0] expected [0:NIMG*NOUT-1];

    integer n, i, bad, total_bad;
    integer exp_digit;
    reg signed [31:0] e, g;

    initial begin
        $readmemh("test_pool2_out.hex", source);
        $readmemh("test_scores.hex",    expected);

        total_bad = 0;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        for (n = 0; n < NIMG; n = n + 1) begin
            for (i = 0; i < NIN; i = i + 1) xmem[i] = source[n*NIN + i];

            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            wait (done == 1'b1);
            repeat (3) @(posedge clk);      // 最後の更新が反映されるのを待つ

            // ---- 期待される argmax（同点は先勝ち。numpy.argmax と同じ）----
            exp_digit = 0;
            for (i = 1; i < NOUT; i = i + 1) begin
                e = expected[n*NOUT + i];
                g = expected[n*NOUT + exp_digit];
                if (e > g) exp_digit = i;
            end

            // ---- スコアを1個ずつ突き合わせる ----
            bad = 0;
            for (i = 0; i < NOUT; i = i + 1) begin
                score_addr = i[3:0];
                #1;
                e = expected[n*NOUT + i];
                if (score_data !== e) begin
                    bad = bad + 1;
                    $display("    スコア[%0d] RTL=%0d 期待=%0d", i, score_data, e);
                end
            end
            if (digit !== exp_digit[3:0]) begin
                bad = bad + 1;
                $display("    argmax RTL=%0d 期待=%0d", digit, exp_digit);
            end
            total_bad = total_bad + bad;

            if (bad == 0)
                $display("  画像%0d: 一致 (スコア10個 + 答え=%0d)", n, digit);
            else
                $display("  画像%0d: 不一致 %0d 箇所", n, bad);
        end

        $display("");
        if (total_bad == 0)
            $display("=== tb_fc: 合格（%0d 枚すべて 1 ビットも違わない）===", NIMG);
        else
            $display("=== tb_fc: 失敗（不一致 %0d 箇所）===", total_bad);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("=== tb_fc: 時間切れ ===");
        $finish;
    end
endmodule
