// ============================================================
//  tb_trans — 表引き (ptrans) を単体で試す
//
//  trans_in.hex から 1 行 4 語 (命令, x, a, b) を読み、順に流して
//  結果を trans_out.txt に書く。Python 側と突き合わせて
//  RECIP / SQRT / POW / EXPN / SSTEP のどれが合わないかを切り分ける。
// ============================================================
`timescale 1ns / 1ps

module tb_trans;

  localparam W = 24;
  localparam N = 256;          // 試す数の上限
  localparam LAT = 40;

  reg clk = 1'b0;
  always #5 clk = ~clk;

  reg [23:0] mem [0:N*4-1];
  integer    ncase;
  initial $readmemh("trans_in.hex", mem);

  reg               vin = 1'b0;
  reg [2:0]         op = 3'd0;
  reg signed [W-1:0] ax = 0, ab = 0, ac = 0;

  wire               vout;
  wire signed [W-1:0] res;

  ptrans #(.W(W), .FRAC(17)) dut
    (.clk(clk), .vin(vin), .op(op), .ax(ax), .ab(ab), .ac(ac),
     .vout(vout), .res(res));

  integer fd, i, got;
  reg signed [W-1:0] out [0:N-1];

  always @(posedge clk) if (vout) begin
    out[got] = res;
    got = got + 1;
  end

  initial begin
    got = 0;
    ncase = mem[0];            // 0 行目に件数を入れておく
    repeat (4) @(negedge clk);
    for (i = 0; i < ncase; i = i + 1) begin
      @(negedge clk);
      vin <= 1'b1;
      op  <= mem[4 + i*4 + 0][2:0];
      ax  <= $signed(mem[4 + i*4 + 1]);
      ab  <= $signed(mem[4 + i*4 + 2]);
      ac  <= $signed(mem[4 + i*4 + 3]);
    end
    @(negedge clk);
    vin <= 1'b0;
    repeat (LAT) @(negedge clk);

    fd = $fopen("trans_out.txt", "w");
    for (i = 0; i < ncase; i = i + 1) $fwrite(fd, "%06x\n", out[i]);
    $fclose(fd);
    $display("trans_out.txt done %0d", got);
    $finish;
  end

endmodule
