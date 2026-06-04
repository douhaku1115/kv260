// -----------------------------------------------------------------------------
// i2s_loop.v  -- 段2: I2S 受信(ADC) → 送信(DAC) ループバック
//   Pmod I2S2 (CS5343 ADC / CS4344 DAC) を PL がマスターで駆動。
//   ADC/DAC とも MCLK=12.5MHz(256fs), SCLK=mclk/4(64fs), LRCK=mclk/256(fs)。
//   単一のフレームカウンタで TX(直列化)/RX(並列化)のビット位置を完全に揃える。
//   ADC SDOUT を SCLK立上りで取り込み、復元した左右16bitをそのまま DAC へ送る。
//   ※ Block Design に Module Reference として取り込み、BDラッパをトップにする。
// -----------------------------------------------------------------------------
module i2s_loop #(
    parameter integer DW   = 16,       // データビット幅
    parameter integer GAIN = 32        // デジタルゲイン倍率(飽和付き)
)(
    input  wire mclk,                  // 12.5 MHz (clk_wiz clk_out1)
    input  wire rst_n,                 // clk_wiz locked (Highで動作)
    // ---- DAC (TX) ----
    output wire dac_mclk,              // DACへのMCLK (ODDRE1出力)
    output reg  dac_sclk,
    output reg  dac_lrck,
    output reg  dac_sdin,              // DACへのI2Sデータ
    // ---- ADC (RX) ----
    output wire adc_mclk,              // ADCへのMCLK (ODDRE1出力)
    output reg  adc_sclk,
    output reg  adc_lrck,
    input  wire adc_sdout              // ADCからのI2Sデータ
);
    // フレームカウンタ: 256 mclk = 1 サンプル周期(fs)
    reg [7:0] c;
    always @(posedge mclk or negedge rst_n)
        if (!rst_n) c <= 8'd0;
        else        c <= c + 8'd1;

    wire [5:0] bi = c[7:2];            // フレーム内ビット位置 0..63
    wire [4:0] cb = bi[4:0];           // チャンネル内ビット位置 0..31
    wire       lr = c[7];              // 0=L(前半32bit), 1=R(後半32bit)

    // =========================================================================
    // RX: ADC SDOUT を SCLK立上りで取り込み、L/R 16bit を復元
    //   I2S規約: WS(LRCK)エッジの1SCLK後にMSB → cb=1..DW がMSB..LSB
    // =========================================================================
    reg sclk_d;
    always @(posedge mclk or negedge rst_n)
        if (!rst_n) sclk_d <= 1'b0;
        else        sclk_d <= c[1];               // 生成SCLKの1mclk前値
    wire sclk_rise = (c[1] == 1'b1) && (sclk_d == 1'b0);

    reg signed [DW-1:0] rxsh;          // 受信シフトレジスタ
    reg signed [DW-1:0] rxL, rxR;      // 復元済み左右サンプル
    always @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            rxsh <= {DW{1'b0}};
            rxL  <= {DW{1'b0}};
            rxR  <= {DW{1'b0}};
        end else if (sclk_rise) begin
            if (cb >= 5'd1 && cb <= DW[4:0])
                rxsh <= {rxsh[DW-2:0], adc_sdout};
            if (cb == DW[4:0]) begin               // チャンネル末尾で確定
                if (lr == 1'b0) rxL <= {rxsh[DW-2:0], adc_sdout};
                else            rxR <= {rxsh[DW-2:0], adc_sdout};
            end
        end
    end

    // =========================================================================
    // TX: 受信サンプルをデジタル増幅(飽和付き)し、DAC へ直列化(ループバック)
    //   GAIN 倍して 16bit にクリップ。小さいマイク信号を聞こえる音量へ。
    // =========================================================================
    function signed [DW-1:0] sat;        // 32bit値を16bitに飽和
        input signed [31:0] v;
        begin
            if      (v >  ((1 << (DW-1)) - 1)) sat =  ((1 << (DW-1)) - 1); // +32767
            else if (v < -(1 << (DW-1)))       sat = -(1 << (DW-1));       // -32768
            else                               sat =  v[DW-1:0];
        end
    endfunction

    wire signed [31:0] ampL = $signed(rxL) * GAIN;
    wire signed [31:0] ampR = $signed(rxR) * GAIN;

    reg signed [DW-1:0] txL, txR;
    always @(posedge mclk)
        if (c == 8'hFF) begin txL <= sat(ampL); txR <= sat(ampR); end

    wire signed [DW-1:0] sample = (lr == 1'b0) ? txL : txR;

    reg sd;                            // cb=1→MSB ... cb=DW→LSB、残りは0
    always @(*) begin
        if (cb >= 5'd1 && cb <= DW[4:0])
            sd = sample[DW-1 - (cb - 5'd1)];
        else
            sd = 1'b0;
    end

    // =========================================================================
    // 出力レジスタ: ADC/DAC へ同一の SCLK/LRCK を供給、DAC へは sd を出力
    // =========================================================================
    always @(posedge mclk or negedge rst_n) begin
        if (!rst_n) begin
            dac_sclk <= 1'b0; dac_lrck <= 1'b0; dac_sdin <= 1'b0;
            adc_sclk <= 1'b0; adc_lrck <= 1'b0;
        end else begin
            dac_sclk <= c[1];          // mclk/4
            dac_lrck <= c[7];          // mclk/256
            dac_sdin <= sd;
            adc_sclk <= c[1];
            adc_lrck <= c[7];
        end
    end

    // MCLK をピンへクリーン転送 (UltraScale+ クロック出力プリミティブ)
    ODDRE1 #(.SRVAL(1'b0)) u_dac_mclk (.Q(dac_mclk), .C(mclk), .D1(1'b1), .D2(1'b0), .SR(1'b0));
    ODDRE1 #(.SRVAL(1'b0)) u_adc_mclk (.Q(adc_mclk), .C(mclk), .D1(1'b1), .D2(1'b0), .SR(1'b0));
endmodule
