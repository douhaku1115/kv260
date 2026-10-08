// ============================================================
//  cell_uram — セル画像を URAM に置く版
//
//  BRAM 版 (cell_mem.v) の置き換え。BRAM が 94% まで来て二重バッファが
//  入らなくなったので、セル画像 2 枚を URAM へ移す。URAM は 0/64 で空き。
//  移すと BRAM が 86 個空く (奥層 29 + 手前層 57)。
//
//  【URAM に載せるための 2 つの決まり】どちらも実測で確かめた (2025.2)
//
//   1. 初期値を持てない
//      `$readmemh` があると
//        WARNING [Synth 8-12183] ... ignored because a non-zero INIT value
//      で BRAM に落ちる。だから中身は起動時に入れる (いまは PS が AXI で書く)。
//
//   2. 同じ口で「書きながら読む」形にできない。語の一部だけ書くのも駄目
//        WARNING [Synth 8-12186] ... ignored because invalid write mode
//      ・書きと読みは if / else で分ける
//      ・`mem[w][sel*16 +: 16] <= d` のような部分選択は、添字が定数でも駄目
//      語まるごと書けば載る (実測: 16384語x64bit → URAM 4 個、BRAM 0)。
//
//  【詰めていない】
//    72bit に 4 画素詰めれば個数は 1/4 で済むが、上の 2 番のせいで
//    1 画素だけ書くのに「読んで直して書き戻す」が要る。まずは詰めずに移す。
//      奥層 65536 語 x 16bit  → URAM 16 個
//      手前層 65536 語 x 32bit → URAM 16 個
//    (深さ 65536 = 4096 x 16 なので、幅によらず 16 個を縦に繋ぐ)
//
//  読み出し遅延 2 クロック (BRAM 版と同じ。TOTAL_LAT を変えずに差し替えられる)。
//  URAM はクロックが 1 本しかないので、口 A も口 B も clk で動く。
// ============================================================

module cell_uram
  #(
    parameter DATA_W = 16,       // 1 画素のビット数
    parameter AW     = 16        // 画素の番地のビット数 (256x256 なら 16)
    )
  (
   input  wire                clk,

   // 口A: 読み出し専用 (映像が引く)
   input  wire [AW-1:0]       a_addr,
   output wire [DATA_W-1:0]   a_dout,

   // 口B: 読み書き。同じ拍では書くか読むかのどちらか
   input  wire [AW-1:0]       b_addr,
   input  wire                b_we,
   input  wire [DATA_W-1:0]   b_din,
   output wire [DATA_W-1:0]   b_dout
   );

  (* ram_style = "ultra" *)
  reg [DATA_W-1:0] mem [0:(1<<AW)-1];

  reg [DATA_W-1:0] a_q0, a_q1, b_q0, b_q1;

  always @(posedge clk) begin
    a_q0 <= mem[a_addr];
    a_q1 <= a_q0;                      // URAM は出力段を持たせた方が速い

    if (b_we) mem[b_addr] <= b_din;
    else      b_q0 <= mem[b_addr];
    b_q1 <= b_q0;
  end

  assign a_dout = a_q1;
  assign b_dout = b_q1;

endmodule
