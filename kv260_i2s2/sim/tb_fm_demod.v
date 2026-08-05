`timescale 1ns/1ps
// fm_demod 検証: 1kHz の音で変調した FM 信号を作って入れ、1kHz が復調できるか見る
module tb_fm_demod;
    localparam integer DECIM = 20;
    localparam real    FS_IQ = 976560.0;      // IQ のサンプリング速度
    localparam real    F_AUD = 1000.0;        // 音の周波数（1kHz）
    localparam real    DEV   = 75000.0;       // 最大周波数偏移（FM放送は±75kHz）

    reg clk = 0, rst_n = 0;
    reg in_valid = 0;
    reg signed [15:0] in_i = 0, in_q = 0;
    reg [7:0] volume = 8'd64;
    wire in_ready;
    wire out_valid;
    wire signed [15:0] out_data;

    fm_demod #(.DECIM(DECIM)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_i(in_i), .in_q(in_q), .in_ready(in_ready),
        .out_valid(out_valid), .out_data(out_data),
        .volume(volume)
    );

    always #5 clk = ~clk;

    // FM 信号を作る: 位相 = ∫ 2π(f_dev × sin(2π f_aud t)) dt
    real t, phase, aud;
    real fs_out, dur, fest;
    integer n;

    // 出力の符号が変わる回数を数えて周波数を推定する
    integer zc = 0, nout = 0;
    reg signed [15:0] prev_out = 0;
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (nout > 40) begin              // 最初の過渡は無視
                if ((prev_out < 0 && out_data >= 0) || (prev_out >= 0 && out_data < 0))
                    zc = zc + 1;
            end
            prev_out = out_data;
            nout = nout + 1;
        end
    end

    initial begin
        rst_n = 0; #100; @(posedge clk); rst_n = 1;

        phase = 0.0;
        // 音声の 20 周期ぶん流す
        for (n = 0; n < 20000; n = n + 1) begin
            t   = n / FS_IQ;
            aud = $sin(6.28318530718 * F_AUD * t);
            // 位相を進める（周波数偏移ぶん）
            phase = phase + 6.28318530718 * (DEV * aud) / FS_IQ;
            @(posedge clk);
            in_valid <= 1;
            in_i     <= $rtoi(8000.0 * $cos(phase));
            in_q     <= $rtoi(8000.0 * $sin(phase));
        end
        @(posedge clk); in_valid <= 0;
        #1000;

        $display("出力標本数 = %0d", nout);
        $display("符号反転の回数 = %0d", zc);
        // 出力のサンプリング速度 = FS_IQ / DECIM = 48828
        // 1kHz なら 1 周期に 2 回反転 → 期待周波数 = zc/2 / (有効標本数/48828)
        if (nout > 100) begin
            fs_out = FS_IQ / DECIM;
            dur    = (nout - 40) / fs_out;
            fest   = (zc / 2.0) / dur;
            $display("推定した音の周波数 = %.0f Hz (期待 %.0f Hz)", fest, F_AUD);
            if (fest > 800.0 && fest < 1200.0)
                $display("PASS: FM 復調が正しく動作");
            else
                $display("FAIL: 周波数がずれている");
        end else begin
            $display("FAIL: 出力が出ていない");
        end
        $finish;
    end
endmodule
