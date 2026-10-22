// ============================================================
// tb_apu.v — 段F: APU の周波数を測る
// ============================================================
//
// tools/apu_test_gen.py の PRG (矩形波 1 と三角波を 440.40Hz に設定) を回し、
//   矩形波 1: 出力が 0 → 0 以外になる時刻の間隔
//   三角波  : ステップが 31 → 0 に戻る時刻の間隔
// から周波数を出す。期待値との差が 0.5Hz 以内なら PASS。
// 最終の音 (audio) の最小・最大も表示する (振れているかの確認)。
`timescale 1ns/1ps

module tb_apu;
  reg clk = 0;
  always #5 clk = ~clk;

  reg         run = 0;
  reg         prg_we = 0;
  reg  [12:0] prg_waddr = 0;
  reg  [31:0] prg_wdata = 0;
  wire signed [15:0] audio;

  nes_core core
    (.clk(clk), .run(run), .prg16(1'b0), .mirror_v(1'b0), .pad(8'd0),
     .chr_we(1'b0), .chr_waddr(13'd0), .chr_wdata(8'd0),
     .pix_we(), .pix_x(), .pix_y(), .pix_c(), .ppu_frames(), .audio(audio),
     .prg_we(prg_we), .prg_waddr(prg_waddr), .prg_wdata(prg_wdata),
     .wram_raddr(11'd0), .wram_rdata(),
     .dbg_pc(), .cpu_cycles(), .cpu_sync(), .cpu_addr());

  // 測る区間 (ns)。最初の 5ms は設定待ち
  localparam real T0 = 5_000_000.0, T1 = 105_000_000.0;
  localparam real EXP = 1789772.727 / (16.0 * 254.0);   // 440.40Hz (三角波も同じ)

  wire [3:0] p1  = core.apu0.p1_out;
  wire [4:0] trs = core.apu0.tr_step;
  reg  [3:0] p1_d  = 0;
  reg  [4:0] trs_d = 0;
  real p1_first, p1_last, tr_first, tr_last;
  integer p1_n = 0, tr_n = 0;
  integer amin = 32767, amax = -32768;

  always @(posedge clk) begin
    p1_d <= p1; trs_d <= trs;
    if ($realtime >= T0 && $realtime < T1) begin
      if (p1_d == 0 && p1 != 0) begin
        if (p1_n == 0) p1_first = $realtime;
        p1_last = $realtime; p1_n = p1_n + 1;
      end
      if (trs_d == 5'd31 && trs == 5'd0) begin
        if (tr_n == 0) tr_first = $realtime;
        tr_last = $realtime; tr_n = tr_n + 1;
      end
      if (audio < amin) amin = audio;
      if (audio > amax) amax = audio;
    end
  end

  reg [31:0] prg32 [0:8191];
  integer i;
  real f1, f2;

  initial begin
    $readmemh("apu_prg.hex", prg32);
    for (i = 0; i < 8192; i = i + 1) begin
      @(posedge clk); prg_we <= 1; prg_waddr <= i; prg_wdata <= prg32[i];
    end
    @(posedge clk); prg_we <= 0;
    @(posedge clk); run <= 1;

    #(T1 + 1000.0);
    f1 = (p1_n > 1) ? (p1_n - 1) / ((p1_last - p1_first) * 1e-9) : 0.0;
    f2 = (tr_n > 1) ? (tr_n - 1) / ((tr_last - tr_first) * 1e-9) : 0.0;
    $display("矩形波1: %0d 周期, %f Hz (期待 %f)", p1_n - 1, f1, EXP);
    $display("三角波 : %0d 周期, %f Hz (期待 %f)", tr_n - 1, f2, EXP);
    $display("audio  : 最小 %0d, 最大 %0d", amin, amax);
    if (f1 > EXP - 0.5 && f1 < EXP + 0.5 && f2 > EXP - 0.5 && f2 < EXP + 0.5 && amax - amin > 1000)
      $display("PASS apu");
    else
      $display("FAIL apu");
    $finish;
  end
endmodule
