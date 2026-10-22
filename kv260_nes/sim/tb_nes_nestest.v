// ============================================================
// tb_nes_nestest.v — 段C: AXI だけで nestest を走らせる
// ============================================================
//
// PS がやるのと同じ手順を AXI で行う:
//   1. PRG 16KB を 0x20000〜 に書く (リセットベクタは $C000 に差し替え)
//   2. CTRL = 3 (実行 + 16KB 折り返し)
//   3. 公式命令の部分が終わる PC=$C6BD の取り出しで CTRL = 2 (停止)
//   4. AXI で PC / CYC を読む
//   5. AXI で内蔵 RAM 2KB を全部読み、回路内の RAM と突き合わせる
//      ($02/$03 が 00 でも読み出し経路が壊れて 0 が返っているだけ、を見分ける)
`timescale 1ns/1ps

module tb_nes_nestest;
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
  reg [31:0] d, pc, cyc;
  integer i, errs, nz;

  initial begin
    errs = 0;
    $readmemh("nestest_prg.hex", prg8);
    prg8[14'h3FFC] = 8'h00;                   // リセットベクタ → $C000
    prg8[14'h3FFD] = 8'hC0;

    repeat (10) @(posedge clk);
    resetn = 1;
    repeat (20) @(posedge clk);

    axi_read(18'h00010, d);
    if (d !== 32'h4E455301) begin $display("NG ID=%h", d); errs = errs + 1; end

    for (i = 0; i < 4096; i = i + 1)
      axi_write(18'h20000 + i*4, {prg8[i*4+3], prg8[i*4+2], prg8[i*4+1], prg8[i*4]});
    $display("PRG written");

    axi_write(18'h00000, 32'd3);              // 実行 + 16KB 折り返し
    @(posedge clk);
    while (!(dut.core.cpu_sync && dut.core.cpu_addr == 16'hC6BD)) @(posedge clk);
    axi_read(18'h00040, pc);
    axi_read(18'h00050, cyc);
    axi_write(18'h00000, 32'd2);              // 停止
    $display("stopped: PC=%h CYC=%0d (nestest.log: C6BD at CYC 14579)", pc, cyc);

    nz = 0;
    for (i = 0; i < 2048; i = i + 1) begin
      axi_read(18'h08000 + i*4, d);
      if (d[7:0] !== dut.core.wram[i]) begin
        if (errs < 5) $display("NG WRAM[%h] axi=%h core=%h", i, d[7:0], dut.core.wram[i]);
        errs = errs + 1;
      end
      if (d[7:0] != 8'h00) nz = nz + 1;
    end
    $display("WRAM 2048 bytes read via AXI, nonzero %0d", nz);

    axi_read(18'h08000 + 2*4, d);
    $display("nestest result $02=%h", d[7:0]);
    if (d[7:0] !== 8'h00) errs = errs + 1;
    axi_read(18'h08000 + 3*4, d);
    $display("nestest result $03=%h", d[7:0]);
    if (d[7:0] !== 8'h00) errs = errs + 1;

    if (errs == 0) $display("PASS"); else $display("FAIL errs=%0d", errs);
    $finish;
  end

  initial begin
    #100_000_000;
    $display("FAIL timeout PC=%h", dut.core.dbg_pc);
    $finish;
  end
endmodule
