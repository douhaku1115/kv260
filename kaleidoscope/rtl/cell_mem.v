// ============================================================
//  cell_mem — セル画像 (筒の中のオイルとピース) を置くメモリ
//
//  読み出し口が2つある。
//    口A: 本来のサンプル位置
//    口B: 影用に少しずらした位置 (手前層でだけ使う)
//  BRAM はもともと2ポートあるので、これで追加のメモリは要らない。
//
//  段5a: 参照実装から取り出した静止画を $readmemh で焼き込む (BRAM)。
//        奥層   DATA_W=16  RGB565
//        手前層 DATA_W=32  {ablur[7:0], a[7:0], rgb565[15:0]}
//  段5c: ここを PL のラスタライザが書き込む URAM に差し替える。
//        URAM は初期値を持てないので、静止画のうちは BRAM で使う。
//
//  読み出し遅延 2 クロック (アドレス登録 + 出力登録)。
// ============================================================

module cell_mem
  #(
    parameter CELL_BITS = 8,
    parameter DATA_W    = 16,
    parameter INIT_FILE = "cell_init.hex"
    )
  (
   input wire                  clk,

   // 口A: 本来のサンプル位置
   input wire [CELL_BITS-1:0]  ix,
   input wire [CELL_BITS-1:0]  iy,
   output wire [DATA_W-1:0]    data,

   // 口B: 影用にずらした位置 (使わないなら ix2/iy2 を 0 に繋いでよい)
   input wire [CELL_BITS-1:0]  ix2,
   input wire [CELL_BITS-1:0]  iy2,
   output wire [DATA_W-1:0]    data2
   );

  (* ram_style = "block" *)
  reg [DATA_W-1:0] mem [0:(1<<(2*CELL_BITS))-1];

  initial $readmemh(INIT_FILE, mem);

  reg [DATA_W-1:0] a0, a1, b0, b1;

  always @(posedge clk) begin
    a0 <= mem[{iy,  ix}];
    a1 <= a0;
    b0 <= mem[{iy2, ix2}];
    b1 <= b0;
  end

  assign data  = a1;
  assign data2 = b1;

endmodule
