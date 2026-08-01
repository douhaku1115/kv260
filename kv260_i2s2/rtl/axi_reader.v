// -----------------------------------------------------------------------------
// axi_reader.v -- 自作 AXI4 読み出しマスタ（PS の DDR を PL が自分で読む）
//
//   段11 の中核。これまで(段5〜10)は PS が AXI4-Lite で 1 標本ずつ書き込んでいた
//   （CPU が働き続ける）。ここでは逆に、PL が主人になって PS の DDR を直接読む。
//   PS は「どこから何バイト読むか」を教えるだけで、あとは PL が自分で取りに行く。
//
//   【AXI4 読み出しの流れ】
//     1. AR チャネル: 「このアドレスから N 個読みたい」と要求を出す
//     2. R チャネル : データが順に返ってくる。最後のデータには RLAST=1 が付く
//     これを 1 回の要求でまとめて連続転送する = バースト転送。1 標本ごとに
//     やり取りする AXI4-Lite より遥かに効率が良い。
//
//   【バースト長】
//     AXI4 は 1 バースト最大 256 転送。ここでは 1 転送 = 64bit(8バイト) とし、
//     16 転送 = 128 バイト を 1 バーストとする。
//
//   【使い方】
//     start=1 で開始。base_addr から total_len バイトを順に読み、
//     読めたデータを out_valid/out_data で 1 転送ずつ吐き出す。
//     全部読み終えると done=1。out_ready で受け側の都合に合わせて待つ。
// -----------------------------------------------------------------------------
module axi_reader #(
    parameter integer DW    = 64,       // データ幅（HP ポートは 64/128 が使える）
    parameter integer BURST = 16        // 1 バーストの転送数（16×8B = 128B）
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---- 制御（PS からレジスタ経由で指示される）----
    input  wire        start,           // 1 クロックのパルスで開始
    input  wire [31:0] base_addr,       // 読み出し開始アドレス（DDR 物理アドレス）
    input  wire [31:0] total_len,       // 読み出す長さ（バイト）
    output reg         busy,            // 転送中
    output reg         done,            // 全部読み終えた
    output reg  [31:0] read_cnt,        // これまでに読んだバイト数（確認用）

    // ---- 読み出したデータの出口 ----
    output wire        out_valid,
    output wire [DW-1:0] out_data,
    input  wire        out_ready,

    // ---- AXI4 マスタ（読み出しのみ。書き込みチャネルは使わない）----
    output reg  [31:0] M_AXI_ARADDR,
    output reg  [7:0]  M_AXI_ARLEN,     // バースト長 - 1
    output wire [2:0]  M_AXI_ARSIZE,    // 1 転送のバイト数（log2）
    output wire [1:0]  M_AXI_ARBURST,   // 01 = INCR（アドレスを増やしながら）
    output wire [3:0]  M_AXI_ARCACHE,
    output wire [2:0]  M_AXI_ARPROT,
    output reg         M_AXI_ARVALID,
    input  wire        M_AXI_ARREADY,

    input  wire [DW-1:0] M_AXI_RDATA,
    input  wire [1:0]  M_AXI_RRESP,
    input  wire        M_AXI_RLAST,
    input  wire        M_AXI_RVALID,
    output wire        M_AXI_RREADY
);
    localparam integer BYTES = DW / 8;              // 1 転送のバイト数（8）
    localparam [2:0]   SIZE  = (DW == 64) ? 3'd3 : 3'd4;  // 8B=3, 16B=4

    assign M_AXI_ARSIZE  = SIZE;
    assign M_AXI_ARBURST = 2'b01;                   // INCR
    assign M_AXI_ARCACHE = 4'b0011;                 // キャッシュ可（HP 経由の標準的な設定）
    assign M_AXI_ARPROT  = 3'b000;

    // 読んだデータはそのまま出口へ流す
    assign out_valid    = M_AXI_RVALID;
    assign out_data     = M_AXI_RDATA;
    assign M_AXI_RREADY = out_ready;

    // ---- 状態機械 ----
    localparam IDLE = 2'd0, ADDR = 2'd1, DATA = 2'd2, FIN = 2'd3;
    reg [1:0]  st;
    reg [31:0] cur_addr;                            // 次に要求するアドレス
    reg [31:0] remain;                              // 残りバイト数

    // 今回のバーストで読む転送数（残りが少なければ切り詰める）
    wire [31:0] remain_beats = remain / BYTES;
    wire [8:0]  this_beats   = (remain_beats >= BURST) ? BURST[8:0] : remain_beats[8:0];

    always @(posedge clk) begin
        if (!rst_n) begin
            st            <= IDLE;
            busy          <= 1'b0;
            done          <= 1'b0;
            read_cnt      <= 32'd0;
            M_AXI_ARVALID <= 1'b0;
        end else begin
            case (st)
                IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        cur_addr <= base_addr;
                        remain   <= total_len;
                        read_cnt <= 32'd0;
                        done     <= 1'b0;
                        busy     <= 1'b1;
                        st       <= ADDR;
                    end
                end

                ADDR: begin
                    if (remain == 32'd0) begin
                        st <= FIN;
                    end else if (!M_AXI_ARVALID) begin
                        // 読み出し要求を出す
                        M_AXI_ARADDR  <= cur_addr;
                        M_AXI_ARLEN   <= this_beats[7:0] - 8'd1;   // AXI は「長さ-1」
                        M_AXI_ARVALID <= 1'b1;
                    end else if (M_AXI_ARREADY) begin
                        // 受理されたのでデータ待ちへ
                        M_AXI_ARVALID <= 1'b0;
                        st            <= DATA;
                    end
                end

                DATA: begin
                    if (M_AXI_RVALID && out_ready) begin
                        read_cnt <= read_cnt + BYTES;
                        cur_addr <= cur_addr + BYTES;
                        remain   <= remain - BYTES;
                        if (M_AXI_RLAST) st <= ADDR;   // このバースト終わり → 次へ
                    end
                end

                FIN: begin
                    done <= 1'b1;
                    busy <= 1'b0;
                    st   <= IDLE;
                end

                default: st <= IDLE;
            endcase
        end
    end
endmodule
