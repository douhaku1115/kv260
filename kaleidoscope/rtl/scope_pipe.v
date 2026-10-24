// ============================================================
//  scope_pipe — 画素座標から「セル画像のどこを見ているか」を求める
//
//  参照実装 (E:/Dropbox/claude/APP/kaleidoscope/index.html の SCOPE_FS) の
//  光線追跡を、1画素/クロックの K 段パイプラインにしたもの。
//
//  前段 (setup)
//    sp    = 画面中心からの位置 (縦を 1 とした正規化座標)
//    rd    = 視線の向き行列 * (sp, focal)       … 段9 で視線を傾けられるようにした
//    slope = rd.xy / rd.z                      … 視線が奥へ 1cm 進むごとの断面での移動
//    p     = slope * Z_MIRROR                  … 鏡の手前の端での位置
//    三角形の外 (筒の縁) と、後ろ向きの視線 (rd.z <= 0) は黒
//
//  本体 (scope_stage を K 段)
//    鏡に当たるたびに反射。remain (= Z_CELL - Z_MIRROR) を消費し切ったら終了。
//    K 回反射してもまだ残りがある画素は黒 (段9。直進させると筒の外を引いて筋になる)
//
//  後段 (out)
//    c  = p / TUBE_R   → セル画像の添字 (0 .. CELL_N-1)
//
//  遅延 LATENCY = SETUP_LAT + K*12 + OUT_LAT。
//  vga_iface の PIXEL_DELAY をこれに合わせること。
//  固定小数点の手順は tools/fx_scope.py と一対一 (照合は sim/tb_scope_pipe.v)。
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
    parameter DW       = 20,     // dir のビット幅 (段9 で 18→20。p は 18 のまま)
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

   // パラメータ (PS が AXI で書く)
   //   視線の向き (段9)。rd*1440 = (a*hn + b*vn + c) を x, y, z の 3 本。
   //   hn = 2h-1279, vn = 719-2v。a, b は Q16 (向き行列の 1, 2 列目)、
   //   c は Q16 で 向き行列の 3 列目 * focal * 1440 (focal = 0.85*zoom、最大 2^28)
   input wire signed [17:0]  vax, vbx,
   input wire signed [31:0]  vcx,
   input wire signed [17:0]  vay, vby,
   input wire signed [31:0]  vcy,
   input wire signed [17:0]  vaz, vbz,
   input wire signed [31:0]  vcz,
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
   // 回したあとの手前層の c (Q15)。きらめき層 (段7) が使う。
   // ★ out_fx より 1 クロック早い (O1 の出力をそのまま出す)
   output wire signed [17:0]   out_cx, out_cy,
   output wire [4:0]           out_nrefl,
   output wire [15:0]          out_seam,
   output wire                 out_black
   );

  localparam SETUP_LAT = 10;
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

  // ============ setup S1: N = a*hn + b*vn + c  (rd の 1440 倍、Q16) ============
  //   |N| は最大 3.3e8 (zoom 2.5) で 32 ビットに収まる
  wire signed [31:0] nx_w = vax * hn_0 + vbx * vn_0 + vcx;
  wire signed [31:0] ny_w = vay * hn_0 + vby * vn_0 + vcy;
  wire signed [31:0] nz_w = vaz * hn_0 + vbz * vn_0 + vcz;

  reg signed [31:0] nx_1, ny_1, nz_1;

  always @(posedge clk) begin
    nx_1 <= nx_w;
    ny_1 <= ny_w;
    nz_1 <= nz_w;
  end

  // ============ setup S2: Nz の先頭 1 の位置 nb。Nz <= 0 は後ろ向き (黒) ============
  wire        back_w = (nz_1 <= 0);
  wire [30:0] dz_w   = back_w ? 31'd1 : nz_1[30:0];

  integer   i;
  reg [4:0] nb_w;
  always @* begin
    nb_w = 5'd0;
    for (i = 0; i < 31; i = i + 1)
      if (dz_w[i]) nb_w = i[4:0] + 5'd1;
  end

  reg signed [31:0] nx_2, ny_2;
  reg [30:0]        dz_2;
  reg [4:0]         nb_2;
  reg               bk_2;

  always @(posedge clk) begin
    nx_2 <= nx_1;  ny_2 <= ny_1;
    dz_2 <= dz_w;
    nb_2 <= nb_w;
    bk_2 <= back_w;
  end

  // ============ setup S3: 仮数 mn ∈ [2^23, 2^24) と、同じだけ縮めた Nx_s, Ny_s ============
  //   Nx_s = Nx >> (nb - 22)   (nb < 22 なら左シフト)。27 ビットで飽和
  localparam MN_B  = 24;
  localparam NS_SH = 22;
  localparam NS_B  = 27;

  wire [54:0] dz_up = {24'd0, dz_2} << (MN_B - nb_2);
  wire [30:0] dz_dn = dz_2 >> (nb_2 - MN_B);
  wire [MN_B-1:0] mn_w = (nb_2 <= MN_B) ? dz_up[MN_B-1:0] : dz_dn[MN_B-1:0];

  wire signed [53:0] nxw = {{22{nx_2[31]}}, nx_2};
  wire signed [53:0] nyw = {{22{ny_2[31]}}, ny_2};
  wire signed [53:0] nxs_w = (nb_2 >= NS_SH) ? (nxw >>> (nb_2 - NS_SH)) : (nxw <<< (NS_SH - nb_2));
  wire signed [53:0] nys_w = (nb_2 >= NS_SH) ? (nyw >>> (nb_2 - NS_SH)) : (nyw <<< (NS_SH - nb_2));

  localparam signed [53:0] NS_MAX = (54'sd1 <<< (NS_B-1)) - 54'sd1;
  localparam signed [53:0] NS_MIN = -(54'sd1 <<< (NS_B-1));

  reg [MN_B-1:0]       mn_3;
  reg signed [NS_B-1:0] nxs_3, nys_3;
  reg                   bk_3;

  always @(posedge clk) begin
    mn_3  <= mn_w;
    nxs_3 <= (nxs_w > NS_MAX) ? NS_MAX[NS_B-1:0] : (nxs_w < NS_MIN) ? NS_MIN[NS_B-1:0] : nxs_w[NS_B-1:0];
    nys_3 <= (nys_w > NS_MAX) ? NS_MAX[NS_B-1:0] : (nys_w < NS_MIN) ? NS_MIN[NS_B-1:0] : nys_w[NS_B-1:0];
    bk_3  <= bk_2;
  end

  // ============ setup S4: 逆数表 (divq と同じ表。最上位ビットの下 9 ビットで引く) ============
  (* rom_style = "distributed" *)
  reg [18:0] rlut [0:511];
  initial $readmemh(LUT_FILE, rlut);

  reg [18:0]            y0_4;
  reg [MN_B-1:0]        mn_4;
  reg signed [NS_B-1:0] nxs_4, nys_4;
  reg                   bk_4;

  always @(posedge clk) begin
    y0_4  <= rlut[mn_3[MN_B-2 -: 9]];
    mn_4  <= mn_3;
    nxs_4 <= nxs_3;  nys_4 <= nys_3;
    bk_4  <= bk_3;
  end

  // ============ setup S5: my = m * y0 (Q17) ============
  wire [MN_B+18:0] mn_y0 = mn_4 * y0_4;

  reg [19:0]            my_5;
  reg [18:0]            y0_5;
  reg signed [NS_B-1:0] nxs_5, nys_5;
  reg                   bk_5;

  always @(posedge clk) begin
    my_5  <= {1'b0, mn_y0[MN_B+18 : MN_B]};
    y0_5  <= y0_4;
    nxs_5 <= nxs_4;  nys_5 <= nys_4;
    bk_5  <= bk_4;
  end

  // ============ setup S6: ニュートン1回  y1 = y0 * (2 - m*y0)  (1/m、Q17) ============
  wire [19:0] corr   = (20'd1 << 18) - my_5;
  wire [38:0] y0corr = y0_5 * corr;
  wire [21:0] y1_raw = y0corr >> 17;

  reg [18:0]            y1_6;
  reg signed [NS_B-1:0] nxs_6, nys_6;
  reg                   bk_6;

  always @(posedge clk) begin
    y1_6  <= (y1_raw[21:19] != 3'd0) ? 19'h7FFFF : y1_raw[18:0];
    nxs_6 <= nxs_5;  nys_6 <= nys_5;
    bk_6  <= bk_5;
  end

  // ============ setup S7: slope = Nx_s * y1 >> 24  (Q15、DW ビットで飽和) ============
  //   1/Nz = y1 / 2^17 / 2^nb、Nx = Nx_s * 2^(nb-22) なので slope*2^15 = Nx_s*y1 / 2^24
  wire signed [NS_B+19:0] slx_f = nxs_6 * $signed({1'b0, y1_6});
  wire signed [NS_B+19:0] sly_f = nys_6 * $signed({1'b0, y1_6});
  wire signed [NS_B+19:0] slx_s = slx_f >>> 24;
  wire signed [NS_B+19:0] sly_s = sly_f >>> 24;

  localparam signed [NS_B+19:0] SL_MAX = (1 <<< (DW-1)) - 1;
  localparam signed [NS_B+19:0] SL_MIN = -(1 <<< (DW-1));

  reg signed [DW-1:0] slx_7, sly_7;
  reg                 bk_7;

  always @(posedge clk) begin
    slx_7 <= (slx_s > SL_MAX) ? SL_MAX[DW-1:0] : (slx_s < SL_MIN) ? SL_MIN[DW-1:0] : slx_s[DW-1:0];
    sly_7 <= (sly_s > SL_MAX) ? SL_MAX[DW-1:0] : (sly_s < SL_MIN) ? SL_MIN[DW-1:0] : sly_s[DW-1:0];
    bk_7  <= bk_6;
  end

  // ============ setup S8: p = slope * Z_MIRROR ============
  //   三角形の外かを見るまでは DW ビットで持つ (18 ビットだと巻き戻って外の画素が内側に化ける)。
  //   z_mirror < 1 なので |p| < 2^(DW-1) に収まる
  wire signed [DW+17:0] p0x_f = slx_7 * z_mirror;
  wire signed [DW+17:0] p0y_f = sly_7 * z_mirror;

  reg signed [DW-1:0] px_8, py_8, dx_8, dy_8;
  reg                 bk_8;

  always @(posedge clk) begin
    px_8 <= $signed(p0x_f[DW+15:16]);
    py_8 <= $signed(p0y_f[DW+15:16]);
    dx_8 <= slx_7;
    dy_8 <= sly_7;
    bk_8 <= bk_7;
  end

  // ============ setup S9: 三角形の外か (筒の縁) ============
  //   内積は 4 ビット広く取って比べる (|p| が 16 近いとき Q4.14 からあふれる)
  wire signed [DW+18:0] q0 = px_8 * nx0 + py_8 * ny0;
  wire signed [DW+18:0] q1 = px_8 * nx1 + py_8 * ny1;
  wire signed [DW+18:0] q2 = px_8 * nx2 + py_8 * ny2;
  wire black_w = bk_8 |
                 ($signed(q0[SH_A+21:SH_A]) > wd0) |
                 ($signed(q1[SH_A+21:SH_A]) > wd1) |
                 ($signed(q2[SH_A+21:SH_A]) > wd2);

  reg signed [17:0]   px_9, py_9;
  reg signed [DW-1:0] dx_9, dy_9;
  reg                 bk_9;

  always @(posedge clk) begin
    px_9 <= px_8[17:0];  py_9 <= py_8[17:0];     // 内側なら 18 ビットに収まる
    dx_9 <= dx_8;        dy_9 <= dy_8;
    bk_9 <= black_w;
  end

  // ============ 本体: scope_stage を K 段 ============
  wire signed [17:0]   s_px   [0:K];
  wire signed [17:0]   s_py   [0:K];
  wire signed [DW-1:0] s_dx   [0:K];
  wire signed [DW-1:0] s_dy   [0:K];
  wire [Q_W-1:0]       s_rm   [0:K];
  wire [4:0]           s_nr   [0:K];
  wire [15:0]          s_sm   [0:K];
  wire                 s_done [0:K];
  wire                 s_bk   [0:K];

  assign s_px[0]   = px_9;
  assign s_py[0]   = py_9;
  assign s_dx[0]   = dx_9;
  assign s_dy[0]   = dy_9;
  assign s_rm[0]   = remain0;
  assign s_nr[0]   = 5'd0;
  assign s_sm[0]   = 16'd32768;          // seam = 1.0 (Q15)
  assign s_done[0] = bk_9;
  assign s_bk[0]   = bk_9;

  genvar g;
  generate
    for (g = 0; g < K; g = g + 1) begin: stage
      scope_stage #(.P_F(P_F), .N_F(N_F), .A_F(A_F), .D_F(D_F),
                    .Q_F(Q_F), .Q_W(Q_W), .DW(DW), .INV_E2(inv_e2(g)),
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

  // K 回反射してもまだ残りがある画素は黒 (段9)
  wire signed [17:0] fpx = s_px[K];
  wire signed [17:0] fpy = s_py[K];
  wire               fbk = s_bk[K] | ~s_done[K];

  // ============ out O0: セル上の位置を2つ作る ============
  //   手前層  c  = p / TUBE_R
  //   奥層    cB = (p + dir*CELL_GAP) / TUBE_R
  //
  //   光線を正規化していないので、参照実装の dir*sl*CELL_GAP は
  //   そのまま我々の dir*CELL_GAP になる。この視差が2層の立体感を作る。
  wire signed [DW+17:0] gx = s_dx[K] * cell_gap;       // Q15 * Q16 = Q31
  wire signed [DW+17:0] gy = s_dy[K] * cell_gap;
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
    bk_o  <= fbk;
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

  assign out_cx    = cxf_r;
  assign out_cy    = cyf_r;
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
