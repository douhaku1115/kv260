// ============================================================
//  cell_mem — セル画像 (筒の中のオイルとピース) を置くメモリ
//
//  段2〜4: 256x256 RGB565 の静止テスト画像を $readmemh で焼き込む (BRAM)。
//  段5   : ここを PL のラスタライザが書き込む 512x512 の URAM に差し替える。
//          URAM は初期値を持てないので、静止画のうちは BRAM で使う。
//
//  読み出し遅延 2 クロック (アドレス登録 + 出力登録)。
// ============================================================

module cell_mem
  #(
    parameter CELL_BITS = 8,
    parameter INIT_FILE = "cell_init.hex"
    )
  (
   input wire                  clk,
   input wire [CELL_BITS-1:0]  ix,
   input wire [CELL_BITS-1:0]  iy,
   output wire [15:0]          rgb565
   );

  (* ram_style = "block" *)
  reg [15:0] mem [0:(1<<(2*CELL_BITS))-1];

  initial $readmemh(INIT_FILE, mem);

  reg [15:0] d0, d1;

  always @(posedge clk) begin
    d0 <= mem[{iy, ix}];
    d1 <= d0;
  end

  assign rgb565 = d1;

endmodule
