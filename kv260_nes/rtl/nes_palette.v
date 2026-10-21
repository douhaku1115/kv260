// ============================================================
// nes_palette.v — NES の色番号 (6bit) → RGB 24bit
// ============================================================
//
// 2C02 PPU は 64 色 (うち黒が重複) を出す。実機は NTSC 信号で
// RGB を持たないので、エミュレータで広く使われている近似表を使う。
// 1 クロックで引く (レジスタ出力)。

module nes_palette (
    input  wire        clk,
    input  wire [5:0]  idx,
    output reg  [23:0] rgb
);
    always @(posedge clk) begin
        case (idx)
        6'h00: rgb <= 24'h7C7C7C; 6'h01: rgb <= 24'h0000FC; 6'h02: rgb <= 24'h0000BC; 6'h03: rgb <= 24'h4428BC;
        6'h04: rgb <= 24'h940084; 6'h05: rgb <= 24'hA80020; 6'h06: rgb <= 24'hA81000; 6'h07: rgb <= 24'h881400;
        6'h08: rgb <= 24'h503000; 6'h09: rgb <= 24'h007800; 6'h0A: rgb <= 24'h006800; 6'h0B: rgb <= 24'h005800;
        6'h0C: rgb <= 24'h004058; 6'h0D: rgb <= 24'h000000; 6'h0E: rgb <= 24'h000000; 6'h0F: rgb <= 24'h000000;
        6'h10: rgb <= 24'hBCBCBC; 6'h11: rgb <= 24'h0078F8; 6'h12: rgb <= 24'h0058F8; 6'h13: rgb <= 24'h6844FC;
        6'h14: rgb <= 24'hD800CC; 6'h15: rgb <= 24'hE40058; 6'h16: rgb <= 24'hF83800; 6'h17: rgb <= 24'hE45C10;
        6'h18: rgb <= 24'hAC7C00; 6'h19: rgb <= 24'h00B800; 6'h1A: rgb <= 24'h00A800; 6'h1B: rgb <= 24'h00A844;
        6'h1C: rgb <= 24'h008888; 6'h1D: rgb <= 24'h000000; 6'h1E: rgb <= 24'h000000; 6'h1F: rgb <= 24'h000000;
        6'h20: rgb <= 24'hF8F8F8; 6'h21: rgb <= 24'h3CBCFC; 6'h22: rgb <= 24'h6888FC; 6'h23: rgb <= 24'h9878F8;
        6'h24: rgb <= 24'hF878F8; 6'h25: rgb <= 24'hF85898; 6'h26: rgb <= 24'hF87858; 6'h27: rgb <= 24'hFCA044;
        6'h28: rgb <= 24'hF8B800; 6'h29: rgb <= 24'hB8F818; 6'h2A: rgb <= 24'h58D854; 6'h2B: rgb <= 24'h58F898;
        6'h2C: rgb <= 24'h00E8D8; 6'h2D: rgb <= 24'h787878; 6'h2E: rgb <= 24'h000000; 6'h2F: rgb <= 24'h000000;
        6'h30: rgb <= 24'hFCFCFC; 6'h31: rgb <= 24'hA4E4FC; 6'h32: rgb <= 24'hB8B8F8; 6'h33: rgb <= 24'hD8B8F8;
        6'h34: rgb <= 24'hF8B8F8; 6'h35: rgb <= 24'hF8A4C0; 6'h36: rgb <= 24'hF0D0B0; 6'h37: rgb <= 24'hFCE0A8;
        6'h38: rgb <= 24'hF8D878; 6'h39: rgb <= 24'hD8F878; 6'h3A: rgb <= 24'hB8F8B8; 6'h3B: rgb <= 24'hB8F8D8;
        6'h3C: rgb <= 24'h00FCFC; 6'h3D: rgb <= 24'hF8D8F8; 6'h3E: rgb <= 24'h000000; 6'h3F: rgb <= 24'h000000;
        endcase
    end
endmodule
