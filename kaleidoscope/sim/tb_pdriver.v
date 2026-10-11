// ============================================================
//  tb_pdriver — ピース表の読み出しを確かめる
//
//  段5d-5 で pdriver を「24 語を同時に引く」から
//  「1 語ずつ 24 クロックかけて読む」に変えた。表を 64 個から 271 個へ
//  増やしたら、同時引きのマルチプレクサで LUT が 30769 個増えて
//  配置できなくなったため。
//
//  ここでは **表の中身がそのまま出てくるか**だけを見る。
//  pparts.hex を読み、1 個ずつ取り込んで 24 語を seq_drv.txt に吐く。
//  tools/tb_pdriver_check.py が gen_pparts.py の出力と突き合わせる。
// ============================================================
`timescale 1ns / 1ps

module tb_pdriver;

  localparam W = 24;
  localparam WORDS = 24;
  localparam NPIECE = 271;

  reg clk = 1'b0;
  always #5 clk = ~clk;
  reg resetn = 1'b0;

  reg  p_take = 1'b0;
  wire p_valid, p_premul, p_front, all_done;
  wire [3:0]  p_type;
  wire [8:0]  p_bw;
  wire [17:0] p_npix;
  wire [7:0]  p_x0, p_y0, p_cr, p_cg, p_cb;
  wire signed [W-1:0] p_vqx0, p_vqy0, p_qx0, p_qy0;
  wire signed [W-1:0] p_sx_vqx, p_sy_vqy, p_sx_qx, p_sy_qx, p_sx_qy, p_sy_qy;
  wire signed [W-1:0] p_seed, p_e, p_rot, p_time, p_depth;

  pdriver #(.NPIECE(NPIECE)) dut
    (.clk(clk), .resetn(resetn), .p_take(p_take),
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

  integer fd, n, cyc;

  initial begin
    fd = $fopen("seq_drv.txt", "w");
    repeat (8) @(negedge clk);
    resetn = 1'b1;

    n = 0;
    cyc = 0;
    while (n < NPIECE && cyc < 200000) begin
      @(posedge clk);
      cyc = cyc + 1;
      if (p_valid && !p_take) begin
        // 24 語をそのまま吐く (gen_pparts.py の並びと同じ)
        $fwrite(fd, "%0d %06x %06x %06x %06x %06x", n,
                {20'd0, p_type}, {15'd0, p_bw}, {6'd0, p_npix},
                {16'd0, p_x0}, {16'd0, p_y0});
        $fwrite(fd, " %06x %06x %06x %06x",
                p_vqx0, p_vqy0, p_qx0, p_qy0);
        $fwrite(fd, " %06x %06x %06x %06x %06x %06x",
                p_sx_vqx, p_sy_vqy, p_sx_qx, p_sy_qx, p_sx_qy, p_sy_qy);
        $fwrite(fd, " %06x %06x %06x %06x",
                p_seed, p_e, p_rot, p_time);
        $fwrite(fd, " %06x %06x %06x %06x %06x\n",
                {16'd0, p_cr}, {16'd0, p_cg}, {16'd0, p_cb},
                p_depth, {22'd0, p_front, p_premul});
        p_take <= 1'b1;
        n = n + 1;
      end else begin
        p_take <= 1'b0;
      end
    end
    $fclose(fd);
    // ★ 最後の p_take を上書きしないこと。
    //   ループを抜けた直後に p_take <= 0 と書くと、最後の 1 個の取り込みが
    //   無かったことになり、idx が 1 つ足りないまま all_done が立たない
    @(posedge clk);
    p_take <= 1'b0;
    repeat (40) @(posedge clk);
    $display("PDRV %0d 個  %0d クロック  all_done=%b p_valid=%b",
             n, cyc, all_done, p_valid);
    if (n < NPIECE) $display("PDRV ★ 途中で止まった");
    if (!all_done)  $display("PDRV ★ all_done が立たない (描き続ける)");
    $finish;
  end

  initial begin
    #4000000;
    $display("PDRV 時間切れ");
    $finish;
  end

endmodule
