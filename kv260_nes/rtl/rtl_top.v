// ============================================================
// rtl_top.v — KV260 NES トップ (段A: 画面バッファ表示 + テスト音)
// ============================================================
//
// NES の画面 256x240 を 3 倍 (768x720) にして 1280x720 の中央 (X=256) に出す。
// 画面バッファ (nes_fb) の色番号を nes_palette で RGB にする。
// 段A では PS が AXI で画面バッファに直接書く。段D 以降は PPU が書く。
// 音は Pmod I2S2 (J2) へ。段A は i2s_tx の固定トーン (約 762Hz) で配線確認だけ。
//
// 【AXI マップ (ベース 0xA0000000, 256KB)】 レジスタは 0x10 刻み
//   0x00000 CTRL  (RW) 段A では未使用 (段C で NES リセット解除に使う)
//   0x00010 ID    (R)  0x4E455301 ("NES" + 版)。AXI が届いているかの確認用
//   0x00020 PAD   (RW) コントローラ (段E)
//   0x00030 FRAME (R)  映像のフレーム数 (60Hz で増える)。映像クロックの生存確認
//   0x10000-0x1EFFC FB (W) 画面バッファ。語番号 = y*64 + x/4、1 語 = 横 4 画素
//                    データ [5:0]=x, [13:8]=x+1, [21:16]=x+2, [29:24]=x+3 (色番号)

module rtl_top
  (
   input wire         clk,
   input wire         clkv,
   input wire         mclk,
   input wire         resetn,
   // nes_axi_slave からのバス
   input  wire        bus_wr_en,
   input  wire [17:0] bus_wr_addr,
   input  wire [31:0] bus_wr_data,
   input  wire [17:0] bus_rd_addr,
   output reg  [31:0] bus_rd_data,
   // DP live video 出力
   output wire        video_de,
   output wire        video_hsyncn,
   output wire        video_vsyncn,
   output wire [35:0] video_color,
   // Pmod I2S2 (J2)
   output wire        pmod_mclk,
   output wire        pmod_sclk,
   output wire        pmod_lrck,
   output wire        pmod_sdin
   );

  wire reset;
  wire resetv;
  wire resetp;
  assign resetp = ~resetn;

  shift_register #(.DELAY(3)) sr_reset  (.clk(clk),  .din(resetp), .dout(reset));
  shift_register #(.DELAY(3)) sr_resetv (.clk(clkv), .din(resetp), .dout(resetv));

  // ------------------------------------------------------------
  // レジスタ (clk 側)
  // ------------------------------------------------------------
  localparam [31:0] NES_ID = 32'h4E455301;

  reg  [31:0] reg_ctrl;
  reg  [31:0] reg_pad;
  reg  [31:0] frame_cnt;

  wire wr_reg = bus_wr_en && (bus_wr_addr[17:16] == 2'b00);
  wire wr_fb  = bus_wr_en && (bus_wr_addr[17:16] == 2'b01);

  always @(posedge clk) begin
    if (reset) begin
      reg_ctrl <= 32'd0;
      reg_pad  <= 32'd0;
    end else if (wr_reg) begin
      case (bus_wr_addr[7:4])
        4'h0: reg_ctrl <= bus_wr_data;
        4'h2: reg_pad  <= bus_wr_data;
        default: ;
      endcase
    end
  end

  always @(posedge clk) begin
    case (bus_rd_addr[7:4])
      4'h0: bus_rd_data <= reg_ctrl;
      4'h1: bus_rd_data <= NES_ID;
      4'h2: bus_rd_data <= reg_pad;
      4'h3: bus_rd_data <= frame_cnt;
      default: bus_rd_data <= 32'd0;
    endcase
  end

  // ------------------------------------------------------------
  // 画面バッファ
  // ------------------------------------------------------------
  wire [13:0] fb_raddr;
  wire [23:0] fb_rdata;

  nes_fb fb0
    (
     .clk   (clk),
     .we    (wr_fb && (bus_wr_addr[15:2] < 14'd15360)),
     .wmask (4'hF),
     .waddr (bus_wr_addr[15:2]),
     .wdata ({bus_wr_data[29:24], bus_wr_data[21:16], bus_wr_data[13:8], bus_wr_data[5:0]}),
     .clkv  (clkv),
     .raddr (fb_raddr),
     .rdata (fb_rdata)
     );

  // ------------------------------------------------------------
  // 表示 (clkv 側)
  // ------------------------------------------------------------
  wire        video_hsync;
  wire        video_vsync;
  wire [23:0] vga_color_in;
  wire [23:0] vga_color_out;
  wire [10:0] count_h;
  wire [10:0] count_v;
  wire        vsync_clk;     // clk 側に乗せ替えた vsync (0 = 同期中)

  assign video_hsyncn = ~video_hsync;
  assign video_vsyncn = ~video_vsync;
  assign video_color = {vga_color_out[7:0], {4{vga_color_out[0]}},
                        vga_color_out[23:16], {4{vga_color_out[16]}},
                        vga_color_out[15:8], {4{vga_color_out[8]}}};

  // 768x720 を X=256 から。縦は 720 全部
  localparam DISP_X = 11'd256;
  localparam DISP_W = 11'd768;

  wire        in_disp = (count_h >= DISP_X) && (count_h < DISP_X + DISP_W) && (count_v < 11'd720);
  wire [9:0]  rel_h   = count_h - DISP_X;          // 0〜767 (画面外では使わない)
  // 3 で割る: n*683 >> 11 は n < 768 で floor(n/3) と一致 (sim で全数確認)
  wire [19:0] mul_h   = rel_h * 10'd683;
  wire [19:0] mul_v   = count_v[9:0] * 10'd683;
  wire [7:0]  nx      = mul_h[18:11];               // 0〜255
  wire [7:0]  ny      = mul_v[18:11];               // 0〜239

  assign fb_raddr = {ny, nx[7:2]};                  // ny*64 + nx/4

  // 段1: RAM 読出と並べて、画素位置と表示範囲を 1 拍遅らせる
  reg [1:0] sel1;
  reg       in1, in2;
  always @(posedge clkv) begin
    sel1 <= nx[1:0];
    in1  <= in_disp;
    in2  <= in1;
  end

  // 段2: 色番号 → RGB (nes_palette が 1 拍)
  wire [5:0]  idx1 = fb_rdata[sel1*6 +: 6];
  wire [23:0] rgb2;
  nes_palette pal0 (.clk(clkv), .idx(idx1), .rgb(rgb2));

  // 画面外は暗い灰色の枠にして、NES 画面の範囲が見えるようにする
  assign vga_color_in = in2 ? rgb2 : 24'h101010;

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
     .vsync            (vsync_clk),
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

  // フレーム数: vsync の立下り (同期の始まり) を数える
  reg vsync_d;
  always @(posedge clk) begin
    vsync_d <= vsync_clk;
    if (reset)
      frame_cnt <= 32'd0;
    else if (vsync_d && !vsync_clk)
      frame_cnt <= frame_cnt + 32'd1;
  end

  // ------------------------------------------------------------
  // 音 (段A: 固定トーン)
  // ------------------------------------------------------------
  i2s_tx i2s0
    (
     .mclk   (mclk),
     .rst_n  (resetn),
     .mclk_o (pmod_mclk),
     .sclk   (pmod_sclk),
     .lrck   (pmod_lrck),
     .sdout  (pmod_sdin)
     );

endmodule
