// ============================================================
//  tb_draw — pdriver と pshade_seq を**繋いだ状態**で描かせる
//
//  これまで pdriver 単体 (tb_pdriver) と pshade_seq 単体 (tb_seq) は
//  それぞれ検証していたが、**繋いだ状態は見ていなかった**。実機はこの形。
//
//  見るもの:
//    ・271 個を描き終えて**止まるか** (busy と all_done)
//    ・止まったあとセルが書き換わらないか (書き込み回数を前後で比べる)
//    ・セルの中身 (seq_out.txt / seq_outf.txt)
//
//  段5d-5 の実機で「模様が速く動いて周期的に出たり消えたりする」症状が
//  出たので、描き終わらずに回り続けていないかをここで確かめる。
// ============================================================
`timescale 1ns / 1ps

module tb_draw;

  localparam W = 24;
  localparam AB = 16;
  localparam CELL = 256;
  localparam NPIECE = 271;

  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg resetn = 1'b0;
  reg draw_req = 1'b0;

  // ---- pdriver → pshade_seq ----
  wire        p_valid, p_take, p_premul, p_front, all_done;
  wire [3:0]  p_type;
  wire [8:0]  p_bw;
  wire [17:0] p_npix;
  wire [7:0]  p_x0, p_y0, p_cr, p_cg, p_cb;
  wire signed [W-1:0] p_vqx0, p_vqy0, p_qx0, p_qy0;
  wire signed [W-1:0] p_sx_vqx, p_sy_vqy, p_sx_qx, p_sy_qx, p_sx_qy, p_sy_qy;
  wire signed [W-1:0] p_seed, p_e, p_rot, p_time, p_depth;

  pdriver #(.NPIECE(NPIECE)) drv
    (.clk(clk), .resetn(resetn), .p_take(p_take), .draw_req(draw_req),
     .p_valid(p_valid), .p_type(p_type), .p_bw(p_bw), .p_npix(p_npix),
     .p_x0(p_x0), .p_y0(p_y0),
     .p_vqx0(p_vqx0), .p_vqy0(p_vqy0), .p_qx0(p_qx0), .p_qy0(p_qy0),
     .p_sx_vqx(p_sx_vqx), .p_sy_vqy(p_sy_vqy),
     .p_sx_qx(p_sx_qx), .p_sy_qx(p_sy_qx),
     .p_sx_qy(p_sx_qy), .p_sy_qy(p_sy_qy),
     .p_seed(p_seed), .p_e(p_e), .p_rot(p_rot), .p_time(p_time),
     .p_cr(p_cr), .p_cg(p_cg), .p_cb(p_cb),
     .p_depth(p_depth), .p_premul(p_premul), .p_front(p_front),
     .all_done(all_done));

  wire        busy, cell_we, cell_front;
  wire [AB-1:0] cell_addr, cell_raddr;
  wire [31:0] cell_wdata;

  // セル 2 枚。奥層は油の地から、手前層は透明から
  reg [15:0] cmem  [0:CELL*CELL-1];
  reg [31:0] cmemf [0:CELL*CELL-1];
  integer ci;
  initial begin
    for (ci = 0; ci < CELL*CELL; ci = ci + 1) begin
      cmem[ci]  = 16'h0000;
      cmemf[ci] = 32'h00000000;
    end
    $readmemh("seq_bg.hex", cmem);
  end

  // 読み出し遅延 2 拍 (cell_uram の口B と同じ)
  reg [15:0] cell_rd0, cell_rdata;
  reg [31:0] cellf_rd0, cellf_rdata;

  integer nwe = 0, nwe_mark = 0;

  always @(posedge clk) begin
    cell_rd0    <= cmem [cell_raddr];
    cell_rdata  <= cell_rd0;
    cellf_rd0   <= cmemf[cell_raddr];
    cellf_rdata <= cellf_rd0;
    if (cell_we) begin
      if (cell_front) cmemf[cell_addr] <= cell_wdata;
      else            cmem [cell_addr] <= cell_wdata[15:0];
      nwe = nwe + 1;
    end
  end

  pshade_seq #(.W(W), .AB(AB)) seq
    (.clk(clk), .resetn(resetn),
     .p_valid(p_valid), .p_take(p_take),
     .p_type(p_type), .p_bw(p_bw), .p_npix(p_npix),
     .p_x0(p_x0), .p_y0(p_y0),
     .p_vqx0(p_vqx0), .p_vqy0(p_vqy0), .p_qx0(p_qx0), .p_qy0(p_qy0),
     .p_sx_vqx(p_sx_vqx), .p_sy_vqy(p_sy_vqy),
     .p_sx_qx(p_sx_qx), .p_sy_qx(p_sy_qx),
     .p_sx_qy(p_sx_qy), .p_sy_qy(p_sy_qy),
     .p_seed(p_seed), .p_e(p_e), .p_rot(p_rot), .p_time(p_time),
     .p_cr(p_cr), .p_cg(p_cg), .p_cb(p_cb),
     .p_depth(p_depth), .p_premul(p_premul), .p_front(p_front),
     .busy(busy),
     .cell_we(cell_we), .cell_front(cell_front),
     .cell_addr(cell_addr), .cell_wdata(cell_wdata),
     .cell_rdata_back(cell_rdata), .cell_rdata_front(cellf_rdata),
     .cell_raddr(cell_raddr));

  integer fd, i, cyc, idle;

  initial begin
    repeat (8) @(negedge clk);
    resetn = 1'b1;

    // ★ まず「描画開始が来るまで描かない」ことを確かめる (段5d-6)。
    //   ここで描いてしまうと、実機では PS の流し込みに上書きされる
    repeat (20000) @(posedge clk);
    if (nwe != 0) $display("DRAW ★ 開始前に %0d 画素も描いている", nwe);
    else          $display("DRAW 開始前は描かない (20000 クロック待って 0 画素)");

    // 描画開始を 1 クロックだけ出す
    @(negedge clk); draw_req = 1'b1;
    @(negedge clk); draw_req = 1'b0;

    // 描き終わる (all_done かつ busy が下りる) まで回す
    cyc = 0;
    while (!(all_done && !busy) && cyc < 20000000) begin
      @(posedge clk);
      cyc = cyc + 1;
    end
    $display("DRAW 描き終えた %0d クロック  all_done=%b busy=%b 書き込み %0d 画素",
             cyc, all_done, busy, nwe);

    // ★ 止まったあと、さらに回してセルが書き換わらないかを見る
    nwe_mark = nwe;
    idle = 0;
    repeat (200000) begin
      @(posedge clk);
      idle = idle + 1;
    end
    $display("DRAW 止まったあと %0d クロックで書き込み %0d 回 (0 なら止まっている)",
             idle, nwe - nwe_mark);
    if (nwe != nwe_mark) $display("DRAW ★ 描き続けている");

    fd = $fopen("seq_out.txt", "w");
    for (i = 0; i < CELL*CELL; i = i + 1)
      if (cmem[i] != 16'h0000) $fwrite(fd, "%0d %04x\n", i, cmem[i]);
    $fclose(fd);
    fd = $fopen("seq_outf.txt", "w");
    for (i = 0; i < CELL*CELL; i = i + 1)
      if (cmemf[i] != 32'h00000000) $fwrite(fd, "%0d %08x\n", i, cmemf[i]);
    $fclose(fd);
    $display("DRAW seq_out.txt / seq_outf.txt を書いた");
    $finish;
  end

  initial begin
    #400000000;
    $display("DRAW 時間切れ");
    $finish;
  end

endmodule
