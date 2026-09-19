// ============================================================
//  scope_pipe — 画素座標から「セル画像のどこを見ているか」を求める
//
//  参照実装 (E:/Dropbox/claude/APP/kaleidoscope/index.html の SCOPE_FS) の
//  光線追跡を、1画素/クロックの K 段パイプラインにしたもの。
//
//  前段 (setup)
//    sp    = 画面中心からの位置 (縦を 1 とした正規化座標)
//    slope = sp / focal            … 視線が奥へ 1cm 進むごとの断面での移動
//    p     = slope * Z_MIRROR      … 鏡の手前の端での位置
//    三角形の外なら黒 (筒の縁)
//
//  本体 (scope_stage を K 段)
//    鏡に当たるたびに反射。remain (= Z_CELL - Z_MIRROR) を消費し切ったら終了。
//
//  後段 (out)
//    c  = p / TUBE_R   → セル画像の添字 (0 .. CELL_N-1)
//
//  遅延 LATENCY = SETUP_LAT + K*12 + OUT_LAT。
//  vga_iface の PIXEL_DELAY をこれに合わせること。
// ============================================================

module scope_pipe
  #(
    parameter K        = 16,     // 反射段数
    parameter CELL_BITS = 8,     // セル画像の一辺 = 2^CELL_BITS
    parameter P_F      = 15,
    parameter N_F      = 16,
    parameter A_F      = 14,
    parameter D_F      = 15,
    parameter Q_F      = 14,
    parameter Q_W      = 20,
    // 影のずらし量。参照実装の (0.012, -0.016) を添字に直したもの
    //   round(0.012 * CELL_N/2) = +2,  round(-0.016 * CELL_N/2) = -2  (CELL_N=256)
    parameter signed [7:0] SHADOW_X =  8'sd2,
    parameter signed [7:0] SHADOW_Y = -8'sd2,
    parameter LUT_FILE = "recip_lut.hex",
    parameter SEAM_LUT_FILE = "seam_lut.hex"
    )
  (
   input wire                clk,

   // 画素座標 (vga_iface の count_h / count_v)
   input wire [10:0]         count_h,
   input wire [10:0]         count_v,

   // パラメータ (PS が AXI で書く。段2 では rtl_top が定数を与える)
   input wire signed [17:0]  kx,        // 2^26 / (2 * VGA_HEIGHT * focal)
   input wire signed [17:0]  z_mirror,  // Q16  のぞき穴 → 鏡の手前の端 (cm)
   input wire [Q_W-1:0]      remain0,   // Q_F  Z_CELL - Z_MIRROR (cm)
   input wire signed [17:0]  inv_tube_r,// Q16  1 / TUBE_R
   input wire signed [17:0]  cos_t,     // Q15  セルの回転 (筒を回した見え方)
   input wire signed [17:0]  sin_t,     // Q15
   input wire signed [17:0]  cell_gap,  // Q16  手前層 → 奥層 (cm)。視差を作る
   input wire signed [17:0]  nx0, ny0, wd0,
   input wire signed [17:0]  nx1, ny1, wd1,
   input wire signed [17:0]  nx2, ny2, wd2,
   input wire signed [17:0]  vx0, vy0,      // 三角形の頂点 (鏡の合わせ目用)
   input wire signed [17:0]  vx1, vy1,
   input wire signed [17:0]  vx2, vy2,
   input wire                mirror2,

   // 出力: セル画像を引く添字を3つ出す
   output wire [CELL_BITS-1:0] out_fx, out_fy,   // 手前層
   output wire [CELL_BITS-1:0] out_bx, out_by,   // 奥層 (CELL_GAP 分ずれた位置)
   output wire [CELL_BITS-1:0] out_sx, out_sy,   // 影 (手前層の α をずらして読む)
   output wire [4:0]           out_nrefl,
   output wire [15:0]          out_seam,
   output wire                 out_black
   );

  localparam SETUP_LAT = 4;
  localparam STAGE_LAT = 12;
  localparam OUT_LAT   = 3;
  localparam LATENCY   = SETUP_LAT + K*STAGE_LAT + OUT_LAT;

  localparam SH_A = P_F + N_F - A_F;

  // 段ごとの 1/e^2。e = 0.03 + 0.004*段番号 なので
  //   INV_E2 = round(2^6 / e^2) = round(64e6 / (30 + 4*i)^2)
  // 整数だけで書ける (real を使うと合成系で扱いが変わるため)
  function integer inv_e2;
    input integer i;
    integer d;
    begin
      d = (30 + 4*i) * (30 + 4*i);
      inv_e2 = (64000000 + d/2) / d;
    end
  endfunction

  // ============ setup S0: 画面中心からのオフセット ============
  //   hn = 2h - (W-1),  vn = (H-1) - 2v    (0.5 画素を整数のまま扱うため 2 倍)
  reg signed [12:0] hn_0, vn_0;

  always @(posedge clk) begin
    hn_0 <= $signed({2'b00, count_h}) * 2 - 13'sd1279;
    vn_0 <= 13'sd719 - $signed({2'b00, count_v}) * 2;
  end

  // ============ setup S1: slope = sp / focal ============
  //   slope_q15 = hn * kx >> KX_SH,  kx = 2^(P_F+KX_SH) / (2*VGA_HEIGHT*focal)
  //
  //   KX_SH = 11 にしてある。12 だと zoom を小さく (広角に) したとき
  //   kx = 2^27/(1440*0.85*zoom) が 18bit (131071) を超えて模様が壊れる。
  //   境界は zoom = 0.837 で、実機でちょうどそこで崩れるのを確認した。
  //   11 なら zoom 0.5 でも kx = 109655 で収まる。
  //   slope の分解能は Q15 のままなので精度は落ちない。
  localparam KX_SH = 11;

  wire signed [30:0] slx_f = hn_0 * kx;
  wire signed [30:0] sly_f = vn_0 * kx;

  reg signed [17:0] slx_1, sly_1;

  always @(posedge clk) begin
    slx_1 <= $signed(slx_f[KX_SH+17 : KX_SH]);
    sly_1 <= $signed(sly_f[KX_SH+17 : KX_SH]);
  end

  // ============ setup S2: p = slope * Z_MIRROR ============
  wire signed [35:0] p0x_f = slx_1 * z_mirror;
  wire signed [35:0] p0y_f = sly_1 * z_mirror;

  reg signed [17:0] px_2, py_2, dx_2, dy_2;

  always @(posedge clk) begin
    px_2 <= $signed(p0x_f[33:16]);
    py_2 <= $signed(p0y_f[33:16]);
    dx_2 <= slx_1;
    dy_2 <= sly_1;
  end

  // ============ setup S3: 三角形の外か (筒の縁) ============
  wire signed [35:0] q0 = px_2 * nx0 + py_2 * ny0;
  wire signed [35:0] q1 = px_2 * nx1 + py_2 * ny1;
  wire signed [35:0] q2 = px_2 * nx2 + py_2 * ny2;
  wire black_w = ($signed(q0[SH_A+17:SH_A]) > wd0) |
                 ($signed(q1[SH_A+17:SH_A]) > wd1) |
                 ($signed(q2[SH_A+17:SH_A]) > wd2);

  reg signed [17:0] px_3, py_3, dx_3, dy_3;
  reg               bk_3;

  always @(posedge clk) begin
    px_3 <= px_2;  py_3 <= py_2;
    dx_3 <= dx_2;  dy_3 <= dy_2;
    bk_3 <= black_w;
  end

  // ============ 本体: scope_stage を K 段 ============
  wire signed [17:0] s_px   [0:K];
  wire signed [17:0] s_py   [0:K];
  wire signed [17:0] s_dx   [0:K];
  wire signed [17:0] s_dy   [0:K];
  wire [Q_W-1:0]     s_rm   [0:K];
  wire [4:0]         s_nr   [0:K];
  wire [15:0]        s_sm   [0:K];
  wire               s_done [0:K];
  wire               s_bk   [0:K];

  assign s_px[0]   = px_3;
  assign s_py[0]   = py_3;
  assign s_dx[0]   = dx_3;
  assign s_dy[0]   = dy_3;
  assign s_rm[0]   = remain0;
  assign s_nr[0]   = 5'd0;
  assign s_sm[0]   = 16'd32768;          // seam = 1.0 (Q15)
  assign s_done[0] = bk_3;
  assign s_bk[0]   = bk_3;

  genvar g;
  generate
    for (g = 0; g < K; g = g + 1) begin: stage
      scope_stage #(.P_F(P_F), .N_F(N_F), .A_F(A_F), .D_F(D_F),
                    .Q_F(Q_F), .Q_W(Q_W), .INV_E2(inv_e2(g)),
                    .LUT_FILE(LUT_FILE), .SEAM_LUT_FILE(SEAM_LUT_FILE))
      u (.clk(clk),
         .nx0(nx0), .ny0(ny0), .wd0(wd0),
         .nx1(nx1), .ny1(ny1), .wd1(wd1),
         .nx2(nx2), .ny2(ny2), .wd2(wd2),
         .vx0(vx0), .vy0(vy0),
         .vx1(vx1), .vy1(vy1),
         .vx2(vx2), .vy2(vy2),
         .mirror2(mirror2),
         .in_px(s_px[g]), .in_py(s_py[g]),
         .in_dx(s_dx[g]), .in_dy(s_dy[g]),
         .in_remain(s_rm[g]), .in_nrefl(s_nr[g]), .in_seam(s_sm[g]),
         .in_done(s_done[g]), .in_black(s_bk[g]),
         .out_px(s_px[g+1]), .out_py(s_py[g+1]),
         .out_dx(s_dx[g+1]), .out_dy(s_dy[g+1]),
         .out_remain(s_rm[g+1]), .out_nrefl(s_nr[g+1]), .out_seam(s_sm[g+1]),
         .out_done(s_done[g+1]), .out_black(s_bk[g+1]));
    end
  endgenerate

  // 反射上限に達してまだ残りがある画素は、最後にまとめて直進させる
  wire signed [37:0] fdx = s_dx[K] * $signed({1'b0, s_rm[K]});
  wire signed [37:0] fdy = s_dy[K] * $signed({1'b0, s_rm[K]});
  wire signed [17:0] fpx = s_done[K] ? s_px[K] : s_px[K] + $signed(fdx[Q_F+17:Q_F]);
  wire signed [17:0] fpy = s_done[K] ? s_py[K] : s_py[K] + $signed(fdy[Q_F+17:Q_F]);

  // ============ out O0: セル上の位置を2つ作る ============
  //   手前層  c  = p / TUBE_R
  //   奥層    cB = (p + dir*CELL_GAP) / TUBE_R
  //
  //   光線を正規化していないので、参照実装の dir*sl*CELL_GAP は
  //   そのまま我々の dir*CELL_GAP になる。この視差が2層の立体感を作る。
  wire signed [35:0] gx = s_dx[K] * cell_gap;          // Q15 * Q16 = Q31
  wire signed [35:0] gy = s_dy[K] * cell_gap;
  wire signed [17:0] bpx = fpx + $signed(gx[33:16]);
  wire signed [17:0] bpy = fpy + $signed(gy[33:16]);

  wire signed [35:0] cxf_f = fpx * inv_tube_r;
  wire signed [35:0] cyf_f = fpy * inv_tube_r;
  wire signed [35:0] cxb_f = bpx * inv_tube_r;
  wire signed [35:0] cyb_f = bpy * inv_tube_r;

  reg signed [17:0] cxf_o, cyf_o, cxb_o, cyb_o;
  reg [4:0]         nr_o;
  reg [15:0]        sm_o;
  reg               bk_o;

  always @(posedge clk) begin
    cxf_o <= $signed(cxf_f[33:16]);
    cyf_o <= $signed(cyf_f[33:16]);
    cxb_o <= $signed(cxb_f[33:16]);
    cyb_o <= $signed(cyb_f[33:16]);
    nr_o  <= s_nr[K];
    sm_o  <= s_sm[K];
    bk_o  <= s_bk[K];
  end

  // ============ out O1: セルを回す ============
  //   筒を回すと、鏡から見たセルの模様が回る。
  //   c' = rot(theta) * c   (cos/sin は PS が計算して AXI で渡す)
  wire signed [35:0] fx0 = cxf_o * cos_t;
  wire signed [35:0] fx1 = cyf_o * sin_t;
  wire signed [35:0] fy0 = cxf_o * sin_t;
  wire signed [35:0] fy1 = cyf_o * cos_t;
  wire signed [35:0] bx0 = cxb_o * cos_t;
  wire signed [35:0] bx1 = cyb_o * sin_t;
  wire signed [35:0] by0 = cxb_o * sin_t;
  wire signed [35:0] by1 = cyb_o * cos_t;

  reg signed [17:0] cxf_r, cyf_r, cxb_r, cyb_r;
  reg [4:0]         nr_r;
  reg [15:0]        sm_r;
  reg               bk_r;

  always @(posedge clk) begin
    cxf_r <= $signed(fx0[32:15]) - $signed(fx1[32:15]);
    cyf_r <= $signed(fy0[32:15]) + $signed(fy1[32:15]);
    cxb_r <= $signed(bx0[32:15]) - $signed(bx1[32:15]);
    cyb_r <= $signed(by0[32:15]) + $signed(by1[32:15]);
    nr_r  <= nr_o;
    sm_r  <= sm_o;
    bk_r  <= bk_o;
  end

  // ============ out O2: セル画像の添字 ============
  //   ix = (c + 1) / 2 * CELL_N    (c は Q P_F の [-1,1])
  localparam SH_IX = P_F + 1 - CELL_BITS;

  //   影は手前層の α を SHADOW_X / SHADOW_Y だけずらして読む。
  //   参照実装の (0.012, -0.016) を添字に直した値 (CELL_N=256 なら +2, -2)。
  wire signed [18:0] uxf = cxf_r + (19'sd1 <<< P_F);
  wire signed [18:0] uyf = cyf_r + (19'sd1 <<< P_F);
  wire signed [18:0] uxb = cxb_r + (19'sd1 <<< P_F);
  wire signed [18:0] uyb = cyb_r + (19'sd1 <<< P_F);

  function [CELL_BITS-1:0] to_ix;
    input signed [18:0] u;
    begin
      to_ix = (u < 0) ? {CELL_BITS{1'b0}} :
              (u >= (19'sd1 <<< (P_F+1))) ? {CELL_BITS{1'b1}} : u[SH_IX +: CELL_BITS];
    end
  endfunction

  wire [CELL_BITS-1:0] fx_w = to_ix(uxf);
  wire [CELL_BITS-1:0] fy_w = to_ix(uyf);

  reg [CELL_BITS-1:0] fx_o, fy_o, bx_o, by_o, sx_o, sy_o;
  reg [4:0]           nr_o2;
  reg [15:0]          sm_o2;
  reg                 bk_o2;

  always @(posedge clk) begin
    fx_o <= fx_w;
    fy_o <= fy_w;
    bx_o <= to_ix(uxb);
    by_o <= to_ix(uyb);
    sx_o <= fx_w + SHADOW_X[CELL_BITS-1:0];   // 端は巻き込む。影なので支障ない
    sy_o <= fy_w + SHADOW_Y[CELL_BITS-1:0];
    nr_o2 <= nr_r;
    sm_o2 <= sm_r;
    bk_o2 <= bk_r;
  end

  assign out_fx    = fx_o;
  assign out_fy    = fy_o;
  assign out_bx    = bx_o;
  assign out_by    = by_o;
  assign out_sx    = sx_o;
  assign out_sy    = sy_o;
  assign out_nrefl = nr_o2;
  assign out_seam  = sm_o2;
  assign out_black = bk_o2;

endmodule
