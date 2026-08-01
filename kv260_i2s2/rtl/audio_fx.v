// -----------------------------------------------------------------------------
// audio_fx.v -- PL でのリアルタイム音声加工（音量・イコライザ・歪み・エコー）
//
//   tick（1サンプル=左右1組ごと）で、次の順に処理する：
//     1. 音量:       in * GAIN >> 6            （GAIN=64 で等倍）
//     2. イコライザ: 低音 * BASS + 高音 * TREBLE（各 64 で等倍）
//     3. 歪み:       DIST で決まる高さで頭を切る（0 で無効）
//     4. エコー:     BRAM ディレイライン（約0.25秒）の遅延音を足す。
//                    結果を書き戻すのでフィードバックがかかり、減衰しながら繰り返す
//     5. 16ビット飽和して出力
//
//   【イコライザの作り】
//     1次ローパス（1極 IIR）で低音成分を取り出す：
//       lp += (in - lp) >> K      ← K が大きいほど低い周波数だけ残る
//     高音成分は「元の音 − 低音成分」で得られる。両者を別々の倍率で混ぜ直す。
//     K=5 のとき遮断周波数 ≒ 48828/(2π*32) ≒ 243Hz。
//
//   【歪み(ディストーション)の作り】
//     一定の高さで波形の頭を切る（クリップ）。切った分が高調波になり歪んだ音になる。
//     切る高さ = 32767 >> (DIST の強さ)。DIST=0 で無効（切らない）。
//
//   左右を32ビットにまとめて1段に置く（[31:16]=左, [15:0]=右）。
//   BRAM は同期読み出しなので、tick から数クロックかけて 読み→計算→書き戻しする
//   （サンプル周期256クロックに対して十分間に合う）。
// -----------------------------------------------------------------------------
module audio_fx #(
    parameter integer AW = 14,          // ディレイ用BRAMアドレス幅（16384段）
    parameter integer D  = 12207,       // 遅延サンプル数（0.25秒 @ 48828Hz）
    parameter integer K  = 5            // ローパスの係数（遮断 ≒ 243Hz）
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,     // 左右1組ごとに1クロック
    input  wire signed [15:0] in_l,
    input  wire signed [15:0] in_r,
    input  wire        [7:0]  gain,     // 音量（64で等倍）
    input  wire        [7:0]  echo,     // エコー量（0で無効）
    input  wire        [7:0]  bass,     // 低音の強さ（64で等倍）
    input  wire        [7:0]  treble,   // 高音の強さ（64で等倍）
    input  wire        [7:0]  dist,     // 歪み（0で無効、大きいほど強い）
    output reg  signed [15:0] out_l,
    output reg  signed [15:0] out_r
);
    localparam [AW-1:0] DLY = D[AW-1:0];

    // ディレイライン（左右を32ビットにまとめて1段に）
    (* ram_style = "block" *) reg [31:0] mem [0:(1<<AW)-1];
    integer ii;
    initial for (ii = 0; ii < (1<<AW); ii = ii + 1) mem[ii] = 32'd0;  // 初期ノイズ防止
    reg [AW-1:0] wptr;                  // 書き込み位置
    reg [AW-1:0] raddr;
    reg [31:0]   rdata;
    reg [1:0]    st;
    reg signed [15:0] hl, hr;          // 入力ホールド

    wire signed [15:0] dl = rdata[31:16];
    wire signed [15:0] dr = rdata[15:0];

    // 16ビットに飽和（使う前に定義しておく）
    function signed [15:0] clip16(input signed [31:0] v);
        if      (v >  32767) clip16 =  16'sd32767;
        else if (v < -32768) clip16 = -16'sd32768;
        else                 clip16 =  v[15:0];
    endfunction

    // 指定の高さで頭を切る（歪み用）
    function signed [15:0] clipdist(input signed [15:0] v, input signed [15:0] l);
        if      (v >  l) clipdist =  l;
        else if (v < -l) clipdist = -l;
        else             clipdist =  v;
    endfunction

    // ---- 1. 音量: in * gain（gain は 0〜255 の正の重み）----
    wire signed [24:0] vl = hl * $signed({1'b0, gain});
    wire signed [24:0] vr = hr * $signed({1'b0, gain});
    wire signed [15:0] gl = clip16(vl >>> 6);   // 音量適用後（16ビットに戻す）
    wire signed [15:0] gr = clip16(vr >>> 6);

    // ---- 2. イコライザ: 1次ローパスで低音を取り出し、残りを高音とする ----
    reg signed [15:0] lp_l, lp_r;               // 低音成分（1極 IIR の状態）
    wire signed [15:0] hi_l = gl - lp_l;        // 高音成分 = 元 − 低音
    wire signed [15:0] hi_r = gr - lp_r;
    // 低音×BASS + 高音×TREBLE（各 >>6 で等倍基準）
    wire signed [24:0] bl = lp_l * $signed({1'b0, bass});
    wire signed [24:0] br = lp_r * $signed({1'b0, bass});
    wire signed [24:0] tl = hi_l * $signed({1'b0, treble});
    wire signed [24:0] tr = hi_r * $signed({1'b0, treble});
    wire signed [15:0] el_eq = clip16((bl >>> 6) + (tl >>> 6));
    wire signed [15:0] er_eq = clip16((br >>> 6) + (tr >>> 6));

    // ---- 3. 歪み: 一定の高さで頭を切る ----
    //   切る高さ = 32767 >> dist_sh。dist=0 なら切らない
    wire [3:0] dist_sh = dist[7:4];             // 0〜15 段階
    wire signed [15:0] lim = 16'sd32767 >>> dist_sh;
    // 切ったあと元の大きさに戻す（音量が落ちないように）
    wire signed [31:0] dl_raw = (dist == 8'd0) ? el_eq : (clipdist(el_eq, lim) <<< dist_sh);
    wire signed [31:0] dr_raw = (dist == 8'd0) ? er_eq : (clipdist(er_eq, lim) <<< dist_sh);
    wire signed [15:0] dl_out = clip16(dl_raw);
    wire signed [15:0] dr_out = clip16(dr_raw);

    // ---- 4. エコー: delayed * echo を足す（>>8 でフィードバック係数<1）----
    wire signed [24:0] ecl = dl * $signed({1'b0, echo});
    wire signed [24:0] ecr = dr * $signed({1'b0, echo});
    wire signed [31:0] yl_raw = dl_out + (ecl >>> 8);
    wire signed [31:0] yr_raw = dr_out + (ecr >>> 8);

    wire signed [15:0] yl = clip16(yl_raw);
    wire signed [15:0] yr = clip16(yr_raw);

    always @(posedge clk) begin
        if (!rst_n) begin
            wptr  <= {AW{1'b0}};
            st    <= 2'd0;
            out_l <= 16'sd0;
            out_r <= 16'sd0;
            lp_l  <= 16'sd0;
            lp_r  <= 16'sd0;
        end else begin
            case (st)
                2'd0: if (tick) begin
                    hl    <= in_l;
                    hr    <= in_r;
                    raddr <= wptr - DLY;         // D前（過去）を読む。自然にwrap
                    st    <= 2'd1;
                end
                2'd1: begin
                    rdata <= mem[raddr];         // BRAM 同期読み出し
                    st    <= 2'd2;
                end
                2'd2: begin
                    // ローパス更新: lp += (gain適用後 - lp) >> K
                    lp_l      <= lp_l + ((gl - lp_l) >>> K);
                    lp_r      <= lp_r + ((gr - lp_r) >>> K);
                    out_l     <= yl;
                    out_r     <= yr;
                    mem[wptr] <= {yl, yr};       // フィードバック保存
                    wptr      <= wptr + 1'b1;
                    st        <= 2'd0;
                end
                default: st <= 2'd0;
            endcase
        end
    end
endmodule
