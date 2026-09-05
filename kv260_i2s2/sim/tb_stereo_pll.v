`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_stereo_pll -- 19kHz パイロット PLL 単体の検証
//
//   MPX を模した信号を直接入れて、
//     (1) パイロットにロックするか
//     (2) 作られた 38kHz の位相誤差が何度か
//   を測る。位相誤差 θ から達成できる分離度は 20*log10(1/tan θ) [dB]。
//
//   ★「動いた／動かない」ではなく角度と dB で出すこと。
//     ロックの有無だけ見ても、分離度が 20dB なのか 40dB なのか分からない。
//
//   入れる信号は本物の MPX に近づけてある:
//     ・パイロット 19kHz を全体の 10%
//     ・L+R を模した 1kHz を 45%
//     ・L−R を模した 30kHz（23〜53kHz 帯の中身）を 40%
//   30kHz は NCO の 19kHz と混ざって 11kHz に落ちてくる妨害になる。
//   位相検出後の 3 段 LPF がこれを落とせているかがこの試験の要点。
// -----------------------------------------------------------------------------
module tb_stereo_pll;
    localparam real FS      = 976560.0;     // PLL が動く速さ
    localparam real F_PILOT = 19000.0;      // パイロットの周波数
    localparam real PI2     = 6.28318530717958647692;

    reg clk = 0, rst_n = 0;
    reg sample_valid = 0;
    reg signed [17:0] mpx = 0;

    wire signed [15:0] cos38;
    wire               locked;
    wire signed [31:0] pilot_level;

    stereo_pll dut (
        .clk(clk), .rst_n(rst_n),
        .sample_valid(sample_valid), .mpx(mpx),
        .cos38(cos38), .locked(locked), .pilot_level(pilot_level)
    );

    always #5 clk = ~clk;

    // ---- 測定用 ----
    real ph_pilot;              // 送信側のパイロット位相（真値）
    real c_acc, s_acc;          // cos38 と真の 38kHz との相関
    integer meas;               // 測定中フラグ
    real t, sig;
    real ppm, fp;
    integer n, nmeas;
    real perr, sep;
    integer lock_at;

    // ★相関の計算は必ずタスクの中でやること（別の always に書かない）
    //
    //   ph_pilot はタスクが「=」で更新している。測定を別の always @(posedge clk)
    //   に書くと、同じ時刻に走る2つのプロセスの実行順が決まらないため、
    //   タスクが先に走った回だけ ph_pilot が1サンプル進んだ値になる。
    //   最初この書き方をしたせいで、常に 1 サンプル ＝ 19kHz で 7.005 度、
    //   38kHz 換算で 13.94 度の「位相誤差」が出た。PLL 側の問題ではなかった。

    task run_test(input real ppm_in, input integer nsamp, input integer nsettle);
        begin
            ppm     = ppm_in;
            fp      = F_PILOT * (1.0 + ppm * 1.0e-6);
            rst_n   = 0;
            meas    = 0;
            c_acc   = 0.0;
            s_acc   = 0.0;
            nmeas   = 0;
            lock_at = -1;
            ph_pilot = 0.0;
            sample_valid = 0;
            repeat (20) @(posedge clk);
            rst_n = 1;
            @(posedge clk);

            for (n = 0; n < nsamp; n = n + 1) begin
                t = n / FS;
                // 送信側のパイロット位相を進める（NCO と同じやり方）
                ph_pilot = PI2 * fp * t;

                sig =   0.10 * $cos(ph_pilot)                       // パイロット
                      + 0.45 * $sin(PI2 * 1000.0  * t)              // L+R 相当
                      + 0.40 * $cos(PI2 * 30000.0 * t);             // L−R 相当

                mpx          <= $rtoi(32768.0 * sig);
                sample_valid <= 1'b1;
                @(posedge clk);
                // ここは DUT がサンプル n を取り込んだ直後。cos38 はまだクロック
                // 前の値（＝DUT が使ったのと同じ値）なので、ph_pilot(n) と比べられる。
                if (meas) begin
                    c_acc = c_acc + cos38 * $cos(2.0 * ph_pilot);
                    s_acc = s_acc + cos38 * $sin(2.0 * ph_pilot);
                    nmeas = nmeas + 1;
                end
                sample_valid <= 1'b0;

                if (lock_at < 0 && locked) lock_at = n;
                if (n == nsettle) meas = 1;                          // 測定開始
            end
            meas = 0;

            // ---- 結果 ----
            $display("--------------------------------------------------");
            $display("水晶誤差 %.0f ppm (パイロット %.2f Hz)", ppm, fp);
            if (lock_at < 0)
                $display("  ロック: しなかった   FAIL");
            else
                $display("  ロック: %0d サンプル目 (%.1f ms)", lock_at, lock_at / FS * 1000.0);
            $display("  パイロット強度 = %0d", pilot_level);

            if (nmeas > 0 && (c_acc != 0.0 || s_acc != 0.0)) begin
                // 相関の偏角がそのまま 38kHz の位相誤差
                // 相関の偏角 θ が位相誤差、分離度 = 20*log10(cosθ/sinθ)
                perr = $atan2(s_acc, c_acc);
                sep  = 20.0 * $log10($sqrt(c_acc*c_acc) / ($sqrt(s_acc*s_acc) + 1.0e-9));
                $display("  38kHz の位相誤差 = %.3f 度", perr * 180.0 / 3.14159265358979);
                $display("  これで到達できる分離度 = %.1f dB", sep);
                if (locked && perr * 180.0 / 3.14159265358979 < 1.0
                           && perr * 180.0 / 3.14159265358979 > -1.0)
                    $display("  PASS (位相誤差 1 度以内 = 分離度 35dB 以上に相当)");
                else
                    $display("  FAIL");
            end else begin
                $display("  FAIL: 測定できなかった");
            end
        end
    endtask

    initial begin
        $display("=== stereo_pll 単体試験 ===");
        run_test(  0.0, 400000, 300000);    // 誤差なし
        run_test( 50.0, 400000, 300000);    // +50ppm（RTL-SDR の典型）
        run_test(-50.0, 400000, 300000);    // -50ppm
        $display("--------------------------------------------------");
        $finish;
    end
endmodule
