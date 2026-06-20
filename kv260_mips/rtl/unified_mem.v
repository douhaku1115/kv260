// ============================================================
// unified_mem.v — 統一メモリ (von Neumann, OS-prep1)
// ============================================================
//
// 【目的】
//   従来は imem(命令)/dmem(データ)が別空間(Harvard)だったが、OS を載せる
//   ため命令とデータを単一メモリ空間に統合する(von Neumann)。これにより
//   lw/sw でコード領域も読み書きでき、PC フェッチも同じ空間から行える。
//   = メモリ上に置いたコード(タスク)をロードして実行できる。
//
// 【容量】
//   2^AW ワード x 4バイト。AW=12 → 4096ワード = 16KB。
//   統一アドレス空間 0x0000〜0x3FFF。命令・データ・スタックを共有する。
//
// 【ポート構成】(非同期読み = 分散RAM。書きは同期)
//   - IF読みポート  : if_addr(PC) → if_instr   命令フェッチ(MIPS実行中)
//   - MEM読み書き   : mem_addr → mem_rdata(lw), byte_en で書込み(sw)
//   - PS ロードポート: ps_we のとき ps_waddr ← ps_wdata (ワード単位)
//
// 【書込みの調停】
//   PS ロード(ps_we) を最優先。それ以外は sw の byte_en で書込み。
//   PS ロードは MIPS halt 中に行い、sw は実行中に行うため両者は排他。
//
// 【アドレス変換】
//   MIPS の PC/アドレスはバイト単位。addr[AW+1:2] でワードに変換。

module unified_mem #(
    parameter AW = 12                 // ワードアドレス幅 (2^12=4096ワード=16KB)
)(
    // IF 読みポート (非同期, 命令フェッチ)
    input  [31:0] if_addr,            // PC (バイトアドレス)
    output [31:0] if_instr,           // フェッチした命令

    // MEM 読み書きポート (lw 非同期読み / sw 同期書き, byte enable)
    input         clk,
    input  [3:0]  byte_en,            // sw のバイトイネーブル
    input  [31:0] mem_addr,           // lw/sw のアドレス (バイト)
    input  [31:0] mem_wdata,          // sw の書込みデータ (バイト複製済み)
    output [31:0] mem_rdata,          // lw の読出しデータ (ワード)

    // PS ロードポート (ワード単位書込み, MIPS halt 中に PS が使う)
    input         ps_we,
    input  [AW-1:0] ps_waddr,         // ワードアドレス
    input  [31:0] ps_wdata
);

    reg [31:0] mem [0:(1<<AW)-1];

    // --- 読み出し (非同期) ---
    assign if_instr  = mem[if_addr[AW+1:2]];
    assign mem_rdata = mem[mem_addr[AW+1:2]];

    // --- 書き込み (同期): PS ロード優先、次に sw の byte enable ---
    always @(posedge clk) begin
        if (ps_we) begin
            mem[ps_waddr] <= ps_wdata;            // PS ロード (ワード)
        end else begin
            if (byte_en[3]) mem[mem_addr[AW+1:2]][31:24] <= mem_wdata[31:24]; // offset 0 (MSB)
            if (byte_en[2]) mem[mem_addr[AW+1:2]][23:16] <= mem_wdata[23:16]; // offset 1
            if (byte_en[1]) mem[mem_addr[AW+1:2]][15: 8] <= mem_wdata[15: 8]; // offset 2
            if (byte_en[0]) mem[mem_addr[AW+1:2]][ 7: 0] <= mem_wdata[ 7: 0]; // offset 3 (LSB)
        end
    end

endmodule
