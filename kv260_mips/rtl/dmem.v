// ============================================================
// dmem.v — データメモリ (256ワード x 32bit RAM, バイトイネーブル付き)
// ============================================================
//
// 【役割】
//   lw/sw/lb/lbu/lh/lhu/sb/sh 命令で使用するデータ格納用メモリ。
//   imem (命令メモリ) とは独立したアドレス空間を持つ。
//
// 【読み書きタイミング】
//   読み出し: 組み合わせ回路 (非同期) — 単一サイクル設計のため、
//             同一クロック内で ALU 結果アドレスを受けてすぐに値を出力する
//   書き込み: クロック立ち上がりで byte_en != 0 のとき実行 (sw/sb/sh 命令)
//
// 【アドレス変換】
//   MIPS のアドレスはバイト単位。addr[9:2] でワード単位に変換する。
//   サブワードアクセス (sb/sh) は byte_en でどのバイトを更新するか制御する。
//
// 【エンディアン: ビッグエンディアン (MIPS 標準)】
//   byte_en[3]=1 → mem[addr][31:24]  (バイトアドレス offset 0, MSB)
//   byte_en[2]=1 → mem[addr][23:16]  (バイトアドレス offset 1)
//   byte_en[1]=1 → mem[addr][15: 8]  (バイトアドレス offset 2)
//   byte_en[0]=1 → mem[addr][ 7: 0]  (バイトアドレス offset 3, LSB)
//
// 【byte_en の生成】
//   datapath.v 側で mem_size と alu_result[1:0] から生成して渡す。
//   halt=1 のときは byte_en を全 0 にして書き込みを禁止する。

module dmem (
    input         clk,
    input  [3:0]  byte_en,       // バイトイネーブル (各ビットで対応バイトを書き込む)
    input  [31:0] addr,          // バイトアドレス (ALU結果 = ベース + オフセット)
    input  [31:0] write_data,    // 書き込みデータ (バイト複製済み: datapath.v で生成)
    output [31:0] read_data      // 読み出しデータ (常にワード単位; スライスは datapath.v で行う)
);

    reg [31:0] mem [0:255];

    // 読み出し: 非同期 (lw/lb/lbu/lh/lhu は同一クロック内で完結)
    assign read_data = mem[addr[9:2]];

    // 書き込み: 同期, バイトイネーブル付き (ビッグエンディアン)
    always @(posedge clk) begin
        if (byte_en[3]) mem[addr[9:2]][31:24] <= write_data[31:24]; // offset 0 (MSB)
        if (byte_en[2]) mem[addr[9:2]][23:16] <= write_data[23:16]; // offset 1
        if (byte_en[1]) mem[addr[9:2]][15: 8] <= write_data[15: 8]; // offset 2
        if (byte_en[0]) mem[addr[9:2]][ 7: 0] <= write_data[ 7: 0]; // offset 3 (LSB)
    end

endmodule
