// ============================================================
// nes_core.v — NES 本体 (段C: CPU + RAM + PRG)
// ============================================================
//
// すべて clk (100MHz) で動かし、NES の時間はクロック許可 (ce) で刻む。
//   ppu_ce: 5.3693MHz (NTSC の PPU ドット = 21.477MHz / 4)。位相の積算で作る
//   cpu_ce: ppu_ce の 3 回に 1 回 (1.7898MHz)
// cpu_ce の間隔は約 56 クロックあるので、RAM は毎クロック読んでおけば間に合う。
//
// CPU から見たメモリ (段C):
//   $0000-$1FFF  内蔵 RAM 2KB (ミラー)
//   $2000-$3FFF  PPU のレジスタ (8 番地ごとにミラー)
//   $4014        OAM DMA (書き込みで 256 バイトを OAM へ)
//   $4016        コントローラ 1 (書: bit0 = 取り込み合図 / 読: 1 回に 1 ボタン、上位は $40)
//   $4017        コントローラ 2 (未接続: $40)
//   $4000-$401F  そのほかは APU (段F。いまは 0 を返す)
//   $8000-$FFFF  PRG 32KB。prg16=1 なら 16KB を折り返す (NROM-128)
//
// PS 側 (AXI) からは:
//   PRG に 1 語 = 4 バイトで書き込む (CPU が止まっている間に)
//   内蔵 RAM を 1 バイトずつ読む (結果の確認用)

