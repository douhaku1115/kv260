// 第2段 CSR/例外 シミュレーション
//   m_proc_csr を直接駆動し、トラップ往復後の x30(=r_rslt) と r_trapcnt を確認。
//   期待: r_rslt = 0x0000000B (=11, mcause of ecall-from-M) / r_trapcnt = 1
module clk_bd_wrapper(output wire pl_clk0); assign pl_clk0=1'b0; endmodule
module vio_0(input wire clk, input wire [31:0] a, input wire [31:0] b); endmodule
module m_tb;
  reg clk=0; always #5 clk=~clk;
  wire [31:0] rslt, trapcnt;
  m_proc_csr dut (clk, rslt, trapcnt);
  integer c;
  initial begin
    for (c=0; c<120; c=c+1) begin
      @(posedge clk);
      // 内部CSR/PCを軽くトレース(先頭40サイクル)
      if (c<40)
        $display("c=%0d pc=%h P2_ir?ecall=%b mret=%b csr=%b mtvec=%h mepc=%h mcause=%h rslt=%h trap=%0d",
          c, dut.r_pc, dut.w_trap_e, dut.w_trap_r, (dut.P2_csr&dut.P2_v),
          dut.csr_mtvec, dut.csr_mepc, dut.csr_mcause, rslt, trapcnt);
    end
    $display("");
    $display("RESULT r_rslt = %h (expect 0000000b)", rslt);
    $display("RESULT r_trapcnt = %0d (expect 1)", trapcnt);
    if (rslt===32'h0000000b && trapcnt===1)
      $display("*** PASS: trap taken, handler ran, mret returned, x30=mcause=11 ***");
    else
      $display("*** FAIL ***");
    $finish;
  end
endmodule
