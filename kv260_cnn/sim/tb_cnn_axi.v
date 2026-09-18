// -----------------------------------------------------------------------------
// tb_cnn_axi.v -- cnn_axi.v を AXI4-Lite 越しに動かして検証する
//
//   PS がやるのと同じ手順を模して、
//     ID を読む → ポインタを戻す → 画素を784個書く → start → done を待つ
//     → 答えとスコア10個を読む
//   を10枚ぶん行い、sim/test_scores.hex と突き合わせる。
//
//   実機で AXI がおかしいと ILA を出す羽目になるので、
//   レジスタの番地・幅・ハンドシェイクはここで潰しておく。
//
//   使い方: bash sim/run_sim.sh axi
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module tb_cnn_axi;

    localparam integer NIMG = 10;
    localparam integer XLEN = 784;
    localparam integer NOUT = 10;

    // レジスタの番地（cnn_axi.v と一致させる）
    localparam [7:0] REG_ID     = 8'h00;
    localparam [7:0] REG_STATUS = 8'h10;
    localparam [7:0] REG_CTRL   = 8'h20;
    localparam [7:0] REG_IMG    = 8'h30;
    localparam [7:0] REG_DIGIT  = 8'h40;
    localparam [7:0] REG_SEL    = 8'h50;
    localparam [7:0] REG_SCORE  = 8'h60;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;                       // 100MHz

    // ---- AXI4-Lite の線 ----
    reg  [7:0]  awaddr;   reg awvalid;  wire awready;
    reg  [31:0] wdata;    reg wvalid;   wire wready;
    wire [1:0]  bresp;    wire bvalid;  reg  bready;
    reg  [7:0]  araddr;   reg arvalid;  wire arready;
    wire [31:0] rdata;    wire [1:0] rresp; wire rvalid; reg rready;

    cnn_axi dut (
        .S_AXI_ACLK(clk), .S_AXI_ARESETN(rst_n),
        .S_AXI_AWADDR(awaddr), .S_AXI_AWPROT(3'b0),
        .S_AXI_AWVALID(awvalid), .S_AXI_AWREADY(awready),
        .S_AXI_WDATA(wdata), .S_AXI_WSTRB(4'hF),
        .S_AXI_WVALID(wvalid), .S_AXI_WREADY(wready),
        .S_AXI_BRESP(bresp), .S_AXI_BVALID(bvalid), .S_AXI_BREADY(bready),
        .S_AXI_ARADDR(araddr), .S_AXI_ARPROT(3'b0),
        .S_AXI_ARVALID(arvalid), .S_AXI_ARREADY(arready),
        .S_AXI_RDATA(rdata), .S_AXI_RRESP(rresp),
        .S_AXI_RVALID(rvalid), .S_AXI_RREADY(rready)
    );

    // ---- 1回の書き込み ----
    task axi_write(input [7:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            awaddr <= addr; awvalid <= 1'b1;
            wdata  <= data; wvalid  <= 1'b1;
            bready <= 1'b1;
            wait (awready && wready);
            @(posedge clk);
            awvalid <= 1'b0; wvalid <= 1'b0;
            wait (bvalid);
            @(posedge clk);
            bready <= 1'b0;
        end
    endtask

    // ---- 1回の読み出し ----
    task axi_read(input [7:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            araddr <= addr; arvalid <= 1'b1; rready <= 1'b1;
            wait (arready);
            @(posedge clk);
            arvalid <= 1'b0;
            wait (rvalid);
            data = rdata;
            @(posedge clk);
            rready <= 1'b0;
        end
    endtask

    reg [7:0]  images   [0:NIMG*XLEN-1];
    reg [31:0] expected [0:NIMG*NOUT-1];

    integer n, i, bad, total_bad, exp_digit, cyc;
    reg [31:0] v;
    reg signed [31:0] e, g;

    initial begin
        $readmemh("test_images.hex", images);
        $readmemh("test_scores.hex", expected);

        awvalid = 0; wvalid = 0; bready = 0; arvalid = 0; rready = 0;
        total_bad = 0;

        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ---- 疎通確認 ----
        axi_read(REG_ID, v);
        if (v !== 32'hC440_0001) begin
            $display("  ID が違う: %08x（期待 c4400001）AXI が通っていない", v);
            total_bad = total_bad + 1;
        end else begin
            $display("  ID = %08x  AXI 疎通 OK", v);
        end

        for (n = 0; n < NIMG; n = n + 1) begin
            // ---- 画素ポインタを戻し、終了フラグも消す ----
            axi_write(REG_CTRL, 32'h6);          // bit1=ポインタ戻す, bit2=終了フラグ消す

            // ---- 画像を 784 個書く ----
            for (i = 0; i < XLEN; i = i + 1)
                axi_write(REG_IMG, {24'b0, images[n*XLEN + i]});

            axi_read(REG_STATUS, v);
            if (v[19:8] !== 12'd0) begin         // 784 書いたら 0 に戻っているはず
                $display("  画像%0d: 画素ポインタが %0d（期待 0）", n, v[19:8]);
                total_bad = total_bad + 1;
            end

            // ---- 開始 ----
            cyc = 0;
            axi_write(REG_CTRL, 32'h1);          // bit0=開始

            // ---- 終了待ち ----
            v = 0;
            while (v[1] !== 1'b1) begin
                axi_read(REG_STATUS, v);
                cyc = cyc + 1;
                // 1枚に約20万クロックかかる。1回の読み出しが数クロックなので
                // 4万回ほど回る。余裕を見て10万回で打ち切る。
                if (cyc > 100000) begin
                    $display("  画像%0d: done が立たない", n);
                    total_bad = total_bad + 1;
                    $finish;
                end
            end

            // ---- 期待される答え（同点は先勝ち）----
            exp_digit = 0;
            for (i = 1; i < NOUT; i = i + 1) begin
                e = expected[n*NOUT + i];
                g = expected[n*NOUT + exp_digit];
                if (e > g) exp_digit = i;
            end

            // ---- 答えとスコアを読む ----
            bad = 0;
            axi_read(REG_DIGIT, v);
            if (v[3:0] !== exp_digit[3:0]) begin
                $display("    答え AXI=%0d 期待=%0d", v[3:0], exp_digit);
                bad = bad + 1;
            end
            for (i = 0; i < NOUT; i = i + 1) begin
                axi_write(REG_SEL, i);
                axi_read(REG_SCORE, v);
                e = expected[n*NOUT + i];
                if ($signed(v) !== e) begin
                    $display("    スコア[%0d] AXI=%0d 期待=%0d", i, $signed(v), e);
                    bad = bad + 1;
                end
            end
            total_bad = total_bad + bad;

            if (bad == 0)
                $display("  画像%0d: 答え=%0d 一致（スコア10個とも）", n, exp_digit);
            else
                $display("  画像%0d: 不一致 %0d 箇所", n, bad);
        end

        $display("");
        if (total_bad == 0)
            $display("=== tb_cnn_axi: 合格（AXI 越しでも %0d 枚すべて一致）===", NIMG);
        else
            $display("=== tb_cnn_axi: 失敗（不一致 %0d 箇所）===", total_bad);
        $finish;
    end

    initial begin
        #200_000_000;
        $display("=== tb_cnn_axi: 時間切れ ===");
        $finish;
    end
endmodule
