`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// fm_demod.v -- FM 復調器（IQ から音声を取り出す）
//
//   RTL-SDR が出す IQ データ（複素数の信号）を受け取り、FM 放送を音声に戻す。
//
//   【全体の流れ】
//     IQ → 帯域制限 → 位相差(外積) → 振幅で正規化 → 3次CICで間引き
//                                                → デエンファシス → 音声
//
//   【1. FM 復調の原理】
//     FM は「周波数の変化」に音が乗っている。周波数 = 位相の進む速さ なので、
//     1 標本ごとの位相の差を取れば音になる。
//
//       z[n] = A・e^(jφ[n])   とすると
//       z[n] × conj(z[n-1]) の
//         虚部 cross = I[n-1]*Q[n] - Q[n-1]*I[n] = A² × sin(Δφ)
//
//     ★ここで sin(Δφ) ≒ Δφ と近似している。この近似には条件がある。
//
//       Δφ = 2π × 75000 / fs        （75kHz は FM 放送の最大周波数偏移）
//
//         fs = 976560Hz → Δφ = 0.48 rad = 27.6°  ← 近似が成立する
//         fs = 244140Hz → Δφ = 1.93 rad = 110.6° ← 破綻する
//
//     90°を超えると sin は減少に転じるため、偏移が大きいほど出力が小さくなる
//     という逆転が起き、強く歪む。**IQ は高いレートのまま復調すること。**
//     （rtl_fm が 244140Hz でも平気なのは、近似ではなく atan2 を使っているため）
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
//     利得は (DECIM)³ になるので、最後に割り戻す（CIC_SHIFT で自動計算）。
//
//   【0. 復調の「前」の帯域制限（★重要）】
//     RTL-SDR が 976560Hz で受けると、帯域は ±488kHz ある。FM 放送が占めるのは
//     ±100kHz 程度なので、残りは全部ただの雑音として復調器に入ってくる。
//
//     かといって受信レートを下げると【1】の sin 近似が破綻する。
//     そこで **間引かずにフィルタだけ掛ける**。4点移動平均を I・Q それぞれに
//     3段かけると、244140Hz（= fs/4）にヌル点ができ、それより外を大きく落とせる。
//
//     加算とシフトだけで済み、乗算器は要らない。
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
    output wire               in_ready,   // FIR 計算中は 0（流量制御）

    // ---- 音声出力（間引き後）----
    output reg                out_valid,
    output reg  signed [15:0] out_data,

    // ---- 音量調整（PS から）----
    input  wire [7:0]         volume      // 復調後の増幅率（64で等倍）
);
    // 出力段の FIR が動いている間は新しい IQ を受け取らない（下で宣言）
    wire fir_busy;
    assign in_ready = ~fir_busy;

    // =========================================================================
    // 0. 復調の前の帯域制限（4点移動平均 × 3段）
    // =========================================================================
    //   ★間引かない。レートを保ったまま帯域だけ絞る。
    //     間引いてしまうと Δφ が大きくなり、上で説明した sin 近似が破綻する。
    //
    //   4点移動平均の周波数特性は sinc で、fs/4 = 244140Hz にヌル点を持つ。
    //   3段重ねると阻止域の落ちが3倍（dB で3倍）になる。
    //   各段の利得は 4 なので >>>2 して桁を戻す（16ビットのまま持てる）。
    //
    //   I と Q に同じ遅延が入るので、位相差には影響しない。
    reg signed [15:0] ia0, ia1, ia2, ia3;      // I 1段目の遅延線
    reg signed [15:0] ib0, ib1, ib2, ib3;      // I 2段目
    reg signed [15:0] ic0, ic1, ic2, ic3;      // I 3段目
    reg signed [15:0] qa0, qa1, qa2, qa3;      // Q 1段目
    reg signed [15:0] qb0, qb1, qb2, qb3;      // Q 2段目
    reg signed [15:0] qc0, qc1, qc2, qc3;      // Q 3段目

    wire signed [15:0] ia_out = (ia0 + ia1 + ia2 + ia3) >>> 2;
    wire signed [15:0] ib_out = (ib0 + ib1 + ib2 + ib3) >>> 2;
    wire signed [15:0] flt_i  = (ic0 + ic1 + ic2 + ic3) >>> 2;
    wire signed [15:0] qa_out = (qa0 + qa1 + qa2 + qa3) >>> 2;
    wire signed [15:0] qb_out = (qb0 + qb1 + qb2 + qb3) >>> 2;
    wire signed [15:0] flt_q  = (qc0 + qc1 + qc2 + qc3) >>> 2;

    // =========================================================================
    // 1. 位相差（外積）と 振幅の2乗（帯域制限した後の値を使う）
    // =========================================================================
    reg signed [15:0] prev_i, prev_q;

    wire signed [31:0] cross = prev_i * flt_q - prev_q * flt_i; // A² × sin(Δφ)
    wire        [31:0] mag2  = flt_i * flt_i + flt_q * flt_q;   // A²（常に非負）

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

    // CIC 利得 DECIM³ で割る → 音量を掛ける
    //   ★シフト量は DECIM から自動で決めること。
    //     以前は >>>13（＝÷8192、DECIM=20 専用）を直書きしていたため、
    //     DECIM を 5 に変えたときに 64 倍ずれた。
    //       DECIM=20 → 利得 8000 → $clog2 = 13
    //       DECIM=5  → 利得  125 → $clog2 =  7
    //     2の冪に丸めるので数%の誤差が出るが、音量レジスタで吸収できる。
    localparam integer CIC_GAIN  = DECIM * DECIM * DECIM;
    localparam integer CIC_SHIFT = $clog2(CIC_GAIN);

    wire signed [31:0] cic_scaled = d3 >>> CIC_SHIFT;
    wire signed [39:0] volumed    = cic_scaled * $signed({1'b0, volume});
    wire signed [31:0] pre_hp     = volumed >>> 6;      // volume=64 で等倍

    // =========================================================================
    // 5. 高域通過（30Hz より下を切る）
    // =========================================================================
    //   FM を復調した波形には直流成分と数Hz〜数十Hz のうねりが大きく乗る。
    //   実測（受信音を FFT）では 0〜300Hz だけで全パワーのほぼ全部を占めていた。
    //   これがゴロゴロという低域雑音になる。
    //
    //   1次の高域通過:  y[n] = x[n] - x[n-1] + a × y[n-1]
    //     a = exp(-2π × 30 / 48828) ≒ 0.99615 → ×65536 = 65283
    localparam signed [17:0] HP_A = 18'sd65283;
    reg signed [31:0] hp_x1, hp_y1;

    wire signed [49:0] hp_fb   = hp_y1 * HP_A;
    wire signed [31:0] hp_next = pre_hp - hp_x1 + (hp_fb >>> 16);

    // デエンファシス: y += (x - y) × 86 / 256
    wire signed [39:0] deemp_d    = (hp_next - deemp_y) * DEEMP_A;
    wire signed [31:0] deemp_next = deemp_y + (deemp_d >>> 8);

    // =========================================================================
    // 6. 低域通過 FIR（15kHz より上を切る、63タップ）
    // =========================================================================
    //   FM 放送には音声(〜15kHz)のほかに 19kHz のパイロット信号（ステレオ放送の
    //   目印）が乗っている。CIC だけでは 19kHz を -7dB 程度しか落とせず、
    //   20kHz 以上の折り返し成分も -12dB 程度しか落ちない。
    //
    //   実測（PL内蔵FFTで比較）では、このフィルタを持つ PS 側（radio.c）に対して
    //   PL 側は SN が 4.6dB 劣っていた。同じフィルタをここに載せて追いつかせる。
    //
    //   係数は窓関数法（sinc × ハミング窓）で設計し 32768 倍したもの（fir15k.hex）。
    //     13kHz 0dB / 15kHz -6dB / 17kHz -60dB / 19kHz -56dB
    //
    //   【計算のしかた】
    //     乗算器を 63 個並べるのは無駄なので、1 個を 63 クロック使い回す。
    //     出力は 48828Hz（= 2048 クロックに 1 回）なので余裕で間に合うが、
    //     DMA が IQ を連続で送ってくると間引き点の間隔が詰まる恐れがある。
    //     そのため計算中は in_ready を下げて DMA を待たせる（流量制御）。
    localparam integer LP_N = 63;
    reg signed [15:0] fir_z [0:LP_N-1];      // 遅延線
    reg signed [15:0] fir_h [0:LP_N-1];      // 係数
    initial $readmemh("fir15k.hex", fir_h);

    reg [6:0]         fir_i;                 // 何番目の係数を処理中か
    reg               fir_run;               // 積和の最中
    reg               fir_fin;               // 最後の加算が確定するのを待つ
    reg signed [39:0] fir_acc;

    assign fir_busy = fir_run | fir_fin;

    function signed [15:0] clip16(input signed [31:0] v);
        if      (v >  32'sd32767)  clip16 =  16'sd32767;
        else if (v < -32'sd32768)  clip16 = -16'sd32768;
        else                       clip16 =  v[15:0];
    endfunction

    integer zi;                              // 遅延線を回すためのループ変数

    always @(posedge clk) begin
        if (!rst_n) begin
            ia0 <= 16'sd0; ia1 <= 16'sd0; ia2 <= 16'sd0; ia3 <= 16'sd0;
            ib0 <= 16'sd0; ib1 <= 16'sd0; ib2 <= 16'sd0; ib3 <= 16'sd0;
            ic0 <= 16'sd0; ic1 <= 16'sd0; ic2 <= 16'sd0; ic3 <= 16'sd0;
            qa0 <= 16'sd0; qa1 <= 16'sd0; qa2 <= 16'sd0; qa3 <= 16'sd0;
            qb0 <= 16'sd0; qb1 <= 16'sd0; qb2 <= 16'sd0; qb3 <= 16'sd0;
            qc0 <= 16'sd0; qc1 <= 16'sd0; qc2 <= 16'sd0; qc3 <= 16'sd0;
            prev_i     <= 16'sd0;
            prev_q     <= 16'sd0;
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
            fir_i      <= 7'd0;
            fir_run    <= 1'b0;
            fir_fin    <= 1'b0;
            fir_acc    <= 40'sd0;
            for (zi = 0; zi < LP_N; zi = zi + 1) fir_z[zi] <= 16'sd0;
            out_valid  <= 1'b0;
            out_data   <= 16'sd0;
        end else begin
            out_valid <= 1'b0;          // 既定は無効

            // ---- 低域通過 FIR の積和（1クロックに1タップずつ）----
            if (fir_run) begin
                fir_acc <= fir_acc + $signed(fir_h[fir_i]) * $signed(fir_z[fir_i]);
                if (fir_i == LP_N - 1) begin
                    fir_run <= 1'b0;
                    fir_fin <= 1'b1;    // 最後の加算は次のクロックで確定する
                end else begin
                    fir_i <= fir_i + 7'd1;
                end
            end else if (fir_fin) begin
                fir_fin   <= 1'b0;
                out_data  <= clip16(fir_acc >>> 15);   // 係数は 32768 倍してある
                out_valid <= 1'b1;
            end

            if (in_valid) begin
                // ---- 帯域制限（4点移動平均 × 3段）----
                //   各段の遅延線を1つずつ送る。段の間に1クロック遅れが入るが、
                //   I と Q で同じなので位相差には影響しない。
                ia0 <= in_i;   ia1 <= ia0; ia2 <= ia1; ia3 <= ia2;
                ib0 <= ia_out; ib1 <= ib0; ib2 <= ib1; ib3 <= ib2;
                ic0 <= ib_out; ic1 <= ic0; ic2 <= ic1; ic3 <= ic2;
                qa0 <= in_q;   qa1 <= qa0; qa2 <= qa1; qa3 <= qa2;
                qb0 <= qa_out; qb1 <= qb0; qb2 <= qb1; qb3 <= qb2;
                qc0 <= qb_out; qc1 <= qc0; qc2 <= qc1; qc3 <= qc2;

                prev_i <= flt_i;
                prev_q <= flt_q;

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

                    // ---- 高域通過 → デエンファシス ----
                    hp_x1   <= pre_hp;
                    hp_y1   <= hp_next;
                    deemp_y <= deemp_next;

                    // ---- 低域通過 FIR へ渡して計算を始める ----
                    //   遅延線を1つ送り、先頭に今回の標本を入れる。
                    for (zi = LP_N - 1; zi > 0; zi = zi - 1)
                        fir_z[zi] <= fir_z[zi - 1];
                    fir_z[0] <= clip16(deemp_next);

                    fir_i   <= 7'd0;
                    fir_acc <= 40'sd0;
                    fir_run <= 1'b1;
                end else begin
                    cnt <= cnt + 8'd1;
                end
            end
        end
    end
endmodule
