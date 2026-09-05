`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// audio_backend.v -- 復調後の音声一本ぶんの後段（間引き→高域通過→デエンファシス）
//
//   fm_demod.v が一体で持っていた後段部分を、そのまま切り出したもの。
//   ステレオでは L+R 用と L−R 用に同じものが 2 本要るので分離した。
//   中身・定数は fm_demod.v と同一（詳しい理由は fm_demod.v の注釈を参照）。
//
//     3次CIC で 1/DECIM に間引き → 音量 → 30Hz 高域通過 → デエンファシス(50µs)
//
//   この後段の出力を 15kHz の FIR に通すところまでで 1 チャンネル。
//   FIR は係数表を共有できるので上位（fm_demod_stereo.v）に置いてある。
//
//   ★フィルタは全て線形なので、
//       (L+R) と (L−R) に通してから足し引きする  …本モジュールの構成
//       足し引きして L, R にしてから通す
//     のどちらでも結果は同じ。前者のほうが乗算器の共有がしやすい。
// -----------------------------------------------------------------------------
module audio_backend #(
    parameter integer DECIM = 20            // 間引き比（976560 / 48828 = 20）
)(
    input  wire               clk,
    input  wire               rst_n,

    input  wire               in_valid,     // 復調直後の速さ（976560Hz）で1標本
    input  wire signed [17:0] in_data,
    input  wire [7:0]         volume,       // 64 で等倍

    output reg                dec_valid,    // 間引き点（48828Hz で1発）
    output reg  signed [15:0] dec_data      // FIR へ渡す値
);
    // ---- 3次 CIC: 積分器3段（入力の速さで動く）----
    reg signed [31:0] int1, int2, int3;
    reg [7:0]         cnt;

    // ---- 3次 CIC: 微分器3段（間引き後の速さで動く）----
    reg signed [31:0] comb1_prev, comb2_prev, comb3_prev;

    wire signed [31:0] d1 = int3 - comb1_prev;
    wire signed [31:0] d2 = d1   - comb2_prev;
    wire signed [31:0] d3 = d2   - comb3_prev;

    // CIC の利得 DECIM^3 を 2 の冪で割り戻す（シフト量は DECIM から自動計算）
    localparam integer CIC_GAIN  = DECIM * DECIM * DECIM;
    localparam integer CIC_SHIFT = $clog2(CIC_GAIN);

    wire signed [31:0] cic_scaled = d3 >>> CIC_SHIFT;
    wire signed [39:0] volumed    = cic_scaled * $signed({1'b0, volume});
    wire signed [31:0] pre_hp     = volumed >>> 6;      // volume=64 で等倍

    // ---- 30Hz 高域通過: y[n] = x[n] - x[n-1] + a*y[n-1] ----
    localparam signed [17:0] HP_A = 18'sd65283;         // a = 0.99615 の 65536 倍
    reg signed [31:0] hp_x1, hp_y1;

    wire signed [49:0] hp_fb   = hp_y1 * HP_A;
    wire signed [31:0] hp_next = pre_hp - hp_x1 + (hp_fb >>> 16);

    // ---- デエンファシス（日本仕様 50µs）: y += (x - y) * 86/256 ----
    localparam signed [8:0] DEEMP_A = 9'sd86;
    reg signed [31:0] deemp_y;

    wire signed [39:0] deemp_d    = (hp_next - deemp_y) * DEEMP_A;
    wire signed [31:0] deemp_next = deemp_y + (deemp_d >>> 8);

    function signed [15:0] clip16(input signed [31:0] v);
        if      (v >  32'sd32767)  clip16 =  16'sd32767;
        else if (v < -32'sd32768)  clip16 = -16'sd32768;
        else                       clip16 =  v[15:0];
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            int1       <= 32'sd0;
            int2       <= 32'sd0;
            int3       <= 32'sd0;
            cnt        <= 8'd0;
            comb1_prev <= 32'sd0;
            comb2_prev <= 32'sd0;
            comb3_prev <= 32'sd0;
            hp_x1      <= 32'sd0;
            hp_y1      <= 32'sd0;
            deemp_y    <= 32'sd0;
            dec_valid  <= 1'b0;
            dec_data   <= 16'sd0;
        end else begin
            dec_valid <= 1'b0;

            if (in_valid) begin
                int1 <= int1 + {{14{in_data[17]}}, in_data};
                int2 <= int2 + int1;
                int3 <= int3 + int2;

                if (cnt == DECIM - 1) begin
                    cnt        <= 8'd0;
                    comb1_prev <= int3;
                    comb2_prev <= d1;
                    comb3_prev <= d2;

                    hp_x1   <= pre_hp;
                    hp_y1   <= hp_next;
                    deemp_y <= deemp_next;

                    dec_data  <= clip16(deemp_next);
                    dec_valid <= 1'b1;
                end else begin
                    cnt <= cnt + 8'd1;
                end
            end
        end
    end
endmodule
