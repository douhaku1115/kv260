`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_fm_demod_amp.v -- 振幅正規化の検証
//
//   FM 放送の振幅は本来一定だが、実際の受信では強度が変動する。
//   正規化が効いていれば、振幅が変わっても復調出力の大きさは変わらないはず。
//
//   同じ 1kHz 変調の FM 信号を、振幅を変えて 2 回入れ、
//   出力の振幅（最大値）を比べる。
//     正規化あり → ほぼ同じ大きさ（比が 1 に近い）
//     正規化なし → 振幅の 2 乗に比例して変わる（比が大きくずれる）
// -----------------------------------------------------------------------------
module tb_fm_demod_amp;
    localparam integer DECIM = 20;
    localparam real    FS_IQ = 976560.0;
    localparam real    F_AUD = 1000.0;
    localparam real    DEV   = 75000.0;

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

    real t, phase, aud, amp;
    integer n, peak, nout;

    // 出力の絶対値の最大を測る
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            nout = nout + 1;
            if (nout > 40) begin       // 最初の過渡は無視
                if (out_data > 0 && out_data > peak)   peak = out_data;
                if (out_data < 0 && -out_data > peak)  peak = -out_data;
            end
        end
    end

    // 指定した振幅で FM 信号を流し、出力の最大振幅を返す
    task run_amp(input real a, output integer result);
        begin
            peak = 0; nout = 0; phase = 0.0;
            for (n = 0; n < 20000; n = n + 1) begin
                t   = n / FS_IQ;
                aud = $sin(6.28318530718 * F_AUD * t);
                phase = phase + 6.28318530718 * (DEV * aud) / FS_IQ;

                // in_ready に従う（出力段の 15kHz FIR が計算中は待つ）
                in_valid <= 1'b0;
                @(posedge clk);
                while (!in_ready) @(posedge clk);

                in_i     <= $rtoi(a * $cos(phase));
                in_q     <= $rtoi(a * $sin(phase));
                in_valid <= 1'b1;
                @(posedge clk);
            end
            in_valid <= 0;
            #1000;
            result = peak;
        end
    endtask

    integer peak_strong, peak_weak;
    real ratio;

    initial begin
        rst_n = 0; #100; @(posedge clk); rst_n = 1;

        // 強い信号（振幅 8000）
        run_amp(8000.0, peak_strong);
        $display("振幅 8000 のとき 出力の最大 = %0d", peak_strong);

        // 弱い信号（振幅 1000 = 1/8）。振幅²なら 1/64 になるはず
        run_amp(1000.0, peak_weak);
        $display("振幅 1000 のとき 出力の最大 = %0d", peak_weak);

        if (peak_weak > 0) begin
            ratio = peak_strong * 1.0 / peak_weak;
            $display("出力の比 = %.2f  (正規化ありなら 1 に近い / 無しなら 64 前後)", ratio);
            if (ratio > 0.4 && ratio < 2.5)
                $display("PASS: 振幅が変わっても出力の大きさがほぼ一定＝正規化が効いている");
            else
                $display("FAIL: 振幅の変動が出力に出ている（正規化が効いていない）");
        end else begin
            $display("FAIL: 弱い信号で出力が出ない");
        end
        $finish;
    end
endmodule
