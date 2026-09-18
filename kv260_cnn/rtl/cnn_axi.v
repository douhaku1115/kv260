// -----------------------------------------------------------------------------
// cnn_axi.v -- cnn_core に AXI4-Lite の窓口を付けたもの（段13 段階C）
//
//   PS(ARM) から
//     ・28x28 の画像を 1 画素ずつ書き込む
//     ・start を打つ
//     ・done を待つ
//     ・答え(0〜9)と 10 個のスコア(int32)を読む
//   ができるようにする。
//
//   【レジスタは 0x10 刻みに整列させる（最重要）】
//     Zynq UltraScale+ の HPM を 32 ビット幅で使うと、0x10 境界に整列して
//     いないアドレスは devmem/mmap の読み出しが必ず 0 を返す。
//     段11（I2S2 音楽再生）でこれに半日はまった。アドレスのデコードは [7:4]。
//
//     0x00 ID     (R)  0xC4400001 が返れば AXI は正常に通っている
//     0x10 STATUS (R)  bit0=計算中, bit1=計算終了(読むまで保持), [19:8]=画素ポインタ
//     0x20 CTRL   (W)  bit0=開始, bit1=画素ポインタを0に戻す, bit2=終了フラグを消す
//     0x30 IMG    (W)  画素を1つ書く。書くたびにポインタが1進む（0〜783）
//     0x40 DIGIT  (R)  答え（0〜9）
//     0x50 SEL    (W)  次に読むスコアの番号（0〜9）
//     0x60 SCORE  (R)  SEL で選んだスコア（int32、符号つき）
//
//   【画素を1つずつ書く理由】
//     AXI スレーブ側に 784 バイトの配列を置いて直接番地を振ると、
//     合成で配列が消えたり書き込みが届かなかったりする事故があった
//     （段Tetris の Phase F）。窓口は 1 本にして、中の並びは
//     ポインタで管理するほうが安全で、配線も軽い。
//
//   【クロック】PS の pl_clk0（100MHz）をそのまま使う。1 枚 1.99ms。
//   【実機で確認済み（2026-09-18）】
//     0x00 を読んで 0xC4400001 が返り、10 枚すべて期待値と一致した。
//     レジスタを 0x10 刻みに整列させてあるので devmem/mmap でも正しく読める。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module cnn_axi #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 8
)(
    // ---- AXI4-Lite スレーブ ----
    input  wire                            S_AXI_ACLK,
    input  wire                            S_AXI_ARESETN,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]   S_AXI_AWADDR,
    input  wire [2:0]                      S_AXI_AWPROT,
    input  wire                            S_AXI_AWVALID,
    output wire                            S_AXI_AWREADY,

    input  wire [C_S_AXI_DATA_WIDTH-1:0]   S_AXI_WDATA,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] S_AXI_WSTRB,
    input  wire                            S_AXI_WVALID,
    output wire                            S_AXI_WREADY,

    output wire [1:0]                      S_AXI_BRESP,
    output wire                            S_AXI_BVALID,
    input  wire                            S_AXI_BREADY,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]   S_AXI_ARADDR,
    input  wire [2:0]                      S_AXI_ARPROT,
    input  wire                            S_AXI_ARVALID,
    output wire                            S_AXI_ARREADY,

    output wire [C_S_AXI_DATA_WIDTH-1:0]   S_AXI_RDATA,
    output wire [1:0]                      S_AXI_RRESP,
    output wire                            S_AXI_RVALID,
    input  wire                            S_AXI_RREADY
);
    wire clk   = S_AXI_ACLK;
    wire rst_n = S_AXI_ARESETN;

    // =========================================================================
    // AXI4-Lite の受け口（段11 の i2s_stream_axi.v と同じ作り）
    // =========================================================================
    reg                          axi_awready, axi_wready, axi_bvalid;
    reg                          axi_arready, axi_rvalid;
    reg [1:0]                    axi_bresp, axi_rresp;
    reg [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
    reg                          aw_en;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    always @(posedge clk) begin
        if (!rst_n) begin
            axi_awready <= 1'b0;
            aw_en       <= 1'b1;
        end else if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
            axi_awready <= 1'b1;
            aw_en       <= 1'b0;
            axi_awaddr  <= S_AXI_AWADDR;
        end else begin
            axi_awready <= 1'b0;
            if (S_AXI_BREADY && axi_bvalid) aw_en <= 1'b1;
        end
    end

    always @(posedge clk) begin
        if (!rst_n)                                                     axi_wready <= 1'b0;
        else if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en) axi_wready <= 1'b1;
        else                                                            axi_wready <= 1'b0;
    end

    wire wr_en = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

    always @(posedge clk) begin
        if (!rst_n) begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b0;
        end else if (wr_en && ~axi_bvalid) begin
            axi_bvalid <= 1'b1;
            axi_bresp  <= 2'b0;                 // OKAY
        end else if (S_AXI_BREADY && axi_bvalid) begin
            axi_bvalid <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (!rst_n)                              axi_arready <= 1'b0;
        else if (~axi_arready && S_AXI_ARVALID)  axi_arready <= 1'b1;
        else                                     axi_arready <= 1'b0;
    end

    // =========================================================================
    // レジスタの書き込み
    // =========================================================================
    reg        start_pulse;                 // cnn_core への開始パルス（1クロック）
    reg        clr_ptr, clr_done;
    reg [9:0]  img_ptr;                     // 0〜783
    reg [7:0]  img_wdata;
    reg        img_we;
    reg [3:0]  score_sel;

    always @(posedge clk) begin
        if (!rst_n) begin
            start_pulse <= 1'b0;
            clr_ptr     <= 1'b0;
            clr_done    <= 1'b0;
            img_we      <= 1'b0;
            score_sel   <= 4'd0;
        end else begin
            start_pulse <= 1'b0;            // どれも1クロックだけ立てる
            clr_ptr     <= 1'b0;
            clr_done    <= 1'b0;
            img_we      <= 1'b0;

            if (wr_en) begin
                case (axi_awaddr[7:4])
                4'h2: begin                 // 0x20 CTRL
                    start_pulse <= S_AXI_WDATA[0];
                    clr_ptr     <= S_AXI_WDATA[1];
                    clr_done    <= S_AXI_WDATA[2];
                end
                4'h3: begin                 // 0x30 IMG（画素を1つ）
                    img_wdata <= S_AXI_WDATA[7:0];
                    img_we    <= 1'b1;
                end
                4'h5: begin                 // 0x50 SEL（スコアの番号）
                    score_sel <= S_AXI_WDATA[3:0];
                end
                default: ;
                endcase
            end
        end
    end

    // ---- 画素ポインタ ----
    always @(posedge clk) begin
        if (!rst_n)        img_ptr <= 10'd0;
        else if (clr_ptr)  img_ptr <= 10'd0;
        else if (img_we)   img_ptr <= (img_ptr == 10'd783) ? 10'd0 : img_ptr + 10'd1;
    end

    // =========================================================================
    // cnn_core 本体
    // =========================================================================
    wire        busy, done;
    wire [3:0]  digit;
    wire signed [31:0] score_data;

    cnn_core u_cnn (
        .clk(clk), .rst_n(rst_n),
        .img_we(img_we), .img_addr(img_ptr), .img_data(img_wdata),
        .start(start_pulse), .busy(busy), .done(done),
        .digit(digit), .score_addr(score_sel), .score_data(score_data)
    );

    // done は1クロックしか立たないので、読まれるまで保持する
    reg done_latched;
    always @(posedge clk) begin
        if (!rst_n)        done_latched <= 1'b0;
        else if (done)     done_latched <= 1'b1;
        else if (clr_done) done_latched <= 1'b0;
    end

    // =========================================================================
    // レジスタの読み出し
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            axi_rvalid <= 1'b0;
            axi_rresp  <= 2'b0;
        end else if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
            axi_rvalid <= 1'b1;
            axi_rresp  <= 2'b0;             // OKAY
        end else if (axi_rvalid && S_AXI_RREADY) begin
            axi_rvalid <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            axi_rdata <= 32'b0;
        end else if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
            case (S_AXI_ARADDR[7:4])
            4'h0: axi_rdata <= 32'hC440_0001;                    // 0x00 ID（疎通確認）
            // 0x10 STATUS: [31:20]=0, [19:8]=画素ポインタ, [7:2]=0, bit1=終了, bit0=計算中
            4'h1: axi_rdata <= {12'b0, 2'b0, img_ptr, 6'b0, done_latched, busy};
            4'h4: axi_rdata <= {28'b0, digit};                   // 0x40 DIGIT
            4'h5: axi_rdata <= {28'b0, score_sel};               // 0x50 SEL（読み戻し）
            4'h6: axi_rdata <= score_data;                       // 0x60 SCORE
            default: axi_rdata <= 32'b0;
            endcase
        end
    end
endmodule
