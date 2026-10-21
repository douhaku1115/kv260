// ============================================================
// tb_stageA.v — 段A の検証 (AXI 書込 → 画面バッファ → 3 倍表示)
// ============================================================
//
// 1. AXI で ID を読み 0x4E455301 か
// 2. AXI で画面バッファ全体に 色番号 = (x + 2*y) & 63 を書く
// 3. 映像 1 フレームの全画素を照合
//      NES 画面内: 位置 (h-256)/3, v/3 の色番号を色表で引いた RGB
//      画面外    : 0x101010
// 4. FRAME レジスタが増えているか
// 5. 3 で割る式 n*683>>11 が floor(n/3) と一致するか (n = 0〜767 全数)
`timescale 1ns/1ps

module tb_stageA;
  reg clk = 0, clkv = 0, mclk = 0;
  always #5      clk  = ~clk;    // 100MHz
  always #6.734  clkv = ~clkv;   // 74.25MHz
  always #40     mclk = ~mclk;   // 12.5MHz

  reg resetn = 0;

  // AXI
  reg  [17:0] awaddr = 0; reg awvalid = 0; wire awready;
  reg  [31:0] wdata  = 0; reg wvalid  = 0; wire wready;
  wire [1:0]  bresp;  wire bvalid; reg bready = 1;
  reg  [17:0] araddr = 0; reg arvalid = 0; wire arready;
  wire [31:0] rdata;  wire [1:0] rresp; wire rvalid; reg rready = 1;

  wire        bus_wr_en;
  wire [17:0] bus_wr_addr, bus_rd_addr;
  wire [31:0] bus_wr_data, bus_rd_data;

  nes_axi_slave axi
    (.S_AXI_ACLK(clk), .S_AXI_ARESETN(resetn),
     .S_AXI_AWADDR(awaddr), .S_AXI_AWPROT(3'd0), .S_AXI_AWVALID(awvalid), .S_AXI_AWREADY(awready),
     .S_AXI_WDATA(wdata), .S_AXI_WSTRB(4'hF), .S_AXI_WVALID(wvalid), .S_AXI_WREADY(wready),
     .S_AXI_BRESP(bresp), .S_AXI_BVALID(bvalid), .S_AXI_BREADY(bready),
     .S_AXI_ARADDR(araddr), .S_AXI_ARPROT(3'd0), .S_AXI_ARVALID(arvalid), .S_AXI_ARREADY(arready),
     .S_AXI_RDATA(rdata), .S_AXI_RRESP(rresp), .S_AXI_RVALID(rvalid), .S_AXI_RREADY(rready),
     .bus_wr_en(bus_wr_en), .bus_wr_addr(bus_wr_addr), .bus_wr_data(bus_wr_data),
     .bus_rd_addr(bus_rd_addr), .bus_rd_data(bus_rd_data));

  wire        de, hsn, vsn;
  wire [35:0] vcolor;
  wire        p_mclk, p_sclk, p_lrck, p_sdin;

  rtl_top dut
    (.clk(clk), .clkv(clkv), .mclk(mclk), .resetn(resetn),
     .bus_wr_en(bus_wr_en), .bus_wr_addr(bus_wr_addr), .bus_wr_data(bus_wr_data),
     .bus_rd_addr(bus_rd_addr), .bus_rd_data(bus_rd_data),
     .video_de(de), .video_hsyncn(hsn), .video_vsyncn(vsn), .video_color(vcolor),
     .pmod_mclk(p_mclk), .pmod_sclk(p_sclk), .pmod_lrck(p_lrck), .pmod_sdin(p_sdin));

  // 色表の正解: 別の nes_palette を回して 64 色を表に取る
  reg  [5:0]  pidx = 0;
  wire [23:0] prgb;
  reg  [23:0] ptab [0:63];
  nes_palette pref (.clk(clk), .idx(pidx), .rgb(prgb));

  task axi_write(input [17:0] a, input [31:0] d);
    begin
      @(posedge clk);
      awaddr <= a; awvalid <= 1; wdata <= d; wvalid <= 1;
      @(posedge clk);
      while (!(awready && wready)) @(posedge clk);
      awvalid <= 0; wvalid <= 0;
      while (!bvalid) @(posedge clk);
      @(posedge clk);
    end
  endtask

  task axi_read(input [17:0] a, output [31:0] d);
    begin
      @(posedge clk);
      araddr <= a; arvalid <= 1;
      @(posedge clk);
      while (!arready) @(posedge clk);
      arvalid <= 0;
      while (!rvalid) @(posedge clk);
      d = rdata;
      @(posedge clk);
    end
  endtask

  function [5:0] pat(input integer x, input integer y);
    pat = (x + 2*y) & 63;
  endfunction

  // 映像出力の RGB (rtl_top の詰め方を戻す)
  wire [23:0] out_rgb = {vcolor[23:16], vcolor[11:4], vcolor[35:28]};

  integer i, x, y, n, errs, cnt, h, v;
  reg [31:0] d, f0, f1;
  reg [23:0] exp_rgb;
  reg [5:0]  p0, p1, p2, p3;
  reg        de_d;

  initial begin
    errs = 0;

    // 3 で割る式の全数確認
    for (n = 0; n < 768; n = n + 1)
      if (((n * 683) >> 11) != n / 3) begin
        $display("NG div3 n=%0d", n); errs = errs + 1;
      end

    for (i = 0; i < 64; i = i + 1) begin
      pidx = i; @(posedge clk); @(posedge clk); #1 ptab[i] = prgb;
    end

    repeat (10) @(posedge clk);
    resetn = 1;
    repeat (20) @(posedge clk);

    axi_read(18'h00010, d);
    if (d !== 32'h4E455301) begin $display("NG ID=%h", d); errs = errs + 1; end
    else $display("ID OK %h", d);

    // 画面バッファ全体を書く
    // ★ 連結式の中で pat() を何度も呼ぶと xsim では x になる。変数に受けてから組む
    for (y = 0; y < 240; y = y + 1)
      for (x = 0; x < 256; x = x + 4) begin
        p0 = pat(x, y); p1 = pat(x+1, y); p2 = pat(x+2, y); p3 = pat(x+3, y);
        axi_write(18'h10000 + ((y*64 + x/4) << 2),
                  {2'b0, p3, 2'b0, p2, 2'b0, p1, 2'b0, p0});
      end
    $display("FB written");

    axi_read(18'h00030, f0);

    // 次のフレームの頭 (vsync 終わり) を待ってから 1 フレーム照合
    @(negedge vsn); @(posedge vsn);
    h = 0; v = 0; cnt = 0; de_d = 0;
    while (v < 720) begin
      @(posedge clkv); #1;
      if (de) begin
        if (h >= 256 && h < 1024) exp_rgb = ptab[pat((h-256)/3, v/3)];
        else                      exp_rgb = 24'h101010;
        if (out_rgb !== exp_rgb) begin
          if (errs < 10) $display("NG h=%0d v=%0d got=%h exp=%h", h, v, out_rgb, exp_rgb);
          errs = errs + 1;
        end
        cnt = cnt + 1;
        h = h + 1;
      end else if (de_d) begin
        h = 0; v = v + 1;
      end
      de_d = de;
    end
    $display("pixels checked %0d", cnt);

    axi_read(18'h00030, f1);
    if (f1 == f0) begin $display("NG FRAME not counting %0d", f1); errs = errs + 1; end
    else $display("FRAME %0d -> %0d", f0, f1);

    if (errs == 0) $display("PASS"); else $display("FAIL errs=%0d", errs);
    $finish;
  end
endmodule
