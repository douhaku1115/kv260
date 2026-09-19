// ============================================================
//  tb_probe — scope_pipe と cell_mem だけを回して中身を覗く
//
//  1 ライン分 (count_v 固定) の画素を流し込み、出てきた
//  ix / iy / nrefl / black / セルの色を表示する。
//  tb_scope が真っ黒になったときの切り分け用。
// ============================================================
`timescale 1ns / 1ps

module tb_probe;

  localparam K         = 16;
  localparam CELL_BITS = 8;
  localparam LAT       = 4 + K*9 + 2;   // scope_pipe の遅延

  localparam signed [17:0] NX0 = -18'sd64276, NY0 =  18'sd12785, WD0 = 18'sd6553;
  localparam signed [17:0] NX1 =  18'sd64276, NY1 =  18'sd12785, WD1 = 18'sd6553;
  localparam signed [17:0] NX2 =  18'sd0,     NY2 = -18'sd65536, WD2 = 18'sd31026;
  localparam signed [17:0] KX       = 18'sd109655;
  localparam signed [17:0] Z_MIRROR = 18'sd19661;
  localparam signed [17:0] INV_TR   = 18'sd29127;
  localparam [19:0]        REMAIN0  = 20'd194970;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg [10:0] ch = 11'd0;
  reg [10:0] cv = 11'd200;

  wire [CELL_BITS-1:0] ix, iy;
  wire [4:0]           nrefl;
  wire                 black;
  wire [15:0]          rgb;

  scope_pipe #(.K(K), .CELL_BITS(CELL_BITS), .LUT_FILE("recip_lut.hex"))
  sp (.clk(clk), .count_h(ch), .count_v(cv),
      .kx(KX), .z_mirror(Z_MIRROR), .remain0(REMAIN0), .inv_tube_r(INV_TR),
      .nx0(NX0), .ny0(NY0), .wd0(WD0),
      .nx1(NX1), .ny1(NY1), .wd1(WD1),
      .nx2(NX2), .ny2(NY2), .wd2(WD2),
      .mirror2(1'b0),
      .out_ix(ix), .out_iy(iy), .out_nrefl(nrefl), .out_black(black));

  cell_mem #(.CELL_BITS(CELL_BITS), .INIT_FILE("cell_init.hex"))
  cm (.clk(clk), .ix(ix), .iy(iy), .rgb565(rgb));

  integer n = 0;

  initial begin
    $display("cell_init.hex の先頭: %04x %04x  中央: %04x",
             cm.mem[0], cm.mem[1], cm.mem[16'h8080]);
    $display("recip_lut の先頭: %05x  末尾: %05x",
             sp.stage[0].u.divq_i.lut[0], sp.stage[0].u.divq_i.lut[511]);
  end

  always @(posedge clk) begin
    ch <= ch + 11'd1;
    n  <= n + 1;

    // 入力した画素が LAT クロック後に出てくる。さらに cell_mem が 2 クロック。
    if (n > LAT + 2 && ((n - LAT - 2) % 160 == 0) && (n - LAT - 2) <= 1280)
      $display("h=%4d  ix=%3d iy=%3d nrefl=%2d black=%b rgb=%04x",
               n - LAT - 3, ix, iy, nrefl, black, rgb);

    if (n > LAT + 1400) $finish;
  end

  // 1段目の中身も覗く (最初の反射が正しいか)
  initial begin
    #200;
    $display("--- stage0 の様子 (h はこの時点でパイプ内) ---");
  end

endmodule
