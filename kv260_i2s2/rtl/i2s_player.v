// -----------------------------------------------------------------------------
// i2s_player.v -- 段4: 音声ファイル再生 (Pmod I2S2 / CS4344)
//   内蔵メモリに焼き込んだ16ビットPCMを毎標本読み出し、I2Sで送出する。
//
//   mclk : 12.5 MHz (= 256 x fs), fs = 12.5MHz/256 = 48828.125 Hz
//   音源  : audio_rom.hex (16ビット符号付き, 48828Hz, 単音)
//           終端まで再生したら先頭に戻って繰り返す
//
// 【メロディ版からの変更点】
//   旧: サインLUT + 位相アキュムレータで音階を合成
//   新: PCMデータを順番に読み出すだけ(合成しない)
// -----------------------------------------------------------------------------
module i2s_player #(
    parameter integer DW       = 16,        // データビット幅
    parameter integer ROM_LEN  = 195312,    // 標本数 (4秒 @48828Hz)
    parameter integer ADDR_W   = 18         // アドレス幅 (2^18=262144 > 195312)
)(
    input  wire mclk,                       // 12.5 MHz (clk_wiz clk_out1)
    input  wire rst_n,                      // clk_wiz locked (Highで動作)
    output wire mclk_o,                     // DACへのMCLK
    output reg  sclk,                       // ビットクロック
    output reg  lrck,                       // ワードセレクト(L=0/R=1)
    output reg  sdout                       // I2Sシリアルデータ
);
    // ---- フレームカウンタ: 256 mclk = 1 標本周期(fs) ----
    reg [7:0] c;
    always @(posedge mclk or negedge rst_n)
        if (!rst_n) c <= 8'd0;
        else        c <= c + 8'd1;

    wire sample_tick = (c == 8'hFF);        // 1標本ごとに1回
    wire [5:0] bi = c[7:2];                 // フレーム内ビット位置 0..63
    wire [4:0] cb = bi[4:0];                // チャンネル内ビット位置 0..31

    // ---- 音声データ(内蔵メモリ) ----
    (* rom_style = "block" *)
    reg signed [15:0] audio [0:ROM_LEN-1];
    initial $readmemh("audio_rom.hex", audio);

    // ---- 再生位置: 1標本ごとに1つ進める。終端で先頭へ戻る ----
    reg [ADDR_W-1:0] addr;
    always @(posedge mclk or negedge rst_n) begin
        if (!rst_n)
            addr <= {ADDR_W{1'b0}};
        else if (sample_tick) begin
            if (addr >= ROM_LEN[ADDR_W-1:0] - 1)
                addr <= {ADDR_W{1'b0}};     // 先頭へ戻って繰り返し
            else
                addr <= addr + 1'b1;
        end
    end

    // ---- 標本の取り出し(内蔵メモリは同期読み出し) ----
    reg signed [15:0] sample;
    always @(posedge mclk)
        if (sample_tick) sample <= audio[addr];

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
            sdout <= sd;                    // L/R同一データ(単音)
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
