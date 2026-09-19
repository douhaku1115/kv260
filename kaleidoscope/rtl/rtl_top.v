// ============================================================
//  rtl_top — 万華鏡 (段4)
//
//  画素クロック 74.25MHz の 1280x720@60 で、1画素ごとに
//  「のぞき穴から出た光線が鏡で何回か反射してセル面のどこに届くか」
//  を求め、その位置のセル画像の色を出す。
//
//  経路と遅延 (count_h/count_v から video_color まで)
//    scope_pipe   199 クロック  (setup 4 + 16段 x 12 + out 3)
//    cell_mem       2 クロック
//    減光            1 クロック
//    周辺減光+合わせ目 1 クロック
//    ------------------------- 合計 203  → vga_iface の PIXEL_DELAY
//
//  鏡の形・画角・セルの回転は kaleido_axi_slave から受け取る。
//  PS が毎フレーム cos/sin を書き換えると模様が回る。
// ============================================================

module rtl_top
  (
   input wire         clk,
   input wire         clkv,
   input wire         resetn,

   // 万華鏡のパラメータ (kaleido_axi_slave から。すべて映像クロック領域で確定済み)
   input wire signed [17:0] p_kx,
   input wire signed [17:0] p_z_mirror,
   input wire [19:0]        p_remain0,
   input wire signed [17:0] p_inv_tr,
   input wire signed [17:0] p_cos_t,
   input wire signed [17:0] p_sin_t,
   input wire signed [17:0] p_nx0, p_ny0, p_wd0,
   input wire signed [17:0] p_nx1, p_ny1, p_wd1,
   input wire signed [17:0] p_nx2, p_ny2, p_wd2,
   input wire signed [17:0] p_vx0, p_vy0,
   input wire signed [17:0] p_vx1, p_vy1,
   input wire signed [17:0] p_vx2, p_vy2,
   input wire               p_mirror2,

   output wire        frame_start,   // フレーム先頭で 1 クロック (AXI スレーブへ)

   // DP live video
   output wire        video_de,
   output wire        video_hsyncn,
   output wire        video_vsyncn,
   output wire [35:0] video_color
   );

  localparam K         = 16;        // 反射段数
  localparam CELL_BITS = 8;         // セル画像 256x256

  localparam signed [17:0] KSP  = 18'sd11651;   // sp を Q15 にする係数
  localparam signed [17:0] KVIG = 18'sd9830;    // 0.3 Q15  周辺減光の強さ

  localparam SCOPE_LAT = 4 + K*12 + 3;              // = 199
  localparam TOTAL_LAT = SCOPE_LAT + 2 + 1 + 1;     // = 203

  // ---- リセット同期 ----
  wire reset, resetv;
  wire resetp = ~resetn;

  shift_register #(.DELAY(3)) sr_reset  (.clk(clk),  .din(resetp), .dout(reset));
  shift_register #(.DELAY(3)) sr_resetv (.clk(clkv), .din(resetp), .dout(resetv));

  // ---- VGA タイミング ----
  wire        video_hsync, video_vsync;
  wire [23:0] vga_color_in;
  wire [23:0] vga_color_out;
  wire [10:0] count_h, count_v;

  assign video_hsyncn = ~video_hsync;
  assign video_vsyncn = ~video_vsync;
  // 24bit RGB -> 36bit (12bit/ch): {B[7:0],B[3:0], R[7:0],R[3:0], G[7:0],G[3:0]}
  assign video_color = {vga_color_out[7:0],   {4{vga_color_out[0]}},
                        vga_color_out[23:16], {4{vga_color_out[16]}},
                        vga_color_out[15:8],  {4{vga_color_out[8]}}};

  // フレーム先頭。AXI スレーブはここでパラメータをまとめて取り込む
  assign frame_start = (count_h == 11'd0) && (count_v == 11'd0);

  // ============ 万華鏡の折り返し ============
  wire [CELL_BITS-1:0] cell_ix, cell_iy;
  wire [4:0]           nrefl;
  wire [15:0]          seam;
  wire                 black;

  scope_pipe #(.K(K), .CELL_BITS(CELL_BITS),
               .LUT_FILE("recip_lut.hex"), .SEAM_LUT_FILE("seam_lut.hex"))
  scope_i
    (.clk(clkv),
     .count_h(count_h), .count_v(count_v),
     .kx(p_kx), .z_mirror(p_z_mirror), .remain0(p_remain0), .inv_tube_r(p_inv_tr),
     .cos_t(p_cos_t), .sin_t(p_sin_t),
     .nx0(p_nx0), .ny0(p_ny0), .wd0(p_wd0),
     .nx1(p_nx1), .ny1(p_ny1), .wd1(p_wd1),
     .nx2(p_nx2), .ny2(p_ny2), .wd2(p_wd2),
     .vx0(p_vx0), .vy0(p_vy0),
     .vx1(p_vx1), .vy1(p_vy1),
     .vx2(p_vx2), .vy2(p_vy2),
     .mirror2(p_mirror2),
     .out_ix(cell_ix), .out_iy(cell_iy),
     .out_nrefl(nrefl), .out_seam(seam), .out_black(black));

  // ============ セル画像を引く (2 クロック) ============
  wire [15:0] cell_rgb;

  cell_mem #(.CELL_BITS(CELL_BITS), .INIT_FILE("cell_init.hex"))
  cell_i (.clk(clkv), .ix(cell_ix), .iy(cell_iy), .rgb565(cell_rgb));

  // nrefl / seam / black をセル読み出しに合わせて遅らせる
  reg [4:0]  nr_d1, nr_d2;
  reg [15:0] sm_d1, sm_d2;
  reg        bk_d1, bk_d2, bk_d3;

  always @(posedge clkv) begin
    nr_d1 <= nrefl;  nr_d2 <= nr_d1;
    sm_d1 <= seam;   sm_d2 <= sm_d1;
    bk_d1 <= black;  bk_d2 <= bk_d1;  bk_d3 <= bk_d2;
  end

  // ============ 周辺減光 (4 クロック) ============
  //   vq = 1 - 0.3 * dot(sp,sp)     sp は画面中心からの正規化座標
  reg signed [12:0] hn_v, vn_v;
  always @(posedge clkv) begin
    hn_v <= $signed({2'b00, count_h}) * 2 - 13'sd1279;
    vn_v <= 13'sd719 - $signed({2'b00, count_v}) * 2;
  end

  wire signed [30:0] spx_f = hn_v * KSP;
  wire signed [30:0] spy_f = vn_v * KSP;
  reg signed [17:0]  spx_v, spy_v;
  always @(posedge clkv) begin
    spx_v <= $signed(spx_f[26:9]);
    spy_v <= $signed(spy_f[26:9]);
  end

  wire signed [36:0] sq = spx_v * spx_v + spy_v * spy_v;   // Q30
  reg [17:0] sp2_v;
  always @(posedge clkv) sp2_v <= sq[32:15];               // Q15

  wire [35:0] vig = sp2_v * KVIG[17:0];                    // Q30
  reg [15:0] vq_v;
  always @(posedge clkv)
    vq_v <= (vig[30:15] >= 16'd32768) ? 16'd0 : (16'd32768 - vig[30:15]);

  // vq を色の最終段まで遅らせる (自身の 4 クロックぶんを差し引く)
  localparam VQ_DELAY = TOTAL_LAT - 2 - 4;                 // = 197
  reg [15:0] vqd [0:VQ_DELAY-1];
  integer i;
  always @(posedge clkv) begin
    vqd[0] <= vq_v;
    for (i = 1; i < VQ_DELAY; i = i + 1)
      vqd[i] <= vqd[i-1];
  end
  wire [15:0] vq = vqd[VQ_DELAY-1];

  // ============ 減光 (反射回数ぶん暗くする) ============
  (* rom_style = "distributed" *)
  reg [8:0] loss_lut [0:31];
  initial $readmemh("loss_lut.hex", loss_lut);

  wire [8:0] gain = loss_lut[nr_d2];

  // RGB565 → 8bit
  wire [7:0] r8 = {cell_rgb[15:11], cell_rgb[15:13]};
  wire [7:0] g8 = {cell_rgb[10:5],  cell_rgb[10:9]};
  wire [7:0] b8 = {cell_rgb[4:0],   cell_rgb[4:2]};

  // 掛け算は必ず幅を持った wire に受けてから切り出す。
  //   r_l <= (r8 * gain) >> 8;  と書くと代入先の 8bit で積が切り捨てられ、
  //   シフト後にほぼ 0 になる (Verilog の式幅の規則)。
  wire [16:0] r_m = r8 * gain;
  wire [16:0] g_m = g8 * gain;
  wire [16:0] b_m = b8 * gain;

  reg [7:0] r_l, g_l, b_l;
  always @(posedge clkv) begin
    r_l <= r_m[15:8];
    g_l <= g_m[15:8];
    b_l <= b_m[15:8];
  end

  // ============ 周辺減光と合わせ目をかけて出力 ============
  wire [31:0] vq_sm = vq * sm_d2;
  reg [15:0] vq2;
  always @(posedge clkv) vq2 <= vq_sm[30:15];

  wire [23:0] r_v = r_l * vq2;
  wire [23:0] g_v = g_l * vq2;
  wire [23:0] b_v = b_l * vq2;

  reg [7:0] r_o, g_o, b_o;
  always @(posedge clkv) begin
    if (bk_d3) begin
      r_o <= 8'd3;  g_o <= 8'd2;  b_o <= 8'd3;   // 筒の縁
    end else begin
      r_o <= r_v[22:15];
      g_o <= g_v[22:15];
      b_o <= b_v[22:15];
    end
  end

  assign vga_color_in = {r_o, g_o, b_o};

  vga_iface
    #(
      .VGA_MAX_H    (1650-1),
      .VGA_MAX_V    (750-1),
      .VGA_WIDTH    (1280),
      .VGA_HEIGHT   (720),
      .VGA_SYNC_H_START (1390),
      .VGA_SYNC_V_START (725),
      .VGA_SYNC_H_END   (1430),
      .VGA_SYNC_V_END   (730),
      .PIXEL_DELAY  (TOTAL_LAT),
      .BPP          (24)
      )
  vga_iface_0
    (
     .clk              (clk),
     .reset            (reset),
     .vsync            (),
     .vcount           (),
     .ext_clkv         (clkv),
     .ext_resetv       (resetv),
     .ext_color_in     (vga_color_in),
     .ext_vga_hs       (video_hsync),
     .ext_vga_vs       (video_vsync),
     .ext_vga_de       (video_de),
     .ext_vga_color_out(vga_color_out),
     .ext_count_h      (count_h),
     .ext_count_v      (count_v)
     );

endmodule
