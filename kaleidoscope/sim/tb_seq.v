// ============================================================
//  tb_seq — 並び替え器にピースを 1 個描かせて、セルの中身を吐く
//
//  seq_in.hex から 1 個ぶんの設定を読み、start を立てて busy が下りるまで回す。
//  セル画像はここでは素のメモリで代用し、終わったら中身を seq_out.txt に書く。
//  Python 側 (tools/tb_seq_check.py) が同じピースを描いて突き合わせる。
// ============================================================
`timescale 1ns / 1ps

module tb_seq;

  localparam W = 24;
  localparam AB = 16;
  localparam CELL = 256;

  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg resetn = 1'b0;

  reg [23:0] cfg [0:31];
  initial $readmemh("seq_in.hex", cfg);

  reg                start = 1'b0;
  wire               busy;

  wire               cell_we;
  wire [AB-1:0]      cell_addr, cell_raddr;
  wire [15:0]        cell_wdata;

  // セル画像の代わり。最初は 0 (黒)
  reg [15:0] cmem [0:CELL*CELL-1];
  reg [15:0] cell_rdata;
  integer ci;
  initial for (ci = 0; ci < CELL*CELL; ci = ci + 1) cmem[ci] = 16'h0000;

  integer nwe = 0, n29 = 0, nout = 0, nxslot = 0, n191 = 0, n190 = 0;
  // 最初の枠で、レーンへ渡した初期値と書き込み先をそのまま覗く
  integer shown = 0;
  always @(posedge clk) begin
    if (dut.l_preload && shown < 12) begin
      $display("PRE slot=%0d rd=%0d lane0=%h lane1=%h  x=%0d y=%0d",
               dut.l_slot, dut.l_rd, dut.l_pre[0], dut.l_pre[1],
               dut.lxw[0], dut.lyw[0]);
      shown = shown + 1;
    end
  end
  integer gq;
  always @(posedge clk) begin
    for (gq = 0; gq < 8; gq = gq + 1) begin
      if (dut.o_we[gq]) begin
        nout = nout + 1;
        if (dut.o_rd[gq] == 5'd29) begin
          n29 = n29 + 1;
          if (^{dut.o_slot[gq]} === 1'bx) nxslot = nxslot + 1;
        end
      end
    end
  end
  always @(posedge clk) begin
    cell_rdata <= cmem[cell_raddr];
    if (cell_we) begin
      cmem[cell_addr] <= cell_wdata;
      nwe = nwe + 1;
      if (dut.bi_d2 == 9'd191) begin
        n191 = n191 + 1;
        if (n191 < 6) $display("W191 addr=%h data=%h  A=%h K=%h W=%h",
                               cell_addr, cell_wdata, dut.cA[191], dut.cK[191], dut.cW[191]);
      end
      if (dut.bi_d2 == 9'd190 && n190 < 3)
        $display("W190 addr=%h data=%h  A=%h", cell_addr, cell_wdata, dut.cA[190]);
      if (dut.bi_d2 == 9'd190) n190 = n190 + 1;
    end
  end

  pshade_seq #(.W(W), .AB(AB)) dut
    (.clk(clk), .resetn(resetn), .start(start),
     .p_type  (cfg[0][3:0]),
     .p_bw    (cfg[1][8:0]),
     .p_npix  (cfg[2][17:0]),
     .p_x0    (cfg[3][7:0]),
     .p_y0    (cfg[4][7:0]),
     .p_vqx0  ($signed(cfg[5])),  .p_vqy0 ($signed(cfg[6])),
     .p_qx0   ($signed(cfg[7])),  .p_qy0  ($signed(cfg[8])),
     .p_sx_vqx($signed(cfg[9])),  .p_sy_vqy($signed(cfg[10])),
     .p_sx_qx ($signed(cfg[11])), .p_sy_qx ($signed(cfg[12])),
     .p_sx_qy ($signed(cfg[13])), .p_sy_qy ($signed(cfg[14])),
     .p_seed  ($signed(cfg[15])), .p_e    ($signed(cfg[16])),
     .p_rot   ($signed(cfg[17])), .p_time ($signed(cfg[18])),
     .p_cr    (cfg[19][7:0]), .p_cg(cfg[20][7:0]), .p_cb(cfg[21][7:0]),
     .p_depth ($signed(cfg[22])),
     .p_premul(cfg[23][0]),
     .busy(busy),
     .cell_we(cell_we), .cell_addr(cell_addr), .cell_wdata(cell_wdata),
     .cell_rdata(cell_rdata), .cell_raddr(cell_raddr));

  integer fd, i, cycles;

  initial begin
    repeat (8) @(negedge clk);
    resetn = 1'b1;
    repeat (4) @(negedge clk);
    start <= 1'b1;
    @(negedge clk);
    start <= 1'b0;
    @(negedge clk);

    cycles = 0;
    while (busy && cycles < 3000000) begin
      @(posedge clk);
      cycles = cycles + 1;
    end
    repeat (8) @(negedge clk);

    fd = $fopen("seq_out.txt", "w");
    for (i = 0; i < CELL*CELL; i = i + 1)
      if (cmem[i] != 16'h0000) $fwrite(fd, "%0d %04x\n", i, cmem[i]);
    $fclose(fd);
    $display("PROBE we=%0d  st=%0d  cVD[15:0]=%b  npix=%0d bw=%0d",
             nwe, dut.st, dut.cVD[15:0], dut.pix_i.r_npix, dut.pix_i.r_bw);
    $display("PROBE bi_d2=190 の書き込み %0d 回、191 は %0d 回", n190, n191);
    $display("PROBE 書き戻し総数=%0d  r29=%0d  slotがX=%0d", nout, n29, nxslot);
    $display("PROBE cVD[191]=%b cA[191]=%h cK[191]=%h cAD[191]=%h",
             dut.cVD[191], dut.cA[191], dut.cK[191], dut.cAD[191]);
    $display("PROBE cA[0]=%h cA[8]=%h cA[100]=%h  cK[100]=%h cW[100]=%h",
             dut.cA[0], dut.cA[8], dut.cA[100], dut.cK[100], dut.cW[100]);
    $display("PROBE cA0=%h cK0=%h cW0=%h cAD0=%h  pre_n=%0d pmask=%b",
             dut.cA[0], dut.cK[0], dut.cW[0], dut.cAD[0], dut.pre_n, dut.pmask);
    $display("seq_out.txt done  %0d クロック", cycles);
    $finish;
  end

  initial begin
    #40000000;
    $display("時間切れ");
    $finish;
  end

endmodule
