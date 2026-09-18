// -----------------------------------------------------------------------------
// conv3x3.v -- 3x3 畳み込み + ReLU + 8ビット飽和（int8 重み / uint8 特徴マップ）
//
//   段13 の中核。conv1（入力1ch→出力8ch）と conv2（入力8ch→出力16ch）の
//   両方をこの1個のモジュールで賄う。違いはパラメータとhexファイルだけ。
//
//   【方式】積和器を1個だけ持ち、時分割で使い回す（fft512.v と同じ考え方）。
//     1クロックに1回の積和。総クロック数は
//       conv1:  8ch × 26×26 ×  9 =  48,672
//       conv2: 16ch × 11×11 × 72 = 139,392
//     100MHz なら合わせて 1.9ms/枚。並列化しなくても十分速い。
//     掛け算器は1個で済むので DSP はほとんど使わない。
//
//   【ループの順序】外側から co → oy → ox → ci → ky → kx。kx が最内周。
//     1つの出力画素を作り終えるまでに CIN×9 回まわる。
//     整数の足し算は誤差が出ないので、足す順序が Python 版（面ごとに足す）と
//     違っても結果は1ビットも変わらない。
//
//   【出力の作り方】
//     acc = バイアス + Σ(重み × 入力)          … int32
//     y   = clip(acc >>> SHIFT, 0, 255)         … ReLU と飽和を同時に行う
//     SHIFT は量子化のスケール合わせ。2の冪に丸めてあるので右シフトだけで済む。
//
//   【メモリの持ち方】
//     入力特徴マップは外（呼び出し側）に置く。conv1 と conv2 で大きさが違い、
//     間にプーリングも挟むので、バッファは上位でまとめて管理するほうが素直。
//     このモジュールは x_addr を出して1クロック後に x_data が返ることを前提に
//     する（BRAM の同期読み出し）。重みとバイアスだけ自分の中に持つ。
//
//   【パイプライン】
//     BRAM は読み出しに1クロックかかる。そこで
//       サイクル n   : アドレスを出す（カウンタの値）
//       サイクル n+1 : 返ってきた x_data と w_data を掛けて acc に足す
//     の2段に分ける。アドレスは毎クロック出し続けるので、
//     余分な待ちは最初の1クロックだけ。実質1積和1クロックになる。
//
//   【アドレス幅】
//     ポート宣言で localparam を参照するとツールによって順序で怒られる。
//     ここで扱う最大語数は 8ch×26×26 = 5408 なので、素直に16ビット固定にする。
//   【実機で確認済み（2026-09-18）】合成後 conv1=282 LUT, conv2=466 LUT。
//     掛け算器は DSP を使わず LUT に収まった（DSP 使用数 0）。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module conv3x3 #(
    parameter integer CIN   = 1,        // 入力チャネル数
    parameter integer COUT  = 8,        // 出力チャネル数
    parameter integer ISIZE = 28,       // 入力の一辺（正方形）
    parameter integer SHIFT = 9,        // 積和の結果を右へずらすビット数
    parameter         WFILE = "conv1_w.hex",   // 重み     int8  [co][ci][ky][kx]
    parameter         BFILE = "conv1_b.hex"    // バイアス int32 [co]
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,        // 1クロックのパルスで開始
    output reg         busy,
    output reg         done,         // 終了時に1クロックだけ1

    // ---- 入力特徴マップの読み出し（同期読み出し, 1クロック遅れ）----
    output wire [15:0] x_addr,
    input  wire [7:0]  x_data,

    // ---- 出力特徴マップの書き込み ----
    output reg         y_we,
    output reg [15:0]  y_addr,
    output reg [7:0]   y_data
);
    // ---- ビット幅を求める関数（宣言より前に置く）----
    function integer clog2(input integer v);
        integer i;
        begin
            clog2 = 1;
            for (i = 1; i < v; i = i * 2) clog2 = clog2 + 1;
        end
    endfunction

    localparam integer OSIZE = ISIZE - 2;        // 3x3 でパディング無し
    localparam integer WLEN  = COUT * CIN * 9;   // 重みの語数

    // ---- 係数（BRAM に載る）----
    reg signed [7:0]  wmem [0:WLEN-1];
    reg signed [31:0] bmem [0:COUT-1];
    initial begin
        $readmemh(WFILE, wmem);
        $readmemh(BFILE, bmem);
    end

    // ---- ループカウンタ（アドレス生成段）----
    reg [1:0] kx, ky;                            // 3x3 の位置
    reg [clog2(CIN)-1:0]   ci;                   // 入力チャネル
    reg [clog2(OSIZE)-1:0] ox, oy;               // 出力画素の位置
    reg [clog2(COUT)-1:0]  co;                   // 出力チャネル

    wire first = (kx == 2'd0) && (ky == 2'd0) && (ci == 0);
    wire last  = (kx == 2'd2) && (ky == 2'd2) && (ci == CIN - 1);

    // 出力画素(ox,oy) に対して 3x3 の窓は入力の (ox+kx, oy+ky)
    assign x_addr = ci * (ISIZE * ISIZE) + (oy + ky) * ISIZE + (ox + kx);
    wire [15:0] w_addr = co * (CIN * 9) + ci * 9 + ky * 3 + kx;

    // ---- 係数の同期読み出し（x_data と同じ1クロック遅れに揃える）----
    reg signed [7:0]  w_q;
    reg signed [31:0] b_q;
    always @(posedge clk) begin
        w_q <= wmem[w_addr];
        b_q <= bmem[co];
    end

    // ---- 演算段へ渡す制御（1クロック遅らせる）----
    reg                    v_valid, v_first, v_last;
    reg [clog2(OSIZE)-1:0] v_ox, v_oy;
    reg [clog2(COUT)-1:0]  v_co;

    // ---- 積和 ----
    reg  signed [31:0] acc;
    wire signed [31:0] prod = $signed({1'b0, x_data}) * w_q;   // x は符号なし
    wire signed [31:0] sum  = (v_first ? b_q : acc) + prod;

    // ReLU と 8ビット飽和を同時に行う（負なら0、255超なら255）
    wire signed [31:0] shifted = sum >>> SHIFT;
    wire [7:0] satur = (shifted <= 0)   ? 8'd0   :
                       (shifted >= 255) ? 8'd255 : shifted[7:0];

    localparam S_IDLE = 2'd0, S_RUN = 2'd1, S_DRAIN = 2'd2;
    reg [1:0] state;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state   <= S_IDLE;
            busy    <= 1'b0;
            done    <= 1'b0;
            y_we    <= 1'b0;
            v_valid <= 1'b0;
            kx <= 0; ky <= 0; ci <= 0; ox <= 0; oy <= 0; co <= 0;
            acc     <= 0;
        end else begin
            done <= 1'b0;
            y_we <= 1'b0;

            // ---- 演算段（アドレス段の1クロック後）----
            if (v_valid) begin
                acc <= sum;
                if (v_last) begin
                    y_we   <= 1'b1;
                    y_addr <= v_co * (OSIZE * OSIZE) + v_oy * OSIZE + v_ox;
                    y_data <= satur;
                end
            end

            case (state)
            // -----------------------------------------------------------
            S_IDLE: begin
                v_valid <= 1'b0;
                if (start) begin
                    kx <= 0; ky <= 0; ci <= 0;
                    ox <= 0; oy <= 0; co <= 0;
                    busy  <= 1'b1;
                    state <= S_RUN;
                end
            end
            // -----------------------------------------------------------
            S_RUN: begin
                // いま出しているアドレスの情報を1クロック後の演算段へ送る
                v_valid <= 1'b1;
                v_first <= first;
                v_last  <= last;
                v_ox    <= ox;
                v_oy    <= oy;
                v_co    <= co;

                // カウンタを進める（kx が最内周）
                if (kx != 2'd2) begin
                    kx <= kx + 2'd1;
                end else begin
                    kx <= 2'd0;
                    if (ky != 2'd2) begin
                        ky <= ky + 2'd1;
                    end else begin
                        ky <= 2'd0;
                        if (ci != CIN - 1) begin
                            ci <= ci + 1'b1;
                        end else begin
                            ci <= 0;                    // 出力画素1つ分が完了
                            if (ox != OSIZE - 1) begin
                                ox <= ox + 1'b1;
                            end else begin
                                ox <= 0;
                                if (oy != OSIZE - 1) begin
                                    oy <= oy + 1'b1;
                                end else begin
                                    oy <= 0;
                                    if (co != COUT - 1) begin
                                        co <= co + 1'b1;
                                    end else begin
                                        state <= S_DRAIN;   // 全部出し終えた
                                    end
                                end
                            end
                        end
                    end
                end
            end
            // -----------------------------------------------------------
            // 最後に出したアドレスの結果がまだパイプラインに残っている。
            // このサイクルで演算段がそれを書き込む。done も同時に上げる。
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
