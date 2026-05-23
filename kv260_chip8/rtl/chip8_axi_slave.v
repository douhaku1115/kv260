// ============================================================
// chip8_axi_slave.v — CHIP-8 AXI4-Lite スレーブ
// ============================================================
//
// PL 内部に 64x32 = 2048 ピクセルのフレームバッファを保持。
// 1 ピクセル = 1 ビット (モノクロ)。8 ピクセルを 1 バイトにまとめ
// MSB を左端ピクセルとする (CHIP-8 sprite と同じ規約)。
//
// メモリレイアウト:
//   - 32 行 × 8 バイト/行 = 256 バイト
//   - byte_pos = y * 8 + x_byte_idx
//   - AXI アドレス = byte_pos * 4 (各バイトに 4 バイトのアドレス空間)
//
// 【AXI レジスタマップ (ベースアドレス: 0xA0000000)】
//
//   0x000 - 0x3FC (フレームバッファ):
//     アドレス = (y * 8 + x_byte_idx) * 4
//     データ   = 8 ピクセル分のビット (MSB=左端, WDATA[7:0])
//
// rtl_top からの読み出しポート:
//   - read_x (6bit), read_y (5bit) → read_pixel (1bit)
//
// Tetris の教訓:
//   - packed register + keep 属性 (最適化回避)
//   - シンプルな unit_idx 比較 (bit pattern 判定回避)

module chip8_axi_slave #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 10   // 1KB 範囲 (256 byte × 4)
)(
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

    // ピクセル読み出しポート (rtl_top から)
    input  wire [5:0]                    read_x,    // 0〜63
    input  wire [4:0]                    read_y,    // 0〜31
    output wire                          read_pixel // 0 or 1
);

    reg                          axi_awready;
    reg                          axi_wready;
    reg [1:0]                    axi_bresp;
    reg                          axi_bvalid;
    reg                          axi_arready;
    reg [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;
    reg [1:0]                    axi_rresp;
    reg                          axi_rvalid;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    // フレームバッファ: 32 行 × 64 列 = 2048 ビット
    // バイト位置 i のバイトは fb[i*8 +: 8] にあり、MSB が左端ピクセル
    (* keep = "true" *) reg [2047:0] fb;

    integer i;
    initial begin
        fb = 2048'b0;
    end

    // --- AXI 書き込み ---
    reg aw_en;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_awready <= 1'b0;
            aw_en <= 1'b1;
        end else if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
            axi_awready <= 1'b1;
            aw_en <= 1'b0;
            axi_awaddr <= S_AXI_AWADDR;
        end else begin
            axi_awready <= 1'b0;
            if (S_AXI_BREADY && axi_bvalid)
                aw_en <= 1'b1;
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            axi_wready <= 1'b0;
        else if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en)
            axi_wready <= 1'b1;
        else
            axi_wready <= 1'b0;
    end

    wire wr_en = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;

    // unit_idx (= バイト位置 0〜255)
    wire [7:0] wr_unit = axi_awaddr[9:2];

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            fb <= 2048'b0;
        end else if (wr_en) begin
            // バイト書き込み (MSB が左端ピクセル)
            fb[wr_unit*8 +: 8] <= S_AXI_WDATA[7:0];
        end
    end

    // 書き込み応答
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_bvalid <= 1'b0;
            axi_bresp <= 2'b0;
        end else if (axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID) begin
            axi_bvalid <= 1'b1;
            axi_bresp <= 2'b0;
        end else if (S_AXI_BREADY && axi_bvalid) begin
            axi_bvalid <= 1'b0;
        end
    end

    // --- AXI 読み出し ---
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            axi_arready <= 1'b0;
        else if (~axi_arready && S_AXI_ARVALID)
            axi_arready <= 1'b1;
        else
            axi_arready <= 1'b0;
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_rvalid <= 1'b0;
            axi_rresp <= 2'b0;
        end else if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
            axi_rvalid <= 1'b1;
            axi_rresp <= 2'b0;
        end else if (axi_rvalid && S_AXI_RREADY) begin
            axi_rvalid <= 1'b0;
        end
    end

    wire [7:0] rd_unit = S_AXI_ARADDR[9:2];

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            axi_rdata <= 32'b0;
        else if (~axi_rvalid && S_AXI_ARVALID) begin
            axi_rdata <= {24'b0, fb[rd_unit*8 +: 8]};
        end
    end

    // --- rtl_top 向け非同期ピクセル読み出し ---
    // pixel (x, y): byte_pos = y*8 + (x/8), bit_in_byte = 7 - (x%8) (MSB が左端)
    wire [7:0] byte_pos = {read_y, 3'b0} + {5'b0, read_x[5:3]};  // y*8 + x[5:3]
    wire [2:0] bit_in_byte_msb = 3'd7 - read_x[2:0];
    assign read_pixel = fb[byte_pos*8 + bit_in_byte_msb];

endmodule
