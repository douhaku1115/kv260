// ============================================================
// nes_fb.v — NES 画面バッファ 256x240 (1 画素 = 6bit の色番号)
// ============================================================
//
// 横に並んだ 4 画素を 1 語にまとめ、語番号 = y*64 + x/4 (0〜15359)。
// 画素ごとに別の RAM (バンク 0〜3 = x%4) にして、
//   - 書込は 4 画素まとめて (AXI) でも 1 画素だけ (PPU、段D) でも書ける
//   - 読出は 1 語 = 4 画素を同時に出す
// 書込は clk、読出は clkv (映像クロック) の 2 クロック RAM。
//
// rdata の並び: [5:0]=x%4==0, [11:6]=1, [17:12]=2, [23:18]=3

module nes_fb (
    input  wire        clk,
    input  wire        we,
    input  wire [3:0]  wmask,      // bit i = バンク i に書く
    input  wire [13:0] waddr,
    input  wire [23:0] wdata,
    input  wire        clkv,
    input  wire [13:0] raddr,
    output wire [23:0] rdata
);
    genvar b;
    generate
        for (b = 0; b < 4; b = b + 1) begin : bank
            (* ram_style = "block" *) reg [5:0] mem [0:15359];
            reg [5:0] q;
            always @(posedge clk)
                if (we && wmask[b]) mem[waddr] <= wdata[b*6 +: 6];
            always @(posedge clkv)
                q <= mem[raddr];
            assign rdata[b*6 +: 6] = q;
        end
    endgenerate
endmodule
