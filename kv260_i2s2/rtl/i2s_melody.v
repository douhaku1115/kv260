// -----------------------------------------------------------------------------
// i2s_melody.v -- 段3: メロディ再生 (Pmod I2S2 / CS4344 DAC)
//   i2s_tx.v(固定762Hzトーン)を拡張し、音階を切り替えてメロディを鳴らす。
//
//   mclk : 12.5 MHz (= 256 x fs), fs = 12.5MHz/256 = 48828.125 Hz
//   出力  : sclk=mclk/4, lrck=mclk/256(fs), sdout=標準I2S 16bit (L/R同一=モノ)
//
// 【固定トーンからの変更点】
//   旧: phase を1フレームごとに+1 → 周波数は fs/64 固定(762Hz)
//   新: 24bit 位相アキュムレータに音ごとの PHASE_INC を毎サンプル加算
//       → 上位6bitで64点サインLUTを読む。任意の音階が出せる
//       freq = fs * PHASE_INC / 2^24   (PHASE_INC = freq * 343.597)
//
// 【シーケンサ】
//   NOTE_LEN サンプルごとに次の音へ進む(16音でループ)。曲: きらきら星の前半
// -----------------------------------------------------------------------------
module i2s_melody #(
    parameter integer DW       = 16,        // データビット幅
    parameter integer NOTE_LEN = 12000      // 1音の長さ[サンプル] (≒0.25秒 @48.8kHz)
)(
    input  wire mclk,                       // 12.5 MHz (clk_wiz clk_out1)
    input  wire rst_n,                      // clk_wiz locked (Highで動作)
    output wire mclk_o,                     // DACへのMCLK
    output reg  sclk,                       // ビットクロック
    output reg  lrck,                       // ワードセレクト(L=0/R=1)
    output reg  sdout                       // I2Sシリアルデータ
);
    // ---- フレームカウンタ: 256 mclk = 1 サンプル周期(fs) ----
    reg [7:0] c;
    always @(posedge mclk or negedge rst_n)
        if (!rst_n) c <= 8'd0;
        else        c <= c + 8'd1;

    wire sample_tick = (c == 8'hFF);        // 1サンプルごとに1回
    wire [5:0] bi = c[7:2];                 // フレーム内ビット位置 0..63
    wire [4:0] cb = bi[4:0];                // チャンネル内ビット位置 0..31

    // ---- 音階テーブル: PHASE_INC = freq * 2^24 / fs  (fs=48828.125) ----
    //   0:ド(C4) 1:レ(D4) 2:ミ(E4) 3:ファ(F4) 4:ソ(G4) 5:ラ(A4) 6:シ(B4) 7:ド(C5)
    function [23:0] note_inc(input [2:0] n);
        case (n)
            3'd0: note_inc = 24'd89893;     // C4 261.63Hz
            3'd1: note_inc = 24'd100902;    // D4 293.66Hz
            3'd2: note_inc = 24'd113258;    // E4 329.63Hz
            3'd3: note_inc = 24'd119994;    // F4 349.23Hz
            3'd4: note_inc = 24'd134687;    // G4 392.00Hz
            3'd5: note_inc = 24'd151183;    // A4 440.00Hz
            3'd6: note_inc = 24'd169696;    // B4 493.88Hz
            3'd7: note_inc = 24'd179787;    // C5 523.25Hz
        endcase
    endfunction

    // ---- 曲データ: きらきら星 前半16音 ----
    //   ドド ソソ ララ ソ(伸) / ファファ ミミ レレ ド(伸)
    function [2:0] melody(input [3:0] step);
        case (step)
            4'd0 : melody = 3'd0;   // ド
            4'd1 : melody = 3'd0;   // ド
            4'd2 : melody = 3'd4;   // ソ
            4'd3 : melody = 3'd4;   // ソ
            4'd4 : melody = 3'd5;   // ラ
            4'd5 : melody = 3'd5;   // ラ
            4'd6 : melody = 3'd4;   // ソ
            4'd7 : melody = 3'd4;   // ソ(伸ばし)
            4'd8 : melody = 3'd3;   // ファ
            4'd9 : melody = 3'd3;   // ファ
            4'd10: melody = 3'd2;   // ミ
            4'd11: melody = 3'd2;   // ミ
            4'd12: melody = 3'd1;   // レ
            4'd13: melody = 3'd1;   // レ
            4'd14: melody = 3'd0;   // ド
            4'd15: melody = 3'd0;   // ド(伸ばし)
        endcase
    endfunction

    // ---- シーケンサ: NOTE_LEN サンプルごとに次の音へ ----
    reg [15:0] note_cnt;                    // 音の経過サンプル数
    reg [3:0]  step;                        // 曲の何音目か(16音でループ)
    always @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            note_cnt <= 16'd0;
            step     <= 4'd0;
        end else if (sample_tick) begin
            if (note_cnt >= NOTE_LEN[15:0] - 1) begin
                note_cnt <= 16'd0;
                step     <= step + 4'd1;    // 16音で自動的に周回
            end else begin
                note_cnt <= note_cnt + 16'd1;
            end
        end
    end

    // ---- NCO: 24bit位相アキュムレータ。毎サンプル PHASE_INC を加算 ----
    reg [23:0] phase_acc;
    always @(posedge mclk or negedge rst_n) begin
        if (!rst_n)           phase_acc <= 24'd0;
        else if (sample_tick) phase_acc <= phase_acc + note_inc(melody(step));
    end

    // ---- サイン波LUT(64点,16bit符号付き)を上位6bitで読む ----
    reg signed [15:0] sine [0:63];
    initial $readmemh("sine_lut.hex", sine);

    reg signed [15:0] sample;
    always @(posedge mclk)
        if (sample_tick) sample <= sine[phase_acc[23:18]];

    // ---- I2S直列化: WSエッジの1SCLK後にMSB。cb=1→MSB ... cb=DW→LSB ----
    reg sd;
    always @(*) begin
        if (cb >= 5'd1 && cb <= DW[4:0])
            sd = sample[DW-1 - (cb - 5'd1)];
        else
            sd = 1'b0;
    end

    // ---- 出力レジスタ(全てmclk同期) ----
    always @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            sclk  <= 1'b0;
            lrck  <= 1'b0;
            sdout <= 1'b0;
        end else begin
            sclk  <= c[1];                  // mclk/4
            lrck  <= c[7];                  // mclk/256
            sdout <= sd;
        end
    end

    // ---- MCLKをピンへクリーン転送 ----
    ODDRE1 #(.SRVAL(1'b0)) u_mclk_oddr (
        .Q  (mclk_o),
        .C  (mclk),
        .D1 (1'b1),
        .D2 (1'b0),
        .SR (1'b0)
    );
endmodule
