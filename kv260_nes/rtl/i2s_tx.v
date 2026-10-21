// -----------------------------------------------------------------------------
// i2s_tx.v  -- 段1: 固定トーン I2S 送信 (Pmod I2S2 / CS4344 DAC 用)
//   mclk      : 12.5 MHz マスタクロック (= 256 x fs, fs≒48.83kHz)
//   mclk_o    : DACへ転送するMCLK (ODDRE1でクリーンに出力)
//   出力       : sclk=mclk/4(3.125MHz), lrck=mclk/256(fs), sdout=標準I2S(16bit)
//   サイン波   : 64エントリLUTをNCOで読み出し → トーン ≒ fs/64 ≒ 762Hz
//   L/R 同一サンプル(モノ)を両チャンネルに出力
//   ※ Block Design に Module Reference として取り込み、BDラッパをトップにする
// -----------------------------------------------------------------------------
module i2s_tx #(
    parameter integer DW = 16          // データビット幅
)(
    input  wire mclk,                  // 12.5 MHz (clk_wiz clk_out1)
    input  wire rst_n,                 // clk_wiz locked (Highで動作)
    output wire mclk_o,                // DACへのMCLK
    output reg  sclk,                  // ビットクロック
    output reg  lrck,                  // ワードセレクト(L=0/R=1)
    output reg  sdout                  // I2Sシリアルデータ
);
    // フレームカウンタ: 256 mclk = 1 サンプル周期(fs)
    reg [7:0] c;
    always @(posedge mclk or negedge rst_n)
        if (!rst_n) c <= 8'd0;
        else        c <= c + 8'd1;

    wire [5:0] bi = c[7:2];            // フレーム内ビット位置 0..63
    wire [4:0] cb = bi[4:0];           // チャンネル内ビット位置 0..31

    // NCO: 1フレームごとに位相を1進める
    reg [5:0] phase;
    always @(posedge mclk or negedge rst_n)
        if (!rst_n)          phase <= 6'd0;
        else if (c == 8'hFF) phase <= phase + 6'd1;

    // サイン波LUT(16bit符号付き)
    reg signed [15:0] sine [0:63];
    initial $readmemh("sine_lut.hex", sine);

    // フレーム頭でサンプル確定
    reg signed [15:0] sample;
    always @(posedge mclk)
        if (c == 8'hFF) sample <= sine[phase];

    // I2S直列化: WSエッジの1SCLK後にMSB。cb=1→MSB ... cb=DW→LSB、残りは0
    reg sd;
    always @(*) begin
        if (cb >= 5'd1 && cb <= DW[4:0])
            sd = sample[DW-1 - (cb - 5'd1)];
        else
            sd = 1'b0;
    end

    // 出力レジスタ(全てmclk同期。データはSCLK立下りでのみ変化しDACは立上りで取込)
    always @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            sclk  <= 1'b0;
            lrck  <= 1'b0;
            sdout <= 1'b0;
        end else begin
            sclk  <= c[1];            // mclk/4
            lrck  <= c[7];            // mclk/256
            sdout <= sd;
        end
    end

    // MCLKをピンへクリーン転送 (UltraScale+ クロック出力プリミティブ)
    ODDRE1 #(.SRVAL(1'b0)) u_mclk_oddr (
        .Q  (mclk_o),
        .C  (mclk),
        .D1 (1'b1),
        .D2 (1'b0),
        .SR (1'b0)
    );
endmodule
