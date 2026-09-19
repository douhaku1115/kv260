// ============================================================
//  tb_scope — rtl_top を 1 フレーム回して、映像を frame.txt に吐く
//
//  clk と clkv は同じクロックで駆動する (CDC の検証が目的ではない)。
//  AXI は叩かない。kaleido_axi_slave の初期値 (ポイント数8・3枚鏡・回転なし)
//  がそのまま使われる。
//  video_de が立っている間の色を 1 行 1 画素の 6 桁 16 進で書き出し、
//  tools/txt2png.py で PNG にして目で見る。
// ============================================================
`timescale 1ns / 1ps

module tb_scope;

  localparam W = 1280;
  localparam H = 720;

  reg clk = 1'b0;
  reg resetn = 1'b0;

  always #5 clk = ~clk;      // 100MHz 相当 (シミュレーションなので値は何でもよい)

  wire        video_de, video_hsyncn, video_vsyncn;
  wire [35:0] video_color;
  wire        frame_start;

  // ---- パラメータ (AXI スレーブの初期値を使う) ----
  wire signed [17:0] p_kx, p_z_mirror, p_inv_tr, p_cos_t, p_sin_t;
  wire [19:0]        p_remain0;
  wire signed [17:0] p_nx0, p_ny0, p_wd0, p_nx1, p_ny1, p_wd1, p_nx2, p_ny2, p_wd2;
  wire signed [17:0] p_vx0, p_vy0, p_vx1, p_vy1, p_vx2, p_vy2;
  wire               p_mirror2, p_text_on;
  wire [10:0]        text_addr;
  wire [7:0]         text_ch;

  kaleido_axi_slave axi_i
    (.S_AXI_ACLK(clk), .S_AXI_ARESETN(resetn),
     .S_AXI_AWADDR(11'd0), .S_AXI_AWPROT(3'd0), .S_AXI_AWVALID(1'b0), .S_AXI_AWREADY(),
     .S_AXI_WDATA(32'd0), .S_AXI_WSTRB(4'd0), .S_AXI_WVALID(1'b0), .S_AXI_WREADY(),
     .S_AXI_BRESP(), .S_AXI_BVALID(), .S_AXI_BREADY(1'b0),
     .S_AXI_ARADDR(11'd0), .S_AXI_ARPROT(3'd0), .S_AXI_ARVALID(1'b0), .S_AXI_ARREADY(),
     .S_AXI_RDATA(), .S_AXI_RRESP(), .S_AXI_RVALID(), .S_AXI_RREADY(1'b0),
     .clkv(clk), .frame_start(frame_start),
     .v_kx(p_kx), .v_z_mirror(p_z_mirror), .v_remain0(p_remain0), .v_inv_tr(p_inv_tr),
     .v_cos_t(p_cos_t), .v_sin_t(p_sin_t),
     .v_nx0(p_nx0), .v_ny0(p_ny0), .v_wd0(p_wd0),
     .v_nx1(p_nx1), .v_ny1(p_ny1), .v_wd1(p_wd1),
     .v_nx2(p_nx2), .v_ny2(p_ny2), .v_wd2(p_wd2),
     .v_vx0(p_vx0), .v_vy0(p_vy0),
     .v_vx1(p_vx1), .v_vy1(p_vy1),
     .v_vx2(p_vx2), .v_vy2(p_vy2),
     .v_mirror2(p_mirror2), .v_text_on(p_text_on),
     .text_addr(text_addr), .text_ch(text_ch));

  rtl_top dut
    (.clk(clk), .clkv(clk), .resetn(resetn),
     .p_kx(p_kx), .p_z_mirror(p_z_mirror), .p_remain0(p_remain0), .p_inv_tr(p_inv_tr),
     .p_cos_t(p_cos_t), .p_sin_t(p_sin_t),
     .p_nx0(p_nx0), .p_ny0(p_ny0), .p_wd0(p_wd0),
     .p_nx1(p_nx1), .p_ny1(p_ny1), .p_wd1(p_wd1),
     .p_nx2(p_nx2), .p_ny2(p_ny2), .p_wd2(p_wd2),
     .p_vx0(p_vx0), .p_vy0(p_vy0),
     .p_vx1(p_vx1), .p_vy1(p_vy1),
     .p_vx2(p_vx2), .p_vy2(p_vy2),
     .p_mirror2(p_mirror2), .p_text_on(p_text_on),
     .text_addr(text_addr), .text_ch(text_ch),
     .frame_start(frame_start),
     .video_de(video_de),
     .video_hsyncn(video_hsyncn),
     .video_vsyncn(video_vsyncn),
     .video_color(video_color));

  // ---- 画面に出す文字を、テストベンチから直接書き込む ----
  //   実機では PS が AXI で書く。ここでは中の RAM に直接入れて
  //   オーバーレイが正しい位置・大きさで出るかを絵で確かめる。
  task put_line;
    input integer row;
    input [8*32-1:0] str;        // 32 文字ぴったりで渡す
    integer i;
    begin
      for (i = 0; i < 32; i = i + 1)
        axi_i.text_ram[row*32 + i] = str[8*(31-i) +: 8];
    end
  endtask

  integer ti;
  initial begin
    #1;
    for (ti = 0; ti < 256; ti = ti + 1) axi_i.text_ram[ti] = 8'h20;
    put_line(0, "      KALEIDOSCOPE              ");
    put_line(1, "                                ");
    put_line(2, "  Q W   POINTS         8        ");
    put_line(3, "  M     MIRROR         3        ");
    put_line(4, "  A S   ZOOM         100        ");
    put_line(5, "  Z X   SPIN          35        ");
    put_line(6, "  0     RESET                   ");
    put_line(7, "  I     HIDE                    ");
    axi_i.regs[0] = 20'd2;                        // CTRL bit1 = 文字を出す
    #200 axi_i.commit_tgl = ~axi_i.commit_tgl;    // 映像側へ取り込ませる
  end

  wire [7:0] px_b = video_color[35:28];
  wire [7:0] px_r = video_color[23:16];
  wire [7:0] px_g = video_color[11:4];

  integer fd;
  integer count = 0;

  initial begin
    fd = $fopen("frame.txt", "w");
    if (fd == 0) begin
      $display("frame.txt を開けない");
      $finish;
    end
    repeat (20) @(posedge clk);
    resetn = 1'b1;
  end

  // 1 フレーム目はリセット直後でパイプラインに前の値が残るので捨て、次を採る
  //   video_vsyncn は垂直同期の間だけ 1 になる。その立ち上がりを数える。
  reg vs_d = 1'b0;
  integer vsync_count = 0;

  always @(posedge clk) begin
    vs_d <= video_vsyncn;
    if (!vs_d && video_vsyncn) vsync_count <= vsync_count + 1;

    if (resetn && vsync_count >= 1 && video_de && count < W*H) begin
      $fwrite(fd, "%02x%02x%02x\n", px_r, px_g, px_b);
      count <= count + 1;
      if (count == W*H - 1) begin
        $display("1 フレーム書き出し完了 (%0d 画素)", W*H);
        $fclose(fd);
        $finish;
      end
    end
  end

  // 保険: 長すぎたら止める
  initial begin
    #60000000;
    $display("時間切れ  count=%0d", count);
    $fclose(fd);
    $finish;
  end

endmodule
