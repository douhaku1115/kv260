// ============================================================
// tb_hdmi_audio.v — HDMI の音 (xlive_audio) の受け渡しを確かめる
// ============================================================
//
// 送る側は rtl_top と同じ: 100MHz 側で 1024 クロックごとに値を止めてトグル、
//   clka 側で受けて 512 クロックに 1 回 (48kHz) FIFO に入れる。
//   値は 1024 クロックごとに 1 増える数 (左右とも同じ値)。48kHz 1 組で約 2.03 増えるはず。
// 受ける側は DP の代わり: 24.576MHz で 256 クロックごとに ready を 1 回立てる
//   (48kHz x 左右 2 語 = 96k 語/秒 = 24.576MHz / 256)。
// 調べること:
//   - 語の [3:0] (preamble) が 0001 (ブロック先頭) / 0010 (左) / 0011 (右) の並びで、id が左 0・右 1
//   - 左右の値が同じ
//   - 1 組ごとに値が増える (FIFO があふれて古い値に戻ったり、止まったりしない)
//   - パリティ [31] が [30:4] の偶数パリティ
`timescale 1ns/1ps

module tb_hdmi_audio;
  reg clk = 0, clka = 0;
  always #5      clk  = ~clk;     // 100MHz
  always #20.345 clka = ~clka;    // 24.576MHz

  reg reset = 1, reseta = 1;

  // clk 側 (rtl_top の aud_div / aud_hold / aud_tgl と同じ)
  reg  [9:0]  aud_div = 10'd0;
  reg  [15:0] aud_hold = 16'd0, cnt = 16'd0;
  reg         aud_tgl = 1'b0;
  always @(posedge clk) begin
    aud_div <= aud_div + 10'd1;
    if (aud_div == 10'd0) begin
      cnt      <= cnt + 16'd1;
      aud_hold <= cnt;
      aud_tgl  <= ~aud_tgl;
    end
  end

  // clka 側 (rtl_top の dpa_* と同じ)
  wire full;
  reg  [2:0]  dpa_sync = 3'd0;
  reg  [15:0] s = 16'd0;
  reg  [8:0]  dpa_div = 9'd0;
  reg         en = 1'b0;
  always @(posedge clka) begin
    dpa_sync <= {dpa_sync[1:0], aud_tgl};
    if (dpa_sync[2] != dpa_sync[1]) s <= aud_hold;
    dpa_div <= dpa_div + 9'd1;
    en      <= !reseta && (dpa_div == 9'd0) && !full;
  end

  wire [31:0] tdata;
  wire        tvalid, tid;
  reg         tready = 1'b0;
  reg  [7:0]  adiv = 8'd0;
  always @(posedge clka) begin
    adiv   <= adiv + 8'd1;
    tready <= (adiv == 8'd0);
  end

  xlive_audio #(.AUDIO_WIDTH(16), .BUFFER_DEPTH(4), .AES_MODE(0), .SAMPLE_FREQ(48000)) dut
    (.clk_tx(clka), .clk_rx(clka), .reset_tx(reseta), .reset_rx(reseta),
     .data_rx({s, s}), .en_rx(en), .full_rx(full),
     .data_tx(tdata), .valid_tx(tvalid), .id_tx(tid), .ready_tx(tready));

  integer n = 0, errs = 0, pairs = 0, blocks = 0;
  reg [15:0] left, prev;
  reg        have_prev = 0;
  wire [15:0] smp = tdata[27:12];   // 24bit 枠の上位 16bit (下 8bit は 0)
  always @(posedge clka) begin
    if (tvalid && tready) begin
      n = n + 1;
      if (^tdata[31:4] !== 1'b0) begin errs = errs + 1; if (errs < 5) $display("NG parity %h", tdata); end
      if (tdata[11:4] !== 8'd0)  begin errs = errs + 1; if (errs < 5) $display("NG low bits %h", tdata); end
      if (tid == 1'b0) begin
        if (tdata[3:0] == 4'b0001) blocks = blocks + 1;
        else if (tdata[3:0] !== 4'b0010) begin errs = errs + 1; if (errs < 5) $display("NG preamble L %h", tdata); end
        left = smp;
      end else begin
        if (tdata[3:0] !== 4'b0011) begin errs = errs + 1; if (errs < 5) $display("NG preamble R %h", tdata); end
        if (smp !== left) begin errs = errs + 1; if (errs < 5) $display("NG L!=R %h %h", left, smp); end
        // 最初の 16 組は FIFO が溜まるまで前の値 (0) を繰り返すので見ない
        if (have_prev && pairs >= 16 && (smp - prev < 16'd1 || smp - prev > 16'd3)) begin
          errs = errs + 1; if (errs < 5) $display("NG step %h -> %h", prev, smp);
        end
        prev = smp; have_prev = 1; pairs = pairs + 1;
      end
    end
  end

  initial begin
    repeat (20) @(posedge clk);
    reset = 0;
    @(posedge clka); reseta = 0;
    #20_000_000;   // 20ms = 960 組
    $display("words=%0d pairs=%0d blocks=%0d errs=%0d", n, pairs, blocks, errs);
    if (errs == 0 && pairs > 900 && blocks >= 4) $display("PASS"); else $display("FAIL");
    $finish;
  end
endmodule
