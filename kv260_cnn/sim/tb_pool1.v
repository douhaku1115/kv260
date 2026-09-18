// -----------------------------------------------------------------------------
// tb_pool1.v -- maxpool2.v を pool1 の設定（8ch 26x26 → 13x13）で検証する
//
//   入力は conv1 の出力（sim/test_conv1_out.hex）、期待値は sim/test_pool1_out.hex。
//   conv1 と切り離して単体で確かめる。
//
//   使い方: bash sim/run_sim.sh pool1
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_pool1;

    localparam integer CH    = 8;
    localparam integer ISIZE = 26;
    localparam integer OSIZE = ISIZE / 2;            // 13
    localparam integer NIMG  = 10;
    localparam integer XLEN  = CH * ISIZE * ISIZE;   // 5408
    localparam integer YLEN  = CH * OSIZE * OSIZE;   // 1352

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg  [7:0]  xmem [0:XLEN-1];
    wire [15:0] x_addr;
    reg  [7:0]  x_data;
    always @(posedge clk) x_data <= xmem[x_addr];

    reg         start = 1'b0;
    wire        busy, done;
    wire        y_we;
    wire [15:0] y_addr;
    wire [7:0]  y_data;

    maxpool2 #(.CH(CH), .ISIZE(ISIZE)) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
        .x_addr(x_addr), .x_data(x_data),
        .y_we(y_we), .y_addr(y_addr), .y_data(y_data)
    );

    reg [7:0] ybuf [0:YLEN-1];
    integer   nwrite;
    always @(posedge clk) begin
        if (y_we) begin
            ybuf[y_addr] <= y_data;
            nwrite <= nwrite + 1;
        end
    end

    reg [7:0] source   [0:NIMG*XLEN-1];
    reg [7:0] expected [0:NIMG*YLEN-1];

    integer n, i, bad, total_bad, first_bad_idx;

    initial begin
        $readmemh("test_conv1_out.hex", source);
        $readmemh("test_pool1_out.hex", expected);

        total_bad = 0;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        for (n = 0; n < NIMG; n = n + 1) begin
            for (i = 0; i < XLEN; i = i + 1) xmem[i] = source[n*XLEN + i];
            for (i = 0; i < YLEN; i = i + 1) ybuf[i] = 8'hxx;
            nwrite = 0;

            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            wait (done == 1'b1);
            repeat (3) @(posedge clk);       // 最後の書き込みが反映されるのを待つ

            bad = 0;
            first_bad_idx = -1;
            for (i = 0; i < YLEN; i = i + 1) begin
                if (ybuf[i] !== expected[n*YLEN + i]) begin
                    if (first_bad_idx < 0) first_bad_idx = i;
                    bad = bad + 1;
                end
            end
            total_bad = total_bad + bad;

            if (bad == 0)
                $display("  画像%0d: 一致 (%0d 語, 書き込み %0d 回)", n, YLEN, nwrite);
            else
                $display("  画像%0d: 不一致 %0d / %0d 語  最初のずれ idx=%0d (ch=%0d y=%0d x=%0d) RTL=%02x 期待=%02x",
                         n, bad, YLEN, first_bad_idx,
                         first_bad_idx / (OSIZE*OSIZE),
                         (first_bad_idx % (OSIZE*OSIZE)) / OSIZE,
                         first_bad_idx % OSIZE,
                         ybuf[first_bad_idx], expected[n*YLEN + first_bad_idx]);
        end

        $display("");
        if (total_bad == 0)
            $display("=== tb_pool1: 合格（%0d 枚すべて 1 バイトも違わない）===", NIMG);
        else
            $display("=== tb_pool1: 失敗（不一致 %0d 語）===", total_bad);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("=== tb_pool1: 時間切れ ===");
        $finish;
    end
endmodule
