// ============================================================
// rtl_top.v — KV260 NES トップ (段A: 画面バッファ表示 + テスト音)
// ============================================================
//
// NES の画面 256x240 を 3 倍 (768x720) にして 1280x720 の中央 (X=256) に出す。
// 画面バッファ (nes_fb) の色番号を nes_palette で RGB にする。
// 段A では PS が AXI で画面バッファに直接書く。段D 以降は PPU が書く。
// 音は Pmod I2S2 (J2) へ。APU (nes_core 内) の音を mclk 側に渡して i2s_tx で送る。
// 同じ音を HDMI (PS の DP の Live Audio) にも出す。xlive_audio (miya4649) が 48kHz の S/PDIF 形式にする。
//
// 【AXI マップ (ベース 0xA0000000, 256KB)】 レジスタは 0x10 刻み
//   0x00000 CTRL  (RW) bit0=1 で CPU 実行 (0 でリセット保持)
//                      bit2=1 でネームテーブル垂直ミラー (0 = 水平。配線で決まるマッパー用)
//                      bit3=1 で CHR-RAM ($2007 で書ける) / [7:4] マッパー番号 (0,1,2,3,4,7)
//                      [11:8] PRG の 16KB 個数 - 1 / [15:12] CHR の 8KB 個数 - 1
//   0x00010 ID    (R)  0x4E455301 ("NES" + 版)。AXI が届いているかの確認用
//   0x00020 PAD   (RW) コントローラ 1。1 = 押下
//                      [0]A [1]B [2]Select [3]Start [4]上 [5]下 [6]左 [7]右
//   0x00030 FRAME (R)  映像のフレーム数 (60Hz で増える)。映像クロックの生存確認
//   0x00040 PC    (R)  CPU の PC (観測用)
//   0x00050 CYC   (R)  CPU の経過サイクル数 (CTRL bit0=0 で 0 に戻る)
//   0x00060 PFRM  (R)  PPU のフレーム数 (VBlank に入った回数)
//   0x00070 LOAD  (RW) PRG / CHR 書き込み窓の位置。[2:0] = PRG の 32KB 単位、[7:4] = CHR の 8KB 単位
//   0x08000-0x09FFC WRAM (R) 内蔵 RAM。1 語 = 1 バイト ([7:0])、番地 = $0000 + n
//   0x10000-0x1EFFC FB (W) 画面バッファ。語番号 = y*64 + x/4、1 語 = 横 4 画素
//                    データ [5:0]=x, [13:8]=x+1, [21:16]=x+2, [29:24]=x+3 (色番号)
//   0x20000-0x27FFC PRG (W) 1 語 = 4 バイト ([7:0] が若い番地)。PRG の LOAD[2:0]*32KB + n*4 に入る
//   0x30000-0x37FFC CHR (W) 1 語 = 1 バイト ([7:0])。CHR の LOAD[7:4]*8KB + n に入る
//                   どちらも CPU 停止中に書く
//
// 画面バッファは PPU が 1 画素ずつ書く。PS からの FB 書き込みは PPU が書かないクロックだけ通る。

