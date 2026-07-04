// 統合コア(m_proc_rvsys: 完全RV32I + CSR/例外) シミュレーション
//   PROG(命令メモリ)を差し替えて実行し、r_rslt/r_done を表示。
//   Σ=0x13ba / CSR/例外=0x0b など、テストごとに期待値を照合。
module clk_bd_wrapper(output wire pl_clk0); assign pl_clk0=1'b0; endmodule
module vio_0(input wire clk, input wire [31:0] a, input wire [31:0] b); endmodule
module m_tb;
  reg clk=0; always #5 clk=~clk;
  wire [31:0] rslt, done;
  m_proc_rvsys dut (clk, rslt, done);
  integer c;
  initial begin
    for (c=0; c<2000; c=c+1) begin
      @(posedge clk);
      if (done===32'd1) begin $display("done at cycle %0d", c); c=2000; end
    end
    $display("RESULT r_rslt = %h  r_done = %0d", rslt, done);
    $finish;
  end
endmodule
