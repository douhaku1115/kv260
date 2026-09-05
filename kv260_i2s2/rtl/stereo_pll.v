`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// stereo_pll.v -- FM ステレオ用 19kHz パイロット PLL
//
//   FM 復調した直後の信号（MPX）から 19kHz のパイロット信号を捕まえ、
//   位相を合わせた 38kHz を作る。ステレオ復調の心臓部。
//
//   【MPX の中身】
//      0〜15kHz : L+R（モノラル互換の主音声）
//         19kHz : パイロット信号（振幅は全偏移の 9〜10%）
//     23〜53kHz : L−R（38kHz の抑圧搬送波 DSB-SC）
//
//   38kHz そのものは送信されていない。受信側で作り直す必要がある。
//
//   【なぜ PLL でなければいけないか】
//     再生する 38kHz の位相が θ ずれると、取り出せる L−R の振幅が cos θ 倍に
//     なる。θ=60° で半分、θ=90° で完全に消える。分離度[dB] ≒ 20log10(tan θ)
//     なので、-40dB を出すには 38kHz の位相誤差を 0.57° 以内に抑える必要が
//     ある。19kHz 側ではその半分の 0.29°。帯域通過＋2逓倍では届かない精度な
//     ので、パイロットに位相ロックさせる。
//
//   【位相検出（誤差の作り方）】
//     パイロットを Ap*cos(θp) とし、NCO の位相を θn とすると
//       pd_i = MPX × cos(θn) → LPF → (Ap/2)*cos(θn−θp)
//       pd_q = MPX × sin(θn) → LPF → (Ap/2)*sin(θn−θp)
//     この2つの比 pd_q / pd_i = tan(位相誤差) が誤差信号になる。
//
//     ★割り算をする理由（重要）
//       pd_q だけを誤差に使うと、誤差に Ap（受信強度）が掛かったまま残る。
//       電界強度が変わるとループ利得が変わり、強電界で発振し弱電界で外れる。
//       pd_i で割ると振幅が消えて tan だけが残り、利得が受信強度に依らなくなる。
//       割り算は fm_demod.v と同じ「2の冪 × 上位4ビット」近似で行う。
//
//     ★180°の曖昧さは無害
//       tan は π 周期なので θn が θp から 180° ずれた点でもロックする。
//       だが 38kHz 側では 2 倍されて 360°＝ずれ無しになるので、実害はない。
//
//   【位相検出後の LPF を 3 段にする理由】
//     MPX の L−R 成分（23〜53kHz）が NCO の 19kHz と混ざると 4〜34kHz に落ちる。
//     L−R はパイロットより 10dB 以上大きいことがあるので、1段（-22dB @4kHz）
//     では取り切れず位相雑音になる。3段なら -66dB。
//
//   【ループフィルタ（PI 制御）】
//     inc = STEP0 + 積分項 − (誤差 << KP_SHIFT)
//     誤差が正（NCO が進みすぎ）なら周波数を下げる、の意味。
//     KP_SHIFT=2 で閉ループ帯域 29.8Hz、KI_SHIFT=4 で減衰係数 ζ=0.89。
//     RTL-SDR の水晶誤差は数十ppm なので 19kHz のずれは 1Hz 未満、
//     この帯域で十分引き込める（定数は gen_nco_lut.py が算出）。
//
//   【38kHz の作り方】
//     表をもう一度引かずに倍角公式で作る:  cos2θ = cos²θ − sin²θ
//     乗算器 2 個で済み、ROM の複製が要らない。
// -----------------------------------------------------------------------------
module stereo_pll #(
    parameter integer ACC_W     = 32,           // 位相アキュムレータの幅
    parameter integer NCO_STEP0 = 83563098,     // 19kHz ぶんの位相増分 @976560Hz
    parameter integer KP_SHIFT  = 2,            // 比例ゲイン（誤差 << KP_SHIFT）
    parameter integer KI_SHIFT  = 4,            // 積分ゲイン（誤差 >> KI_SHIFT）
    parameter integer LPF_SHIFT = 9,            // 位相検出後の LPF（約300Hz）
    parameter integer PILOT_TH  = 400,          // パイロット有無のしきい値
    parameter integer LOCK_HOLD = 32768         // ロック判定までの継続サンプル数
)(
    input  wire               clk,
    input  wire               rst_n,

    input  wire               sample_valid,     // MPX が1標本来た
    input  wire signed [17:0] mpx,              // FM 復調直後の信号

    output wire signed [15:0] cos38,            // 位相の合った 38kHz（Q15）
    output reg                locked,           // パイロットを捕まえている
    output wire signed [31:0] pilot_level,      // パイロットの強さ（調整用）
    output wire signed [31:0] pilot_quad        // 直交成分（位相が合っていれば 0）
);
    // =========================================================================
    // NCO（数値制御発振器）
    // =========================================================================
    //   位相アキュムレータの上位10ビットで 1024 点のサイン表を引く。
    //   cos は添字を +256（=90°）ずらして同じ表を使う。
    //   位相の量子化は 360/1024 = 0.35°、38kHz 側で 0.70° 相当だが、
    //   これは分周ではなく丸め誤差なので分離度への影響は -50dB 以下。
    localparam integer LUT_W = 10;
    localparam integer LUT_N = 1 << LUT_W;

    reg signed [15:0] lut [0:LUT_N-1];
    initial $readmemh("nco_sin.hex", lut);

    reg [ACC_W-1:0]   phase;
    reg signed [31:0] freq_q8;                  // 周波数の補正量（Q8 固定小数点）

    wire [LUT_W-1:0] idx_sin = phase[ACC_W-1 -: LUT_W];
    wire [LUT_W-1:0] idx_cos = idx_sin + (LUT_N / 4);

    wire signed [15:0] nco_sin = lut[idx_sin];
    wire signed [15:0] nco_cos = lut[idx_cos];

    // 倍角公式で 38kHz を作る: cos2θ = cos²θ − sin²θ
    wire signed [32:0] cc    = nco_cos * nco_cos;
    wire signed [32:0] ss    = nco_sin * nco_sin;
    wire signed [32:0] cos38_wide = (cc - ss) >>> 15;
    assign cos38 = (cos38_wide >  33'sd32767) ?  16'sd32767 :
                   (cos38_wide < -33'sd32768) ? -16'sd32768 :
                                                 cos38_wide[15:0];

    // =========================================================================
    // 位相検出（MPX と NCO の掛け算 → 3段 LPF）
    // =========================================================================
    wire signed [33:0] mul_i = mpx * nco_cos;
    wire signed [33:0] mul_q = mpx * nco_sin;
    wire signed [31:0] pd_i  = mul_i >>> 15;
    wire signed [31:0] pd_q  = mul_q >>> 15;

    // ★LPF の状態は小数部 FRAC ビットを付けて持つ（重要）
    //
    //   1次 LPF を素朴に  y += (x - y) >>> LPF_SHIFT  と書くと、
    //   差が 2^LPF_SHIFT 未満のとき右シフトの結果が 0 になり、y が全く育たない。
    //   パイロットの相関出力は (Ap/2) ≒ 1638 しかないのに LPF_SHIFT=9 では
    //   刻みが 512 なので、実際に値がゼロのまま張り付いた（最初の実装の不具合）。
    //
    //   入力を <<< FRAC してから積分すれば、刻みは 2^-12 相当になり潰れない。
    //   出力を使うときに >>> FRAC で戻す。誤差の割り算では分子分母とも同じ
    //   Q12 なので、戻さずそのまま比を取ってよい（そのほうが精度が良い）。
    localparam integer FRAC = 12;

    reg signed [39:0] i1f, i2f, i3f;
    reg signed [39:0] q1f, q2f, q3f;

    // =========================================================================
    // 誤差の正規化: e = q3 / i3 を Q15 で求める（fm_demod.v と同じ近似）
    // =========================================================================
    function [5:0] msb_pos(input [39:0] v);
        integer b;
        begin
            msb_pos = 6'd0;
            for (b = 0; b < 40; b = b + 1)
                if (v[b]) msb_pos = b[5:0];
        end
    endfunction

    wire signed [39:0] i3_abs_s = (i3f < 0) ? -i3f : i3f;
    wire signed [39:0] q3_abs_s = (q3f < 0) ? -q3f : q3f;
    wire [39:0]        i3_abs   = i3_abs_s;

    wire [5:0] k    = msb_pos(i3_abs);
    wire [5:0] ksh  = (k > 6'd3) ? (k - 6'd3) : 6'd0;
    wire [3:0] top4 = (k > 6'd3) ? i3_abs[ksh +: 4] : i3_abs[3:0];

    reg [12:0] recip;                           // 32768 / top4
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

    wire signed [52:0] e_mul = q3f * $signed({1'b0, recip});
    wire signed [52:0] e_shf = e_mul >>> ksh;
    wire signed [52:0] e_sgn = (i3f < 0) ? -e_shf : e_shf;  // i3 の符号を付ける

    // ±1.0（Q15 の 32768）に制限する。
    //   引き込み中は i3 が 0 を横切り tan が発散するので、必ず要る。
    //   さらに i3 が極小（信号なし）のときは誤差を 0 にして暴走を防ぐ。
    //   しきい値 1<<FRAC は Q12 で 1.0、つまり相関出力が 1 未満なら無信号扱い。
    wire e_valid = (i3_abs > (40'd1 <<< FRAC));
    wire signed [17:0] e =
        (!e_valid)             ?  18'sd0     :
        (e_sgn >  53'sd32767)  ?  18'sd32767 :
        (e_sgn < -53'sd32768)  ? -18'sd32768 :
                                  e_sgn[17:0];

    // =========================================================================
    // ループフィルタ（PI）
    // =========================================================================
    localparam signed [31:0] FREQ_CLAMP = 32'sd536870912;   // ±約476Hz 相当

    wire signed [31:0] freq_next_raw = freq_q8 - (e >>> KI_SHIFT);
    wire signed [31:0] freq_next =
        (freq_next_raw >  FREQ_CLAMP) ?  FREQ_CLAMP :
        (freq_next_raw < -FREQ_CLAMP) ? -FREQ_CLAMP : freq_next_raw;

    wire signed [31:0] inc = $signed(NCO_STEP0) + (freq_q8 >>> 8) - (e <<< KP_SHIFT);

    // =========================================================================
    // パイロットの有無（ロック検出）
    // =========================================================================
    //   位相に依らない大きさが要るので |i3| と |q3| から複素振幅を近似する。
    //     mag ≒ max + min/2   （誤差 ±5% 程度）
    //   こちらも Q12 のまま計算する（>>>12 の刻みで潰れないように）。
    wire signed [39:0] mx  = (i3_abs_s > q3_abs_s) ? i3_abs_s : q3_abs_s;
    wire signed [39:0] mn  = (i3_abs_s > q3_abs_s) ? q3_abs_s : i3_abs_s;
    wire signed [39:0] mag = mx + (mn >>> 1);

    reg signed [39:0] amp_f;                    // 遅い LPF（ちらつき防止、Q12）
    reg [31:0]        hold;                     // しきい値超えの継続数

    assign pilot_level = amp_f >>> FRAC;

    // ---- 実機での切り分け用 ----
    //   pilot_quad は位相検出の直交成分 (Ap/2)*sin(位相誤差)。
    //   ロックしていれば 0 付近になる。pilot_level を i とすれば
    //     位相誤差 = atan(pilot_quad / pilot_level)
    //   で度数に直せる。38kHz 側ではその 2 倍が効く。
    //   ★これが 0 付近なのに音が広がらないなら、位相ではなく振幅の問題。
    assign pilot_quad = q3f >>> FRAC;

    // ヒステリシス: 立ち上がりは PILOT_TH、外れるのは その 3/4
    wire signed [39:0] th_hi = $signed(PILOT_TH)             <<< FRAC;
    wire signed [39:0] th_lo = $signed((PILOT_TH * 3) / 4)   <<< FRAC;
    wire above = (amp_f > th_hi);
    wire below = (amp_f < th_lo);

    always @(posedge clk) begin
        if (!rst_n) begin
            phase   <= {ACC_W{1'b0}};
            freq_q8 <= 32'sd0;
            i1f <= 40'sd0; i2f <= 40'sd0; i3f <= 40'sd0;
            q1f <= 40'sd0; q2f <= 40'sd0; q3f <= 40'sd0;
            amp_f   <= 40'sd0;
            hold    <= 32'd0;
            locked  <= 1'b0;
        end else if (sample_valid) begin
            // ---- 位相検出後の 1次 LPF を 3 段（状態は Q12）----
            i1f <= i1f + (((pd_i <<< FRAC) - i1f) >>> LPF_SHIFT);
            i2f <= i2f + ((i1f - i2f) >>> LPF_SHIFT);
            i3f <= i3f + ((i2f - i3f) >>> LPF_SHIFT);
            q1f <= q1f + (((pd_q <<< FRAC) - q1f) >>> LPF_SHIFT);
            q2f <= q2f + ((q1f - q2f) >>> LPF_SHIFT);
            q3f <= q3f + ((q2f - q3f) >>> LPF_SHIFT);

            // ---- NCO を進める ----
            phase   <= phase + inc[ACC_W-1:0];
            freq_q8 <= freq_next;

            // ---- パイロットの強さ ----
            amp_f <= amp_f + ((mag - amp_f) >>> 12);

            // ---- ロック判定 ----
            //   しきい値を LOCK_HOLD サンプル続けて超えたらロックとみなす。
            //   PLL が落ち着くまでの時間（帯域 30Hz なら数十ms）も兼ねる。
            if (below) begin
                hold   <= 32'd0;
                locked <= 1'b0;
            end else if (above) begin
                if (hold >= LOCK_HOLD) locked <= 1'b1;
                else                   hold   <= hold + 32'd1;
            end
        end
    end
endmodule
