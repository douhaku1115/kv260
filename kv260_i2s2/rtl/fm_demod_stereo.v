`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// fm_demod_stereo.v -- FM ステレオ復調器（IQ から L/R を取り出す）
//
//   fm_demod.v（モノラル）の後継。前段は同じで、後段を 2 本に増やしてある。
//   ★fm_demod.v は動いている実績があるので触っていない。差し替えは
//     このモジュールで分離度を測ってからにすること。
//
//   【全体の流れ】
//     IQ ─→ 帯域制限 ─→ 位相差(外積) ─→ 振幅で正規化 ─→ MPX
//                                                      │
//                    ┌─────────────────────────────────┤
//                    │                                 │
//                    │                          19kHz PLL → 38kHz
//                    │                                 │
//                    │                        ×2cos(2ωt)（周波数変換）
//                    │                                 │
//                 [S=L+R]                           [D=L−R]
//                    │                                 │
//              3次CIC 1/20                       3次CIC 1/20
//              30Hz 高域通過                     30Hz 高域通過
//              デエンファシス50µs                 デエンファシス50µs
//              15kHz FIR(63タップ)               15kHz FIR(63タップ)
//                    │                                 │
//                    └──────── L = S+D / R = S−D ──────┘
//
//   【ステレオ復調の原理】
//     MPX の中で L−R は 38kHz を中心に置かれているが、38kHz 搬送波そのものは
//     送信されていない（DSB-SC＝抑圧搬送波。電力の節約とモノラル互換のため）。
//     代わりに半分の 19kHz が小さく送られている。これがパイロット信号。
//
//     受信側で 38kHz を作って掛け算すると、L−R が 0Hz 付近に戻ってくる：
//       (L−R)cos(2ωt) × 2cos(2ωt) = (L−R)(1 + cos(4ωt))
//     15kHz の低域通過で cos(4ωt) の項を捨てれば L−R が残る。
//     ★2 を掛けているのは、この式の右辺の直流成分が (L−R) ちょうどに
//       なるようにするため。掛け忘れると L−R が半分になり分離が崩れる。
//
//   【出力の大きさについて】
//     L = S+D, R = S−D としている（1/2 していない）。
//       ・モノラル素材（L=R）なら D=0 なので L出力 = R出力 = L+R
//         → fm_demod.v の出力と完全に同じ大きさ。音量設定を変えなくてよい。
//       ・片チャンネルだけの素材なら S=D=L となり L出力 = 2L, R出力 = 0
//         → ピーク値はモノラル時と同じ。クリップは増えない。
//
//   【パイロットが無いとき】
//     モノラル放送や電界が弱いときは stereo_pll が locked を落とすので、
//     D を 0 にして L=R=S（＝モノラル）に自動で戻る。
//     雑音の多い L−R 帯域を混ぜないので、弱電界では素直にモノラルが良い。
//
//   【既知の注意点（要測定）】
//     前段の帯域制限（4点移動平均×PRE_STAGES 段）は 53kHz 付近を削る。
//     3段だと MPX の上端が落ちて高域の分離度が悪化する可能性がある。
//     PRE_STAGES を 2 にして分離度が改善するか、必ず測って決めること。
//       段数 3 → 128kHz で -12.3dB、段数 2 → -8.2dB
// -----------------------------------------------------------------------------
module fm_demod_stereo #(
    parameter integer DECIM      = 20,          // 間引き比（976560 / 48828）
    parameter integer PRE_STAGES = 3,           // 前段の帯域制限の段数
    parameter integer NCO_STEP0  = 83563098,    // 19kHz ぶんの位相増分 @976560Hz
    parameter integer PILOT_TH   = 400          // パイロット検出のしきい値
)(
    input  wire               clk,
    input  wire               rst_n,

    // ---- IQ 入力 ----
    input  wire               in_valid,
    input  wire signed [15:0] in_i,
    input  wire signed [15:0] in_q,
    output wire               in_ready,         // FIR 計算中は 0（流量制御）

    // ---- 音声出力（間引き後、L と R が同時に出る）----
    output reg                out_valid,
    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r,

    // ---- 制御・状態 ----
    input  wire [7:0]         volume,           // 64 で等倍
    input  wire               stereo_en,        // 0 なら強制モノラル
    input  wire               diag_d,           // 1 なら L−R をそのまま左右に出す（診断用）
    output wire               pilot_locked,     // パイロットを捕まえている
    output wire signed [31:0] pilot_level,      // パイロットの強さ（調整用）

    // ---- 実機での切り分け用（音を聞いても分からないので数字で出す）----
    output wire signed [31:0] pilot_quad,       // PLL の直交成分（位相が合えば 0）
    output reg  signed [31:0] sum_level,        // S = L+R の平均振幅
    output reg  signed [31:0] diff_level        // D = L−R の平均振幅
);
    wire fir_busy;
    assign in_ready = ~fir_busy;

    // =========================================================================
    // 0. 復調の前の帯域制限（4点移動平均 × PRE_STAGES 段、間引かない）
    // =========================================================================
    //   間引くと Δφ が大きくなり sin 近似が破綻するのでレートは保つ。
    //   I と Q に同じ遅延が入るので位相差には影響しない。
    //
    //   ★fm_demod.v との違い: 4本の和を 18bit で取ってからシフトしている。
    //     元は 16bit 幅のまま足していたので、入力が大振幅だと桁あふれし得た。
    wire signed [15:0] pi_out [0:PRE_STAGES];
    wire signed [15:0] pq_out [0:PRE_STAGES];

    assign pi_out[0] = in_i;
    assign pq_out[0] = in_q;

    genvar g;
    generate
        for (g = 0; g < PRE_STAGES; g = g + 1) begin : pre
            reg signed [15:0] zi0, zi1, zi2, zi3;
            reg signed [15:0] zq0, zq1, zq2, zq3;

            wire signed [17:0] si = zi0 + zi1 + zi2 + zi3;
            wire signed [17:0] sq = zq0 + zq1 + zq2 + zq3;
            assign pi_out[g+1] = si >>> 2;
            assign pq_out[g+1] = sq >>> 2;

            always @(posedge clk) begin
                if (!rst_n) begin
                    zi0 <= 16'sd0; zi1 <= 16'sd0; zi2 <= 16'sd0; zi3 <= 16'sd0;
                    zq0 <= 16'sd0; zq1 <= 16'sd0; zq2 <= 16'sd0; zq3 <= 16'sd0;
                end else if (in_valid) begin
                    zi0 <= pi_out[g]; zi1 <= zi0; zi2 <= zi1; zi3 <= zi2;
                    zq0 <= pq_out[g]; zq1 <= zq0; zq2 <= zq1; zq3 <= zq2;
                end
            end
        end
    endgenerate

    wire signed [15:0] flt_i = pi_out[PRE_STAGES];
    wire signed [15:0] flt_q = pq_out[PRE_STAGES];

    // =========================================================================
    // 1. 位相差（外積）と 振幅の2乗
    // =========================================================================
    reg signed [15:0] prev_i, prev_q;

    wire signed [31:0] cross = prev_i * flt_q - prev_q * flt_i;  // A^2 * sin(Δφ)
    wire        [31:0] mag2  = flt_i * flt_i + flt_q * flt_q;    // A^2

    // =========================================================================
    // 2. 振幅で正規化（8語の表で 32768/top4 を引く）
    // =========================================================================
    function [5:0] msb_pos(input [31:0] v);
        integer b;
        begin
            msb_pos = 6'd0;
            for (b = 0; b < 32; b = b + 1)
                if (v[b]) msb_pos = b[5:0];
        end
    endfunction

    wire [5:0] k    = msb_pos(mag2);
    wire [5:0] ksh  = (k > 6'd3) ? (k - 6'd3) : 6'd0;
    wire [3:0] top4 = (k > 6'd3) ? mag2[ksh +: 4] : mag2[3:0];

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
            default: recip = 13'd4096;
        endcase
    end

    wire signed [44:0] cross_r = $signed(cross) * $signed({1'b0, recip});
    wire signed [44:0] norm45  = cross_r >>> ksh;
    wire signed [17:0] norm    = norm45[17:0];      // これが MPX（976560Hz）

    // =========================================================================
    // 3. 19kHz パイロット PLL → 38kHz
    // =========================================================================
    wire signed [15:0] cos38;
    wire               locked;

    stereo_pll #(
        .NCO_STEP0(NCO_STEP0),
        .PILOT_TH (PILOT_TH)
    ) u_pll (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_valid(in_valid),
        .mpx         (norm),
        .cos38       (cos38),
        .locked      (locked),
        .pilot_level (pilot_level),
        .pilot_quad  (pilot_quad)
    );

    assign pilot_locked = locked;
    wire stereo_active = locked & stereo_en;

    // =========================================================================
    // 4. L−R を 0Hz に戻す（MPX × 2cos(2ωt)）
    // =========================================================================
    function signed [17:0] clip18(input signed [33:0] v);
        if      (v >  34'sd131071)  clip18 =  18'sd131071;
        else if (v < -34'sd131072)  clip18 = -18'sd131072;
        else                        clip18 =  v[17:0];
    endfunction

    //   ★D_GAIN による振幅補正（分離度を決める最重要点）
    //
    //     分離度を制限するのは位相ではなく S と D の振幅の食い違い。
    //       L = S+D で R を打ち消すので、D が S の g 倍だと
    //         分離度[dB] = 20*log10( (1+g)/(1-g) )
    //       g=0.89 なら 25dB しか出ない。PLL の位相誤差 0.07 度（58dB 相当）
    //       より 2 桁厳しい制約になる。
    //
    //     D は MPX の 38kHz 付近に載っているため、S(0〜15kHz) より余計に減る:
    //       (a) 前段の 4点移動平均 x PRE_STAGES 段
    //       (b) 位相差を 1 標本の差分で取ること（sinc）
    //     この 2 つを打ち消す定数を掛けて S と揃える。
    //
    //     PRE_STAGES による値（gen_nco_lut.py が算出、fs=976560）:
    //       1段 → 4264（補正なし 33.9dB / 補正後 78.9dB）
    //       2段 → 4426（補正なし 28.2dB / 補正後 66.6dB）
    //       3段 → 4593（補正なし 24.8dB / 補正後 58.8dB）
    //     ★PRE_STAGES を変えたら D_GAIN も必ず変えること。
    localparam integer D_GAIN = 4593;               // Q12（4096 で等倍）

    wire signed [33:0] dmul  = norm * cos38;
    wire signed [33:0] dshf  = dmul >>> 14;         // >>>15 で等倍、>>>14 で 2 倍
    wire signed [45:0] dcmp  = dshf * D_GAIN;
    wire signed [33:0] dfix  = dcmp >>> 12;
    wire signed [17:0] d_in  = stereo_active ? clip18(dfix) : 18'sd0;

    // =========================================================================
    // 5. 後段 2 本（間引き → 高域通過 → デエンファシス）
    // =========================================================================
    wire               s_dec_valid, d_dec_valid;
    wire signed [15:0] s_dec_data,  d_dec_data;

    audio_backend #(.DECIM(DECIM)) u_sum (      // S = L+R
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_data(norm), .volume(volume),
        .dec_valid(s_dec_valid), .dec_data(s_dec_data)
    );

    audio_backend #(.DECIM(DECIM)) u_dif (      // D = L−R
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_data(d_in), .volume(volume),
        .dec_valid(d_dec_valid), .dec_data(d_dec_data)
    );

    // =========================================================================
    // 6. 15kHz 低域通過 FIR（63タップ）を 2 チャンネルぶん
    // =========================================================================
    //   係数表は共通。乗算器を 2 個並べて同じ添字で同時に積和するので、
    //   所要クロックは 1 チャンネルのときと同じ 63 クロック。
    //   48828Hz ＝ 2048 クロックに 1 回なので十分間に合う。
    localparam integer LP_N = 63;
    reg signed [15:0] fir_h  [0:LP_N-1];
    reg signed [15:0] fir_zs [0:LP_N-1];        // S 用の遅延線
    reg signed [15:0] fir_zd [0:LP_N-1];        // D 用の遅延線
    initial $readmemh("fir15k.hex", fir_h);

    reg [6:0]         fir_i;
    reg               fir_run, fir_fin;
    reg signed [39:0] acc_s, acc_d;

    assign fir_busy = fir_run | fir_fin;

    function signed [15:0] clip16(input signed [31:0] v);
        if      (v >  32'sd32767)  clip16 =  16'sd32767;
        else if (v < -32'sd32768)  clip16 = -16'sd32768;
        else                       clip16 =  v[15:0];
    endfunction

    wire signed [31:0] fir_s = acc_s >>> 15;    // 係数は 32768 倍してある
    wire signed [31:0] fir_d = acc_d >>> 15;

    // ---- S と D の平均振幅（実機での切り分け用）----
    //   漏れ積分器: acc += |x| - (acc >> 10) なので acc は |x| の 1024 倍に落ち着く。
    //   時定数は 1024/48828 = 21ms。
    //   ★診断の要点
    //     diff_level が sum_level に比べて極端に小さいなら、L−R そのものが
    //     取れていない（位相ずれ、または放送の L−R が小さい）。
    //     両方それなりにあるのに音が広がらないなら、聴き方か出力側の問題。
    localparam integer LVL_SHIFT = 10;
    reg signed [31:0] sum_acc, diff_acc;
    wire signed [31:0] abs_s = (fir_s < 0) ? -fir_s : fir_s;
    wire signed [31:0] abs_d = (fir_d < 0) ? -fir_d : fir_d;

    integer zi;

    always @(posedge clk) begin
        if (!rst_n) begin
            prev_i    <= 16'sd0;
            prev_q    <= 16'sd0;
            fir_i     <= 7'd0;
            fir_run   <= 1'b0;
            fir_fin   <= 1'b0;
            acc_s     <= 40'sd0;
            acc_d     <= 40'sd0;
            out_valid <= 1'b0;
            out_l     <= 16'sd0;
            out_r     <= 16'sd0;
            sum_acc    <= 32'sd0;
            diff_acc   <= 32'sd0;
            sum_level  <= 32'sd0;
            diff_level <= 32'sd0;
            for (zi = 0; zi < LP_N; zi = zi + 1) begin
                fir_zs[zi] <= 16'sd0;
                fir_zd[zi] <= 16'sd0;
            end
        end else begin
            out_valid <= 1'b0;

            // ---- FIR の積和（1クロックに1タップ、2チャンネル同時）----
            if (fir_run) begin
                acc_s <= acc_s + $signed(fir_h[fir_i]) * $signed(fir_zs[fir_i]);
                acc_d <= acc_d + $signed(fir_h[fir_i]) * $signed(fir_zd[fir_i]);
                if (fir_i == LP_N - 1) begin
                    fir_run <= 1'b0;
                    fir_fin <= 1'b1;            // 最後の加算は次のクロックで確定
                end else begin
                    fir_i <= fir_i + 7'd1;
                end
            end else if (fir_fin) begin
                fir_fin   <= 1'b0;
                // ---- 行列演算: L = S+D, R = S−D ----
                // ---- 診断モード: L−R をそのまま両チャンネルへ ----
                //   計算で原因が当たらないときは中身を直接聞くのが早い。
                //     音楽に聞こえる → 本物の L−R。行列演算か出力側の問題
                //     ピーという音   → 折り返し（57kHz や 38kHz の混入）
                //     サーッという音 → 雑音
                //   PL FFT は FIFO の左チャンネルを見ているので、このモードに
                //   すると FFT がそのまま L−R のスペクトル計になる（配線不要）。
                if (diag_d) begin
                    out_l <= clip16(fir_d);
                    out_r <= clip16(fir_d);
                end else begin
                    out_l <= clip16(fir_s + fir_d);
                    out_r <= clip16(fir_s - fir_d);
                end
                out_valid <= 1'b1;

                // ---- 平均振幅の更新（切り分け用の計測）----
                sum_acc    <= sum_acc  + abs_s - (sum_acc  >>> LVL_SHIFT);
                diff_acc   <= diff_acc + abs_d - (diff_acc >>> LVL_SHIFT);
                sum_level  <= sum_acc  >>> LVL_SHIFT;
                diff_level <= diff_acc >>> LVL_SHIFT;
            end

            if (in_valid) begin
                prev_i <= flt_i;
                prev_q <= flt_q;
            end

            // ---- 間引き点で FIR を起動 ----
            if (s_dec_valid) begin
                for (zi = LP_N - 1; zi > 0; zi = zi - 1) begin
                    fir_zs[zi] <= fir_zs[zi - 1];
                    fir_zd[zi] <= fir_zd[zi - 1];
                end
                fir_zs[0] <= s_dec_data;
                fir_zd[0] <= d_dec_data;

                fir_i   <= 7'd0;
                acc_s   <= 40'sd0;
                acc_d   <= 40'sd0;
                fir_run <= 1'b1;
            end
        end
    end
endmodule
