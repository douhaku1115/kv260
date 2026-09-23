// ============================================================
//  tb_lane — 演算器 1 レーンに 9 種のプログラムを流して結果を吐く
//
//  テストベンチが並び替え器の代わりをする。
//    1. レジスタ r0..r8 (qx qy vqx vqy seed z e rot time) に
//       lane_in.hex の値を WARP 画素ぶん入れる
//    2. pprog.hex の命令を 1 つずつ、WARP 画素ぶん続けて発行する
//    3. r29(A) r30(K) r31(W) への書き戻しを覗いて lane_out.txt に書く
//
//  Python 側 (tools/tb_lane_check.py) が同じ入力で同じ計算をして突き合わせる。
//  固定小数点と CORDIC・表引きの誤差がここで実測できる。
// ============================================================
`timescale 1ns / 1ps

module tb_lane;

  localparam W     = 24;
  localparam WARP  = 24;
  localparam LAT   = 22;
  localparam NIN   = 9;          // 入り口のレジスタの数
  localparam MAXI  = 400;        // 命令の総数の上限

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg                 issue = 1'b0;
  reg [5:0]           op = 6'd0;
  reg [4:0]           rd = 5'd0, ra = 5'd0, rb = 5'd0, rc = 5'd0;
  reg signed [W-1:0]  imm0 = 0, imm1 = 0;
  reg [4:0]           slot = 5'd0;
  reg                 preload = 1'b0;
  reg signed [W-1:0]  pre_val = 0;
  // ピースごとの定数。lane_in.hex の該当スロットから取って渡す
  reg signed [W-1:0]  pc_seed = 0, pc_z = 0, pc_e = 0, pc_rot = 0, pc_time = 0;

  wire signed [W-1:0] out_val;
  wire                out_we;
  wire [4:0]          out_rd, out_slot;

  pshade_lane #(.W(W), .WARP(WARP), .LAT(LAT)) dut
    (.clk(clk), .issue(issue), .op(op), .rd(rd), .ra(ra), .rb(rb), .rc(rc),
     .imm0(imm0), .imm1(imm1), .slot(slot),
     .preload(preload), .pre_val(pre_val),
     .pc_seed(pc_seed), .pc_z(pc_z), .pc_e(pc_e),
     .pc_rot(pc_rot), .pc_time(pc_time),
     .out_val(out_val), .out_we(out_we), .out_rd(out_rd), .out_slot(out_slot));

  // ---- プログラムと入力 ----
  reg [63:0] prog [0:MAXI-1];
  reg [15:0] pbase [0:15];
  reg [23:0] pin [0:WARP*NIN-1];     // 画素ごとの入り口の値
  integer    n_instr;
  integer    start;

  initial begin
    $readmemh("pprog.hex", prog);
    $readmemh("pprog_base.hex", pbase);
    $readmemh("lane_in.hex", pin);
  end

  // ---- 結果を覚えておく ----
  reg signed [W-1:0] resA [0:WARP-1];
  reg signed [W-1:0] resK [0:WARP-1];
  reg signed [W-1:0] resW [0:WARP-1];

  always @(posedge clk) if (out_we) begin
    if (out_rd == 5'd29) resA[out_slot] <= out_val;
    if (out_rd == 5'd30) resK[out_slot] <= out_val;
    if (out_rd == 5'd31) resW[out_slot] <= out_val;
  end

  // ---- 1 命令を WARP 画素ぶん発行する ----
  integer s;
  task run_one;
    input [63:0] w;
    begin
      for (s = 0; s < WARP; s = s + 1) begin
        @(negedge clk);
        issue <= 1'b1;
        op    <= w[63:58];
        rd    <= w[57:53];
        ra    <= w[52:48];
        rb    <= w[28:24];        // B の下位 5bit がレジスタ番号
        imm0  <= w[47:24];
        rc    <= w[4:0];          // C の下位 5bit
        imm1  <= w[23:0];
        slot  <= s[4:0];
      end
      @(negedge clk);
      issue <= 1'b0;
    end
  endtask

  integer fd, i, j;
  integer n_start, n_len;

  // 流す命令の範囲。プラス引数は Windows のバッチで壊れるので
  // 小さなファイルで渡す (1 行目 = 開始番地、2 行目 = 命令数)
  reg [15:0] range [0:1];
  initial $readmemh("lane_range.hex", range);

  initial begin
    repeat (5) @(negedge clk);
    n_start = range[0];
    n_len   = range[1];

    // ---- 入り口のレジスタを埋める ----
    for (j = 0; j < NIN; j = j + 1)
      for (i = 0; i < WARP; i = i + 1) begin
        @(negedge clk);
        preload <= 1'b1;
        rd      <= j[4:0];
        slot    <= i[4:0];
        pre_val <= $signed(pin[j*WARP + i]);
      end
    @(negedge clk);
    preload <= 1'b0;
    // r4..r8 はピースごとの定数として渡す (どの画素でも同じ値にしてある)
    pc_seed <= $signed(pin[4*WARP]);
    pc_z    <= $signed(pin[5*WARP]);
    pc_e    <= $signed(pin[6*WARP]);
    pc_rot  <= $signed(pin[7*WARP]);
    pc_time <= $signed(pin[8*WARP]);
    @(negedge clk);

    // ---- プログラムを流す ----
    for (i = 0; i < n_len; i = i + 1)
      run_one(prog[n_start + i]);

    // ---- 全部書き戻るまで待つ ----
    repeat (LAT + 8) @(negedge clk);

    fd = $fopen("lane_out.txt", "w");
    for (i = 0; i < WARP; i = i + 1)
      $fwrite(fd, "%06x %06x %06x\n", resA[i], resK[i], resW[i]);
    $fclose(fd);
    $display("lane_out.txt に %0d 画素ぶん書いた (命令 %0d〜%0d)",
             WARP, n_start, n_start + n_len - 1);
    $finish;
  end

  initial begin
    #2000000;
    $display("時間切れ");
    $finish;
  end

endmodule
