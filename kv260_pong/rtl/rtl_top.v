// ============================================================
// rtl_top.v — KV260 Pong トップモジュール (Phase A2: 3 オブジェクト)
// ============================================================
//
// 1280x720 60Hz VGA timing で 3 つの白矩形を青背景に描画。
//   - 左パドル (20 x 100)
//   - 右パドル (20 x 100)
//   - ボール   (20 x 20)
//
// 位置 (padl_xy, padr_xy, ball_xy) は AXI クロック領域から CDC で受け取る。

module rtl_top
  (
   input wire         clk,
   input wire         clkv,
   input wire         resetn,
   // AXI クロック領域の制御信号
   input wire [10:0]  padl_x_axi,
   input wire [10:0]  padl_y_axi,
   input wire [10:0]  padr_x_axi,
   input wire [10:0]  padr_y_axi,
   input wire [10:0]  ball_x_axi,
   input wire [10:0]  ball_y_axi,
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

  // CDC: AXI クロック領域 → ビデオクロック領域
  wire [10:0] padl_x_v, padl_y_v;
  wire [10:0] padr_x_v, padr_y_v;
  wire [10:0] ball_x_v, ball_y_v;

  cdc_synchronizer #(.DATA_WIDTH(11)) cdc_padl_x (.data_in(padl_x_axi), .data_out(padl_x_v), .clk(clkv));
  cdc_synchronizer #(.DATA_WIDTH(11)) cdc_padl_y (.data_in(padl_y_axi), .data_out(padl_y_v), .clk(clkv));
  cdc_synchronizer #(.DATA_WIDTH(11)) cdc_padr_x (.data_in(padr_x_axi), .data_out(padr_x_v), .clk(clkv));
  cdc_synchronizer #(.DATA_WIDTH(11)) cdc_padr_y (.data_in(padr_y_axi), .data_out(padr_y_v), .clk(clkv));
  cdc_synchronizer #(.DATA_WIDTH(11)) cdc_ball_x (.data_in(ball_x_axi), .data_out(ball_x_v), .clk(clkv));
  cdc_synchronizer #(.DATA_WIDTH(11)) cdc_ball_y (.data_in(ball_y_axi), .data_out(ball_y_v), .clk(clkv));

  // オブジェクトサイズ (固定)
  localparam PAD_W  = 11'd20;
  localparam PAD_H  = 11'd100;
  localparam BALL_W = 11'd20;
  localparam BALL_H = 11'd20;

  // 各ピクセルがどのオブジェクトに属するか判定
  wire in_padl = (count_h >= padl_x_v) && (count_h < padl_x_v + PAD_W) &&
                 (count_v >= padl_y_v) && (count_v < padl_y_v + PAD_H);
  wire in_padr = (count_h >= padr_x_v) && (count_h < padr_x_v + PAD_W) &&
                 (count_v >= padr_y_v) && (count_v < padr_y_v + PAD_H);
  wire in_ball = (count_h >= ball_x_v) && (count_h < ball_x_v + BALL_W) &&
                 (count_v >= ball_y_v) && (count_v < ball_y_v + BALL_H);

  reg [7:0] color_r;
  reg [7:0] color_g;
  reg [7:0] color_b;

  always @(posedge clkv) begin
    if (in_padl | in_padr | in_ball) begin
      // 白
      color_r <= 8'd255;
      color_g <= 8'd255;
      color_b <= 8'd255;
    end else begin
      // 青背景
      color_r <= 8'd0;
      color_g <= 8'd0;
      color_b <= 8'd128;
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
