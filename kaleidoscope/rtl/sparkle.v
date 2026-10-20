// ============================================================
//  sparkle — きらめき層 (段7)
//
//  模様を大きくすると、セル (256x256) の 1 画素が画面で拡大されて、
//  細かい粒が点でなく塊になる。そこで、折り返したあとの細かい座標
//  (scope_pipe の O1、Q15 で 1 画素の 1/256 まである) の上に格子を敷き、
//  マスごとに光る点を 1 つ置いて、画面の画素の細かさで描く。
//
//    ・点の有無・マスの中の位置・光る時刻・色はマスの番号のハッシュで決める
//    ・点の大きさは k (PS が模様の大きさから計算) で画面の画素に合わせる。
//      模様を大きくしても点は大きくならない
//    ・格子の細かさ lv も PS が模様の大きさで選び、画面上の点の間隔をほぼ一定にする
//    ・点はセル座標に置くので、模様と同じく鏡に映り、筒と一緒に回る
//    ・点は必ずマスの 0.2〜0.8 の位置にあり、光る範囲もマスの中で収まるので、
//      隣のマスを調べなくてよい
//
//  計算は tools/sparkle_fx.py と 1 ビットも違わない (tb_sparkle で照合する)。
//  入力から出力まで LAT = 10 クロック。各段の中身は sparkle_fx.py の説明を参照。
// ============================================================

