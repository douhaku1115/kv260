// -----------------------------------------------------------------------------
// i2s_tx.v  -- I2S 送信 (Pmod I2S2 / CS4344 DAC 用)
//   mclk      : 12.5 MHz マスタクロック (= 256 x fs, fs≒48.83kHz)
//   mclk_o    : DACへ転送するMCLK (ODDRE1でクリーンに出力)
//   出力       : sclk=mclk/4(3.125MHz), lrck=mclk/256(fs), sdout=標準I2S(16bit)
//   ext_sample: 送るサンプル (mclk 側で安定した値。フレーム頭で取り込む)
//   L/R 同一サンプル(モノ)を両チャンネルに出力
//   (NES 段A までは内部のサイン波を鳴らしていた。段F から APU の音を外から入れる)
//   ※ Block Design に Module Reference として取り込み、BDラッパをトップにする
// -----------------------------------------------------------------------------
module i2s_tx #(
    parameter integer DW = 16          // データビット幅
)(
    input  wire mclk,                  // 12.5 MHz (clk_wiz clk_out1)
    input  wire rst_n,                 // clk_wiz locked (Highで動作)
    input  wire signed [15:0] ext_sample,
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

    // フレーム頭でサンプル確定
    reg signed [15:0] sample;
    always @(posedge mclk)
        if (c == 8'hFF) sample <= ext_sample;

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
