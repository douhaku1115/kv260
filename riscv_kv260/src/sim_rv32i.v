// 第3段 完全RV32I + gccフロー シミュレーション
//   asm_gcc.txt(gcc生成のΣ0..100)を命令メモリに焼いて実行。
//   期待: r_rslt = 0x000013ba (=5050) / r_done = 1
module clk_bd_wrapper(output wire pl_clk0); assign pl_clk0=1'b0; endmodule
module vio_0(input wire clk, input wire [31:0] a, input wire [31:0] b); endmodule
module m_tb;
  reg clk=0; always #5 clk=~clk;
  wire [31:0] rslt, done;
  m_proc_rv32i dut (clk, rslt, done);
  integer c;
  initial begin
    for (c=0; c<1000; c=c+1) begin
      @(posedge clk);
      if (done===32'd1) begin
        $display("done at cycle %0d", c);
        c = 1000; // ループ終了
      end
    end
    $display("");
    $display("RESULT r_rslt = %h (expect 000013ba = 5050)", rslt);
    $display("RESULT r_done = %0d", done);
    if (rslt===32'h000013ba && done===32'd1)
      $display("*** PASS: gcc RV32I program ran, sum(0..100)=5050 ***");
    else
      $display("*** FAIL ***");
    $finish;
  end
endmodule
