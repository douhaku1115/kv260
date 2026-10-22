// ============================================================
// tb_ppu_nestest.v — 段D1: nestest を普通に起動してメニュー画面 (背景) を描かせる
// ============================================================
//
// PS と同じく AXI で PRG と CHR を書き、CTRL = 3 (実行 + 16KB 折り返し、水平ミラー)。
// リセットベクタはそのまま ($C004 = 画面に一覧を出す通常の起動)。
// PPU のフレーム数が NFRAMES になったら、画面バッファを frame.ppm に書き出す。
// 確認は tools/ppm2png.py で PNG にして目で見る。
`timescale 1ns/1ps

module tb_ppu_nestest;
  parameter NFRAMES = 10;   // nestest は最初の数フレーム、描画オフで画面を書く

  reg clk = 0, clkv = 0, mclk = 0;
  always #5      clk  = ~clk;
  always #6.734  clkv = ~clkv;
  always #40     mclk = ~mclk;

  reg resetn = 0;

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

  rtl_top dut
    (.clk(clk), .clkv(clkv), .mclk(mclk), .resetn(resetn),
     .bus_wr_en(bus_wr_en), .bus_wr_addr(bus_wr_addr), .bus_wr_data(bus_wr_data),
     .bus_rd_addr(bus_rd_addr), .bus_rd_data(bus_rd_data),
     .video_de(), .video_hsyncn(), .video_vsyncn(), .video_color(),
     .pmod_mclk(), .pmod_sclk(), .pmod_lrck(), .pmod_sdin());

  // 色表の正解
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

  reg [7:0]  prg8 [0:16383];
  reg [7:0]  chr8 [0:8191];
  reg [31:0] d;
  reg [5:0]  c;
  integer i, f, x, y, used [0:63], ncol;

  initial begin
    for (i = 0; i < 64; i = i + 1) begin
      pidx = i; @(posedge clk); @(posedge clk); #1 ptab[i] = prgb; used[i] = 0;
    end
    $readmemh("nestest_prg.hex", prg8);
    $readmemh("nestest_chr.hex", chr8);

    repeat (10) @(posedge clk);
    resetn = 1;
    repeat (20) @(posedge clk);

    for (i = 0; i < 4096; i = i + 1)
      axi_write(18'h20000 + i*4, {prg8[i*4+3], prg8[i*4+2], prg8[i*4+1], prg8[i*4]});
    for (i = 0; i < 8192; i = i + 1)
      axi_write(18'h30000 + i*4, {24'd0, chr8[i]});
    $display("PRG/CHR written");

    axi_write(18'h00000, 32'd3);
    while (dut.core.ppu0.frame_cnt < NFRAMES) @(posedge clk);
    // そのフレームの表示が全部書かれたあと (VBlank 中) に取り出す
    repeat (100) @(posedge clk);
    axi_read(18'h00040, d);
    $display("frames %0d, CPU PC=%h, PPUCTRL=%h PPUMASK=%h", NFRAMES, d[15:0],
             dut.core.ppu0.ctrl, dut.core.ppu0.mask);

    // ---- 観測: PPU の中身 ----
    ncol = 0;
    for (i = 0; i < 2048; i = i + 1) if (dut.core.ppu0.nt[i] != 0) ncol = ncol + 1;
    $display("NT nonzero bytes: %0d / 2048", ncol);
    for (y = 0; y < 8; y = y + 1) begin
      $write("NT row %0d:", y);
      for (x = 0; x < 32; x = x + 1) $write(" %h", dut.core.ppu0.nt[y*32 + x]);
      $write("\n");
    end
    ncol = 0;
    for (i = 0; i < 8192; i = i + 1) if (dut.core.ppu0.chr[i] != 0) ncol = ncol + 1;
    $display("CHR nonzero bytes: %0d / 8192", ncol);
    $write("PAL:");
    for (i = 0; i < 32; i = i + 1) $write(" %h", dut.core.ppu0.pal[i]);
    $write("\n");
    $display("v=%h t=%h fx=%0d", dut.core.ppu0.v, dut.core.ppu0.t, dut.core.ppu0.fx);

    f = $fopen("frame.ppm", "w");
    $fwrite(f, "P3\n256 240\n255\n");
    for (y = 0; y < 240; y = y + 1)
      for (x = 0; x < 256; x = x + 1) begin
        case (x % 4)
          0: c = dut.fb0.bank[0].mem[y*64 + x/4];
          1: c = dut.fb0.bank[1].mem[y*64 + x/4];
          2: c = dut.fb0.bank[2].mem[y*64 + x/4];
          default: c = dut.fb0.bank[3].mem[y*64 + x/4];
        endcase
        if (^c === 1'bx) c = 6'h0F;
        used[c] = used[c] + 1;
        $fwrite(f, "%0d %0d %0d\n", ptab[c][23:16], ptab[c][15:8], ptab[c][7:0]);
      end
    $fclose(f);
    ncol = 0;
    for (i = 0; i < 64; i = i + 1)
      if (used[i] > 0) begin ncol = ncol + 1; $display("color %h: %0d px", i, used[i]); end
    $display("frame.ppm written, %0d colors", ncol);
    $finish;
  end

  initial begin
    #400_000_000;
    $display("FAIL timeout frames=%0d PC=%h", dut.core.ppu0.frame_cnt, dut.core.dbg_pc);
    $finish;
  end
endmodule
