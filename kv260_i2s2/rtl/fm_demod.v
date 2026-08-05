// -----------------------------------------------------------------------------
// fm_demod.v -- FM 復調器（IQ から音声を取り出す）
//
//   RTL-SDR が出す IQ データ（複素数の信号）を受け取り、FM 放送を音声に戻す。
//
//   【全体の流れ】
//     IQ → 位相差(外積) → 振幅で正規化 → 3次CICで間引き → デエンファシス → 音声
//
//   【1. FM 復調の原理】
//     FM は「周波数の変化」に音が乗っている。周波数 = 位相の進む速さ なので、
//     1 標本ごとの位相の差を取れば音になる。
//
//       z[n] = A・e^(jφ[n])   とすると
//       z[n] × conj(z[n-1]) の
//         虚部 cross = I[n-1]*Q[n] - Q[n-1]*I[n] = A² × sin(Δφ)
//
//   【2. 振幅の正規化（これが無いと雑音になる）】
//     cross には A²（振幅の2乗）が掛かったまま残る。実際の受信では強度が常に
//     揺れるので、その揺れがそのまま音量変動＝雑音になる。mag2 = A² で割る。
//
//     除算器は重いので、mag2 を「2のべき乗 × 上位4ビット」に分解して近似する：
//       mag2 ≒ top4 × 2^(k-3)          k = mag2 の最上位ビット位置
//       cross/mag2 ≒ (cross × (32768/top4)) >>> (k-3)
//     32768/top4 は 8 語の表（RECIP_LUT）で引く。誤差は 0.5dB 以下。
//     （最上位ビット位置だけで近似すると最大 2 倍＝6dB の誤差が出る）
//
//   【3. 間引き（デシメーション）— 3次 CIC】
//     IQ は毎秒 976560 個、音声は 48828 個。20 分の 1 に間引く。
//     このとき 24.4kHz より上の成分は音声帯域に折り返す（エイリアス）。
//     FM 放送には 19kHz パイロット、23〜53kHz ステレオ信号が乗っているので、
//     これらを十分に落とさないと雑音になる。
//
//     20点移動平均（1次CIC）の減衰:  30kHz -6.3dB / 38kHz -11.6dB  ← 不足
//     3次CIC にすると:               30kHz -18.8dB / 38kHz -34.8dB
//
//     CIC = 積分器を3段（入力側）→ 間引き → 微分器を3段（出力側）
//     利得は (20)³ = 8000 になるので、最後に割り戻す。
//
//   【4. デエンファシス（日本仕様 50µs）】
//     FM 放送は送信時に高音を持ち上げている。受信側で同じだけ下げる。
//     FM の雑音は高い周波数ほど大きいので、雑音低減にも効く。
//       y += α × (x - y)、α = 1-exp(-1/(fs·τ)) ≒ 0.336 → ×256 = 86
//
//   【入力】
//     rtl_sdr の出力は「符号なし8ビットの I, Q が交互」。PS 側で 128 を引いて
//     符号付きにし、<<6 で 16 ビットに広げて渡す。
// -----------------------------------------------------------------------------
module fm_demod #(
    parameter integer DECIM = 20        // 間引き比（976560 / 48828 = 20）
)(
    input  wire               clk,
    input  wire               rst_n,

    // ---- IQ 入力 ----
    input  wire               in_valid,
    input  wire signed [15:0] in_i,
    input  wire signed [15:0] in_q,
    output wire               in_ready,   // 常に受け取れる

    // ---- 音声出力（間引き後）----
    output reg                out_valid,
    output reg  signed [15:0] out_data,

    // ---- 音量調整（PS から）----
    input  wire [7:0]         volume      // 復調後の増幅率（64で等倍）
);
    assign in_ready = 1'b1;             // 詰まらせない（常に受ける）

    // =========================================================================
    // 1. 位相差（外積）と 振幅の2乗
    // =========================================================================
    reg signed [15:0] prev_i, prev_q;

    wire signed [31:0] cross = prev_i * in_q - prev_q * in_i;   // A² × sin(Δφ)
    wire        [31:0] mag2  = in_i * in_i + in_q * in_q;       // A²（常に非負）

    // =========================================================================
    // 2. 振幅で正規化（8語の表で 32768/top4 を引く）
    // =========================================================================
    function [5:0] msb_pos(input [31:0] v);      // 最上位ビットの位置
        integer i;
        begin
            msb_pos = 6'd0;
            for (i = 0; i < 32; i = i + 1)
                if (v[i]) msb_pos = i[5:0];
        end
    endfunction

    wire [5:0] k = msb_pos(mag2);
    // mag2 の上位4ビット（最上位は必ず1なので 8〜15 の範囲）
    wire [5:0] ksh  = (k > 6'd3) ? (k - 6'd3) : 6'd0;
    wire [3:0] top4 = (k > 6'd3) ? mag2[ksh +: 4] : mag2[3:0];

    // 32768 / top4 の表（top4 = 8〜15）
    //   8→4096, 9→3641, 10→3277, 11→2979, 12→2731, 13→2521, 14→2341, 15→2185
    reg [12:0] recip;
    always @(*) begin
        case (top4)
            4'd8:    recip = 13'd4096;
            4'd9:    recip = 13'd3641;
            4'd10:   recip = 13'd3277;
            4'd11:   recip = 13'd2979;
            4'd12:   recip = 13'd2731;
            4'd13:   recip = 13'd2521;
            4'd14:   recip = 13'd2341;
            4'd15:   recip = 13'd2185;
            default: recip = 13'd4096;   // mag2 が極小のとき（弱電界）
        endcase
    end

    // norm = (cross × 32768/top4) >>> (k-3) ≒ sin(Δφ) × 32768、±32768 に収まる
    wire signed [44:0] cross_r = $signed(cross) * $signed({1'b0, recip});
    wire signed [44:0] norm45  = cross_r >>> ksh;
    wire signed [17:0] norm    = norm45[17:0];

    // =========================================================================
    // 3. 3次 CIC で間引き
    // =========================================================================
    //   積分器3段（入力の速さで動く）。利得 20³=8000 のぶん桁が伸びるので
    //   32ビットで持つ（CIC は途中で桁あふれしても最終差分で正しい値になる）
    reg signed [31:0] int1, int2, int3;
    reg [7:0]         cnt;

    // 微分器3段（間引き後の速さで動く）
    reg signed [31:0] comb1_prev, comb2_prev, comb3_prev;

    // =========================================================================
    // 4. デエンファシス（日本仕様 50µs）
    // =========================================================================
    localparam signed [8:0] DEEMP_A = 9'sd86;   // α × 256（α ≒ 0.336）
    reg signed [31:0] deemp_y;

    // 微分器3段の結果（この場で組み合わせ回路として計算する）
    wire signed [31:0] d1  = int3 - comb1_prev;
    wire signed [31:0] d2  = d1   - comb2_prev;
    wire signed [31:0] d3  = d2   - comb3_prev;

    // CIC 利得 8000 で割る（>>13 = ÷8192、2.4%の差は音量で吸収）→ 音量を掛ける
    wire signed [31:0] cic_scaled = d3 >>> 13;
    wire signed [39:0] volumed    = cic_scaled * $signed({1'b0, volume});
    wire signed [31:0] pre_deemp  = volumed >>> 6;      // volume=64 で等倍

    // デエンファシス: y += (x - y) × 86 / 256
    wire signed [39:0] deemp_d    = (pre_deemp - deemp_y) * DEEMP_A;
    wire signed [31:0] deemp_next = deemp_y + (deemp_d >>> 8);

    function signed [15:0] clip16(input signed [31:0] v);
        if      (v >  32'sd32767)  clip16 =  16'sd32767;
        else if (v < -32'sd32768)  clip16 = -16'sd32768;
        else                       clip16 =  v[15:0];
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            prev_i     <= 16'sd0;
            prev_q     <= 16'sd0;
            int1       <= 32'sd0;
            int2       <= 32'sd0;
            int3       <= 32'sd0;
            cnt        <= 8'd0;
            comb1_prev <= 32'sd0;
            comb2_prev <= 32'sd0;
            comb3_prev <= 32'sd0;
            deemp_y    <= 32'sd0;
            out_valid  <= 1'b0;
            out_data   <= 16'sd0;
        end else begin
            out_valid <= 1'b0;          // 既定は無効

            if (in_valid) begin
                prev_i <= in_i;
                prev_q <= in_q;

                // ---- 積分器3段 ----
                int1 <= int1 + {{14{norm[17]}}, norm};
                int2 <= int2 + int1;
                int3 <= int3 + int2;

                if (cnt == DECIM - 1) begin
                    cnt <= 8'd0;
                    // ---- 間引き点で微分器3段の状態を更新 ----
                    comb1_prev <= int3;
                    comb2_prev <= d1;
                    comb3_prev <= d2;

                    // ---- デエンファシスして出力（d3 は上で計算済み）----
                    deemp_y   <= deemp_next;
                    out_data  <= clip16(deemp_next);
                    out_valid <= 1'b1;
                end else begin
                    cnt <= cnt + 8'd1;
                end
            end
        end
    end
endmodule
