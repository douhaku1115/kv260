// -----------------------------------------------------------------------------
// fc.v -- 全結合層 400 → 10 と argmax（どの数字か）
//
//   段13 の最終段。pool2 の出力 16ch x 5 x 5 = 400 個（uint8）を受け、
//   10 個のスコア（int32）を出し、いちばん大きいものの番号を答えとする。
//
//   【シフトが 0 なわけ】
//     ここは最終層なので、欲しいのは 10 個のスコアの大小関係だけ。
//     絶対値には意味がないから、次の層に合わせるスケール調整が要らない。
//     積和の int32 をそのまま出す（cnn_param.vh の FC_SHIFT = 0）。
//     無理にスケールを合わせて右シフトすると、スコアが全部 0 に潰れて壊れる。
//     おかげで RTL 側もシフト回路が不要になっている。
//
//   【方式】conv3x3.v と同じ。積和器1個を時分割で使い回す。
//     総クロック数 10 x 400 = 4,000。畳み込みに比べれば一瞬。
//
//   【argmax の同点処理】
//     Python の numpy.argmax は「最初に出てきた最大値」を返す。
//     RTL も同じにするため、更新条件は > （>= ではない）にしてある。
//     ここを >= にすると同点のとき答えが変わる。
//
//   【出力】
//     score_addr でスコア10個を後から読める（デバッグと PS への受け渡し用）。
//     digit が答え（0〜9）。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module fc #(
    parameter integer NIN   = 400,      // 入力の数（16ch x 5 x 5）
    parameter integer NOUT  = 10,       // 出力の数（数字 0〜9）
    parameter integer SHIFT = 0,        // FC_SHIFT
    parameter         WFILE = "fc_w.hex",      // 重み     int8  [out][in]
    parameter         BFILE = "fc_b.hex"       // バイアス int32 [out]
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output reg         busy,
    output reg         done,

    // ---- 入力（pool2 の出力。同期読み出し, 1クロック遅れ）----
    output wire [15:0] x_addr,
    input  wire [7:0]  x_data,

    // ---- 結果 ----
    output reg  [3:0]         digit,    // いちばんスコアが高い数字
    input  wire [3:0]         score_addr,
    output wire signed [31:0] score_data
);
    function integer clog2(input integer v);
        integer i;
        begin
            clog2 = 1;
            for (i = 1; i < v; i = i * 2) clog2 = clog2 + 1;
        end
    endfunction

    localparam integer WLEN = NOUT * NIN;

    reg signed [7:0]  wmem [0:WLEN-1];
    reg signed [31:0] bmem [0:NOUT-1];
    initial begin
        $readmemh(WFILE, wmem);
        $readmemh(BFILE, bmem);
    end

    // ---- 求めたスコアの置き場 ----
    reg signed [31:0] smem [0:NOUT-1];
    assign score_data = smem[score_addr];

    // ---- カウンタ（アドレス生成段）----
    reg [clog2(NIN)-1:0]  ii;           // 入力の番号 0..NIN-1
    reg [clog2(NOUT)-1:0] oo;           // 出力の番号 0..NOUT-1

    wire first = (ii == 0);
    wire last  = (ii == NIN - 1);

    assign x_addr = ii;
    wire [15:0] w_addr = oo * NIN + ii;

    reg signed [7:0]  w_q;
    reg signed [31:0] b_q;
    always @(posedge clk) begin
        w_q <= wmem[w_addr];
        b_q <= bmem[oo];
    end

    // ---- 演算段へ渡す制御（1クロック遅らせる）----
    reg                   v_valid, v_first, v_last;
    reg [clog2(NOUT)-1:0] v_oo;

    reg  signed [31:0] acc;
    wire signed [31:0] prod = $signed({1'b0, x_data}) * w_q;
    wire signed [31:0] sum  = (v_first ? b_q : acc) + prod;
    wire signed [31:0] outv = sum >>> SHIFT;

    // ---- argmax（最初に出た最大値を採る）----
    reg signed [31:0] best;
    reg               have_best;

    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_DRAIN = 2'd2;
    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            v_valid   <= 1'b0;
            ii <= 0; oo <= 0;
            acc       <= 0;
            best      <= 0;
            have_best <= 1'b0;
            digit     <= 4'd0;
        end else begin
            done <= 1'b0;

            // ---- 演算段（アドレス段の1クロック後）----
            if (v_valid) begin
                acc <= sum;
                if (v_last) begin
                    smem[v_oo] <= outv;
                    if (!have_best || (outv > best)) begin   // 同点は先勝ち
                        best      <= outv;
                        have_best <= 1'b1;
                        digit     <= v_oo;
                    end
                end
            end

            case (state)
            S_IDLE: begin
                v_valid <= 1'b0;
                if (start) begin
                    ii <= 0; oo <= 0;
                    have_best <= 1'b0;
                    busy      <= 1'b1;
                    state     <= S_RUN;
                end
            end

            S_RUN: begin
                v_valid <= 1'b1;
                v_first <= first;
                v_last  <= last;
                v_oo    <= oo;

                if (ii != NIN - 1) begin
                    ii <= ii + 1'b1;
                end else begin
                    ii <= 0;
                    if (oo != NOUT - 1) begin
                        oo <= oo + 1'b1;
                    end else begin
                        state <= S_DRAIN;
                    end
                end
            end

            // 最後の積和がまだパイプラインに残っている。
            // このサイクルで演算段が smem と argmax を更新する。
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
