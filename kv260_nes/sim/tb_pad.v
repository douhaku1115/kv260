// ============================================================
// tb_pad.v — 段E: コントローラ $4016/$4017 の読み出し
// ============================================================
//
// tools/pad_test_gen.py の PRG を回す。プログラムは合図 1→0 のあと $4016 を 10 回読んで
// $00-$09 に、$4017 を $10 に置き、$20 を 1 周ごとに増やす。
// pad に値を入れ、$20 が 2 つ進んだら RAM を照合する。
//   $00-$07 = $40 | ボタン (A,B,Select,Start,上,下,左,右 の順)
//   $08,$09 = $41 (8 回読んだあとは 1)    $10 = $40
`timescale 1ns/1ps

module tb_pad;
  reg clk = 0;
  always #5 clk = ~clk;

  reg         run = 0;
  reg  [7:0]  pad = 0;
  reg         prg_we = 0;
  reg  [12:0] prg_waddr = 0;
  reg  [31:0] prg_wdata = 0;

  nes_core core
    (.clk(clk), .run(run), .prg16(1'b0), .mirror_v(1'b0), .pad(pad),
     .chr_we(1'b0), .chr_waddr(13'd0), .chr_wdata(8'd0),
     .pix_we(), .pix_x(), .pix_y(), .pix_c(), .ppu_frames(),
     .prg_we(prg_we), .prg_waddr(prg_waddr), .prg_wdata(prg_wdata),
     .wram_raddr(11'd0), .wram_rdata(),
     .dbg_pc(), .cpu_cycles(), .cpu_sync(), .cpu_addr());

  reg [31:0] prg32 [0:8191];
  integer i, err;

  task check(input [7:0] p);
    reg [7:0] c0, e;
    begin
      pad = p;
      c0 = core.wram[11'h20];
      while (core.wram[11'h20] != c0 + 8'd2) @(posedge clk);
      for (i = 0; i < 10; i = i + 1) begin
        e = (i < 8) ? (8'h40 | p[i]) : 8'h41;
        if (core.wram[i] !== e) begin
          err = err + 1; $display("NG pad=%h $%02h = %h (期待 %h)", p, i, core.wram[i], e);
        end
      end
      if (core.wram[11'h10] !== 8'h40) begin
        err = err + 1; $display("NG pad=%h $10 = %h (期待 40)", p, core.wram[11'h10]);
      end
      $write("pad=%h:", p);
      for (i = 0; i < 10; i = i + 1) $write(" %h", core.wram[i]);
      $write(" / $10=%h\n", core.wram[11'h10]);
    end
  endtask

  initial begin
    err = 0;
    $readmemh("pad_prg.hex", prg32);
    for (i = 0; i < 8192; i = i + 1) begin
      @(posedge clk); prg_we <= 1; prg_waddr <= i; prg_wdata <= prg32[i];
    end
    @(posedge clk); prg_we <= 0;
    @(posedge clk); run <= 1;

    check(8'hA5);
    check(8'h5A);
    check(8'hFF);
    check(8'h00);
    if (err == 0) $display("PASS pad");
    else          $display("FAIL pad: %0d 個不一致", err);
    $finish;
  end

  initial begin
    #50_000_000;
    $display("FAIL timeout");
    $finish;
  end
endmodule
