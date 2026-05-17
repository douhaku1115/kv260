// ============================================================
// rect_axi_slave.v — Pong 用 AXI4-Lite スレーブ (Phase A2: 3 オブジェクト対応)
// ============================================================
//
// 左パドル・右パドル・ボールの 3 オブジェクトの位置を制御する。
// サイズと色は RTL 内固定 (Phase A2)。
//
// 【AXI レジスタマップ (ベースアドレス: 0xA0000000)】
//
//   オフセット | 名前    | 方向 | 内容
//   ----------+---------+------+----------------------
//   0x00      | PADL_X  | R/W  | 左パドル X 座標
//   0x04      | PADL_Y  | R/W  | 左パドル Y 座標
//   0x08      | PADR_X  | R/W  | 右パドル X 座標
//   0x0C      | PADR_Y  | R/W  | 右パドル Y 座標
//   0x10      | BALL_X  | R/W  | ボール X 座標
//   0x14      | BALL_Y  | R/W  | ボール Y 座標

module rect_axi_slave #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 5   // 8 レジスタ枠 = 32 バイト → 5 bit アドレス
)(
    // AXI4-Lite スレーブインターフェース
    input  wire                          S_AXI_ACLK,
    input  wire                          S_AXI_ARESETN,

    // 書き込みアドレス
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_AWADDR,
    input  wire [2:0]                    S_AXI_AWPROT,
    input  wire                          S_AXI_AWVALID,
    output wire                          S_AXI_AWREADY,

    // 書き込みデータ
    input  wire [C_S_AXI_DATA_WIDTH-1:0] S_AXI_WDATA,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] S_AXI_WSTRB,
    input  wire                          S_AXI_WVALID,
    output wire                          S_AXI_WREADY,

    // 書き込み応答
    output wire [1:0]                    S_AXI_BRESP,
    output wire                          S_AXI_BVALID,
    input  wire                          S_AXI_BREADY,

    // 読み出しアドレス
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_ARADDR,
    input  wire [2:0]                    S_AXI_ARPROT,
    input  wire                          S_AXI_ARVALID,
    output wire                          S_AXI_ARREADY,

    // 読み出しデータ
    output wire [C_S_AXI_DATA_WIDTH-1:0] S_AXI_RDATA,
    output wire [1:0]                    S_AXI_RRESP,
    output wire                          S_AXI_RVALID,
    input  wire                          S_AXI_RREADY,

    // オブジェクト位置出力 (AXI クロック領域)
    output wire [10:0]                   padl_x,
    output wire [10:0]                   padl_y,
    output wire [10:0]                   padr_x,
    output wire [10:0]                   padr_y,
    output wire [10:0]                   ball_x,
    output wire [10:0]                   ball_y
);

    // AXI ハンドシェイク信号
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

    // 内部レジスタ
    reg [10:0] reg_padl_x, reg_padl_y;
    reg [10:0] reg_padr_x, reg_padr_y;
    reg [10:0] reg_ball_x, reg_ball_y;

    assign padl_x = reg_padl_x;
    assign padl_y = reg_padl_y;
    assign padr_x = reg_padr_x;
    assign padr_y = reg_padr_y;
    assign ball_x = reg_ball_x;
    assign ball_y = reg_ball_y;

    // --- AXI4-Lite 書き込みロジック ---

    reg aw_en;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;

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

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            // Pong 初期配置
            reg_padl_x <= 11'd50;    // 左端から少し内側
            reg_padl_y <= 11'd310;   // 縦中央 (720/2 - 100/2 = 310)
            reg_padr_x <= 11'd1210;  // 右端から (1280 - 50 - 20 = 1210)
            reg_padr_y <= 11'd310;
            reg_ball_x <= 11'd630;   // 横中央 (1280/2 - 20/2 = 630)
            reg_ball_y <= 11'd350;   // 縦中央 (720/2 - 20/2 = 350)
        end else if (wr_en) begin
            case (axi_awaddr[4:2])
                3'd0: reg_padl_x <= S_AXI_WDATA[10:0];  // 0x00
                3'd1: reg_padl_y <= S_AXI_WDATA[10:0];  // 0x04
                3'd2: reg_padr_x <= S_AXI_WDATA[10:0];  // 0x08
                3'd3: reg_padr_y <= S_AXI_WDATA[10:0];  // 0x0C
                3'd4: reg_ball_x <= S_AXI_WDATA[10:0];  // 0x10
                3'd5: reg_ball_y <= S_AXI_WDATA[10:0];  // 0x14
                default: ;
            endcase
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

    // --- AXI4-Lite 読み出しロジック ---

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_arready <= 1'b0;
            axi_araddr <= 0;
        end else if (~axi_arready && S_AXI_ARVALID) begin
            axi_arready <= 1'b1;
            axi_araddr <= S_AXI_ARADDR;
        end else begin
            axi_arready <= 1'b0;
        end
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

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            axi_rdata <= 32'b0;
        else if (~axi_rvalid && S_AXI_ARVALID) begin
            case (S_AXI_ARADDR[4:2])
                3'd0: axi_rdata <= {21'b0, reg_padl_x};
                3'd1: axi_rdata <= {21'b0, reg_padl_y};
                3'd2: axi_rdata <= {21'b0, reg_padr_x};
                3'd3: axi_rdata <= {21'b0, reg_padr_y};
                3'd4: axi_rdata <= {21'b0, reg_ball_x};
                3'd5: axi_rdata <= {21'b0, reg_ball_y};
                default: axi_rdata <= 32'b0;
            endcase
        end
    end

endmodule