module rtl_top
  (
   input wire         clk,
   input wire         clkv,
   input wire         mclk,
   input wire         clka,      // DP の音のクロック 24.576MHz (= 48kHz x 512)
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
   // DP live audio 出力 (AXI ストリーム)
   output wire [31:0] audio_data,
   output wire        audio_id,
   output wire        audio_valid,
   input  wire        audio_ready,
   // Pmod I2S2 (J2)
   output wire        pmod_mclk,
   output wire        pmod_sclk,
   output wire        pmod_lrck,
   output wire        pmod_sdin
   );

  wire reset;
  wire resetv;
  wire reseta;
  wire resetp;
  assign resetp = ~resetn;

  shift_register #(.DELAY(3)) sr_reset  (.clk(clk),  .din(resetp), .dout(reset));
  shift_register #(.DELAY(3)) sr_resetv (.clk(clkv), .din(resetp), .dout(resetv));
  shift_register #(.DELAY(3)) sr_reseta (.clk(clka), .din(resetp), .dout(reseta));

  // ------------------------------------------------------------
  // レジスタ (clk 側)
  // ------------------------------------------------------------
  localparam [31:0] NES_ID = 32'h4E455301;

  reg  [31:0] reg_ctrl;
  reg  [31:0] reg_pad;
  reg  [7:0]  reg_load;
  reg  [31:0] frame_cnt;

  wire wr_reg = bus_wr_en && (bus_wr_addr[17:16] == 2'b00);
  wire wr_fb  = bus_wr_en && (bus_wr_addr[17:16] == 2'b01);
  wire wr_prg = bus_wr_en && (bus_wr_addr[17:15] == 3'b100);
  wire wr_chr = bus_wr_en && (bus_wr_addr[17:15] == 3'b110);

  // NES 本体
  wire [15:0] cpu_pc;
  wire [31:0] cpu_cycles;
  wire [7:0]  wram_rdata;
  wire        pix_we;
  wire [7:0]  pix_x, pix_y;
  wire [5:0]  pix_c;
  wire [31:0] ppu_frames;
  wire signed [15:0] audio;

  nes_core core
    (
     .clk        (clk),
     .run        (reg_ctrl[0]),
     .cart       (reg_ctrl[15:0]),
     .pad        (reg_pad[7:0]),
     .chr_we     (wr_chr),
     .chr_waddr  ({reg_load[7:4], bus_wr_addr[14:2]}),
     .chr_wdata  (bus_wr_data[7:0]),
     .pix_we     (pix_we),
     .pix_x      (pix_x),
     .pix_y      (pix_y),
     .pix_c      (pix_c),
     .ppu_frames (ppu_frames),
     .audio      (audio),
     .prg_we     (wr_prg),
     .prg_waddr  ({reg_load[2:0], bus_wr_addr[14:2]}),
     .prg_wdata  (bus_wr_data),
     .wram_raddr (bus_rd_addr[12:2]),
     .wram_rdata (wram_rdata),
     .dbg_pc     (cpu_pc),
     .cpu_cycles (cpu_cycles),
     .cpu_sync   (),
     .cpu_addr   ()
     );

  always @(posedge clk) begin
    if (reset) begin
      reg_ctrl <= 32'd0;
      reg_pad  <= 32'd0;
      reg_load <= 8'd0;
    end else if (wr_reg) begin
      case (bus_wr_addr[7:4])
        4'h0: reg_ctrl <= bus_wr_data;
        4'h2: reg_pad  <= bus_wr_data;
        4'h7: reg_load <= bus_wr_data[7:0];
        default: ;
      endcase
    end
  end

  // 読み: WRAM は nes_core 内で 1 拍遅れ、ここでさらに 1 拍 (nes_axi_slave は 3 拍待つ)
  always @(posedge clk) begin
    if (bus_rd_addr[17:13] == 5'b00100)
      bus_rd_data <= {24'd0, wram_rdata};
    else
      case (bus_rd_addr[7:4])
        4'h0: bus_rd_data <= reg_ctrl;
        4'h1: bus_rd_data <= NES_ID;
        4'h2: bus_rd_data <= reg_pad;
        4'h3: bus_rd_data <= frame_cnt;
        4'h4: bus_rd_data <= {16'd0, cpu_pc};
        4'h5: bus_rd_data <= cpu_cycles;
        4'h6: bus_rd_data <= ppu_frames;
        4'h7: bus_rd_data <= {24'd0, reg_load};
        default: bus_rd_data <= 32'd0;
      endcase
  end

  // ------------------------------------------------------------
  // 画面バッファ
  // ------------------------------------------------------------
  wire [13:0] fb_raddr;
  wire [23:0] fb_rdata;

  // PPU の 1 画素書き (優先) と PS の 4 画素書き
  wire        axi_fb_we = wr_fb && (bus_wr_addr[15:2] < 14'd15360);
  wire [3:0]  pix_mask  = 4'b0001 << pix_x[1:0];

  nes_fb fb0
    (
     .clk   (clk),
     .we    (pix_we | axi_fb_we),
     .wmask (pix_we ? pix_mask : 4'hF),
     .waddr (pix_we ? {pix_y, pix_x[7:2]} : bus_wr_addr[15:2]),
     .wdata (pix_we ? {4{pix_c}}
                    : {bus_wr_data[29:24], bus_wr_data[21:16], bus_wr_data[13:8], bus_wr_data[5:0]}),
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
  // 音 (APU → Pmod I2S2)
  // ------------------------------------------------------------
  // clk 側: 1024 クロック (約 10us) ごとに値を止めて、トグルで知らせる
  // mclk 側: トグルを 2 段で受け、変わったら値を取る (値はその間止まっているので安全)
  reg  [9:0]  aud_div = 10'd0;
  reg  signed [15:0] aud_hold = 16'sd0;
  reg         aud_tgl = 1'b0;
  always @(posedge clk) begin
    aud_div <= aud_div + 10'd1;
    if (aud_div == 10'd0) begin
      aud_hold <= audio;
      aud_tgl  <= ~aud_tgl;
    end
  end

  (* ASYNC_REG = "TRUE" *) reg [2:0] aud_sync = 3'd0;
  reg signed [15:0] aud_m = 16'sd0;
  always @(posedge mclk) begin
    aud_sync <= {aud_sync[1:0], aud_tgl};
    if (aud_sync[2] != aud_sync[1]) aud_m <= aud_hold;
  end

  i2s_tx i2s0
    (
     .mclk   (mclk),
     .rst_n  (resetn),
     .ext_sample (aud_m),
     .mclk_o (pmod_mclk),
     .sclk   (pmod_sclk),
     .lrck   (pmod_lrck),
     .sdout  (pmod_sdin)
     );

  // ------------------------------------------------------------
  // 音 (APU → HDMI)
  // ------------------------------------------------------------
  // I2S と同じく aud_hold / aud_tgl を clka (24.576MHz) 側で受け、512 クロックに 1 回 (= 48kHz ちょうど)
  // その値を FIFO に入れる。DP は同じ clka から 48kHz で取り出すので、入りと出の速さが一致する。
  // (FIFO が空くたびに clk 側から入れる作りは、空きの知らせが遅れて 3 個ずつ固まって入り、
  //  値の間隔が 1/16kHz になった。tb_hdmi_audio で確認)
  // APU 出力は約 18kHz のローパス済みなので、48kHz で拾い直しても折り返しは小さい。左右とも同じ値。
  (* ASYNC_REG = "TRUE" *) reg [2:0] dpa_sync = 3'd0;
  reg  signed [15:0] dpa_s = 16'sd0;
  reg  [8:0] dpa_div = 9'd0;
  reg        dpa_en = 1'b0;
  wire       dpa_full;
  always @(posedge clka) begin
    dpa_sync <= {dpa_sync[1:0], aud_tgl};
    if (dpa_sync[2] != dpa_sync[1]) dpa_s <= aud_hold;
    dpa_div <= dpa_div + 9'd1;
    dpa_en  <= !reseta && (dpa_div == 9'd0) && !dpa_full;
  end

  xlive_audio
    #(
      .AUDIO_WIDTH (16),
      .BUFFER_DEPTH (4),
      .AES_MODE (0),
      .SAMPLE_FREQ (48000)
      )
  xlive_audio_0
    (
     .clk_tx   (clka),
     .clk_rx   (clka),
     .reset_tx (reseta),
     .reset_rx (reseta),
     .data_rx  ({dpa_s, dpa_s}),
     .en_rx    (dpa_en),
     .full_rx  (dpa_full),
     .data_tx  (audio_data),
     .valid_tx (audio_valid),
     .id_tx    (audio_id),
     .ready_tx (audio_ready)
     );

endmodule
