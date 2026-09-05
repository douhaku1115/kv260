`timescale 1ns/1ps
// -----------------------------------------------------------------------------
// tb_fm_stereo -- fm_demod_stereo の分離度を dB で測る
//
//   送信側と同じ手順で FM ステレオの電波を作って入れ、L と R の漏れを測る。
//
//   【作る信号】
//     MPX  = 0.9*( 0.5*(L+R) + 0.5*(L−R)*cos(2ωt) ) + 0.10*cos(ωt)
//              └ 主音声 ┘   └─── 38kHz DSB-SC ───┘   └ 19kHz パイロット ┘
//     IQ   = 8000 * exp( j * ∫ 2π*75000*MPX dt )
//
//   【測り方】
//     片チャンネルだけに 1kHz を入れ、反対側の出力の実効値を測る。
//       分離度[dB] = 20*log10( 鳴っている側 / 漏れている側 )
//     実用機で 30dB あれば十分、40dB 出れば良好とされる。
//
//   ★合否だけでなく必ず dB を出すこと。「聞こえた」では改善したか分からない。
// -----------------------------------------------------------------------------
module tb_fm_stereo;
    localparam integer DECIM = 20;
    localparam real FS_IQ = 976560.0;       // IQ のサンプリング速度
    localparam real FS_AU = FS_IQ / DECIM;  // 音声のサンプリング速度 48828
    localparam real DEV   = 75000.0;        // 最大周波数偏移
    localparam real FP    = 19000.0;        // パイロット
    localparam real PI2   = 6.28318530717958647692;

    reg clk = 0, rst_n = 0;
    reg in_valid = 0;
    reg signed [15:0] in_i = 0, in_q = 0;
    reg [7:0] volume    = 8'd64;
    reg       stereo_en = 1'b1;

    wire in_ready, out_valid, pilot_locked;
    wire signed [15:0] out_l, out_r;
    wire signed [31:0] pilot_level;

    fm_demod_stereo #(.DECIM(DECIM)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_i(in_i), .in_q(in_q), .in_ready(in_ready),
        .out_valid(out_valid), .out_l(out_l), .out_r(out_r),
        .volume(volume), .stereo_en(stereo_en), .diag_d(1'b0),
        .pilot_locked(pilot_locked), .pilot_level(pilot_level),
        .pilot_quad(), .sum_level(), .diff_level()
    );

    always #5 clk = ~clk;

    // ---- 測定 ----
    integer meas;
    real    sum_l2, sum_r2;
    real    rl, rr, mph, mc, ms;
    real    lc, ls, rc, rs;                 // 音声周波数との相関（同相・直交）
    integer nout, ndiff;
    real    faud_now;

    // ★実効値だけ見てはいけない
    //   漏れの実効値には「本当の左右の漏れ（音声と同じ周波数）」と
    //   「量子化雑音・折り返しなどの雑音」が混ざっている。
    //   分離度として意味があるのは前者だけなので、音声周波数の
    //   sin/cos と相関を取って成分を分離する。振幅は sqrt(同相²+直交²) で
    //   求まるので、復調の遅延による位相ずれは気にしなくてよい。
    //
    //   ★2乗の前に必ず real に移すこと
    //     out_l * out_l と書くと 16bit 幅のまま計算されて桁あふれし、
    //     和が負になって $sqrt が nan を返す。
    always @(posedge clk) begin
        if (rst_n && out_valid) begin
            if (out_l !== out_r) ndiff = ndiff + 1;
            if (meas) begin
                rl     = out_l;
                rr     = out_r;
                sum_l2 = sum_l2 + rl * rl;
                sum_r2 = sum_r2 + rr * rr;

                mph = PI2 * faud_now * nout / FS_AU;
                mc  = $cos(mph);
                ms  = $sin(mph);
                lc  = lc + rl * mc;   ls = ls + rl * ms;
                rc  = rc + rr * mc;   rs = rs + rr * ms;

                nout = nout + 1;
            end
        end
    end

    // ---- 送信側 ----
    real t, ph_rf, mpx, aud_l, aud_r, s, d;
    real ii, qq, qstep, iq_amp;
    integer n;
    real rms_l, rms_r, sep, amp_l, amp_r, nz_l, nz_r;
    integer lock_at;
    reg [8*28:1] name;

    // qstep: IQ の量子化の刻み（0 なら量子化なし）
    //   rtl_sdr の出力は符号なし 8bit。PS 側で 128 を引いて <<6 して 16bit に
    //   広げているので、実機の刻みは 64、満スケールは ±8192。
    // iq_amp: IQ の振幅。8192 に近いほど 8bit を使い切っている＝雑音が少ない。
    task run_test(input real gl, input real gr, input real faud,
                  input integer with_pilot,
                  input integer nsamp, input integer nsettle);
        begin
            rst_n    = 0;
            meas     = 0;
            faud_now = faud;
            sum_l2   = 0.0;
            sum_r2   = 0.0;
            lc = 0.0; ls = 0.0; rc = 0.0; rs = 0.0;
            nout     = 0;
            ndiff    = 0;
            lock_at  = -1;
            ph_rf    = 0.0;
            in_valid = 0;
            repeat (20) @(posedge clk);
            rst_n = 1;
            @(posedge clk);

            for (n = 0; n < nsamp; n = n + 1) begin
                t     = n / FS_IQ;
                aud_l = gl * $sin(PI2 * faud * t);
                aud_r = gr * $sin(PI2 * faud * t);
                s     = aud_l + aud_r;          // L+R
                d     = aud_l - aud_r;          // L−R

                if (with_pilot)
                    // ステレオ放送の MPX
                    mpx = 0.9 * (0.5 * s + 0.5 * d * $cos(2.0 * PI2 * FP * t))
                          + 0.10 * $cos(PI2 * FP * t);
                else
                    // モノラル放送（パイロットも副搬送波も無い）
                    mpx = 0.9 * (0.5 * s);

                // FM 変調（位相 = ∫ 2π*偏移 dt）
                ph_rf = ph_rf + PI2 * (DEV * mpx) / FS_IQ;

                // ★in_ready に従うこと（FIR の積和中は受け取れない）
                in_valid <= 1'b0;
                @(posedge clk);
                while (!in_ready) @(posedge clk);

                ii = iq_amp * $cos(ph_rf);
                qq = iq_amp * $sin(ph_rf);
                if (qstep > 0.0) begin      // 実機の 8bit ADC を模す（四捨五入）
                    ii = $rtoi(ii / qstep + ((ii >= 0.0) ? 0.5 : -0.5)) * qstep;
                    qq = $rtoi(qq / qstep + ((qq >= 0.0) ? 0.5 : -0.5)) * qstep;
                end
                in_i     <= $rtoi(ii);
                in_q     <= $rtoi(qq);
                in_valid <= 1'b1;
                @(posedge clk);

                if (lock_at < 0 && pilot_locked) lock_at = n;
                if (n == nsettle) meas = 1;     // ここから測定
            end
            in_valid <= 1'b0;
            meas = 0;
            #1000;

            // ---- 結果 ----
            if (lock_at < 0)
                $display("  パイロット: ロックせず (強度 %0d)", pilot_level);
            else
                $display("  パイロット: %0d サンプル目でロック (%.1f ms, 強度 %0d)",
                         lock_at, lock_at / FS_IQ * 1000.0, pilot_level);

            if (nout > 100) begin
                rms_l = $sqrt(sum_l2 / nout);
                rms_r = $sqrt(sum_r2 / nout);
                // 音声周波数成分の振幅（相関から復元）
                amp_l = 2.0 * $sqrt(lc*lc + ls*ls) / nout;
                amp_r = 2.0 * $sqrt(rc*rc + rs*rs) / nout;
                // 実効値から音声成分を引いた残り＝雑音
                nz_l  = sum_l2 / nout - amp_l * amp_l / 2.0;
                nz_r  = sum_r2 / nout - amp_r * amp_r / 2.0;
                nz_l  = (nz_l > 0.0) ? $sqrt(nz_l) : 0.0;
                nz_r  = (nz_r > 0.0) ? $sqrt(nz_r) : 0.0;

                $display("  実効値   : L = %.1f      R = %.1f      (%0d 標本)",
                         rms_l, rms_r, nout);
                $display("  音声成分 : L = %.2f      R = %.2f", amp_l, amp_r);
                $display("  雑音     : L = %.2f      R = %.2f", nz_l, nz_r);
                sep = 20.0 * $log10((amp_l + 1.0e-9) / (amp_r + 1.0e-9));
                $display("  分離度(音声成分のみ) L/R = %.2f dB", sep);
            end else begin
                $display("  FAIL: 出力が出ていない (%0d)", nout);
            end
            $display("  L と R が異なった標本数 = %0d", ndiff);
        end
    endtask

    initial begin
        $display("=== fm_demod_stereo 分離度測定 ===");
        qstep   = 0.0;          // 既定は量子化なし（理想の IQ）
        iq_amp  = 8000.0;

        $display("--------------------------------------------------");
        $display("[1] L のみ 1kHz");
        run_test(0.9, 0.0, 1000.0, 1, 260000, 120000);
        if (sep > 25.0) $display("  PASS (分離度 %.1f dB)", sep);
        else            $display("  FAIL (分離度 %.1f dB, 25dB 未満)", sep);

        $display("--------------------------------------------------");
        $display("[2] R のみ 1kHz");
        run_test(0.0, 0.9, 1000.0, 1, 260000, 120000);
        if (sep < -25.0) $display("  PASS (分離度 %.1f dB)", -sep);
        else             $display("  FAIL (分離度 %.1f dB, 25dB 未満)", -sep);

        $display("--------------------------------------------------");
        $display("[3] L のみ 5kHz（高域の分離度）");
        run_test(0.9, 0.0, 5000.0, 1, 260000, 120000);
        if (sep > 25.0) $display("  PASS (分離度 %.1f dB)", sep);
        else            $display("  FAIL (分離度 %.1f dB, 25dB 未満)", sep);

        $display("--------------------------------------------------");
        $display("[4] モノラル素材 L=R 1kHz（左右バランス）");
        run_test(0.9, 0.9, 1000.0, 1, 260000, 120000);
        if (sep > -1.0 && sep < 1.0) $display("  PASS (L/R 差 %.2f dB)", sep);
        else                         $display("  FAIL (L/R 差 %.2f dB)", sep);

        $display("--------------------------------------------------");
        $display("[5] モノラル放送（パイロット無し）");
        run_test(0.9, 0.9, 1000.0, 0, 200000, 120000);
        if (!pilot_locked && ndiff == 0)
            $display("  PASS (ロックせず、L と R が完全一致)");
        else
            $display("  FAIL (locked=%0d, 不一致 %0d 標本)", pilot_locked, ndiff);

        // ---- ここから実機の再現: rtl_sdr の 8bit IQ を模す ----
        //   実機で L-R が「一定のサーッという雑音」になり、局を 13dB 強くしても
        //   下がらなかった。電波の雑音ではないので、取り込み経路を疑う。
        //   FM の雑音は周波数の2乗で増えるため、L-R が載る 23〜53kHz では
        //   L+R 帯より約 16dB 大きく出る。8bit の量子化雑音がここに効く。
        qstep = 64.0;           // 8bit（刻み 64、満スケール ±8192）

        $display("--------------------------------------------------");
        $display("[6] L のみ 1kHz / 8bit IQ・振幅 8000（ほぼ満スケール）");
        iq_amp = 8000.0;
        run_test(0.9, 0.0, 1000.0, 1, 260000, 120000);
        $display("  → 理想IQの [1] と比べる");

        $display("--------------------------------------------------");
        $display("[7] L のみ 1kHz / 8bit IQ・振幅 2000（ゲイン不足）");
        iq_amp = 2000.0;
        run_test(0.9, 0.0, 1000.0, 1, 260000, 120000);
        $display("  → 振幅が小さいほど量子化雑音が相対的に大きくなる");

        qstep = 0.0;
        $display("--------------------------------------------------");
        $finish;
    end
endmodule