module nes_core #(
    // ppu_ce の積算の刻み = (21477272.727 / 4) / 100e6 * 2^32
    parameter [31:0] PPU_STEP = 32'd230610460
)(
    input  wire        clk,
    input  wire        run,          // 0 = CPU をリセットのまま止める
    input  wire        prg16,        // 1 = PRG 16KB を折り返す
    input  wire        mirror_v,     // 1 = ネームテーブル垂直ミラー
    input  wire [7:0]  pad,          // コントローラ 1 (1 = 押下) [0]A [1]B [2]Select [3]Start [4]上 [5]下 [6]左 [7]右
    // PS から CHR へ書き込み (1 バイトずつ)
    input  wire        chr_we,
    input  wire [12:0] chr_waddr,
    input  wire [7:0]  chr_wdata,
    // 画素の出力 (画面バッファへ)
    output wire        pix_we,
    output wire [7:0]  pix_x,
    output wire [7:0]  pix_y,
    output wire [5:0]  pix_c,
    output wire [31:0] ppu_frames,
    // PS から PRG へ書き込み
    input  wire        prg_we,
    input  wire [12:0] prg_waddr,    // 語番号 (1 語 = 4 バイト)
    input  wire [31:0] prg_wdata,    // [7:0] が若い番地
    // PS から内蔵 RAM を読む (1 クロック遅れ)
    input  wire [10:0] wram_raddr,
    output reg  [7:0]  wram_rdata,
    // 観測用
    output wire [15:0] dbg_pc,
    output reg  [31:0] cpu_cycles,
    output wire        cpu_sync,
    output wire [15:0] cpu_addr
);
    // ---------------- クロック許可 ----------------
    // 初期値が無いと sim では x のまま足し続けて ce が一度も立たない
    reg  [31:0] acc    = 32'd0;
    reg         ppu_ce = 1'b0;
    reg  [1:0]  dot3   = 2'd0;
    reg         cpu_ce = 1'b0;
    always @(posedge clk) begin
        {ppu_ce, acc} <= {1'b0, acc} + {1'b0, PPU_STEP};
        cpu_ce <= 1'b0;
        if (ppu_ce) begin
            dot3   <= (dot3 == 2'd2) ? 2'd0 : dot3 + 2'd1;
            cpu_ce <= (dot3 == 2'd2);
        end
    end

    // ---------------- CPU ----------------
    wire [15:0] c_addr;
    wire [7:0]  c_dout;
    wire        c_we;
    reg  [7:0]  din;

    wire        ppu_nmi;

    // ---------------- OAM DMA ($4014) ----------------
    // $4014 に書いた次のサイクルから、バスを DMA が持つ (その間 CPU の ce を止める)。
    // 空きサイクル 1 (奇数サイクルなら 2) のあと、$xx00〜$xxFF を読んで $2004 に書くのを 256 回。
    // 合計 513/514 サイクル。CPU は止められたサイクルを DMA の後にそのままやり直す。
    reg        dma_act = 1'b0;
    reg        dma_rw;                  // 0 = 読むサイクル, 1 = $2004 に書くサイクル
    reg [1:0]  dma_wait;
    reg [7:0]  dma_page, dma_idx, dma_data;

    // バス (CPU か DMA)
    wire [15:0] addr = dma_act ? (dma_rw ? 16'h2004 : {dma_page, dma_idx}) : c_addr;
    wire [7:0]  dout = dma_act ? dma_data : c_dout;
    wire        we   = dma_act ? dma_rw   : c_we;

    always @(posedge clk) begin
        if (!run)
            dma_act <= 1'b0;
        else if (cpu_ce) begin
            if (!dma_act) begin
                if (we && addr == 16'h4014) begin
                    dma_act  <= 1'b1;
                    dma_page <= dout;
                    dma_idx  <= 8'd0;
                    dma_rw   <= 1'b0;
                    dma_wait <= cpu_cycles[0] ? 2'd2 : 2'd1;
                end
            end else if (dma_wait != 2'd0)
                dma_wait <= dma_wait - 2'd1;
            else if (!dma_rw) begin
                dma_data <= din;                       // 読んだ値 → 次のサイクルで $2004 へ
                dma_rw   <= 1'b1;
            end else begin
                dma_rw <= 1'b0;
                if (dma_idx == 8'hFF) dma_act <= 1'b0;
                else                  dma_idx <= dma_idx + 8'd1;
            end
        end
    end

    cpu6502 cpu
      (.clk(clk), .rst(!run), .ce(cpu_ce && !dma_act), .addr(c_addr), .dout(c_dout), .we(c_we), .din(din),
       .nmi(ppu_nmi), .irq(1'b0), .sync(cpu_sync),
       .dbg_pc(dbg_pc), .dbg_a(), .dbg_x(), .dbg_y(), .dbg_s(), .dbg_p());

    assign cpu_addr = addr;

    // ---------------- PPU ($2000-$3FFF、8 番地ごとにミラー) ----------------
    // 読み書きの合図は CPU サイクルの終わり (cpu_ce) の 1 クロックだけ
    wire       sel_ppu = (addr[15:13] == 3'b001);
    wire [7:0] ppu_rdata;

    ppu ppu0
      (.clk(clk), .rst(!run), .ce(ppu_ce),
       .reg_addr(addr[2:0]),
       .reg_rd(cpu_ce && !we && sel_ppu),
       .reg_wr(cpu_ce && we && sel_ppu),
       .reg_wdata(dout), .reg_rdata(ppu_rdata), .nmi(ppu_nmi),
       .mirror_v(mirror_v),
       .chr_axi_we(chr_we), .chr_axi_addr(chr_waddr), .chr_axi_data(chr_wdata),
       .pix_we(pix_we), .pix_x(pix_x), .pix_y(pix_y), .pix_c(pix_c),
       .frame_cnt(ppu_frames));

    always @(posedge clk) begin
        if (!run)        cpu_cycles <= 32'd0;
        else if (cpu_ce) cpu_cycles <= cpu_cycles + 32'd1;
    end

    // ---------------- 内蔵 RAM 2KB ----------------
    (* ram_style = "block" *) reg [7:0] wram [0:2047];
    reg [7:0] wram_q;
    // 0 で始める (実機の BRAM も初期値 0。sim で読み残しが x にならないように)
    integer wi;
    initial for (wi = 0; wi < 2048; wi = wi + 1) wram[wi] = 8'h00;
    wire sel_wram = (addr[15:13] == 3'b000);
    always @(posedge clk) begin
        if (cpu_ce && we && sel_wram) wram[addr[10:0]] <= dout;   // サイクルの終わりで書く
        wram_q     <= wram[addr[10:0]];                            // 毎クロック読む
    end
    always @(posedge clk)
        wram_rdata <= wram[wram_raddr];

    // ---------------- PRG 32KB (1 語 = 4 バイト) ----------------
    (* ram_style = "block" *) reg [31:0] prg [0:8191];
    reg [31:0] prg_q;
    reg [1:0]  prg_bsel;
    wire [14:0] prg_a = prg16 ? {1'b0, addr[13:0]} : addr[14:0];
    always @(posedge clk) begin
        if (prg_we) prg[prg_waddr] <= prg_wdata;
        prg_q    <= prg[prg_a[14:2]];
        prg_bsel <= prg_a[1:0];
    end
    wire [7:0] prg_byte = prg_q[prg_bsel*8 +: 8];

    // ---------------- コントローラ ($4016) ----------------
    // 合図が 1 の間は押下状態を取り込み続ける。0 にしたあとは読むたびに右へずらし、
    // 空いた所に 1 を入れる (8 回読んだあとは 1 が返る。実機と同じ)
    reg       pad_strobe;
    reg [7:0] pad_sh;
    always @(posedge clk) begin
        if (!run) begin
            pad_strobe <= 1'b0;
            pad_sh     <= 8'd0;
        end else begin
            if (cpu_ce && we && addr == 16'h4016) pad_strobe <= dout[0];
            if (pad_strobe)
                pad_sh <= pad;
            else if (cpu_ce && !we && addr == 16'h4016)
                pad_sh <= {1'b1, pad_sh[7:1]};      // CPU は同じクロックで前の [0] を受け取る
        end
    end

    // ---------------- 読みの選択 ----------------
    reg [15:0] addr_d;
    always @(posedge clk) addr_d <= addr;       // RAM の読み遅れに合わせる
    always @(*) begin
        if (addr_d[15:13] == 3'b000) din = wram_q;
        else if (addr_d[15:13] == 3'b001) din = ppu_rdata;
        else if (addr_d == 16'h4016) din = {7'b0100000, pad_sh[0]};
        else if (addr_d == 16'h4017) din = 8'h40;
        else if (addr_d[15])         din = prg_byte;
        else                         din = 8'h00;
    end
endmodule
