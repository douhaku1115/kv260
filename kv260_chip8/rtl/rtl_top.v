// ============================================================
// rtl_top.v — KV260 CHIP-8 トップ
// ============================================================
//
// CHIP-8 の 64x32 モノクロディスプレイを 16x スケール (1024x512 px)
// で表示。chip8_axi_slave のフレームバッファからピクセルを読み、
// 白/黒で出力。

module rtl_top
  (
   input wire         clk,
   input wire         clkv,
   input wire         resetn,
   // chip8_axi_slave へのピクセル読み出しポート
   output wire [5:0]  read_x,
   output wire [4:0]  read_y,
   input  wire        read_pixel,
   // DP live video 出力
   output wire        video_de,
   output wire        video_hsyncn,
   output wire        video_vsyncn,
   output wire [35:0] video_color
   );

  wire reset;
  wire resetv;
  wire resetp;
  assign resetp = ~resetn;

  shift_register #(.DELAY(3)) sr_reset  (.clk(clk),  .din(resetp), .dout(reset));
  shift_register #(.DELAY(3)) sr_resetv (.clk(clkv), .din(resetp), .dout(resetv));

  wire        video_hsync;
  wire        video_vsync;
  wire [23:0] vga_color_in;
  wire [23:0] vga_color_out;
  wire [10:0] count_h;
  wire [10:0] count_v;

  assign video_hsyncn = ~video_hsync;
  assign video_vsyncn = ~video_vsync;
  assign video_color = {vga_color_out[7:0], {4{vga_color_out[0]}},
                        vga_color_out[23:16], {4{vga_color_out[16]}},
                        vga_color_out[15:8], {4{vga_color_out[8]}}};

  // --- CHIP-8 ディスプレイ領域 (64×32 → 16x スケール = 1024×512 px) ---
  // 中央配置: (1280-1024)/2=128, (720-512)/2=104
  localparam DISP_X = 11'd128;
  localparam DISP_Y = 11'd104;
  localparam DISP_W_PX = 11'd1024;
  localparam DISP_H_PX = 11'd512;

  wire in_disp = (count_h >= DISP_X) && (count_h < DISP_X + DISP_W_PX) &&
                 (count_v >= DISP_Y) && (count_v < DISP_Y + DISP_H_PX);

  wire [10:0] rel_h = count_h - DISP_X;  // 0〜1023
  wire [10:0] rel_v = count_v - DISP_Y;  // 0〜511

  // 16x スケール: x = rel_h / 16, y = rel_v / 16
  assign read_x = rel_h[9:4];  // 6 bit, 0〜63
  assign read_y = rel_v[8:4];  // 5 bit, 0〜31

  // --- 色変換 ---
  reg [7:0] color_r, color_g, color_b;
  always @(posedge clkv) begin
    if (!in_disp) begin
      // 画面外: 黒
      color_r <= 8'd0; color_g <= 8'd0; color_b <= 8'd0;
    end else if (read_pixel) begin
      // ON: 緑 (古い CRT 風)
      color_r <= 8'd0;
      color_g <= 8'd255;
      color_b <= 8'd80;
    end else begin
      // OFF: 暗緑
      color_r <= 8'd0;
      color_g <= 8'd20;
      color_b <= 8'd0;
    end
  end

  assign vga_color_in = {color_r, color_g, color_b};

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
      .PIXEL_DELAY  (2),
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
