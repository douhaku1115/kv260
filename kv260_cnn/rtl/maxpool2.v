// -----------------------------------------------------------------------------
// maxpool2.v -- 2x2 最大値プーリング（重なりなし、ストライド2）
//
//   段13。conv1 の後（8ch 26x26 → 13x13）と conv2 の後（16ch 11x11 → 5x5）で使う。
//
//   【端数の扱い】入力の一辺が奇数のときは余りを捨てる。
//     11 → 5（最後の1行1列は使わない）。PyTorch の max_pool2d と同じで、
//     Python 版も x[:, :h2*2, :w2*2] と切り捨てている。ここがずれると
//     conv2 の入力が丸ごと1画素分ずれるので、切り捨ての向きを合わせること。
//
//   【方式】conv3x3.v と同じ作り。1クロックに1画素ずつ読み、4回で1出力。
//     総クロック数は pool1 が 8×13×13×4 = 5,408、pool2 が 16×5×5×4 = 1,600。
//     畳み込みに比べれば無視できる。
//
//   【パイプライン】BRAM の読み出しは1クロック遅れ。
//     サイクル n でアドレスを出し、n+1 で返ってきた値を最大値と比べる。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module maxpool2 #(
    parameter integer CH    = 8,        // チャネル数（入出力で同じ）
    parameter integer ISIZE = 26        // 入力の一辺
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,           // 1クロックのパルスで開始
    output reg         busy,
    output reg         done,            // 終了時に1クロックだけ1

    // ---- 入力特徴マップの読み出し（同期読み出し, 1クロック遅れ）----
    output wire [15:0] x_addr,
    input  wire [7:0]  x_data,

    // ---- 出力特徴マップの書き込み ----
    output reg         y_we,
    output reg [15:0]  y_addr,
    output reg [7:0]   y_data
);
    function integer clog2(input integer v);
        integer i;
        begin
            clog2 = 1;
            for (i = 1; i < v; i = i * 2) clog2 = clog2 + 1;
        end
    endfunction

    localparam integer OSIZE = ISIZE / 2;      // 端数は切り捨て

    // ---- カウンタ（アドレス生成段）----
    reg [1:0] k;                               // 2x2 の位置 0..3
    reg [clog2(OSIZE)-1:0] ox, oy;
    reg [clog2(CH)-1:0]    ch;

    wire dy = k[1];                            // k = {dy, dx}
    wire dx = k[0];
    wire first = (k == 2'd0);
    wire last  = (k == 2'd3);

    assign x_addr = ch * (ISIZE * ISIZE) + (oy * 2 + dy) * ISIZE + (ox * 2 + dx);

    // ---- 演算段へ渡す制御（1クロック遅らせる）----
    reg                    v_valid, v_first, v_last;
    reg [clog2(OSIZE)-1:0] v_ox, v_oy;
    reg [clog2(CH)-1:0]    v_ch;

    reg  [7:0] mx;
    wire [7:0] cur = v_first ? x_data : ((x_data > mx) ? x_data : mx);

    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_DRAIN = 2'd2;
    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            busy    <= 1'b0;
            done    <= 1'b0;
            y_we    <= 1'b0;
            v_valid <= 1'b0;
            k <= 0; ox <= 0; oy <= 0; ch <= 0;
            mx <= 8'd0;
        end else begin
            done <= 1'b0;
            y_we <= 1'b0;

            // ---- 演算段（アドレス段の1クロック後）----
            if (v_valid) begin
                mx <= cur;
                if (v_last) begin
                    y_we   <= 1'b1;
                    y_addr <= v_ch * (OSIZE * OSIZE) + v_oy * OSIZE + v_ox;
                    y_data <= cur;
                end
            end

            case (state)
            S_IDLE: begin
                v_valid <= 1'b0;
                if (start) begin
                    k <= 0; ox <= 0; oy <= 0; ch <= 0;
                    busy  <= 1'b1;
                    state <= S_RUN;
                end
            end

            S_RUN: begin
                v_valid <= 1'b1;
                v_first <= first;
                v_last  <= last;
                v_ox    <= ox;
                v_oy    <= oy;
                v_ch    <= ch;

                if (k != 2'd3) begin
                    k <= k + 2'd1;
                end else begin
                    k <= 2'd0;
                    if (ox != OSIZE - 1) begin
                        ox <= ox + 1'b1;
                    end else begin
                        ox <= 0;
                        if (oy != OSIZE - 1) begin
                            oy <= oy + 1'b1;
                        end else begin
                            oy <= 0;
                            if (ch != CH - 1) begin
                                ch <= ch + 1'b1;
                            end else begin
                                state <= S_DRAIN;
                            end
                        end
                    end
                end
            end

            // 最後のアドレスの結果がまだパイプラインに残っている。
            // このサイクルで演算段が書き込む。done も同時に上げる。
            S_DRAIN: begin
                v_valid <= 1'b0;
                busy    <= 1'b0;
                done    <= 1'b1;
                state   <= S_IDLE;
            end
            endcase
        end
    end
endmodule
