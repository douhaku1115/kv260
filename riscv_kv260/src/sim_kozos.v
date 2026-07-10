// KOZOS sleep デモ用シミュレーション(完了まで長め, m_proc_timer)
//   sleep を使うので idle 待ち込みで ~1万サイクル。done で結果表示。
module clk_bd_wrapper(output wire pl_clk0); assign pl_clk0=1'b0; endmodule
module vio_0(input wire clk, input wire [31:0] a, input wire [31:0] b); endmodule
module m_tb;
  reg clk=0; always #5 clk=~clk;
  wire [31:0] rslt, done;
  m_proc_timer dut (clk, rslt, done);
  integer c;
  initial begin
    for (c=0; c<40000; c=c+1) begin
      @(posedge clk);
      if (done===32'd1) begin $display("done at cycle %0d", c); c=40000; end
    end
    $display("RESULT r_rslt = %h  r_done = %0d", rslt, done);
    $finish;
  end
endmodule
