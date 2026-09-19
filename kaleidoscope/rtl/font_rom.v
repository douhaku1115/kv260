// ============================================================
//  font_rom — 8x16 ピクセルの ASCII フォント
//
//  ASCII 0x20〜0x7E の 95 文字。字形は tools/gen_font.py が
//  Windows の等幅フォント (Consolas) から起こして font_rom.hex に出す。
//  手で打ち込まないので字形の間違いが起きない。
//
//  アドレス = (ch - 0x20) * 16 + row
//  出力は 8 ピクセル。MSB が左端。1 = 文字、0 = 背景。
//  範囲外の文字は空白を返す。
//
//  読み出し遅延 1 クロック。
// ============================================================

module font_rom
  #(
    parameter INIT_FILE = "font_rom.hex"
    )
  (
   input wire       clk,
   input wire [7:0] ch,
   input wire [3:0] row,
   output reg [7:0] pixels
   );

  localparam FIRST = 8'h20;
  localparam LAST  = 8'h7E;
  localparam N     = (LAST - FIRST + 1) * 16;   // 95 * 16 = 1520

  (* rom_style = "block" *)
  reg [7:0] rom [0:N-1];
  initial $readmemh(INIT_FILE, rom);

  wire in_range = (ch >= FIRST) && (ch <= LAST);
  wire [10:0] addr = ((ch - FIRST) << 4) + row;

  always @(posedge clk)
    pixels <= in_range ? rom[addr] : 8'h00;

endmodule
