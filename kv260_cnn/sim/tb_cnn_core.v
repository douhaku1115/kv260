// -----------------------------------------------------------------------------
// tb_cnn_core.v -- CNN 全体（conv1→pool1→conv2→pool2→fc）を通しで検証する
//
//   28x28 の画像を書き込んで start、done を待って答えとスコアを見る。
//   期待値は sim/test_scores.hex（Python の量子化版が出した int32 x 10）。
//   段階Aで確認した「8ビット整数版」と 1 ビットも違わないことが合格条件。
//
//   所要クロック数も測る。100MHz で 1 枚あたり何ミリ秒かかるかの目安になる。
//
//   使い方: bash sim/run_sim.sh core
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_cnn_core;

    localparam integer NIMG = 10;
    localparam integer XLEN = 784;
    localparam integer NOUT = 10;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;                    // 100MHz

    reg         img_we = 1'b0;
    reg  [9:0]  img_addr = 10'd0;
    reg  [7:0]  img_data = 8'd0;
    reg         start = 1'b0;
    wire        busy, done;
    wire [3:0]  digit;
    reg  [3:0]  score_addr = 4'd0;
    wire signed [31:0] score_data;

    cnn_core dut (
        .clk(clk), .rst_n(rst_n),
        .img_we(img_we), .img_addr(img_addr), .img_data(img_data),
        .start(start), .busy(busy), .done(done),
        .digit(digit), .score_addr(score_addr), .score_data(score_data)
    );

    reg [7:0]  images   [0:NIMG*XLEN-1];
    reg [31:0] expected [0:NIMG*NOUT-1];

    integer n, i, bad, total_bad, cyc, exp_digit;
    reg signed [31:0] e, g;

    // ---- クロック数を数える ----
    integer counter;
    always @(posedge clk) if (busy) counter = counter + 1;

    initial begin
        $readmemh("test_images.hex", images);
        $readmemh("test_scores.hex", expected);

        total_bad = 0;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        for (n = 0; n < NIMG; n = n + 1) begin
            // ---- 画像を書き込む ----
            for (i = 0; i < XLEN; i = i + 1) begin
                @(posedge clk);
                img_we   = 1'b1;
                img_addr = i[9:0];
                img_data = images[n*XLEN + i];
            end
            @(posedge clk);
            img_we = 1'b0;

            // ---- 起動 ----
            counter = 0;
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            wait (done == 1'b1);
            cyc = counter;
            repeat (3) @(posedge clk);

            // ---- 期待される答え（同点は先勝ち。numpy.argmax と同じ）----
            exp_digit = 0;
            for (i = 1; i < NOUT; i = i + 1) begin
                e = expected[n*NOUT + i];
                g = expected[n*NOUT + exp_digit];
                if (e > g) exp_digit = i;
            end

            // ---- 突き合わせ ----
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
                $display("    答え RTL=%0d 期待=%0d", digit, exp_digit);
            end
            total_bad = total_bad + bad;

            if (bad == 0)
                $display("  画像%0d: 答え=%0d 一致  (%0d クロック = %0.3f ms @100MHz)",
                         n, digit, cyc, cyc / 100000.0);
            else
                $display("  画像%0d: 不一致 %0d 箇所", n, bad);
        end

        $display("");
        if (total_bad == 0)
            $display("=== tb_cnn_core: 合格（%0d 枚すべて 1 ビットも違わない）===", NIMG);
        else
            $display("=== tb_cnn_core: 失敗（不一致 %0d 箇所）===", total_bad);
        $finish;
    end

    initial begin
        #100_000_000;
        $display("=== tb_cnn_core: 時間切れ ===");
        $finish;
    end
endmodule
