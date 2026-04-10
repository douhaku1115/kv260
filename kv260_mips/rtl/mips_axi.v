// AXI4-Lite スレーブラッパー
//
// PS(ARM) と MIPS コアを AXI4-Lite バスで接続する
// PS 側から以下の操作が可能:
//   - MIPS の reset/run/halt/single_step 制御
//   - 命令メモリへのプログラム書き込み
//   - PC・レジスタ値の読み出し (デバッグ)
//
// レジスタマップ (ベースアドレス: 0xA000_0000):
//   0x00 [R/W] CTRL       - bit0: reset, bit1: run, bit2: single_step
//   0x04 [R]   PC         - 現在のプログラムカウンタ値
//   0x08 [R/W] DBG_ADDR   - 読み出し対象レジスタ番号 (0-31)
//   0x0C [R]   DBG_DATA   - 指定レジスタの値
//   0x10 [W]   IMEM_ADDR  - 命令メモリ書き込みアドレス
//   0x14 [W]   IMEM_DATA  - 命令メモリ書き込みデータ (書き込み時に格納実行)

module mips_axi #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 5   // 6レジスタ = 24バイト → 5bitアドレス
)(
    // AXI4-Lite スレーブインターフェース
    input  wire                          S_AXI_ACLK,
    input  wire                          S_AXI_ARESETN,

    // 書き込みアドレスチャネル
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_AWADDR,
    input  wire [2:0]                    S_AXI_AWPROT,
    input  wire                          S_AXI_AWVALID,
    output wire                          S_AXI_AWREADY,

    // 書き込みデータチャネル
    input  wire [C_S_AXI_DATA_WIDTH-1:0] S_AXI_WDATA,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] S_AXI_WSTRB,
    input  wire                          S_AXI_WVALID,
    output wire                          S_AXI_WREADY,

    // 書き込み応答チャネル
    output wire [1:0]                    S_AXI_BRESP,
    output wire                          S_AXI_BVALID,
    input  wire                          S_AXI_BREADY,

    // 読み出しアドレスチャネル
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] S_AXI_ARADDR,
    input  wire [2:0]                    S_AXI_ARPROT,
    input  wire                          S_AXI_ARVALID,
    output wire                          S_AXI_ARREADY,

    // 読み出しデータチャネル
    output wire [C_S_AXI_DATA_WIDTH-1:0] S_AXI_RDATA,
    output wire [1:0]                    S_AXI_RRESP,
    output wire                          S_AXI_RVALID,
    input  wire                          S_AXI_RREADY
);

    // AXI4-Lite信号
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
    // 0x00: ctrl  [bit0=reset, bit1=run, bit2=single_step]
    // 0x04: pc    (読み出し専用)
    // 0x08: dbg_reg_addr
    // 0x0C: dbg_reg_data (読み出し専用)
    // 0x10: imem_waddr
    // 0x14: imem_wdata (書き込み時にimem_weをアサート)
    reg [31:0] reg_ctrl;
    reg [4:0]  reg_dbg_addr;
    reg [7:0]  reg_imem_waddr;

    // MIPS制御信号
    wire mips_reset = reg_ctrl[0];
    wire mips_run   = reg_ctrl[1];
    wire mips_step  = reg_ctrl[2];

    // single_step ワンショット
    reg step_prev;
    wire step_pulse = mips_step & ~step_prev;
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            step_prev <= 1'b0;
        else
            step_prev <= mips_step;
    end

    wire halt = ~(mips_run | step_pulse);

    // 命令メモリ書き込み
    reg imem_we;
    reg [31:0] imem_wdata;

    // MIPS コア
    wire [31:0] mips_pc;
    wire [31:0] mips_dbg_reg_data;

    mips_top mips (
        .clk(S_AXI_ACLK),
        .reset(mips_reset),
        .halt(halt),
        .imem_we(imem_we),
        .imem_waddr(reg_imem_waddr),
        .imem_wdata(imem_wdata),
        .pc(mips_pc),
        .dbg_reg_addr(reg_dbg_addr),
        .dbg_reg_data(mips_dbg_reg_data)
    );

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
            reg_ctrl <= 32'h1; // 初期状態: reset=1
            reg_dbg_addr <= 5'b0;
            reg_imem_waddr <= 8'b0;
            imem_we <= 1'b0;
            imem_wdata <= 32'b0;
        end else begin
            imem_we <= 1'b0; // デフォルト: 書き込み無効

            if (wr_en) begin
                case (axi_awaddr[4:2])
                    3'd0: reg_ctrl <= S_AXI_WDATA;           // 0x00
                    3'd2: reg_dbg_addr <= S_AXI_WDATA[4:0];  // 0x08
                    3'd4: reg_imem_waddr <= S_AXI_WDATA[7:0]; // 0x10
                    3'd5: begin                                // 0x14
                        imem_wdata <= S_AXI_WDATA;
                        imem_we <= 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end

    // 書き込み応答
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_bvalid <= 1'b0;
            axi_bresp <= 2'b0;
        end else if (axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID) begin
            axi_bvalid <= 1'b1;
            axi_bresp <= 2'b0; // OKAY
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
            axi_rresp <= 2'b0; // OKAY
        end else if (axi_rvalid && S_AXI_RREADY) begin
            axi_rvalid <= 1'b0;
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            axi_rdata <= 32'b0;
        else if (~axi_rvalid && S_AXI_ARVALID) begin
            case (S_AXI_ARADDR[4:2])
                3'd0: axi_rdata <= reg_ctrl;
                3'd1: axi_rdata <= mips_pc;
                3'd2: axi_rdata <= {27'b0, reg_dbg_addr};
                3'd3: axi_rdata <= mips_dbg_reg_data;
                3'd4: axi_rdata <= {24'b0, reg_imem_waddr};
                default: axi_rdata <= 32'b0;
            endcase
        end
    end

endmodule
