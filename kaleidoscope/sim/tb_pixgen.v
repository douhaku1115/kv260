// ============================================================
//  tb_pixgen — 座標を作る部分 (ppixgen) を単体で試す
//
//  pixgen_in.hex から 1 つのピースの枠と増分を読み、step を叩きながら
//  レーンごとの vqx/vqy/qx/qy を pixgen_out.txt に書き出す。
//  Python 側 (tools/tb_pixgen_check.py) が同じ走査をして突き合わせる。
//  確かめたいのは主に「行をまたぐときの折り返し」が合っているか。
// ============================================================
`timescale 1ns / 1ps

module tb_pixgen;

  localparam W = 24;
  localparam LANES = 8;
  localparam CB = 9;
  localparam MAXSTEP = 4096;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg [23:0] cfg [0:15];
  initial $readmemh("pixgen_in.hex", cfg);

  reg                load = 1'b0;
  reg                step = 1'b0;
  reg [CB-1:0]       bw;
  reg [2*CB-1:0]     npix;
  reg signed [W-1:0] vqx0, vqy0, qx0, qy0;
  reg signed [W-1:0] sx_vqx, sy_vqy, sx_qx, sy_qx, sx_qy, sy_qy;

  wire [LANES-1:0]     lv;
  wire [LANES*W-1:0]   lvqx, lvqy, lqx, lqy;
  wire                 done;

  ppixgen #(.W(W), .LANES(LANES), .CB(CB)) dut
    (.clk(clk), .load(load), .bw(bw), .npix(npix),
     .vqx0(vqx0), .vqy0(vqy0), .qx0(qx0), .qy0(qy0),
     .sx_vqx(sx_vqx), .sy_vqy(sy_vqy),
     .sx_qx(sx_qx), .sy_qx(sy_qx), .sx_qy(sx_qy), .sy_qy(sy_qy),
     .step(step),
     .lane_valid(lv), .lane_vqx(lvqx), .lane_vqy(lvqy),
     .lane_qx(lqx), .lane_qy(lqy), .done(done));

  integer fd, i, k, nstep;

  initial begin
    bw     = cfg[0][CB-1:0];
    npix   = cfg[1][2*CB-1:0];
    vqx0   = $signed(cfg[2]);
    vqy0   = $signed(cfg[3]);
    qx0    = $signed(cfg[4]);
    qy0    = $signed(cfg[5]);
    sx_vqx = $signed(cfg[6]);
    sy_vqy = $signed(cfg[7]);
    sx_qx  = $signed(cfg[8]);
    sy_qx  = $signed(cfg[9]);
    sx_qy  = $signed(cfg[10]);
    sy_qy  = $signed(cfg[11]);
    nstep  = cfg[12];

    @(negedge clk);
    load <= 1'b1;
    @(negedge clk);
    load <= 1'b0;

    fd = $fopen("pixgen_out.txt", "w");
    for (i = 0; i < nstep; i = i + 1) begin
      @(posedge clk);
      #1;
      for (k = 0; k < LANES; k = k + 1)
        $fwrite(fd, "%0d %06x %06x %06x %06x\n", lv[k],
                lvqx[(k+1)*W-1 -: W], lvqy[(k+1)*W-1 -: W],
                lqx[(k+1)*W-1 -: W],  lqy[(k+1)*W-1 -: W]);
      @(negedge clk);
      step <= 1'b1;
      @(negedge clk);
      step <= 1'b0;
    end
    $fclose(fd);
    $display("pixgen_out.txt done %0d", nstep);
    $finish;
  end

endmodule
