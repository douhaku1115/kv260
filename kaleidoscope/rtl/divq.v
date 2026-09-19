// ============================================================
//  divq — 万華鏡の光線追跡で使う除算  q = a / dn
//
//  a  : Q4.14  18bit 符号付き (0 以上)   壁までの距離の分子
//  dn : Q3.15  18bit 符号付き (正)       光線方向と壁法線の内積
//  q  : Q6.14  Q_W bit 符号なし          交差までの媒介変数 (0〜11.9)
//
//  方式
//    先頭1の位置 nbits を求めて仮数を mn ∈ [2^17, 2^18) に正規化し、
//    512エントリの逆数表 → ニュートン1回 で 1/m を 18bit 精度まで上げ、
//    a を掛けてから 2+nbits ビット右シフトする。
//    除算器 IP を使わずに 1クロック1データで流せる。
//
//    dn      = mn * 2^(nbits-18)              (mn = m * 2^18, m ∈ [0.5,1))
//    dn_real = m * 2^(nbits - D_F)
//    q_real  = a_real / dn_real
//    q       = a * y1 >> (A_F + LUT_F - Q_F - D_F + nbits)
//
//  遅延 LATENCY = 6 クロック。
// ============================================================

module divq
  #(
    parameter A_F = 14,          // a の小数ビット
    parameter D_F = 15,          // dn の小数ビット
    parameter Q_F = 14,          // q の小数ビット
    parameter Q_W = 20,          // q のビット幅
    parameter LUT_F = 17,        // 逆数表の小数ビット (Q1.17)
    parameter LUT_BITS = 9,      // 逆数表のアドレス幅 (512 エントリ)
    parameter LUT_FILE = "recip_lut.hex"
    )
  (
   input wire               clk,
   input wire signed [17:0] a,    // >= 0
   input wire signed [17:0] dn,   // >  0
   output wire [Q_W-1:0]    q
   );

  localparam LATENCY  = 6;
  localparam SH_BASE  = A_F + LUT_F - Q_F - D_F;   // 既定値では 2

  // ---- 逆数表 ----
  (* rom_style = "distributed" *)
  reg [18:0] lut [0:(1<<LUT_BITS)-1];
  initial $readmemh(LUT_FILE, lut);

  // ---- P0: 先頭1の位置 nbits と正規化仮数 mn ----
  integer   i;
  reg [4:0] nb;
  reg [17:0] dnu;

  always @* begin
    dnu = dn[17] ? 18'd0 : dn[17:0];     // 負は来ない前提。来たら 0 扱い
    nb  = 5'd0;
    for (i = 0; i < 18; i = i + 1)
      if (dnu[i]) nb = i[4:0] + 5'd1;    // 最上位の 1 の位置 (1 始まり)
  end

  reg [4:0]  nbits_0;
  reg [17:0] mn_0;
  reg [17:0] a_0;

  always @(posedge clk) begin
    nbits_0 <= nb;
    mn_0    <= (nb == 5'd0) ? 18'h20000 : (dnu << (5'd18 - nb));
    a_0     <= a[17] ? 18'd0 : a;        // 負は 0 に丸める
  end

  // ---- P1: 表引き ----
  reg [18:0] y0_1;
  reg [17:0] mn_1;
  reg [4:0]  nbits_1;
  reg [17:0] a_1;

  always @(posedge clk) begin
    y0_1    <= lut[mn_0[16 : 16-LUT_BITS+1]];   // 最上位ビットの下 LUT_BITS ビット
    mn_1    <= mn_0;
    nbits_1 <= nbits_0;
    a_1     <= a_0;
  end

  // ---- P2: my = m * y0  (Q LUT_F) ----
  wire [36:0] mn_y0 = mn_1 * y0_1;              // Q(18 + LUT_F)

  reg [19:0] my_2;
  reg [18:0] y0_2;
  reg [4:0]  nbits_2;
  reg [17:0] a_2;

  always @(posedge clk) begin
    my_2    <= mn_y0[36:18];                    // Q LUT_F, ≈ 2^LUT_F
    y0_2    <= y0_1;
    nbits_2 <= nbits_1;
    a_2     <= a_1;
  end

  // ---- P3: ニュートン1回  y1 = y0 * (2 - m*y0) ----
  wire [19:0] corr   = (20'd1 << (LUT_F+1)) - my_2;   // 2 - my  (Q LUT_F)
  wire [38:0] y0corr = y0_2 * corr;
  wire [21:0] y1_raw = y0corr >> LUT_F;

  reg [18:0] y1_3;
  reg [4:0]  nbits_3;
  reg [17:0] a_3;

  always @(posedge clk) begin
    y1_3    <= (y1_raw[21:19] != 3'd0) ? 19'h7FFFF : y1_raw[18:0];
    nbits_3 <= nbits_2;
    a_3     <= a_2;
  end

  // ---- P4: prod = a * y1 ----
  reg [36:0] prod_4;
  reg [4:0]  nbits_4;

  always @(posedge clk) begin
    prod_4  <= a_3 * y1_3;
    nbits_4 <= nbits_3;
  end

  // ---- P5: 可変シフト  q = prod >> (SH_BASE + nbits) ----
  wire [5:0]  sh      = SH_BASE[5:0] + nbits_4;
  wire [36:0] shifted = prod_4 >> sh;

  reg [Q_W-1:0] q_5;

  always @(posedge clk) begin
    q_5 <= (shifted[36:Q_W] != 0) ? {Q_W{1'b1}} : shifted[Q_W-1:0];
  end

  assign q = q_5;

endmodule
