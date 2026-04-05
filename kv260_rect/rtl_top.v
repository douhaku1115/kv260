module rtl_top
  (
   input wire         clk,
   input wire         clkv,
   output wire        video_de,
   output wire        video_hsyncn,
   output wire        video_vsyncn,
   output wire [35:0] video_color,
   input wire         resetn
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
  // 24bit RGB -> 36bit (12bit per channel): {B[7:0],B[3:0], R[7:0],R[3:0], G[7:0],G[3:0]}
  assign video_color = {vga_color_out[7:0], {4{vga_color_out[0]}},
                        vga_color_out[23:16], {4{vga_color_out[16]}},
                        vga_color_out[15:8], {4{vga_color_out[8]}}};

  // Draw white rectangle on blue background
  reg [7:0] color_r;
  reg [7:0] color_g;
  reg [7:0] color_b;

  always @(posedge clkv) begin
    if ((count_h >= 200) && (count_h < 600) &&
        (count_v >= 150) && (count_v < 450)) begin
      // White rectangle
      color_r <= 8'd255;
      color_g <= 8'd255;
      color_b <= 8'd255;
    end else begin
      // Blue background
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
