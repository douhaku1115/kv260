// ============================================================
//  tb_scope_pipe — scope_pipe 単体を tools/fx_scope.py と照合する (段9 視線の傾き)
//
//  python tools/tilt_tb.py gen <傾き> <方向> <間引き> が書いた simbuild/tilt_par.hex
//  (視線の係数・鏡の形・間引き) を読み、画面を間引きながら 1 画素/クロックで流す。
//  出力を 1 行 1 画素 "fx fy nrefl black seam" (16 進) で tilt_out.txt に書く。
//  照合は python tools/tilt_tb.py cmp ...
// ============================================================
`timescale 1ns / 1ps

module tb_scope_pipe;

  localparam K   = 16;
  localparam LAT = 10 + K*12 + 3;          // scope_pipe の LATENCY

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg [31:0] par [0:31];
  initial $readmemh("tilt_par.hex", par);

  reg  [10:0] count_h = 11'd0, count_v = 11'd0;
  wire [7:0]  fx, fy, bx, by, sx, sy;
  wire signed [17:0] cx, cy;
  wire [4:0]  nrefl;
  wire [15:0] seam;
  wire        black;

  scope_pipe #(.K(K), .CELL_BITS(8)) dut
    (.clk(clk), .count_h(count_h), .count_v(count_v),
     .vax(par[0][17:0]), .vbx(par[1][17:0]), .vcx(par[2]),
     .vay(par[3][17:0]), .vby(par[4][17:0]), .vcy(par[5]),
     .vaz(par[6][17:0]), .vbz(par[7][17:0]), .vcz(par[8]),
     .z_mirror(par[9][17:0]), .remain0(par[10][19:0]), .inv_tube_r(par[11][17:0]),
     .cos_t(18'sd32768), .sin_t(18'sd0), .cell_gap(18'sd22938),
     .nx0(par[12][17:0]), .ny0(par[13][17:0]), .wd0(par[14][17:0]),
     .nx1(par[15][17:0]), .ny1(par[16][17:0]), .wd1(par[17][17:0]),
     .nx2(par[18][17:0]), .ny2(par[19][17:0]), .wd2(par[20][17:0]),
     .vx0(par[21][17:0]), .vy0(par[22][17:0]),
     .vx1(par[23][17:0]), .vy1(par[24][17:0]),
     .vx2(par[25][17:0]), .vy2(par[26][17:0]),
     .mirror2(par[27][0]),
     .out_fx(fx), .out_fy(fy), .out_bx(bx), .out_by(by), .out_sx(sx), .out_sy(sy),
     .out_cx(cx), .out_cy(cy),
     .out_nrefl(nrefl), .out_seam(seam), .out_black(black));

  // 入力の「有効」を LAT クロック遅らせて、出力を拾う印にする
  reg in_vld = 1'b0;
  reg vld [0:LAT-1];
  integer k;
  initial for (k = 0; k < LAT; k = k + 1) vld[k] = 1'b0;
  always @(posedge clk) begin
    vld[0] <= in_vld;
    for (k = 1; k < LAT; k = k + 1) vld[k] <= vld[k-1];
  end

  // out_cx/out_cy は out_fx より 1 クロック早いので 1 段遅らせて並べる
  reg signed [17:0] cx_d, cy_d;
  always @(posedge clk) begin cx_d <= cx; cy_d <= cy; end

  // 前段 (setup) の出力 px_9 .. dy_9 も別のファイルに書く (vld[9] = 入力から 10 クロック)
  integer fs;
  always @(posedge clk)
    if (vld[9])
      $fwrite(fs, "%h %h %h %h\n", dut.px_9, dut.py_9, dut.dx_9, dut.dy_9);

  // 調べたい 1 画素 (par[29], par[30]) の各段の出力を表示する
  reg [10:0] th = 11'h7FF, tv = 11'h7FF;
  reg tgt [0:LAT-1];
  integer m;
  always @(posedge clk) begin
    tgt[0] <= in_vld && count_h == th && count_v == tv;
    for (m = 1; m < LAT; m = m + 1) tgt[m] <= tgt[m-1];
  end
  genvar gs;
  generate
    for (gs = 0; gs <= K; gs = gs + 1) begin: trace
      always @(posedge clk)
        if (tgt[9 + 12*gs] === 1'b1)
          $display("段 %0d: p=(%0d,%0d) d=(%0d,%0d) rm=%0d nr=%0d done=%0d", gs,
                   dut.s_px[gs], dut.s_py[gs], dut.s_dx[gs], dut.s_dy[gs],
                   dut.s_rm[gs], dut.s_nr[gs], dut.s_done[gs]);
    end
  endgenerate

  integer fd, h, v, step, nout;
  always @(posedge clk)
    if (vld[LAT-1]) begin
      $fwrite(fd, "%h %h %h %h %h %h %h\n", fx, fy, nrefl, black, seam, cx_d, cy_d);
      nout = nout + 1;
    end

  initial begin
    nout = 0;
    #1;
    step = par[28];
    if (par[29] !== 32'hxxxxxxxx) begin th = par[29]; tv = par[30]; end
    fd = $fopen("tilt_out.txt", "w");
    fs = $fopen("tilt_setup.txt", "w");
    @(negedge clk);
    for (v = 0; v < 720; v = v + step)
      for (h = 0; h < 1280; h = h + step) begin
        count_h = h;  count_v = v;  in_vld = 1'b1;
        @(negedge clk);
      end
    in_vld = 1'b0;
    repeat (LAT + 4) @(negedge clk);
    $fclose(fd);
    $fclose(fs);
    $display("出力 %0d 画素", nout);
    $finish;
  end

endmodule
