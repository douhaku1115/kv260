`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_fm_demod_bpf.v -- 復調の「前」の帯域制限が効いているかを検証
//
//   RTL-SDR が 976560Hz で受けると帯域は ±488kHz ある。FM 放送が占めるのは
//   ±100kHz 程度なので、残りは全部ただの雑音として復調器に入ってくる。
//
//   かといって受信レートを下げると sin(Δφ) ≒ Δφ の近似が破綻するので、
//   **間引かずにフィルタだけ掛ける**。fm_demod.v の中で I・Q それぞれに
//   4点移動平均を3段かけている。
//
//   ここでは IQ に振幅一定の複素正弦波（単一の周波数）を入れ、
//   フィルタを通った後の振幅（dut.flt_i）を測って周波数特性を出す。
//
//   4点移動平均の振幅応答は  |sin(4πf/fs) / (4·sin(πf/fs))|  で、
//   3段かけるとその3乗になる。fs/4 = 244140Hz にヌル点ができる。
//
//   理論値:
//        0Hz     0.0dB
//      100kHz   -7.2dB
//      122kHz  -11.1dB   ← FM 放送の端
//      244kHz    ヌル（大きく落ちる）
//      300kHz  -42.0dB
//      400kHz  -37.6dB
// -----------------------------------------------------------------------------
module tb_fm_demod_bpf;
    localparam integer DECIM = 20;
    localparam real    FS_IQ = 976560.0;
    localparam real    AMP   = 8000.0;
    localparam real    TWOPI = 6.28318530718;

    reg clk = 0, rst_n = 0;
    reg in_valid = 0;
    reg signed [15:0] in_i = 0, in_q = 0;
    reg [7:0] volume = 8'd64;
    wire in_ready, out_valid;
    wire signed [15:0] out_data;

    fm_demod #(.DECIM(DECIM)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_i(in_i), .in_q(in_q), .in_ready(in_ready),
        .out_valid(out_valid), .out_data(out_data),
        .volume(volume)
    );

    always #5 clk = ~clk;

    integer n, peak;
    real    ph;

    // フィルタ通過後の振幅を測る（dut の内部信号を直接見る）
    always @(posedge clk) begin
        if (rst_n && in_valid && n > 40) begin      // 過渡は無視
            if (dut.flt_i > 0 &&  dut.flt_i > peak) peak =  dut.flt_i;
            if (dut.flt_i < 0 && -dut.flt_i > peak) peak = -dut.flt_i;
        end
    end

    // 指定した周波数の複素正弦波を流し、フィルタ後の最大振幅を返す
    task run_tone(input real f_in, output integer result);
        begin
            peak = 0; n = 0; ph = 0.0;
            for (n = 0; n < 4000; n = n + 1) begin
                ph = TWOPI * f_in * n / FS_IQ;

                // in_ready に従う（出力段の 15kHz FIR が計算中は待つ）
                //   FIR は 1 標本の積和に 63 クロックかかる。無視して送ると
                //   計算がやり直しになり続け、出力が出なくなる。
                in_valid <= 1'b0;
                @(posedge clk);
                while (!in_ready) @(posedge clk);

                in_i     <= $rtoi(AMP * $cos(ph));
                in_q     <= $rtoi(AMP * $sin(ph));
                in_valid <= 1'b1;
                @(posedge clk);
            end
            in_valid <= 0;
            #200;
            result = peak;
        end
    endtask

    integer p_dc, p100k, p122k, p244k, p300k, p400k;
    real    d100k, d122k, d244k, d300k, d400k;

    initial begin
        rst_n = 0; #100; @(posedge clk); rst_n = 1;

        run_tone(     0.0, p_dc );   // 直流（基準）
        run_tone( 100000.0, p100k);
        run_tone( 122000.0, p122k);
        run_tone( 244140.0, p244k);  // ここがヌル点
        run_tone( 300000.0, p300k);
        run_tone( 400000.0, p400k);

        $display("基準（直流）の振幅 = %0d", p_dc);
        $display("");
        $display("  周波数      振幅      減衰量      理論値");
        $display("  --------------------------------------------");

        d100k = (p100k > 0) ? 20.0 * $log10(p100k * 1.0 / p_dc) : -99.0;
        d122k = (p122k > 0) ? 20.0 * $log10(p122k * 1.0 / p_dc) : -99.0;
        d244k = (p244k > 0) ? 20.0 * $log10(p244k * 1.0 / p_dc) : -99.0;
        d300k = (p300k > 0) ? 20.0 * $log10(p300k * 1.0 / p_dc) : -99.0;
        d400k = (p400k > 0) ? 20.0 * $log10(p400k * 1.0 / p_dc) : -99.0;

        $display("  100 kHz  %8d  %8.1f dB    -7.2 dB", p100k, d100k);
        $display("  122 kHz  %8d  %8.1f dB   -11.1 dB  <- FM放送の端", p122k, d122k);
        $display("  244 kHz  %8d  %8.1f dB    ヌル点",  p244k, d244k);
        $display("  300 kHz  %8d  %8.1f dB   -42.0 dB", p300k, d300k);
        $display("  400 kHz  %8d  %8.1f dB   -37.6 dB", p400k, d400k);
        $display("");

        // 判定: 放送帯域(122kHz)は残し、帯域外(300kHz以上)は大きく落ちること
        if (d122k > -15.0 && d300k < -25.0 && d400k < -25.0)
            $display("PASS: 放送帯域を残して帯域外を落とせている（帯域制限が効いている）");
        else
            $display("FAIL: 122kHz=%.1fdB 300kHz=%.1fdB 400kHz=%.1fdB", d122k, d300k, d400k);

        $finish;
    end
endmodule
