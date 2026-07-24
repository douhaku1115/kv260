// -----------------------------------------------------------------------------
// audio_fifo.v -- 音声標本の緩衝記憶（FIFO）
//
//   PS(Linux)側が AXI 経由で書き込み、I2S送信側が1標本ごとに読み出す。
//   両側とも同じクロック(mclk)で動く同期FIFO。
//
//   書き込み: wr_en=1 で wr_data を1つ積む（満杯なら捨てる）
//   読み出し: rd_en=1 で1つ取り出す（空なら 0 を返し、無音になる）
//
//   段数は 2 のべき乗にして、上位ビットで満杯/空を判定する。
// -----------------------------------------------------------------------------
module audio_fifo #(
    parameter integer DW    = 16,           // 標本のビット幅
    parameter integer DEPTH = 8192,         // 段数（2のべき乗）
    parameter integer AW    = 13            // log2(DEPTH)
)(
    input  wire           clk,
    input  wire           rst_n,

    // 書き込み側（PS から）
    input  wire           wr_en,
    input  wire [DW-1:0]  wr_data,

    // 読み出し側（I2S送信へ）
    input  wire           rd_en,
    output wire [DW-1:0]  rd_data,

    // 状態（PS が読んで空き具合を知る）
    output wire           full,
    output wire           empty,
    output wire [AW:0]    count             // 現在溜まっている数（0〜DEPTH）
);
    reg [DW-1:0] mem [0:DEPTH-1];

    // 書き込み・読み出し位置。1ビット余分に持ち、最上位で周回を区別する
    reg [AW:0] wr_ptr;
    reg [AW:0] rd_ptr;

    // 満杯: 位置の下位が一致し、最上位（周回）が違う
    assign full  = (wr_ptr[AW-1:0] == rd_ptr[AW-1:0]) && (wr_ptr[AW] != rd_ptr[AW]);
    assign empty = (wr_ptr == rd_ptr);
    assign count = wr_ptr - rd_ptr;

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    // ---- 書き込み ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      wr_ptr <= {(AW+1){1'b0}};
        else if (do_wr)  wr_ptr <= wr_ptr + 1'b1;
    end

    always @(posedge clk)
        if (do_wr) mem[wr_ptr[AW-1:0]] <= wr_data;

    // ---- 読み出し ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      rd_ptr <= {(AW+1){1'b0}};
        else if (do_rd)  rd_ptr <= rd_ptr + 1'b1;
    end

    // 空のときは無音（0）を返す。データが枯れても雑音にならない
    assign rd_data = empty ? {DW{1'b0}} : mem[rd_ptr[AW-1:0]];

endmodule
