// iverilog 検証用テストベンチ (Xilinx IP はスタブ)
module clk_bd_wrapper(output wire pl_clk0); assign pl_clk0 = 1'b0; endmodule
module vio_0(input wire clk, input wire [31:0] a, b, c); endmodule

module m_tb;
  reg w_clk = 0;
  always #5 w_clk = ~w_clk;
  wire [31:0] w_rslt, w_miss, w_brn;
  m_proc9 dut (w_clk, w_rslt, w_miss, w_brn);
  initial begin
    repeat (6000) @(posedge w_clk);   // Σ/ネストループ どちらも完走する長さ
    $display("RESULT = %0d (0x%h)", w_rslt, w_rslt);
    $display("MISS   = %0d", w_miss);
    $display("BRANCH = %0d", w_brn);
    $finish;
  end
endmodule
