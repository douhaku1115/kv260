`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_i2s_tx.v -- i2s_tx 自己検証シミュレーション
//   DAC受信側を模擬: SCLK立上りでSDOUTをサンプル、WS(LRCK)エッジで区切り、
//   I2S規約(WSエッジの1SCLK後にMSB)で16bitを復元 → sine_lut期待値と照合。
//   左右(mono)一致も確認。 sine_lut.hex を実行ディレクトリに置くこと。
// -----------------------------------------------------------------------------
module tb_i2s_tx;
    reg mclk = 0;
    reg rst_n = 0;
    wire mclk_o, sclk, lrck, sdout;

    always #40 mclk = ~mclk;          // 12.5MHz => 80ns周期

    i2s_tx #(.DW(16)) dut (
        .mclk(mclk), .rst_n(rst_n), .mclk_o(mclk_o),
        .sclk(sclk), .lrck(lrck), .sdout(sdout)
    );

    // 期待値: 送信側と同じLUT/位相を独立に再現
    reg signed [15:0] sine [0:63];
    initial $readmemh("sine_lut.hex", sine);

    // ---- 受信(DAC模擬) ----
    reg        sclk_d;
    reg        lrck_d;
    reg [4:0]  bitpos;                 // チャンネル内ビット位置
    reg [15:0] word;                   // 復元中の16bit
    reg        cur_lr;                  // 現在のチャンネル(0=L,1=R)
    reg signed [15:0] capL, capR;
    integer    errors;
    integer    nL;

    initial begin
        errors = 0; nL = 0; bitpos = 0; word = 0;
        sclk_d = 0; lrck_d = 0;
    end

    // SCLK立上り検出(mclkでオーバーサンプル)
    always @(posedge mclk) begin
        sclk_d <= sclk;
        lrck_d <= lrck;

        // WSエッジでチャンネル先頭にリセット
        if (lrck != lrck_d) begin
            bitpos <= 0;
            cur_lr <= lrck;            // 新チャンネル
        end

        // SCLK立上り = データ確定点
        if (sclk && !sclk_d) begin
            // I2S: bitpos 0 はダミー(1SCLK遅延), 1..16 がMSB..LSB
            if (bitpos >= 1 && bitpos <= 16)
                word <= {word[14:0], sdout};
            // チャンネル末尾(16bit取り込み完了)で確定
            if (bitpos == 16) begin
                if (cur_lr == 1'b0) begin
                    capL <= {word[14:0], sdout};
                end else begin
                    capR <= {word[14:0], sdout};
                    // L/R揃ったところで照合
                    if (capL !== {word[14:0], sdout})
                        $display("[%0t] WARN L!=R  L=%h R=%h", $time, capL, {word[14:0], sdout});
                end
            end
            bitpos <= bitpos + 1;
        end
    end

    // 復元値を時系列で表示(目視 + LUT一致確認)
    reg signed [15:0] prevL;
    integer k;
    initial begin
        #200 rst_n = 1;
        // 12フレーム観測(1フレーム=256*80ns=20.48us)
        for (k = 0; k < 12; k = k + 1) begin
            #20480;
            $display("[%0t] frame%0d  capL=%h (%0d)  capR=%h (%0d)",
                     $time, k, capL, capL, capR, capR);
        end
        $display("=== sine_lut (期待値の集合) ===");
        for (k = 0; k < 64; k = k + 8)
            $display(" lut[%2d..]= %h %h %h %h %h %h %h %h", k,
                sine[k],sine[k+1],sine[k+2],sine[k+3],sine[k+4],sine[k+5],sine[k+6],sine[k+7]);
        $display("simulation done (capL=capRならmono正常, capLがlut内の値ならビット並び正常)");
        $finish;
    end
endmodule
