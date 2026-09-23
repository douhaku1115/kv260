// ============================================================
//  rtl_top — 万華鏡 (段5a: 奥層/手前層の2層合成)
//
//  画素クロック 74.25MHz の 1280x720@60 で、1画素ごとに
//  「のぞき穴から出た光線が鏡で何回か反射してセル面のどこに届くか」
//  を求め、その位置のセル画像の色を出す。
//
//  セル画像は2層ある。
//    手前層 (z>=0.5)  α付き。位置 c でサンプル
//    奥層   (z< 0.5)  不透明。位置 c + dir*CELL_GAP でサンプル (視差)
//    影              手前層の α を少しずらして読み、奥層を暗くする
//  この視差が立体感を作る。1枚に潰すと平板になり、参照実装との差が倍になる
//  (実測: 平均差 8.9 → 16.5)。
//
//  経路と遅延 (count_h/count_v から video_color まで)
//    scope_pipe   199 クロック  (setup 4 + 16段 x 12 + out 3)
//    cell_mem       2 クロック
//    影で奥層を暗くする  1 クロック
//    α合成          1 クロック
//    減光            1 クロック
//    周辺減光+合わせ目 1 クロック
//    ------------------------- 合計 205  → vga_iface の PIXEL_DELAY
//
//  鏡の形・画角・セルの回転は kaleido_axi_slave から受け取る。
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
   input wire               p_text_on,     // 画面に操作一覧を出す

   // 画面に出す文字 (kaleido_axi_slave の中の RAM を引く)
   output wire [10:0]       text_addr,
   input wire [7:0]         text_ch,

   output wire        frame_start,   // フレーム先頭で 1 クロック (AXI スレーブへ)

   // DP live video
   output wire        video_de,
   output wire        video_hsyncn,
   output wire        video_vsyncn,
   output wire [35:0] video_color
   );

  localparam K         = 16;        // 反射段数
  localparam CELL_BITS = 8;         // セル画像 256x256

  localparam signed [17:0] KSP      = 18'sd11651;   // sp を Q15 にする係数
  localparam signed [17:0] KVIG     = 18'sd9830;    // 0.3 Q15  周辺減光の強さ
  localparam signed [17:0] CELL_GAP = 18'sd22938;   // 0.35 cm Q16  手前層 → 奥層

  localparam SCOPE_LAT = 4 + K*12 + 3;                  // = 199
  localparam TOTAL_LAT = SCOPE_LAT + 2 + 1 + 1 + 1 + 1; // = 205

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
  wire [CELL_BITS-1:0] fx, fy, bx, by, sx, sy;
  wire [4:0]           nrefl;
  wire [15:0]          seam;
  wire                 black;

  scope_pipe #(.K(K), .CELL_BITS(CELL_BITS),
               .LUT_FILE("recip_lut.hex"), .SEAM_LUT_FILE("seam_lut.hex"))
  scope_i
    (.clk(clkv),
     .count_h(count_h), .count_v(count_v),
     .kx(p_kx), .z_mirror(p_z_mirror), .remain0(p_remain0), .inv_tube_r(p_inv_tr),
     .cos_t(p_cos_t), .sin_t(p_sin_t), .cell_gap(CELL_GAP),
     .nx0(p_nx0), .ny0(p_ny0), .wd0(p_wd0),
     .nx1(p_nx1), .ny1(p_ny1), .wd1(p_wd1),
     .nx2(p_nx2), .ny2(p_ny2), .wd2(p_wd2),
     .vx0(p_vx0), .vy0(p_vy0),
     .vx1(p_vx1), .vy1(p_vy1),
     .vx2(p_vx2), .vy2(p_vy2),
     .mirror2(p_mirror2),
     .out_fx(fx), .out_fy(fy),
     .out_bx(bx), .out_by(by),
     .out_sx(sx), .out_sy(sy),
     .out_nrefl(nrefl), .out_seam(seam), .out_black(black));

  // ============ セル画像を引く (2 クロック) ============
  wire [15:0] back_d;
  wire [31:0] front_d;    // 口A: {ablur, a, rgb565}
  wire [31:0] shadow_d;   // 口B: 影用にずらした位置

  // 奥層は油の地だけを焼き込んでおき、その上へ PL がピースを描く (段5c)。
  // 口B を書き込みに使うので、影用の読み出しは奥層では使わない。
  wire        pc_we;
  wire [2*CELL_BITS-1:0] pc_addr;
  wire [15:0] pc_wdata;

  cell_mem #(.CELL_BITS(CELL_BITS), .DATA_W(16),
             .INIT_FILE("cell_oil.hex"), .HAS_WRITE(1))
  cell_back_i (.clk(clkv), .ix(bx), .iy(by), .data(back_d),
               .ix2({CELL_BITS{1'b0}}), .iy2({CELL_BITS{1'b0}}), .data2(),
               .we(pc_we), .waddr(pc_addr), .wdata(pc_wdata));

  cell_mem #(.CELL_BITS(CELL_BITS), .DATA_W(32), .INIT_FILE("cell_front_init.hex"))
  cell_front_i (.clk(clkv), .ix(fx), .iy(fy), .data(front_d),
                .ix2(sx), .iy2(sy), .data2(shadow_d),
                .we(1'b0), .waddr({2*CELL_BITS{1'b0}}), .wdata(32'd0));

  // ============ ピースを描く (段5c・最小版) ============
  //   焼き込んだ表を頭から順に描いて止まる。動かすのは次の段。
  wire        ps_busy, ps_start, ps_premul, ps_done;
  wire [3:0]  ps_type;
  wire [8:0]  ps_bw;
  wire [17:0] ps_npix;
  wire [7:0]  ps_x0, ps_y0, ps_cr, ps_cg, ps_cb;
  wire signed [23:0] ps_vqx0, ps_vqy0, ps_qx0, ps_qy0;
  wire signed [23:0] ps_sxv, ps_syv, ps_sxqx, ps_syqx, ps_sxqy, ps_syqy;
  wire signed [23:0] ps_seed, ps_e, ps_rot, ps_time, ps_depth;

  pdriver #(.NPIECE(64)) pdrv_i
    (.clk(clkv), .resetn(~resetv), .seq_busy(ps_busy), .start(ps_start),
     .p_type(ps_type), .p_bw(ps_bw), .p_npix(ps_npix),
     .p_x0(ps_x0), .p_y0(ps_y0),
     .p_vqx0(ps_vqx0), .p_vqy0(ps_vqy0), .p_qx0(ps_qx0), .p_qy0(ps_qy0),
     .p_sx_vqx(ps_sxv), .p_sy_vqy(ps_syv),
     .p_sx_qx(ps_sxqx), .p_sy_qx(ps_syqx),
     .p_sx_qy(ps_sxqy), .p_sy_qy(ps_syqy),
     .p_seed(ps_seed), .p_e(ps_e), .p_rot(ps_rot), .p_time(ps_time),
     .p_cr(ps_cr), .p_cg(ps_cg), .p_cb(ps_cb),
     .p_depth(ps_depth), .p_premul(ps_premul), .all_done(ps_done));

  //  最小版では下の色を読まない (BRAM の口は 1 クロックに読みか書きの
  //  どちらかだけ)。油の地の上に重ねるので、重なり合う所だけ後勝ちになる。
  pshade_seq #(.CELLB(CELL_BITS)) pseq_i
    (.clk(clkv), .resetn(~resetv), .start(ps_start),
     .p_type(ps_type), .p_bw(ps_bw), .p_npix(ps_npix),
     .p_x0(ps_x0), .p_y0(ps_y0),
     .p_vqx0(ps_vqx0), .p_vqy0(ps_vqy0), .p_qx0(ps_qx0), .p_qy0(ps_qy0),
     .p_sx_vqx(ps_sxv), .p_sy_vqy(ps_syv),
     .p_sx_qx(ps_sxqx), .p_sy_qx(ps_syqx),
     .p_sx_qy(ps_sxqy), .p_sy_qy(ps_syqy),
     .p_seed(ps_seed), .p_e(ps_e), .p_rot(ps_rot), .p_time(ps_time),
     .p_cr(ps_cr), .p_cg(ps_cg), .p_cb(ps_cb),
     .p_depth(ps_depth), .p_premul(ps_premul), .busy(ps_busy),
     .cell_we(pc_we), .cell_addr(pc_addr), .cell_wdata(pc_wdata),
     .cell_rdata(16'd0), .cell_raddr());

  // RGB565 → 8bit
  function [7:0] r8; input [15:0] c; begin r8 = {c[15:11], c[15:13]}; end endfunction
  function [7:0] g8; input [15:0] c; begin g8 = {c[10:5],  c[10:9]};  end endfunction
  function [7:0] b8; input [15:0] c; begin b8 = {c[4:0],   c[4:2]};   end endfunction

  wire [7:0] fa = front_d[23:16];     // 手前層の α
  wire [7:0] sh = shadow_d[31:24];    // ずらした位置のぼかし α (影)

  // ============ C1: 手前層の影で奥層を暗くする ============
  //   B' = B * (1 - 0.5*sh/255) = B * (510-sh)/510 ≈ B*(510-sh) >> 9
  wire [8:0] shk = 9'd510 - {1'b0, sh};

  wire [7:0] rb = r8(back_d);
  wire [7:0] gb = g8(back_d);
  wire [7:0] bb = b8(back_d);
  wire [16:0] rb_m = rb * shk;
  wire [16:0] gb_m = gb * shk;
  wire [16:0] bb_m = bb * shk;

  reg [7:0] rb_s, gb_s, bb_s;      // 影を落とした奥層
  reg [7:0] rf_s, gf_s, bf_s;      // 手前層 (プリマルチプライド済み)
  reg [7:0] fa_s;

  always @(posedge clkv) begin
    rb_s <= rb_m[16:9];
    gb_s <= gb_m[16:9];
    bb_s <= bb_m[16:9];
    rf_s <= r8(front_d[15:0]);
    gf_s <= g8(front_d[15:0]);
    bf_s <= b8(front_d[15:0]);
    fa_s <= fa;
  end

  // ============ C2: α合成 ============
  //   col = F.rgb + B' * (1 - F.a)     手前層はプリマルチプライドα
  wire [8:0]  inv_a = 9'd255 - {1'b0, fa_s};
  wire [16:0] rb_c = rb_s * inv_a;
  wire [16:0] gb_c = gb_s * inv_a;
  wire [16:0] bb_c = bb_s * inv_a;
  wire [8:0]  r_sum = {1'b0, rf_s} + rb_c[15:8];
  wire [8:0]  g_sum = {1'b0, gf_s} + gb_c[15:8];
  wire [8:0]  b_sum = {1'b0, bf_s} + bb_c[15:8];

  reg [7:0] r_c, g_c, b_c;
  always @(posedge clkv) begin
    r_c <= r_sum[8] ? 8'hFF : r_sum[7:0];
    g_c <= g_sum[8] ? 8'hFF : g_sum[7:0];
    b_c <= b_sum[8] ? 8'hFF : b_sum[7:0];
  end

  // ============ nrefl / seam / black を合成の遅れに合わせる ============
  //   scope_pipe の出力 (199) から、使うところまで遅らせる
  reg [4:0]  nr_d [0:3];
  reg [15:0] sm_d [0:3];
  reg        bk_d [0:4];
  integer d;
  always @(posedge clkv) begin
    nr_d[0] <= nrefl;  sm_d[0] <= seam;  bk_d[0] <= black;
    for (d = 1; d < 4; d = d + 1) begin
      nr_d[d] <= nr_d[d-1];
      sm_d[d] <= sm_d[d-1];
    end
    for (d = 1; d < 5; d = d + 1) bk_d[d] <= bk_d[d-1];
  end

  // ============ 画面に出す文字 (操作一覧) ============
  //   8x16 のフォントを 2 倍に拡大して 16x32 の枡に描く。
  //   32 桁 x 8 行 = 512 x 256 px の枠を画面の下寄り中央に置く。
  //
  //   万華鏡の計算とは独立なので、count_h/count_v から直接 4 クロックで
  //   「その画素が文字かどうか」の 1 ビットを作り、あとは
  //   TOTAL_LAT-4 段の遅延線で色の最終段まで運ぶ。
  //   座標そのもの (22bit) を遅らせるより桁違いに安い (SRL に入る)。
  localparam TEXT_COLS = 32;
  localparam TEXT_ROWS = 8;
  localparam TEXT_X0   = 11'd384;                    // (1280 - 32*16) / 2
  localparam TEXT_Y0   = 11'd416;
  localparam TEXT_W    = TEXT_COLS * 16;             // 512
  localparam TEXT_H    = TEXT_ROWS * 32;             // 256

  wire [10:0] tx = count_h - TEXT_X0;
  wire [10:0] ty = count_v - TEXT_Y0;
  wire        in_box_w = (count_h >= TEXT_X0) && (tx < TEXT_W) &&
                         (count_v >= TEXT_Y0) && (ty < TEXT_H);

  reg        box_1;
  reg [2:0]  fx_1;                 // 文字の中の横位置 0〜7
  reg [3:0]  fy_1;                 // 文字の中の縦位置 0〜15
  always @(posedge clkv) begin
    box_1 <= in_box_w;
    fx_1  <= tx[3:1];              // 2 倍拡大なので 1 ビット落とす
    fy_1  <= ty[4:1];
  end

  assign text_addr = {3'd0, ty[7:5], 5'd0} + {6'd0, tx[8:4]};   // row*32 + col

  reg [2:0] fx_2;
  reg [3:0] fy_2;
  reg       box_2;
  always @(posedge clkv) begin
    fx_2 <= fx_1;  fy_2 <= fy_1;  box_2 <= box_1;
  end

  wire [7:0] glyph;
  font_rom #(.INIT_FILE("font_rom.hex"))
  font_i (.clk(clkv), .ch(text_ch), .row(fy_2), .pixels(glyph));

  reg [2:0] fx_3;
  reg       box_3;
  always @(posedge clkv) begin
    fx_3 <= fx_2;  box_3 <= box_2;
  end

  reg txt_p, txt_box;
  always @(posedge clkv) begin
    txt_p   <= glyph[3'd7 - fx_3];
    txt_box <= box_3;
  end

  // 色の最終段まで運ぶ (自分の 4 クロックぶんを差し引く)
  localparam TXT_DELAY = TOTAL_LAT - 4;
  reg [1:0] txtd [0:TXT_DELAY-1];
  integer k;
  always @(posedge clkv) begin
    txtd[0] <= {txt_box, txt_p};
    for (k = 1; k < TXT_DELAY; k = k + 1)
      txtd[k] <= txtd[k-1];
  end
  //   枠の外でも tx/ty が折り返して文字が読めてしまうので、
  //   文字の点も必ず「枠の中か」で区切る。片方だけ区切ると
  //   同じ一覧が画面いっぱいに並ぶ (2026-09-19 のシミュレーションで確認)。
  wire text_on_here = p_text_on & txtd[TXT_DELAY-1][1];
  wire text_pixel   = text_on_here & txtd[TXT_DELAY-1][0];

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
  localparam VQ_DELAY = TOTAL_LAT - 2 - 4;                 // = 199
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

  wire [8:0] gain = loss_lut[nr_d[3]];

  // 掛け算は必ず幅を持った wire に受けてから切り出す。
  //   r_l <= (r_c * gain) >> 8;  と書くと代入先の 8bit で積が切り捨てられ、
  //   シフト後にほぼ 0 になる (Verilog の式幅の規則)。
  wire [16:0] r_m = r_c * gain;
  wire [16:0] g_m = g_c * gain;
  wire [16:0] b_m = b_c * gain;

  reg [7:0] r_l, g_l, b_l;
  always @(posedge clkv) begin
    r_l <= r_m[15:8];
    g_l <= g_m[15:8];
    b_l <= b_m[15:8];
  end

  // ============ 周辺減光と合わせ目をかけて出力 ============
  wire [31:0] vq_sm = vq * sm_d[3];
  reg [15:0] vq2;
  always @(posedge clkv) vq2 <= vq_sm[30:15];

  wire [23:0] r_v = r_l * vq2;
  wire [23:0] g_v = g_l * vq2;
  wire [23:0] b_v = b_l * vq2;

  wire [7:0] r_base = bk_d[4] ? 8'd3 : r_v[22:15];   // 筒の縁は暗い色
  wire [7:0] g_base = bk_d[4] ? 8'd2 : g_v[22:15];
  wire [7:0] b_base = bk_d[4] ? 8'd3 : b_v[22:15];

  reg [7:0] r_o, g_o, b_o;
  always @(posedge clkv) begin
    if (text_pixel) begin
      r_o <= 8'hFF;  g_o <= 8'hFF;  b_o <= 8'hFF;          // 文字は白
    end else if (text_on_here) begin
      r_o <= {2'b00, r_base[7:2]};                          // 枠の中は暗くして読みやすく
      g_o <= {2'b00, g_base[7:2]};
      b_o <= {2'b00, b_base[7:2]};
    end else begin
      r_o <= r_base;
      g_o <= g_base;
      b_o <= b_base;
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
