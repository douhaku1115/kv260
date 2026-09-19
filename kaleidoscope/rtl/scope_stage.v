// ============================================================
//  scope_stage — 万華鏡の折り返し 1 反射ぶん
//
//  やること
//    1. 3枚の壁それぞれについて
//         a[w]  = wd[w] - dot(p, n[w])      壁までの距離の分子   (Q4.14)
//         dn[w] = dot(dir, n[w])            近づく速さ           (Q3.15)
//       dn > 0 の壁だけが候補。
//    2. 一番近い壁を選ぶ。除算は使わない:
//         t_i < t_j  <=>  a_i * dn_j < a_j * dn_i     (dn > 0 なので符号は不要)
//    3. 残り距離を越えるなら、そこで打ち切って残りぶん直進する。
//         t >= remain  <=>  a >= remain * dn          (ここも除算不要)
//    4. 越えないなら q = a/dn を 1 回だけ除算して求め、
//         p    += dir * q
//         remain -= q
//         dir   = dir - 2 * dn * n            (反射)
//    5. 鏡の合わせ目: 当たった点が三角形の頂点に近いほど暗くする。
//         dv    = 3頂点までの距離の最小値
//         seam *= mix(0.35, 1.0, smoothstep(0, 0.03+0.004*n, dv))
//       dv の平方根は取らず、dv^2 と (1/e^2) の掛け算で表を引く。
//       e は段ごとに決まる定数なので 1/e^2 もパラメータで渡せる。
//
//  光線は正規化しない。p(z) = slope * z なので媒介変数に z をそのまま使え、
//  remain は全画素で同じ定数 (Z_CELL - Z_MIRROR) から始まる。
//  平方根も正規化の除算も要らない。
//
//  遅延 STAGE_LAT = 12 クロック (本体 9 + 合わせ目 3)。1画素/クロックで流せる。
// ============================================================

