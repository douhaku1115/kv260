// ============================================================
// nes_axi_slave.v — NES AXI4-Lite スレーブ (汎用バスへの変換だけ)
// ============================================================
//
// AXI4-Lite を単純なバスに変換して rtl_top へ渡す。
// レジスタやメモリの中身は rtl_top 側が持つ。
//
//   書込: bus_wr_en が 1 クロック立つ。そのとき bus_wr_addr / bus_wr_data が有効
//   読出: bus_rd_addr を出してから RD_WAIT クロック後の bus_rd_data を返す
//         (rtl_top は BRAM を読むので 1〜2 クロックの遅れを許す)
//
// アドレスはバイト単位 (18 bit = 256KB)。マップは rtl_top.v の冒頭を参照。

module nes_axi_slave #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 18,
    parameter RD_WAIT            = 3
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

    // rtl_top へのバス
    output wire                          bus_wr_en,
    output wire [C_S_AXI_ADDR_WIDTH-1:0] bus_wr_addr,
    output wire [31:0]                   bus_wr_data,
    output wire [C_S_AXI_ADDR_WIDTH-1:0] bus_rd_addr,
    input  wire [31:0]                   bus_rd_data
);

    reg                          axi_awready;
    reg                          axi_wready;
    reg                          axi_bvalid;
    reg                          axi_arready;
    reg [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;
    reg                          axi_rvalid;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = 2'b00;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = 2'b00;
    assign S_AXI_RVALID  = axi_rvalid;

    // --- 書込 (CHIP-8 と同じ握手) ---
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

    assign bus_wr_en   = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;
    assign bus_wr_addr = axi_awaddr;
    assign bus_wr_data = S_AXI_WDATA;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            axi_bvalid <= 1'b0;
        else if (bus_wr_en && ~axi_bvalid)
            axi_bvalid <= 1'b1;
        else if (S_AXI_BREADY && axi_bvalid)
            axi_bvalid <= 1'b0;
    end

    // --- 読出: アドレスを保持して RD_WAIT クロック待ってから取り込む ---
    reg [C_S_AXI_ADDR_WIDTH-1:0] rd_addr;
    reg [3:0]                    rd_cnt;    // 0 = 待ち無し
    assign bus_rd_addr = rd_addr;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_arready <= 1'b0;
            axi_rvalid  <= 1'b0;
            axi_rdata   <= 32'd0;
            rd_addr     <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            rd_cnt      <= 4'd0;
        end else begin
            axi_arready <= 1'b0;
            if (~axi_arready && S_AXI_ARVALID && ~axi_rvalid && rd_cnt == 4'd0) begin
                axi_arready <= 1'b1;
                rd_addr     <= S_AXI_ARADDR;
                rd_cnt      <= RD_WAIT;
            end else if (rd_cnt != 4'd0) begin
                rd_cnt <= rd_cnt - 4'd1;
                if (rd_cnt == 4'd1) begin
                    axi_rdata  <= bus_rd_data;
                    axi_rvalid <= 1'b1;
                end
            end else if (axi_rvalid && S_AXI_RREADY) begin
                axi_rvalid <= 1'b0;
            end
        end
    end

endmodule
