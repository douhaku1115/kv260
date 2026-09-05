`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_fm_demod_alias.v -- 折り返し雑音（エイリアス）の低減を検証
//
//   FM 放送の信号には音声(0〜15kHz)のほかに 19kHz パイロット、
//   23〜53kHz のステレオ信号が乗っている。出力は 48828Hz なので
//   24.4kHz より上は音声帯域に折り返して雑音になる。
//
//   ここでは変調信号として 38kHz（ステレオ副搬送波の位置）を入れ、
//   出力にどれだけ漏れてくるかを測る。
//     1次CIC（20点移動平均）→ -11.6dB 程度しか落ちない
//     3次CIC               → -34.8dB まで落ちる
//
//   比較のため 1kHz（本来の音声）も同じ条件で測り、その比を見る。
// -----------------------------------------------------------------------------
module tb_fm_demod_alias;
    localparam integer DECIM = 20;
    localparam real    FS_IQ = 976560.0;
    localparam real    DEV   = 75000.0;
    localparam real    AMP   = 8000.0;

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

    real t, phase, aud;
    integer n, peak, nout;

    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            nout = nout + 1;
            if (nout > 60) begin        // 過渡は無視
                if (out_data > 0 &&  out_data > peak) peak =  out_data;
                if (out_data < 0 && -out_data > peak) peak = -out_data;
            end
        end
    end

    // 指定した変調周波数で FM 信号を流し、出力の最大振幅を返す
    task run_freq(input real f_mod, output integer result);
        begin
            peak = 0; nout = 0; phase = 0.0;
            for (n = 0; n < 30000; n = n + 1) begin
                t   = n / FS_IQ;
                aud = $sin(6.28318530718 * f_mod * t);
                phase = phase + 6.28318530718 * (DEV * aud) / FS_IQ;

                // in_ready に従う（出力段の 15kHz FIR が計算中は待つ）
                //   FIR は 1 標本の積和に 63 クロックかかる。無視して送ると
                //   計算がやり直しになり続け、出力が出なくなる。
                in_valid <= 1'b0;
                @(posedge clk);
                while (!in_ready) @(posedge clk);

                in_i     <= $rtoi(AMP * $cos(phase));
                in_q     <= $rtoi(AMP * $sin(phase));
                in_valid <= 1'b1;
                @(posedge clk);
            end
            in_valid <= 0;
            #2000;
            result = peak;
        end
    endtask

    integer p_1k, p_38k;
    real ratio_db;

    initial begin
        rst_n = 0; #100; @(posedge clk); rst_n = 1;

        // 本来の音声帯域（1kHz）
        run_freq(1000.0, p_1k);
        $display("変調 1kHz（音声帯域）  出力の最大 = %0d", p_1k);

        // 折り返す成分（38kHz = ステレオ副搬送波の位置）
        run_freq(38000.0, p_38k);
        $display("変調 38kHz（折り返す） 出力の最大 = %0d", p_38k);

        if (p_1k > 0 && p_38k > 0) begin
            ratio_db = 20.0 * $log10(p_38k * 1.0 / p_1k);
            $display("38kHz の漏れ = %.1f dB （1次CICなら約 -12dB、3次CICなら約 -35dB）",
                     ratio_db);
            if (ratio_db < -25.0)
                $display("PASS: 折り返し成分が十分に落ちている（3次CICが効いている）");
            else
                $display("FAIL: 折り返し成分が残っている（%.1f dB）", ratio_db);
        end else if (p_38k == 0) begin
            $display("38kHz の漏れ = ほぼゼロ");
            $display("PASS: 折り返し成分が十分に落ちている");
        end else begin
            $display("FAIL: 1kHz で出力が出ない");
        end
        $finish;
    end
endmodule
