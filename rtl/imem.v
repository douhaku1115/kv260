// 命令メモリ (デュアルポートRAM, 256ワード x 32bit)
//
// ポートA (MIPS側): 組み合わせ読み出し。PCのバイトアドレスを
//   ワードアドレス (addr_a[9:2]) に変換して命令をフェッチする
// ポートB (PS側):   クロック同期書き込み。AXI 経由で PS(ARM) から
//   プログラムをロードする。再合成なしでプログラム変更が可能

module imem (
    // ポートA: MIPS側 (読み出し専用)
    input  [31:0] addr_a,
    output [31:0] instr,

    // ポートB: PS側 (書き込み専用)
    input         clk_b,
    input         we_b,
    input  [7:0]  addr_b,
    input  [31:0] din_b
);

    reg [31:0] mem [0:255];

    // ポートA: 組み合わせ読み出し (ワードアドレス = addr_a[9:2])
    assign instr = mem[addr_a[9:2]];

    // ポートB: クロック同期書き込み
    always @(posedge clk_b) begin
        if (we_b)
            mem[addr_b] <= din_b;
    end

endmodule
