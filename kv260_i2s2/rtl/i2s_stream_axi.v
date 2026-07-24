// -----------------------------------------------------------------------------
// i2s_stream_axi.v -- 段5: 長時間再生（PS から流し込む方式）
//
//   PS(Linux)が音声標本を AXI4-Lite 経由で FIFO に書き込み、
//   PL が 1標本ごとに取り出して I2S で送出する。
//   内蔵メモリの容量制限が無くなり、曲を丸ごと再生できる。
//
//   ★クロックは mclk(12.5MHz)の1つだけ。AXI もこのクロックで動かす。
//     異なるクロック間の受け渡しを無くし、取りこぼしを防ぐため。
//     AXI4-Lite は 12.5MHz でも毎秒100万回以上書けるので、
//     必要な 48828標本/秒 に対して十分な余裕がある。
//
//   fs = 12.5MHz / 256 = 48828.125 Hz
//
// 【レジスタマップ（ベースアドレス 0xA000_0000）】
//   0x00 [W]  DATA   - 標本を1つ書き込む（下位16ビット、符号付き）
//   0x04 [R]  STATUS - bit0:満杯 bit1:空 bit29..16:溜まっている数
//   0x08 [RW] CTRL   - bit0:再生有効（0で無音）
//
// 【PS 側の手順】
//   1. CTRL に 1 を書いて再生開始
//   2. STATUS を読み、満杯でなければ DATA に標本を書く、を繰り返す
//   3. 曲の終わりで CTRL に 0 を書く
// -----------------------------------------------------------------------------
// ※ レジスタは 0x10 刻みに配置する。0x10 境界に整列していないアドレスは
//    devmem/mmap での読み出しが 0 を返す(Zynq US+ の既知問題)。
//    実機で 0x00=0xDEADBEEF が返り 0x04/0x08 が 0 だったことで確認済み。
//    アドレス幅は 0x00〜0x3F を覆う 6 ビット。
module i2s_stream_axi #(
    parameter integer DW         = 16,      // 標本のビット幅
    parameter integer FIFO_DEPTH = 8192,    // FIFO段数（約0.17秒分）
    parameter integer FIFO_AW    = 13,      // log2(FIFO_DEPTH)
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 6
)(
    // ---- AXI4-Lite スレーブ（クロックは mclk と同一） ----
    input  wire                          S_AXI_ACLK,
    input  wire                          S_AXI_ARESETN,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_AWADDR,
    input  wire [2:0]                    S_AXI_AWPROT,
    input  wire                          S_AXI_AWVALID,
    output wire                          S_AXI_AWREADY,

    input  wire [C_S_AXI_DATA_WIDTH-1:0] S_AXI_WDATA,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] S_AXI_WSTRB,
    input  wire                          S_AXI_WVALID,
    output wire                          S_AXI_WREADY,

    output wire [1:0]                    S_AXI_BRESP,
    output wire                          S_AXI_BVALID,
    input  wire                          S_AXI_BREADY,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_ARADDR,
    input  wire [2:0]                    S_AXI_ARPROT,
    input  wire                          S_AXI_ARVALID,
    output wire                          S_AXI_ARREADY,

    output wire [C_S_AXI_DATA_WIDTH-1:0] S_AXI_RDATA,
    output wire [1:0]                    S_AXI_RRESP,
    output wire                          S_AXI_RVALID,
    input  wire                          S_AXI_RREADY,

    // ---- I2S 出力（Pmod I2S2 へ） ----
    output wire mclk_o,
    output reg  sclk,
    output reg  lrck,
    output reg  sdout
);
    // クロックとリセットは AXI と共通（単一クロック構成）
    wire clk   = S_AXI_ACLK;
    wire rst_n = S_AXI_ARESETN;

    // =========================================================================
    // AXI4-Lite スレーブ
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

    // ---- レジスタ書き込み ----
    reg          reg_play;                  // 0x08 CTRL bit0: 再生有効
    reg          fifo_wr;                   // FIFOへの書き込み（1クロックだけ1）
    reg [DW-1:0] fifo_wr_data;

    always @(posedge clk) begin
        if (!rst_n) begin
            reg_play     <= 1'b0;
            fifo_wr      <= 1'b0;
            fifo_wr_data <= {DW{1'b0}};
        end else begin
            fifo_wr <= 1'b0;                // 既定は書かない
            if (wr_en) begin
                case (axi_awaddr[5:4])
                    2'd0: begin             // 0x00 DATA
                        fifo_wr_data <= S_AXI_WDATA[DW-1:0];
                        fifo_wr      <= 1'b1;
                    end
                    2'd2: reg_play <= S_AXI_WDATA[0];   // 0x20 CTRL
                    default: ;
                endcase
            end
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b0;
        end else if (axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID) begin
            axi_bvalid <= 1'b1;
            axi_bresp  <= 2'b0;
        end else if (S_AXI_BREADY && axi_bvalid) begin
            axi_bvalid <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (!rst_n)                             axi_arready <= 1'b0;
        else if (~axi_arready && S_AXI_ARVALID) axi_arready <= 1'b1;
        else                                    axi_arready <= 1'b0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            axi_rvalid <= 1'b0;
            axi_rresp  <= 2'b0;
        end else if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
            axi_rvalid <= 1'b1;
            axi_rresp  <= 2'b0;
        end else if (axi_rvalid && S_AXI_RREADY) begin
            axi_rvalid <= 1'b0;
        end
    end

    // ---- レジスタ読み出し ----
    wire             fifo_full, fifo_empty;
    wire [FIFO_AW:0] fifo_count;            // 0〜DEPTH（14ビット）

    always @(posedge clk) begin
        if (!rst_n)
            axi_rdata <= 32'b0;
        else if (~axi_rvalid && S_AXI_ARVALID) begin
            case (S_AXI_ARADDR[5:4])
                // 0x00: 動作確認用の固定値(整列アドレス)。0xDEADBEEF が返れば AXI 正常。
                2'd0: axi_rdata <= 32'hDEADBEEF;
                // 0x10 STATUS: bit29..16=溜まっている数, bit1=空, bit0=満杯
                2'd1: axi_rdata <= {2'b0, fifo_count, 14'b0, fifo_empty, fifo_full};
                // 0x20 CTRL
                2'd2: axi_rdata <= {31'b0, reg_play};
                default: axi_rdata <= 32'b0;
            endcase
        end
    end

    // =========================================================================
    // FIFO（書き込み・読み出しとも同じクロック）
    // =========================================================================
    wire sample_tick;
    wire signed [DW-1:0] fifo_out;

    audio_fifo #(.DW(DW), .DEPTH(FIFO_DEPTH), .AW(FIFO_AW)) u_fifo (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (fifo_wr),
        .wr_data (fifo_wr_data),
        .rd_en   (sample_tick & reg_play),
        .rd_data (fifo_out),
        .full    (fifo_full),
        .empty   (fifo_empty),
        .count   (fifo_count)
    );

    // =========================================================================
    // I2S 送信（段1〜4と同一。音源が FIFO になっただけ）
    // =========================================================================
    reg [7:0] c;
    always @(posedge clk)
        if (!rst_n) c <= 8'd0;
        else        c <= c + 8'd1;

    assign sample_tick = (c == 8'hFF);      // 1標本ごとに1回
    wire [5:0] bi = c[7:2];
    wire [4:0] cb = bi[4:0];

    reg signed [DW-1:0] sample;
    always @(posedge clk)
        if (!rst_n)           sample <= {DW{1'b0}};
        else if (sample_tick) sample <= reg_play ? fifo_out : {DW{1'b0}};

    reg sd;
    always @(*) begin
        if (cb >= 5'd1 && cb <= DW[4:0]) sd = sample[DW-1 - (cb - 5'd1)];
        else                             sd = 1'b0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            sclk  <= 1'b0;
            lrck  <= 1'b0;
            sdout <= 1'b0;
        end else begin
            sclk  <= c[1];                  // mclk/4
            lrck  <= c[7];                  // mclk/256
            sdout <= sd;
        end
    end

    ODDRE1 #(.SRVAL(1'b0)) u_mclk_oddr (
        .Q(mclk_o), .C(clk), .D1(1'b1), .D2(1'b0), .SR(1'b0)
    );
endmodule
