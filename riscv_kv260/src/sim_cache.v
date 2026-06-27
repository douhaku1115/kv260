module clk_bd_wrapper(output wire pl_clk0); assign pl_clk0 = 1'b0; endmodule
module vio_0(input wire clk, input wire [31:0] a, b, c); endmodule
module m_tb;
  reg w_clk = 0;
  always #5 w_clk = ~w_clk;
  wire [31:0] w_pc, w_ir, w_rslt, w_cyc, w_miss;
  wire w_re, w_oe;
  m_proc8_c2 u1 (w_clk, w_pc, w_ir, w_oe, w_re, w_rslt, w_cyc, w_miss);
  m_imem     u2 (w_clk, w_pc, w_re, w_ir, w_oe);
  initial begin
    repeat (20000) @(posedge w_clk);
    $display("RESULT = %0d (0x%h)", w_rslt, w_rslt);
    $display("CYCLES = %0d", w_cyc);
    $display("MISS   = %0d", w_miss);
    $finish;
  end
endmodule
