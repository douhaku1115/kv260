// -----------------------------------------------------------------------------
// tb_conv1.v -- conv3x3.v を conv1 の設定（1ch → 8ch, 28x28）で検証する
//
//   Python の量子化版（train_mnist.py の QuantNet）が出した中間値
//   sim/test_conv1_out.hex と、RTL の出力を1バイトずつ突き合わせる。
//   1バイトでも違えば失敗。ここが合わないまま先へ進んでも意味がない。
//
//   使い方: bash sim/run_sim.sh conv1
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_conv1;

    // ---- conv1 の諸元（cnn_param.vh と一致させる）----
    localparam integer CIN   = 1;
    localparam integer COUT  = 8;
    localparam integer ISIZE = 28;
    localparam integer OSIZE = ISIZE - 2;               // 26
    localparam integer SHIFT = 9;                       // CONV1_SHIFT
    localparam integer NIMG  = 10;                      // テスト画像の枚数
    localparam integer XLEN  = CIN  * ISIZE * ISIZE;    // 784
    localparam integer YLEN  = COUT * OSIZE * OSIZE;    // 5408

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;                               // 100MHz

    // ---- 入力特徴マップ（BRAM 相当。同期読み出し1クロック遅れ）----
    reg  [7:0]  xmem [0:XLEN-1];
    wire [15:0] x_addr;
    reg  [7:0]  x_data;
    always @(posedge clk) x_data <= xmem[x_addr];

    // ---- 被試験モジュール ----
    reg         start = 1'b0;
    wire        busy, done;
    wire        y_we;
    wire [15:0] y_addr;
    wire [7:0]  y_data;

    conv3x3 #(
        .CIN(CIN), .COUT(COUT), .ISIZE(ISIZE), .SHIFT(SHIFT),
        .WFILE("conv1_w.hex"), .BFILE("conv1_b.hex")
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
        .x_addr(x_addr), .x_data(x_data),
        .y_we(y_we), .y_addr(y_addr), .y_data(y_data)
    );

    // ---- 出力の受け皿 ----
    reg [7:0] ybuf [0:YLEN-1];
    integer   nwrite;
    always @(posedge clk) begin
        if (y_we) begin
            ybuf[y_addr] <= y_data;
            nwrite <= nwrite + 1;
        end
    end

    // ---- 期待値とテスト画像 ----
    reg [7:0] images   [0:NIMG*XLEN-1];
    reg [7:0] expected [0:NIMG*YLEN-1];

    integer n, i, bad, total_bad;
    integer first_bad_idx;

    initial begin
        $readmemh("test_images.hex",    images);
        $readmemh("test_conv1_out.hex", expected);

        total_bad = 0;
        rst_n = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        for (n = 0; n < NIMG; n = n + 1) begin
            // ---- 画像を入力バッファへ ----
            for (i = 0; i < XLEN; i = i + 1)
                xmem[i] = images[n*XLEN + i];
            for (i = 0; i < YLEN; i = i + 1)
                ybuf[i] = 8'hxx;                 // 書き漏らしを検出できるようにする
            nwrite = 0;

            // ---- 起動 ----
            @(posedge clk);
            start = 1'b1;
            @(posedge clk);
            start = 1'b0;
            wait (done == 1'b1);
            // done と最後の書き込みは同じクロックで立つ。ノンブロッキング代入が
            // ybuf に反映されるのを待たずに比較すると、最後の1語だけ x のまま
            // 読んでしまう。数クロック余分に待ってから突き合わせる。
            repeat (3) @(posedge clk);

            // ---- 突き合わせ ----
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
            else begin
                $display("  画像%0d: 不一致 %0d / %0d 語  最初のずれ idx=%0d (ch=%0d y=%0d x=%0d) RTL=%02x 期待=%02x",
                         n, bad, YLEN, first_bad_idx,
                         first_bad_idx / (OSIZE*OSIZE),
                         (first_bad_idx % (OSIZE*OSIZE)) / OSIZE,
                         first_bad_idx % OSIZE,
                         ybuf[first_bad_idx], expected[n*YLEN + first_bad_idx]);
            end
        end

        $display("");
        if (total_bad == 0)
            $display("=== tb_conv1: 合格（%0d 枚すべて 1 バイトも違わない）===", NIMG);
        else
            $display("=== tb_conv1: 失敗（不一致 %0d 語）===", total_bad);
        $finish;
    end

    // ---- 暴走したら止める ----
    initial begin
        #20_000_000;                  // 20ms
        $display("=== tb_conv1: 時間切れ ===");
        $finish;
    end
endmodule
