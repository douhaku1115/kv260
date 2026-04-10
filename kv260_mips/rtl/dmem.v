// データメモリ (256ワード x 32bit RAM)
//
// lw/sw 命令で使用するデータ用メモリ
// - 読み出し: 組み合わせ (非同期) — 単一サイクル設計のため
// - 書き込み: クロック立ち上がりで mem_write=1 のとき実行
// - アドレスはバイト単位で入力し、ワード単位 (addr[9:2]) に変換

module dmem (
    input         clk,
    input         mem_write,
    input  [31:0] addr,
    input  [31:0] write_data,
    output [31:0] read_data
);

    reg [31:0] mem [0:255];

    assign read_data = mem[addr[9:2]];

    always @(posedge clk) begin
        if (mem_write)
            mem[addr[9:2]] <= write_data;
    end

endmodule
