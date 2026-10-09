// ============================================================
//  tb_seq — 並び替え器にピースを描かせて、セルの中身を吐く
//
//  seq_in.hex の形式 (tools/tb_seq_check.py が作る)
//    0 番地        ピースの個数 N
//    1 番地から    1 個あたり 24 語 x N 個
//
//  供給元 (pdriver / AXI のピース表) の代わりをここでやる。
//  p_valid を立てておき、p_take が来たら次のピースへ進める。
//  **同じ種類のピースを続けて並べると、並び替え器が 1 つの枠に
//  4 個まで詰める**ので、そこを見るのがこのテストベンチの目的。
//
//  セル画像はここでは素のメモリで代用し、終わったら中身を seq_out.txt に書く。
//  Python 側 (tools/tb_seq_check.py) が同じピースを描いて突き合わせる。
// ============================================================
`timescale 1ns / 1ps

module tb_seq;

  localparam W = 24;
  localparam AB = 16;
  localparam CELL = 256;
  localparam WORDS = 24;        // 1 個あたりの語数
  localparam MAXP = 64;         // 入れられる個数

  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg resetn = 1'b0;

  reg [23:0] tab [0:WORDS*MAXP];
  integer ti;
  initial begin
    for (ti = 0; ti <= WORDS*MAXP; ti = ti + 1) tab[ti] = 24'h000000;
    $readmemh("seq_in.hex", tab);
  end

  // ---- ピースの供給元のまね ----
  wire [15:0] NP = tab[0][15:0];
  reg  [15:0] idx = 16'd0;
  wire        p_valid = (idx < NP);
  wire [15:0] base = 16'd1 + idx * WORDS;
  wire        p_take;

  always @(posedge clk) if (resetn && p_take) idx <= idx + 16'd1;

  wire               busy;
  wire               cell_we;
  wire [AB-1:0]      cell_addr, cell_raddr;
  wire [15:0]        cell_wdata;

  // セル画像の代わり。最初は 0 (黒)
  reg [15:0] cmem [0:CELL*CELL-1];
  integer ci;
  // 下地。tools/tb_seq_check.py が seq_bg.hex を置く
  //   ・無ければ全部 0 (黒地)
  //   ・油の地を入れると「下の色に重ねる」(段5d-3) を確かめられる
  initial begin
    for (ci = 0; ci < CELL*CELL; ci = ci + 1) cmem[ci] = 16'h0000;
    $readmemh("seq_bg.hex", cmem);
  end

  // ★ 読み出し遅延は **2 拍**。cell_uram の口B が b_q0 → b_q1 と
  //   2 段持っているので、ここも 2 段にしないと実機と合わない。
  reg [15:0] cell_rd0, cell_rdata;

  integer nwe = 0, ngroup = 0, ntake = 0;
  // 枠ごとに「何個のピースを混ぜたか」を数える。詰められているかの確かめ
  integer mixhist [0:4];
  integer mi;
  initial for (mi = 0; mi <= 4; mi = mi + 1) mixhist[mi] = 0;

  // 最初の枠で、スロットごとに「どのピースの定数を渡したか」を覗く
  integer shown = 0;
  always @(posedge clk) if (resetn && dut.st == 4'd5 && shown < 24) begin
    $display("EXEC slot=%0d cPS=%0d seed=%h e=%h rot=%h",
             dut.slot, dut.cPS[dut.slot], dut.pb_seed[dut.cPS[dut.slot]],
             dut.pb_e[dut.cPS[dut.slot]], dut.pb_rot[dut.cPS[dut.slot]]);
    shown = shown + 1;
  end

  // レーンへ渡した毎画素の初期値をそのまま吐く (単独と混合で比べるため)
  integer pfd;
  initial pfd = $fopen("seq_pre.txt", "w");
  always @(posedge clk) if (resetn && dut.l_preload)
    $fwrite(pfd, "%0d %0d %h %h %h %h %h %h %h %h\n",
            dut.l_slot, dut.l_rd,
            dut.l_pre[0], dut.l_pre[1], dut.l_pre[2], dut.l_pre[3],
            dut.l_pre[4], dut.l_pre[5], dut.l_pre[6], dut.l_pre[7]);

  // レーン0 に入る被演算子を命令ごとに吐く。どの命令から食い違うかが分かる
  integer vfd;
  initial vfd = $fopen("seq_lane0.txt", "w");
  always @(posedge clk) if (resetn && dut.lanes[0].lane_i.v1)
    $fwrite(vfd, "%0d %0d %0d %h %h %h %h %0d %h %0d\n",
            dut.lanes[0].lane_i.slot1, dut.lanes[0].lane_i.op1,
            dut.lanes[0].lane_i.rd1,
            dut.lanes[0].lane_i.va, dut.lanes[0].lane_i.vb,
            dut.lanes[0].lane_i.vc, dut.lanes[0].lane_i.pcs_r,
            dut.lanes[0].lane_i.ra_r, dut.lanes[0].lane_i.va_r,
            dut.lanes[0].lane_i.slot);

  // S_DRAIN (4'd6) に入った最初の拍が「枠を 1 つ流し終えた」ところ。
  // そのときの nmix が、その枠に混ざったピースの数 - 1。
  always @(posedge clk) if (resetn) begin
    if (p_take) ntake = ntake + 1;
    if (dut.st == 4'd6 && dut.drain == (22 + 8)) begin
      ngroup = ngroup + 1;
      mixhist[dut.nmix] = mixhist[dut.nmix] + 1;
    end
  end

  always @(posedge clk) begin
    cell_rd0   <= cmem[cell_raddr];
    cell_rdata <= cell_rd0;
    if (cell_we) begin
      cmem[cell_addr] <= cell_wdata;
      nwe = nwe + 1;
    end
  end

  pshade_seq #(.W(W), .AB(AB)) dut
    (.clk(clk), .resetn(resetn),
     .p_valid (p_valid), .p_take(p_take),
     .p_type  (tab[base +  0][3:0]),
     .p_bw    (tab[base +  1][8:0]),
     .p_npix  (tab[base +  2][17:0]),
     .p_x0    (tab[base +  3][7:0]),
     .p_y0    (tab[base +  4][7:0]),
     .p_vqx0  ($signed(tab[base +  5])), .p_vqy0 ($signed(tab[base +  6])),
     .p_qx0   ($signed(tab[base +  7])), .p_qy0  ($signed(tab[base +  8])),
     .p_sx_vqx($signed(tab[base +  9])), .p_sy_vqy($signed(tab[base + 10])),
     .p_sx_qx ($signed(tab[base + 11])), .p_sy_qx ($signed(tab[base + 12])),
     .p_sx_qy ($signed(tab[base + 13])), .p_sy_qy ($signed(tab[base + 14])),
     .p_seed  ($signed(tab[base + 15])), .p_e    ($signed(tab[base + 16])),
     .p_rot   ($signed(tab[base + 17])), .p_time ($signed(tab[base + 18])),
     .p_cr    (tab[base + 19][7:0]), .p_cg(tab[base + 20][7:0]),
     .p_cb    (tab[base + 21][7:0]),
     .p_depth ($signed(tab[base + 22])),
     .p_premul(tab[base + 23][0]),
     .busy(busy),
     .cell_we(cell_we), .cell_addr(cell_addr), .cell_wdata(cell_wdata),
     .cell_rdata(cell_rdata), .cell_raddr(cell_raddr));

  integer fd, i, cycles;

  initial begin
    repeat (8) @(negedge clk);
    resetn = 1'b1;
    @(negedge clk);

    // 全部のピースを取り込み、描き終わるまで回す
    cycles = 0;
    while (((idx < NP) || busy) && cycles < 3000000) begin
      @(posedge clk);
      cycles = cycles + 1;
    end
    repeat (8) @(negedge clk);

    fd = $fopen("seq_out.txt", "w");
    for (i = 0; i < CELL*CELL; i = i + 1)
      if (cmem[i] != 16'h0000) $fwrite(fd, "%0d %04x\n", i, cmem[i]);
    $fclose(fd);
    $display("PROBE ピース %0d 個  取り込み %0d 回  書き込み %0d 画素  枠 %0d 個",
             NP, ntake, nwe, ngroup);
    $display("PROBE 枠に混ざった個数の分布: 1個=%0d 2個=%0d 3個=%0d 4個=%0d",
             mixhist[0], mixhist[1], mixhist[2], mixhist[3]);
    // 最後の枠の A/K/W をそのまま吐く。単独で流したときと比べれば、
    // 壊れているのが「演算器の出力」か「合成」かを分けられる
    fd = $fopen("seq_dbg.txt", "w");
    for (i = 0; i < 192; i = i + 1)
      $fwrite(fd, "%0d %b %h %h %h %h\n", i, dut.cVD[i], dut.cAD[i],
              dut.cA[i], dut.cK[i], dut.cW[i]);
    $fclose(fd);
    $display("seq_out.txt done  %0d クロック", cycles);
    $finish;
  end

  initial begin
    #40000000;
    $display("時間切れ");
    $finish;
  end

endmodule
