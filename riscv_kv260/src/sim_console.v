// UARTコンソール検証: RX線に "sum\r" を流し込み、TX線をデコードして応答を表示。
//   -DUARTDIV=8 でコンパイルする(1bit=8サイクル)。
module clk_bd_wrapper(output wire pl_clk0); assign pl_clk0=1'b0; endmodule
module vio_0(input wire clk, input wire [31:0] a, input wire [31:0] b); endmodule
module m_tb;
  reg clk=0; always #5 clk=~clk;
  wire [31:0] rslt, done;
  reg  rx=1;                 // アイドルHigh
  wire tx;
  m_proc_console dut (clk, rslt, done, tx, rx);
  localparam D=8;            // UARTDIV(sim)

  // --- RX 送信タスク(8N1, LSB first) ---
  task send_byte(input [7:0] b); integer i; begin
    rx=0; repeat(D) @(posedge clk);                  // start
    for(i=0;i<8;i=i+1) begin rx=b[i]; repeat(D) @(posedge clk); end
    rx=1; repeat(D*2) @(posedge clk);                // stop + 余白
  end endtask

  // --- TX デコーダ(サンプルして文字を集める) ---
  reg txd=1; integer st=0,dc=0,bc=0; reg [7:0] by;
  always @(posedge clk) begin
    txd<=tx;
    case(st)
      0: if(txd==1 && tx==0) begin st<=1; dc<=D+D/2-1; bc<=0; end
      1: if(dc==0) begin by[bc]<=tx; if(bc==7) st<=2; else begin bc<=bc+1; dc<=D-1; end end
         else dc<=dc-1;
      2: begin
           $write("%c", (by>=32 && by<127) ? by : (by==13?" ":(by==10?10:8'h2e)));
           st<=0;
         end
    endcase
  end

  integer k;
  initial begin
    $write("TX> ");
    rx=1; repeat(1500) @(posedge clk);     // 起動+最初のプロンプト出力を待つ
    send_byte("s"); send_byte("u"); send_byte("m"); send_byte(8'h0d);  // "sum\r"
    repeat(4000) @(posedge clk);
    $display("");
    $display("(TX出力に 5050 が含まれていれば sum コマンド成功)");
    $finish;
  end
endmodule
