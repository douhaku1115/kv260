// ============================================================
//  tb_dbuf — 二重バッファで 2 回描き直す (段5d-7)
//
//  pdriver + pshade_seq + cell_dbuf (本物の cell_uram) を繋ぐ。
//  表は焼き込み (pparts.hex) ではなく、書き込み口から入れる。
//
//    1. 表 1 (tbl1.hex) を書く → 描き直し → 入れ替えを待つ → 映す面を書き出す
//    2. 表 2 (tbl2.hex) を書く → 描き直し → 入れ替えを待つ → 映す面を書き出す
//
//  見るもの:
//    ・描き直しを頼むまで描かない
//    ・★ 映している面には 1 回も書き込まない (描きかけが画面に出ない)
//    ・入れ替えはフレーム先頭でだけ起きる
//    ・映す面の中身 (dbuf1_*.txt / dbuf2_*.txt を tools/tb_dbuf_check.py が採点)
//    ・1 回の描き直しのクロック数
//
//  フレーム先頭は実機 (1650 x 750 = 1,237,500 クロック) より短い
//  300,000 クロックごとに出す。描画 (約 84 万クロック) の途中に何度も来るので、
//  「描き終える前に入れ替えない」ことも同時に確かめられる。
// ============================================================
`timescale 1ns / 1ps

module tb_dbuf;

  localparam W = 24;
  localparam AB = 16;
  localparam CELL = 256;
  localparam FRAME = 300000;

  reg clk = 1'b0;
  always #5 clk = ~clk;
  // 表の書き込み口のクロック (実機の AXI クロック)。段6b から映像クロックとは別。
  // わざと周期をずらして、2 つのクロックで動く RAM を確かめる
  reg wclk = 1'b0;
  always #3.7 wclk = ~wclk;
  reg resetn = 1'b0;
  reg draw_req = 1'b0;

  // ---- フレーム先頭 ----
  integer fcnt = 0;
  reg frame_start = 1'b0;
  always @(posedge clk) begin
    fcnt        <= (fcnt == FRAME - 1) ? 0 : fcnt + 1;
    frame_start <= (fcnt == FRAME - 1);
  end

  // ---- 表の書き込み口 ----
  reg         t_we = 1'b0;
  reg [15:0]  t_addr = 16'd0;
  reg [W-1:0] t_data = {W{1'b0}};
  reg [15:0]  n_words = 16'd0;

  // ---- pdriver → pshade_seq ----
  wire        p_valid, p_take, p_premul, p_front, all_done;
  wire [3:0]  p_type;
  wire [8:0]  p_bw;
  wire [17:0] p_npix;
  wire [7:0]  p_x0, p_y0, p_cr, p_cg, p_cb;
  wire signed [W-1:0] p_vqx0, p_vqy0, p_qx0, p_qy0;
  wire signed [W-1:0] p_sx_vqx, p_sy_vqy, p_sx_qx, p_sy_qx, p_sx_qy, p_sy_qy;
  wire signed [W-1:0] p_seed, p_e, p_rot, p_time, p_depth;
  wire        drv_start;

  pdriver drv
    (.clk(clk), .resetn(resetn), .p_take(p_take), .draw_req(drv_start),
     .wclk(wclk), .t_we(t_we), .t_addr(t_addr), .t_data(t_data), .n_words(n_words),
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
  wire [15:0] rd_back;
  wire [31:0] rd_front;

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
     .cell_rdata_back(rd_back), .cell_rdata_front(rd_front),
     .cell_raddr(cell_raddr));

  wire dbusy, show_buf;
  wire [15:0] back_d;
  wire [31:0] front_d, shadow_d;

  cell_dbuf #(.AW(AB), .OIL_FILE("cell_oil.hex")) cells
    (.clk(clk), .reset(!resetn),
     .back_addr(16'd0), .front_addr(16'd0), .shadow_addr(16'd0),
     .back_d(back_d), .front_d(front_d), .shadow_d(shadow_d),
     .d_we_back(cell_we && !cell_front), .d_we_front(cell_we && cell_front),
     .d_waddr(cell_addr), .d_raddr(cell_raddr), .d_wdata(cell_wdata),
     .d_rdata_back(rd_back), .d_rdata_front(rd_front),
     .draw_req(draw_req), .frame_start(frame_start),
     .draw_idle(all_done && !busy),
     .drv_start(drv_start), .busy(dbusy), .show_buf(show_buf));

  // ---- ★ 映している面への書き込みを数える (0 でなければならない) ----
  integer bad_we = 0, swaps = 0, bad_swap = 0;
  reg show_prev = 1'b0;
  always @(posedge clk) begin
    if (( show_buf && (cells.back1_i.b_we || cells.front1_i.b_we)) ||
        (!show_buf && (cells.back0_i.b_we || cells.front0_i.b_we)))
      bad_we = bad_we + 1;
    show_prev <= show_buf;
    if (show_buf != show_prev) begin
      swaps = swaps + 1;
      // 入れ替えはフレーム先頭の次の拍にだけ見える
      if (fcnt != 1) bad_swap = bad_swap + 1;
    end
  end

  // ---- 表を書き込み口から入れる ----
  reg [W-1:0] tbl [0:65535];
  integer nw;
  task load_table(input [8*16-1:0] fname);
    integer k;
    begin
      for (k = 0; k < 65536; k = k + 1) tbl[k] = {W{1'b0}};
      $readmemh(fname, tbl);
      nw = tbl[0] * 24;                 // 1 行目は個数
      for (k = 0; k < nw; k = k + 1) begin
        @(negedge wclk);
        t_we = 1'b1; t_addr = k; t_data = tbl[k + 1];
      end
      @(negedge wclk);
      t_we = 1'b0;
      n_words = nw;
      $display("DBUF 表を書いた %0s : %0d 個 (%0d 語)", fname, nw / 24, nw);
    end
  endtask

  // ---- 映している面を書き出す ----
  task dump(input [8*16-1:0] fb, input [8*16-1:0] ff);
    integer fd, i;
    reg [15:0] vb;
    reg [31:0] vf;
    begin
      fd = $fopen(fb, "w");
      for (i = 0; i < CELL*CELL; i = i + 1) begin
        vb = show_buf ? cells.back1_i.mem[i] : cells.back0_i.mem[i];
        $fwrite(fd, "%0d %04x\n", i, vb);
      end
      $fclose(fd);
      fd = $fopen(ff, "w");
      for (i = 0; i < CELL*CELL; i = i + 1) begin
        vf = show_buf ? cells.front1_i.mem[i] : cells.front0_i.mem[i];
        if (vf != 32'h00000000) $fwrite(fd, "%0d %08x\n", i, vf);
      end
      $fclose(fd);
      $display("DBUF 映す面 (面 %0d) を %0s / %0s に書いた", show_buf, fb, ff);
    end
  endtask

  // ---- 描き直し 1 回 ----
  integer cyc, t_clear;
  task redraw;
    begin
      @(negedge clk); draw_req = 1'b1;
      @(negedge clk); draw_req = 1'b0;
      cyc = 0; t_clear = 0;
      while (dbusy && cyc < 20000000) begin
        @(posedge clk);
        cyc = cyc + 1;
        if (t_clear == 0 && drv_start) t_clear = cyc;
      end
      $display("DBUF 描き直し %0d クロック (地の復元 %0d、入れ替え待ちを含む) 面 %0d を映す",
               cyc, t_clear, show_buf);
    end
  endtask

  initial begin
    repeat (8) @(negedge clk);
    resetn = 1'b1;

    load_table("tbl1.hex");
    repeat (20000) @(posedge clk);
    if (seq.cell_we !== 1'b0 || dbusy) $display("DBUF ★ 頼む前に動いている");
    else $display("DBUF 頼むまで描かない (20000 クロック待った)");

    redraw;
    dump("dbuf1_b.txt", "dbuf1_f.txt");

    load_table("tbl2.hex");
    redraw;
    dump("dbuf2_b.txt", "dbuf2_f.txt");

    // 入れ替えの監視は 1 クロック遅れて数えるので、少し回してから集計する
    repeat (4) @(posedge clk);
    $display("DBUF 映す面への書き込み %0d 回 (0 であること)", bad_we);
    $display("DBUF 入れ替え %0d 回 (2 であること)、フレーム先頭以外での入れ替え %0d 回",
             swaps, bad_swap);
    $finish;
  end

  initial begin
    #400000000;
    $display("DBUF 時間切れ");
    $finish;
  end

endmodule