module sparkle
  #(parameter FALL_FILE = "spk_fall.hex",   // exp(-i/64)
    parameter TW_FILE   = "spk_tw.hex")     // (0.5+0.5 sin)^10
  (
   input  wire               clk,
   input  wire signed [17:0] cx, cy,        // 回したあとのセル座標 c (Q15)
   input  wire               en,
   input  wire [2:0]         lv,            // 格子の 1 辺 = 2^lv マス (3〜7)
   input  wire [7:0]         dens,          // 点がある割合 /256
   input  wire [15:0]        k,             // (1 マスの画面画素 / 点の半径)^2  Q8
   input  wire [7:0]         base,          // いつも光っている明るさ (128 = 1.0)
   input  wire [7:0]         flash,         // キラッと光るとき足す明るさ (128 = 1.0)
   input  wire [7:0]         tphase,        // 時刻 (256 で 1 周)
   output reg  [8:0]         out_r, out_g, out_b   // 足し込む明るさ 0〜510
   );

  localparam [15:0] K1 = 16'h9E37, K2 = 16'h7F4B;
  localparam [23:0] K3 = 24'h5BD1E9;
  localparam [17:0] K4 = 18'h2C1B3;
  localparam [15:0] OFF0 = 16'd13107;
  localparam [7:0]  OFFK = 8'd154;

  (* rom_style = "distributed" *) reg [7:0] fall_lut [0:255];
  (* rom_style = "distributed" *) reg [7:0] tw_lut   [0:255];
  initial begin
    $readmemh(FALL_FILE, fall_lut);
    $readmemh(TW_FILE,   tw_lut);
  end

  // ---- P1: u = c + 1 を 0〜65535 に収め、マスの番号と中の位置に分ける ----
  wire signed [18:0] ux_w = cx + 19'sd32768;
  wire signed [18:0] uy_w = cy + 19'sd32768;
  wire [15:0] ux_c = (ux_w < 0) ? 16'd0 : (ux_w > 19'sd65535) ? 16'hFFFF : ux_w[15:0];
  wire [15:0] uy_c = (uy_w < 0) ? 16'd0 : (uy_w > 19'sd65535) ? 16'hFFFF : uy_w[15:0];
  wire [4:0]  sh   = 5'd16 - {2'b00, lv};
  wire [31:0] uxl  = {16'd0, ux_c} << lv;
  wire [31:0] uyl  = {16'd0, uy_c} << lv;

  reg [6:0]  gx1, gy1;
  reg [15:0] frx1, fry1;
  always @(posedge clk) begin
    gx1  <= ux_c >> sh;
    gy1  <= uy_c >> sh;
    frx1 <= uxl[15:0];
    fry1 <= uyl[15:0];
  end

  // ---- P2: a = (gx*K1 ^ gy*K2) の下位 24bit ----
  wire [22:0] mx = gx1 * K1;
  wire [22:0] my = gy1 * K2;
  reg [23:0] a2;
  reg [15:0] frx2, fry2;
  always @(posedge clk) begin
    a2   <= {1'b0, mx ^ my};
    frx2 <= frx1;  fry2 <= fry1;
  end

  // ---- P3: b = a*K3、e = a*K4 (どちらも下位 24bit) ----
  wire [47:0] bm = a2 * K3;
  wire [41:0] em = a2 * K4;
  reg [23:0] b3, e3;
  reg [15:0] frx3, fry3;
  always @(posedge clk) begin
    b3   <= bm[23:0];
    e3   <= em[23:0];
    frx3 <= frx2;  fry3 <= fry2;
  end

  // ---- P4: 混ぜて、点の有無・位置・位相・速さ・色を切り出す ----
  wire [23:0] h4  = b3 ^ (b3 >> 11);
  wire [23:0] e4  = e3 ^ (e3 >> 9);
  wire [15:0] ox4 = h4[15:8]  * OFFK;
  wire [15:0] oy4 = h4[23:16] * OFFK;
  reg        have4;
  reg [16:0] offx4, offy4;
  reg [7:0]  ph4;
  reg [1:0]  rate4, csel4;
  reg [15:0] frx4, fry4;
  always @(posedge clk) begin
    have4 <= en && (h4[7:0] < dens);
    offx4 <= OFF0 + ox4;
    offy4 <= OFF0 + oy4;
    ph4   <= e4[7:0];
    rate4 <= e4[9:8];
    csel4 <= e4[11:10];
    frx4  <= frx3;  fry4 <= fry3;
  end

  // ---- P5: 点からの距離 (マスの中の Q16)、きらめきの表の番地 ----
  wire [10:0] tpr = tphase * {1'b0, 2'b01, rate4};      // tphase * (4 + 速さ)
  reg signed [17:0] dx5, dy5;
  reg [7:0]  t5;
  reg        have5;
  reg [1:0]  csel5;
  always @(posedge clk) begin
    dx5   <= $signed({2'b00, frx4}) - $signed({1'b0, offx4});
    dy5   <= $signed({2'b00, fry4}) - $signed({1'b0, offy4});
    t5    <= tpr[9:2] + ph4;
    have5 <= have4;
    csel5 <= csel4;
  end

  // ---- P6: d2s = (dx^2 + dy^2) >> 16、きらめきの表を引く ----
  wire signed [35:0] dxx = dx5 * dx5;
  wire signed [35:0] dyy = dy5 * dy5;
  wire [35:0] d2 = dxx + dyy;
  reg [19:0] d2s6;
  reg [7:0]  tw6;
  reg        have6;
  reg [1:0]  csel6;
  always @(posedge clk) begin
    d2s6  <= d2[35:16];
    tw6   <= tw_lut[t5];
    have6 <= have5;
    csel6 <= csel5;
  end

  // ---- P7: 減衰の表の番地、きらめきの明るさ ----
  wire [35:0] ag = d2s6 * k;
  wire [15:0] fl = flash * tw6;
  reg [17:0] idx7;
  reg [8:0]  s7;
  reg        have7;
  reg [1:0]  csel7;
  always @(posedge clk) begin
    idx7  <= ag[35:18];
    s7    <= {1'b0, base} + {1'b0, fl[15:8]};
    have7 <= have6;
    csel7 <= csel6;
  end

  // ---- P8: 減衰 (番地が 256 以上なら 0) ----
  reg [7:0]  fall8;
  reg [8:0]  s8;
  reg        have8;
  reg [1:0]  csel8;
  always @(posedge clk) begin
    fall8 <= (idx7 < 18'd256) ? fall_lut[idx7[7:0]] : 8'd0;
    s8    <= s7;
    have8 <= have7;
    csel8 <= csel7;
  end

  // ---- P9: 明るさ = fall * s >> 7 を 511 で切る ----
  wire [16:0] am = fall8 * s8;
  reg [8:0]  amt9;
  reg [1:0]  csel9;
  always @(posedge clk) begin
    amt9  <= !have8 ? 9'd0 : (am[16:7] > 10'd511) ? 9'd511 : am[15:7];
    csel9 <= csel8;
  end

  // ---- P10: 色を掛ける ----
  reg [7:0] cr, cg, cb;
  always @(*) begin
    case (csel9)
      2'd2:    begin cr = 8'd255; cg = 8'd224; cb = 8'd140; end   // 金
      2'd3:    begin cr = 8'd191; cg = 8'd217; cb = 8'd255; end   // 淡い青
      default: begin cr = 8'd255; cg = 8'd255; cb = 8'd255; end   // 白
    endcase
  end
  wire [16:0] rm = amt9 * cr;
  wire [16:0] gm = amt9 * cg;
  wire [16:0] bmc = amt9 * cb;
  always @(posedge clk) begin
    out_r <= rm[16:8];
    out_g <= gm[16:8];
    out_b <= bmc[16:8];
  end

endmodule
