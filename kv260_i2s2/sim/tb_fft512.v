`timescale 1ns/1ps
// fft512 検証: 3000Hzの正弦波を入れて、ピークが正しいビンに出るか確認
module tb_fft512;
    reg clk = 0, rst_n = 0, start = 0, in_valid = 0;
    reg signed [15:0] in_data = 0;
    wire done;
    reg  [8:0] rd_addr = 0;
    wire signed [15:0] rd_re, rd_im;

    integer n, k, maxbin;
    real maxmag, mag;

    fft512 dut (
        .clk(clk), .rst_n(rst_n), .start(start),
        .in_valid(in_valid), .in_data(in_data),
        .done(done), .rd_addr(rd_addr), .rd_re(rd_re), .rd_im(rd_im)
    );

    always #5 clk = ~clk;

    initial begin
        rst_n = 0; #100; @(posedge clk); rst_n = 1;
        @(posedge clk); start <= 1; @(posedge clk); start <= 0;

        // LOAD: 3000Hz の正弦波を512点投入（fs=48828.125）
        for (n = 0; n < 512; n = n + 1) begin
            @(posedge clk);
            in_valid <= 1;
            in_data  <= $rtoi(10000.0 * $sin(6.28318530718 * 3000.0 * n / 48828.125));
        end
        @(posedge clk); in_valid <= 0;

        wait (done);
        @(posedge clk);

        // ピーク探索（0〜255ビン）
        maxmag = 0.0; maxbin = 0;
        for (k = 0; k < 256; k = k + 1) begin
            rd_addr = k[8:0]; #1;
            mag = (rd_re * 1.0) * rd_re + (rd_im * 1.0) * rd_im;
            if (mag > maxmag) begin maxmag = mag; maxbin = k; end
        end
        $display("入力3000Hz -> ピークビン=%0d, 周波数=%.0fHz (期待:31付近≒2957Hz)",
                 maxbin, maxbin * 48828.125 / 512.0);

        // 32ビン周期の繰り返しが無いか確認（31, 63, 95... の mag を並べる）
        for (k = 31; k < 256; k = k + 32) begin
            rd_addr = k[8:0]; #1;
            mag = (rd_re * 1.0) * rd_re + (rd_im * 1.0) * rd_im;
            $display("  bin%0d (%.0fHz) mag^2=%.0f", k, k * 48828.125 / 512.0, mag);
        end

        if (maxbin >= 29 && maxbin <= 33)
            $display("PASS: 正しいビンにピークが出た");
        else
            $display("FAIL: ピーク位置がずれている");
        $finish;
    end
endmodule
