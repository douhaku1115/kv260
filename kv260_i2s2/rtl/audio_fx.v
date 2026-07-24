// -----------------------------------------------------------------------------
// audio_fx.v -- PL でのリアルタイム音声加工（音量・エコー）
//
//   tick（1サンプル=左右1組ごと）で処理する：
//     1. 音量:   in * GAIN >> 6      （GAIN=64 で等倍）
//     2. エコー: BRAM ディレイライン（約0.25秒）から遅延音を読み、
//                delayed * ECHO >> 8 を足す。結果を書き戻すので
//                フィードバックがかかり、減衰しながら繰り返す（リバーブ風）
//     3. 16ビット飽和して出力
//
//   左右を32ビットにまとめて1段に置く（[31:16]=左, [15:0]=右）。
//   BRAM は同期読み出しなので、tick から数クロックかけて 読み→計算→書き戻し
//   する（サンプル周期256クロックに対して十分間に合う）。
// -----------------------------------------------------------------------------
module audio_fx #(
    parameter integer AW = 14,          // ディレイ用BRAMアドレス幅（16384段）
    parameter integer D  = 12207        // 遅延サンプル数（0.25秒 @ 48828Hz）
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,     // 左右1組ごとに1クロック
    input  wire signed [15:0] in_l,
    input  wire signed [15:0] in_r,
    input  wire        [7:0]  gain,     // 音量（64で等倍）
    input  wire        [7:0]  echo,     // エコー量（0で無効）
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

    // 音量: in * gain（gain は 0〜255 の正の重み）
    wire signed [24:0] vl = hl * $signed({1'b0, gain});
    wire signed [24:0] vr = hr * $signed({1'b0, gain});
    // エコー: delayed * echo
    wire signed [24:0] el = dl * $signed({1'b0, echo});
    wire signed [24:0] er = dr * $signed({1'b0, echo});
    // 合成（音量は >>6 で等倍基準、エコーは >>8 でフィードバック係数<1）
    wire signed [31:0] yl_raw = (vl >>> 6) + (el >>> 8);
    wire signed [31:0] yr_raw = (vr >>> 6) + (er >>> 8);

    function signed [15:0] clip16(input signed [31:0] v);
        if      (v >  32767) clip16 =  16'sd32767;
        else if (v < -32768) clip16 = -16'sd32768;
        else                 clip16 =  v[15:0];
    endfunction

    wire signed [15:0] yl = clip16(yl_raw);
    wire signed [15:0] yr = clip16(yr_raw);

    always @(posedge clk) begin
        if (!rst_n) begin
            wptr  <= {AW{1'b0}};
            st    <= 2'd0;
            out_l <= 16'sd0;
            out_r <= 16'sd0;
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