module scope_stage
  #(
    parameter P_F = 15,          // p, dir の小数ビット
    parameter N_F = 16,          // 法線の小数ビット
    parameter A_F = 14,          // a, wd の小数ビット
    parameter D_F = 15,          // dn の小数ビット
    parameter Q_F = 14,          // q, remain の小数ビット
    parameter Q_W = 20,          // q, remain のビット幅
    // 鏡の合わせ目
    parameter INV_E2 = 71111,    // round(2^6 / (0.03 + 0.004*段番号)^2)
    parameter DV2_F = 22,        // dv^2 の小数ビット
    parameter U2_F  = 16,        // (dv/e)^2 の小数ビット
    parameter SEAM_F = 15,       // seam の小数ビット
    parameter SEAM_OUT_F = 8,    // 表の値 f の小数ビット
    parameter SEAM_LUT_BITS = 8,
    parameter LUT_FILE = "recip_lut.hex",
    parameter SEAM_LUT_FILE = "seam_lut.hex"
    )
  (
   input wire                    clk,

   // 鏡の三角形 (フレーム中は不変。PS が AXI で書く)
   input wire signed [17:0]      nx0, ny0, wd0,
   input wire signed [17:0]      nx1, ny1, wd1,
   input wire signed [17:0]      nx2, ny2, wd2,
   input wire signed [17:0]      vx0, vy0,      // 頂点 (合わせ目用)
   input wire signed [17:0]      vx1, vy1,
   input wire signed [17:0]      vx2, vy2,
   input wire                    mirror2,      // 1 = 2枚鏡 (底辺 wall2 は鏡でなく黒い面)

   // 入力 (1画素/クロック)
   input wire signed [17:0]      in_px, in_py,
   input wire signed [17:0]      in_dx, in_dy,
   input wire [Q_W-1:0]          in_remain,
   input wire [4:0]              in_nrefl,
   input wire [15:0]             in_seam,
   input wire                    in_done,
   input wire                    in_black,

   // 出力
   output wire signed [17:0]     out_px, out_py,
   output wire signed [17:0]     out_dx, out_dy,
   output wire [Q_W-1:0]         out_remain,
   output wire [4:0]             out_nrefl,
   output wire [15:0]            out_seam,
   output wire                   out_done,
   output wire                   out_black
   );

  localparam SH_A   = P_F + N_F - A_F;   // dot(p,n)   を Q A_F にする右シフト
  localparam SH_D   = P_F + N_F - D_F;   // dot(dir,n) を Q D_F にする右シフト
  localparam SH_OV  = Q_F + D_F - A_F;   // a を remain*dn と比べるための左シフト
  localparam SH_DV2 = 2*P_F - DV2_F;     // 距離の2乗を Q DV2_F にする右シフト
  localparam SH_U2  = DV2_F + 6 - U2_F;  // INV_E2 は Q6 なので
  localparam DIV_LAT = 6;                // divq の遅延

  // ============ T0: a[w], dn[w] を求める ============
  wire signed [35:0] pn0 = in_px * nx0 + in_py * ny0;
  wire signed [35:0] pn1 = in_px * nx1 + in_py * ny1;
  wire signed [35:0] pn2 = in_px * nx2 + in_py * ny2;
  wire signed [35:0] dn0f = in_dx * nx0 + in_dy * ny0;
  wire signed [35:0] dn1f = in_dx * nx1 + in_dy * ny1;
  wire signed [35:0] dn2f = in_dx * nx2 + in_dy * ny2;

  // 部分選択は符号無しになるので $signed で戻すこと (符号付き演算にならず化ける)
  wire signed [17:0] a0_w = wd0 - $signed(pn0[SH_A+17 : SH_A]);
  wire signed [17:0] a1_w = wd1 - $signed(pn1[SH_A+17 : SH_A]);
  wire signed [17:0] a2_w = wd2 - $signed(pn2[SH_A+17 : SH_A]);

  reg signed [17:0] a0_0, a1_0, a2_0;
  reg signed [17:0] d0_0, d1_0, d2_0;
  reg signed [17:0] px_0, py_0, dx_0, dy_0;
  reg [Q_W-1:0]     rm_0;
  reg [4:0]         nr_0;
  reg [15:0]        sm_0;
  reg               dn_0, bk_0;

  always @(posedge clk) begin
    a0_0 <= a0_w[17] ? 18'sd0 : a0_w;     // a は 0 以上に丸める
    a1_0 <= a1_w[17] ? 18'sd0 : a1_w;
    a2_0 <= a2_w[17] ? 18'sd0 : a2_w;
    d0_0 <= $signed(dn0f[SH_D+17 : SH_D]);
    d1_0 <= $signed(dn1f[SH_D+17 : SH_D]);
    d2_0 <= $signed(dn2f[SH_D+17 : SH_D]);
    px_0 <= in_px;  py_0 <= in_py;
    dx_0 <= in_dx;  dy_0 <= in_dy;
    rm_0 <= in_remain;
    nr_0 <= in_nrefl;
    sm_0 <= in_seam;
    dn_0 <= in_done;
    bk_0 <= in_black;
  end

  // ============ T1: 一番近い壁を選ぶ (除算なし) ============
  wire c0 = (d0_0 > 0);
  wire c1 = (d1_0 > 0);
  wire c2 = (d2_0 > 0);

  // t_i < t_j  <=>  a_i * dn_j < a_j * dn_i
  wire signed [35:0] m01 = a0_0 * d1_0;
  wire signed [35:0] m10 = a1_0 * d0_0;
  wire signed [35:0] m02 = a0_0 * d2_0;
  wire signed [35:0] m20 = a2_0 * d0_0;
  wire signed [35:0] m12 = a1_0 * d2_0;
  wire signed [35:0] m21 = a2_0 * d1_0;
  wire t01 = (m01 < m10);     // t0 < t1
  wire t02 = (m02 < m20);     // t0 < t2
  wire t12 = (m12 < m21);     // t1 < t2

  wire sel0 = c0 & (~c1 | t01) & (~c2 | t02);
  wire sel1 = ~sel0 & c1 & (~c0 | ~t01) & (~c2 | t12);
  wire sel2 = ~sel0 & ~sel1 & c2;
  wire has  = c0 | c1 | c2;

  reg signed [17:0] as_1, ds_1, nsx_1, nsy_1;
  reg               bot_1, has_1;
  reg signed [17:0] px_1, py_1, dx_1, dy_1;
  reg [Q_W-1:0]     rm_1;
  reg [4:0]         nr_1;
  reg [15:0]        sm_1;
  reg               dn_1, bk_1;

  always @(posedge clk) begin
    as_1  <= sel0 ? a0_0 : sel1 ? a1_0 : a2_0;
    ds_1  <= sel0 ? d0_0 : sel1 ? d1_0 : d2_0;
    nsx_1 <= sel0 ? nx0  : sel1 ? nx1  : nx2;
    nsy_1 <= sel0 ? ny0  : sel1 ? ny1  : ny2;
    bot_1 <= sel2;
    has_1 <= has;
    px_1 <= px_0;  py_1 <= py_0;
    dx_1 <= dx_0;  dy_1 <= dy_0;
    rm_1 <= rm_0;
    nr_1 <= nr_0;
    sm_1 <= sm_0;
    dn_1 <= dn_0;
    bk_1 <= bk_0;
  end

  // ============ 除算 q = a/dn を開始 (6クロック) ============
  wire [Q_W-1:0] q_div;

  divq #(.A_F(A_F), .D_F(D_F), .Q_F(Q_F), .Q_W(Q_W), .LUT_FILE(LUT_FILE))
  divq_i (.clk(clk), .a(as_1), .dn(ds_1), .q(q_div));

  // ============ T2: 打ち切り判定と、打ち切る画素の直進 ============
  //   t >= remain  <=>  a << SH_OV >= remain * dn
  wire [37:0] rm_dn = rm_1 * $unsigned(ds_1[17] ? 18'd0 : ds_1);
  wire [37:0] a_sh  = {20'd0, $unsigned(as_1)} << SH_OV;
  wire        over  = (a_sh >= rm_dn);
  wire        fin   = ~dn_1 & (~has_1 | over);
  wire        hit   = ~dn_1 & has_1 & ~over;

  wire signed [37:0] dxr = dx_1 * $signed({1'b0, rm_1});
  wire signed [37:0] dyr = dy_1 * $signed({1'b0, rm_1});

  // 打ち切る画素は残り距離ぶん直進させてしまう
  wire signed [17:0] px_fin = px_1 + $signed(dxr[Q_F+17 : Q_F]);
  wire signed [17:0] py_fin = py_1 + $signed(dyr[Q_F+17 : Q_F]);

  // 除算の遅延に合わせて DIV_LAT 段ぶん持ち回す
  localparam CW = 18*4 + Q_W + 5 + 16 + 3 + 18*3 + 1;   // 持ち回すビット幅

  wire [CW-1:0] carry_in = {
    (fin ? px_fin : px_1), (fin ? py_fin : py_1),
    dx_1, dy_1,
    (fin ? {Q_W{1'b0}} : rm_1),
    nr_1,
    sm_1,
    (dn_1 | fin), bk_1, hit,
    ds_1, nsx_1, nsy_1,
    bot_1
  };

  reg [CW-1:0] carry [0:DIV_LAT-1];
  integer k;
  always @(posedge clk) begin
    carry[0] <= carry_in;
    for (k = 1; k < DIV_LAT; k = k + 1)
      carry[k] <= carry[k-1];
  end

  wire [CW-1:0]      c = carry[DIV_LAT-1];
  wire signed [17:0] px_c  = c[CW-1     -: 18];
  wire signed [17:0] py_c  = c[CW-19    -: 18];
  wire signed [17:0] dx_c  = c[CW-37    -: 18];
  wire signed [17:0] dy_c  = c[CW-55    -: 18];
  wire [Q_W-1:0]     rm_c  = c[CW-73    -: Q_W];
  wire [4:0]         nr_c  = c[CW-73-Q_W -: 5];
  wire [15:0]        sm_c  = c[CW-78-Q_W -: 16];
  wire               dn_c  = c[CW-94-Q_W];
  wire               bk_c  = c[CW-95-Q_W];
  wire               hit_c = c[CW-96-Q_W];
  wire signed [17:0] ds_c  = c[CW-97-Q_W  -: 18];
  wire signed [17:0] nsx_c = c[CW-115-Q_W -: 18];
  wire signed [17:0] nsy_c = c[CW-133-Q_W -: 18];
  wire               bot_c = c[0];

  // ============ T8: 交点まで進めて反射させる ============
  wire signed [37:0] dxq = dx_c * $signed({1'b0, q_div});
  wire signed [37:0] dyq = dy_c * $signed({1'b0, q_div});
  wire signed [17:0] px_hit = px_c + $signed(dxq[Q_F+17 : Q_F]);
  wire signed [17:0] py_hit = py_c + $signed(dyq[Q_F+17 : Q_F]);

  // dir = dir - 2 * dn * n
  wire signed [18:0] two_dn = {ds_c, 1'b0};
  wire signed [36:0] rx = two_dn * nsx_c;
  wire signed [36:0] ry = two_dn * nsy_c;
  wire signed [17:0] dx_ref = dx_c - $signed(rx[N_F+17 : N_F]);
  wire signed [17:0] dy_ref = dy_c - $signed(ry[N_F+17 : N_F]);

  wire kill = hit_c & bot_c & mirror2;   // 2枚鏡で底辺に当たったら黒

  reg signed [17:0] px_s0, py_s0, dx_s0, dy_s0;
  reg [Q_W-1:0]     rm_s0;
  reg [4:0]         nr_s0;
  reg [15:0]        sm_s0;
  reg               dn_s0, bk_s0, hit_s0;

  always @(posedge clk) begin
    px_s0  <= hit_c ? px_hit : px_c;
    py_s0  <= hit_c ? py_hit : py_c;
    dx_s0  <= hit_c ? dx_ref : dx_c;
    dy_s0  <= hit_c ? dy_ref : dy_c;
    rm_s0  <= hit_c ? (rm_c > q_div ? rm_c - q_div : {Q_W{1'b0}}) : rm_c;
    nr_s0  <= hit_c ? nr_c + 5'd1 : nr_c;
    sm_s0  <= sm_c;
    dn_s0  <= dn_c | kill;
    bk_s0  <= bk_c | kill;
    hit_s0 <= hit_c & ~kill;
  end

  // ============ 合わせ目 S1: 頂点までの距離の2乗の最小値 ============
  wire signed [18:0] e0x = px_s0 - vx0;
  wire signed [18:0] e0y = py_s0 - vy0;
  wire signed [18:0] e1x = px_s0 - vx1;
  wire signed [18:0] e1y = py_s0 - vy1;
  wire signed [18:0] e2x = px_s0 - vx2;
  wire signed [18:0] e2y = py_s0 - vy2;

  wire [38:0] q0d = e0x * e0x + e0y * e0y;     // Q(2*P_F)
  wire [38:0] q1d = e1x * e1x + e1y * e1y;
  wire [38:0] q2d = e2x * e2x + e2y * e2y;

  wire [38:0] qmin01 = (q0d < q1d) ? q0d : q1d;
  wire [38:0] qmin   = (qmin01 < q2d) ? qmin01 : q2d;
  wire [38:0] qsh    = qmin >> SH_DV2;         // Q DV2_F

  reg [17:0] dv2_s1;
  reg signed [17:0] px_s1, py_s1, dx_s1, dy_s1;
  reg [Q_W-1:0]     rm_s1;
  reg [4:0]         nr_s1;
  reg [15:0]        sm_s1;
  reg               dn_s1, bk_s1, hit_s1;

  always @(posedge clk) begin
    dv2_s1 <= (qsh[38:18] != 0) ? 18'h3FFFF : qsh[17:0];
    px_s1 <= px_s0;  py_s1 <= py_s0;
    dx_s1 <= dx_s0;  dy_s1 <= dy_s0;
    rm_s1 <= rm_s0;  nr_s1 <= nr_s0;  sm_s1 <= sm_s0;
    dn_s1 <= dn_s0;  bk_s1 <= bk_s0;  hit_s1 <= hit_s0;
  end

  // ============ 合わせ目 S2: u2 = (dv/e)^2 を求めて表を引く ============
  (* rom_style = "distributed" *)
  reg [8:0] seam_lut [0:(1<<SEAM_LUT_BITS)-1];
  initial $readmemh(SEAM_LUT_FILE, seam_lut);

  wire [35:0] u2f = dv2_s1 * INV_E2;
  wire [23:0] u2  = u2f >> SH_U2;              // Q U2_F
  wire [SEAM_LUT_BITS-1:0] sidx =
       (u2[23:U2_F] != 0) ? {SEAM_LUT_BITS{1'b1}} : u2[U2_F-1 -: SEAM_LUT_BITS];

  reg [8:0] f_s2;
  reg signed [17:0] px_s2, py_s2, dx_s2, dy_s2;
  reg [Q_W-1:0]     rm_s2;
  reg [4:0]         nr_s2;
  reg [15:0]        sm_s2;
  reg               dn_s2, bk_s2, hit_s2;

  always @(posedge clk) begin
    f_s2  <= seam_lut[sidx];
    px_s2 <= px_s1;  py_s2 <= py_s1;
    dx_s2 <= dx_s1;  dy_s2 <= dy_s1;
    rm_s2 <= rm_s1;  nr_s2 <= nr_s1;  sm_s2 <= sm_s1;
    dn_s2 <= dn_s1;  bk_s2 <= bk_s1;  hit_s2 <= hit_s1;
  end

  // ============ 合わせ目 S3: seam に掛ける ============
  wire [24:0] sm_mul = sm_s2 * f_s2;

  reg signed [17:0] px_o, py_o, dx_o, dy_o;
  reg [Q_W-1:0]     rm_o;
  reg [4:0]         nr_o;
  reg [15:0]        sm_o;
  reg               dn_o, bk_o;

  always @(posedge clk) begin
    px_o <= px_s2;  py_o <= py_s2;
    dx_o <= dx_s2;  dy_o <= dy_s2;
    rm_o <= rm_s2;
    nr_o <= nr_s2;
    // (seam * f) >> SEAM_OUT_F。seam=1.0, f=1.0 のとき 32768 ちょうどになる
    sm_o <= hit_s2 ? (sm_mul[24] ? 16'hFFFF : sm_mul[SEAM_OUT_F+15 -: 16]) : sm_s2;
    dn_o <= dn_s2;
    bk_o <= bk_s2;
  end

  assign out_px     = px_o;
  assign out_py     = py_o;
  assign out_dx     = dx_o;
  assign out_dy     = dy_o;
  assign out_remain = rm_o;
  assign out_nrefl  = nr_o;
  assign out_seam   = sm_o;
  assign out_done   = dn_o;
  assign out_black  = bk_o;

endmodule
