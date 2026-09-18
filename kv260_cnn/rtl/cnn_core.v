// -----------------------------------------------------------------------------
// cnn_core.v -- MNIST 手書き数字認識 CNN の本体（段13 段階B の総仕上げ）
//
//   28x28 の画像を1枚受け取り、0〜9 のどれかを答える。
//
//     入力 28x28x1
//      → conv1 3x3 1ch→8ch  + ReLU → 26x26x8
//      → maxpool 2x2               → 13x13x8
//      → conv2 3x3 8ch→16ch + ReLU → 11x11x16
//      → maxpool 2x2               → 5x5x16
//      → 全結合 400→10 → argmax
//
//   【バッファは2枚で足りる】
//     大きいほう buf_a（5408語）と小さいほう buf_b（1352語）を交互に使う。
//       conv1: buf_img → buf_a      (5408語)
//       pool1: buf_a   → buf_b      (1352語)
//       conv2: buf_b   → buf_a      (1936語。buf_a に収まる)
//       pool2: buf_a   → buf_b      ( 400語)
//       fc   : buf_b   → スコア
//     conv2 の入力は buf_b、出力は buf_a。上書きし合わないので安全。
//
//   【演算器は4個並べる】
//     conv1 用と conv2 用の conv3x3 を別々に置く。1個を使い回すと
//     チャネル数と重みファイルをパラメータで切り替えられないため。
//     pool も 26→13 用と 11→5 用で別インスタンス。
//     どれも動くのは一度に1個だけなので、DSP は増えても4個。
//     BRAM も 12KB 程度で、KV260 の資源に対しては誤差。
//
//   【所要クロック】約 195,000（≒1.95ms @100MHz、毎秒 約510枚）
//
//   【使い方】
//     img_we / img_addr / img_data で 784 バイトを書き込む
//      → start を1クロック
//      → done を待つ
//      → digit が答え。score_addr で 10 個のスコア(int32)も読める
//   【実機で確認済み（2026-09-18）】
//     KV260 の PL に載せて 1 枚 1.991ms（毎秒 502 枚）。
//     答えもスコア(int32)も Python の量子化版と 1 ビットも違わなかった。
//     シミュレーションの 199,088 クロックと実測が小数第3位まで一致している。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module cnn_core (
    input  wire        clk,
    input  wire        rst_n,

    // ---- 画像の書き込み（28x28 = 784 バイト）----
    input  wire        img_we,
    input  wire [9:0]  img_addr,
    input  wire [7:0]  img_data,

    // ---- 制御 ----
    input  wire        start,
    output reg         busy,
    output reg         done,

    // ---- 結果 ----
    output wire [3:0]         digit,
    input  wire [3:0]         score_addr,
    output wire signed [31:0] score_data
);
    `include "cnn_param.vh"

    localparam integer LEN_IMG = C1_IN  * C1_SIZE * C1_SIZE;               // 784
    localparam integer LEN_A   = C1_OUT * (C1_SIZE-2) * (C1_SIZE-2);       // 5408
    localparam integer LEN_B   = C1_OUT * ((C1_SIZE-2)/2) * ((C1_SIZE-2)/2); // 1352

    // =======================================================================
    // バッファ（BRAM）
    // =======================================================================
    reg [7:0] buf_img [0:LEN_IMG-1];
    reg [7:0] buf_a   [0:LEN_A-1];
    reg [7:0] buf_b   [0:LEN_B-1];

    // 各バッファの読み書き線（どの段が使うかは下のマルチプレクサで決める）
    reg  [15:0] a_raddr, b_raddr, i_raddr;
    reg  [7:0]  a_rdata, b_rdata, i_rdata;
    reg         a_we,    b_we;
    reg  [15:0] a_waddr, b_waddr;
    reg  [7:0]  a_wdata, b_wdata;

    always @(posedge clk) begin
        i_rdata <= buf_img[i_raddr[9:0]];
        if (img_we) buf_img[img_addr] <= img_data;
    end
    always @(posedge clk) begin
        a_rdata <= buf_a[a_raddr[12:0]];
        if (a_we) buf_a[a_waddr[12:0]] <= a_wdata;
    end
    always @(posedge clk) begin
        b_rdata <= buf_b[b_raddr[10:0]];
        if (b_we) buf_b[b_waddr[10:0]] <= b_wdata;
    end

    // =======================================================================
    // 演算器
    // =======================================================================
    reg  c1_start, p1_start, c2_start, p2_start, fc_start;
    wire c1_done,  p1_done,  c2_done,  p2_done,  fc_done;
    wire c1_busy,  p1_busy,  c2_busy,  p2_busy,  fc_busy;

    wire [15:0] c1_xaddr, p1_xaddr, c2_xaddr, p2_xaddr, fc_xaddr;
    wire        c1_we,    p1_we,    c2_we,    p2_we;
    wire [15:0] c1_waddr, p1_waddr, c2_waddr, p2_waddr;
    wire [7:0]  c1_wdata, p1_wdata, c2_wdata, p2_wdata;

    // ---- conv1: buf_img → buf_a ----
    conv3x3 #(
        .CIN(C1_IN), .COUT(C1_OUT), .ISIZE(C1_SIZE), .SHIFT(CONV1_SHIFT),
        .WFILE("conv1_w.hex"), .BFILE("conv1_b.hex")
    ) u_conv1 (
        .clk(clk), .rst_n(rst_n), .start(c1_start), .busy(c1_busy), .done(c1_done),
        .x_addr(c1_xaddr), .x_data(i_rdata),
        .y_we(c1_we), .y_addr(c1_waddr), .y_data(c1_wdata)
    );

    // ---- pool1: buf_a (26x26x8) → buf_b (13x13x8) ----
    maxpool2 #(.CH(C1_OUT), .ISIZE(C1_SIZE-2)) u_pool1 (
        .clk(clk), .rst_n(rst_n), .start(p1_start), .busy(p1_busy), .done(p1_done),
        .x_addr(p1_xaddr), .x_data(a_rdata),
        .y_we(p1_we), .y_addr(p1_waddr), .y_data(p1_wdata)
    );

    // ---- conv2: buf_b (13x13x8) → buf_a (11x11x16) ----
    conv3x3 #(
        .CIN(C2_IN), .COUT(C2_OUT), .ISIZE(C2_SIZE), .SHIFT(CONV2_SHIFT),
        .WFILE("conv2_w.hex"), .BFILE("conv2_b.hex")
    ) u_conv2 (
        .clk(clk), .rst_n(rst_n), .start(c2_start), .busy(c2_busy), .done(c2_done),
        .x_addr(c2_xaddr), .x_data(b_rdata),
        .y_we(c2_we), .y_addr(c2_waddr), .y_data(c2_wdata)
    );

    // ---- pool2: buf_a (11x11x16) → buf_b (5x5x16) ----
    maxpool2 #(.CH(C2_OUT), .ISIZE(C2_SIZE-2)) u_pool2 (
        .clk(clk), .rst_n(rst_n), .start(p2_start), .busy(p2_busy), .done(p2_done),
        .x_addr(p2_xaddr), .x_data(a_rdata),
        .y_we(p2_we), .y_addr(p2_waddr), .y_data(p2_wdata)
    );

    // ---- fc: buf_b (400) → スコア10個 → argmax ----
    fc #(
        .NIN(FC_IN), .NOUT(FC_OUT), .SHIFT(FC_SHIFT),
        .WFILE("fc_w.hex"), .BFILE("fc_b.hex")
    ) u_fc (
        .clk(clk), .rst_n(rst_n), .start(fc_start), .busy(fc_busy), .done(fc_done),
        .x_addr(fc_xaddr), .x_data(b_rdata),
        .digit(digit), .score_addr(score_addr), .score_data(score_data)
    );

    // =======================================================================
    // どの段がどのバッファを使うかを切り替える
    // =======================================================================
    localparam S_IDLE  = 3'd0, S_CONV1 = 3'd1, S_POOL1 = 3'd2,
               S_CONV2 = 3'd3, S_POOL2 = 3'd4, S_FC    = 3'd5, S_END = 3'd6;
    reg [2:0] state;

    always @(*) begin
        i_raddr = 16'd0;
        a_raddr = 16'd0;
        b_raddr = 16'd0;
        a_we    = 1'b0;  a_waddr = 16'd0;  a_wdata = 8'd0;
        b_we    = 1'b0;  b_waddr = 16'd0;  b_wdata = 8'd0;
        case (state)
        S_CONV1: begin                       // buf_img を読み buf_a へ書く
            i_raddr = c1_xaddr;
            a_we    = c1_we;  a_waddr = c1_waddr;  a_wdata = c1_wdata;
        end
        S_POOL1: begin                       // buf_a を読み buf_b へ書く
            a_raddr = p1_xaddr;
            b_we    = p1_we;  b_waddr = p1_waddr;  b_wdata = p1_wdata;
        end
        S_CONV2: begin                       // buf_b を読み buf_a へ書く
            b_raddr = c2_xaddr;
            a_we    = c2_we;  a_waddr = c2_waddr;  a_wdata = c2_wdata;
        end
        S_POOL2: begin                       // buf_a を読み buf_b へ書く
            a_raddr = p2_xaddr;
            b_we    = p2_we;  b_waddr = p2_waddr;  b_wdata = p2_wdata;
        end
        S_FC: begin                          // buf_b を読む
            b_raddr = fc_xaddr;
        end
        default: ;
        endcase
    end

    // =======================================================================
    // 順番に起動していく状態機械
    // =======================================================================
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state    <= S_IDLE;
            busy     <= 1'b0;
            done     <= 1'b0;
            c1_start <= 1'b0; p1_start <= 1'b0; c2_start <= 1'b0;
            p2_start <= 1'b0; fc_start <= 1'b0;
        end else begin
            done     <= 1'b0;
            c1_start <= 1'b0; p1_start <= 1'b0; c2_start <= 1'b0;
            p2_start <= 1'b0; fc_start <= 1'b0;

            case (state)
            S_IDLE: if (start) begin
                busy     <= 1'b1;
                c1_start <= 1'b1;
                state    <= S_CONV1;
            end
            // 各段の done を待って次を起動する。done は1クロックだけ立つ。
            S_CONV1: if (c1_done) begin p1_start <= 1'b1; state <= S_POOL1; end
            S_POOL1: if (p1_done) begin c2_start <= 1'b1; state <= S_CONV2; end
            S_CONV2: if (c2_done) begin p2_start <= 1'b1; state <= S_POOL2; end
            S_POOL2: if (p2_done) begin fc_start <= 1'b1; state <= S_FC;    end
            S_FC:    if (fc_done) begin                   state <= S_END;   end
            // 最後の書き込みがバッファに落ちるのを1クロック待ってから done を出す
            S_END: begin
                busy  <= 1'b0;
                done  <= 1'b1;
                state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
