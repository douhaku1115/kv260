// ============================================================
// mapper.v — カートリッジのマッパー (段G)
// ============================================================
//
// CPU が $8000-$FFFF に書いた値からバンク番号を作り、nes_core (PRG) と ppu (CHR) に渡す。
//   prg_banks: $8000/$A000/$C000/$E000 の 4 窓それぞれの 8KB 単位の番号 (5bit x 4、[4:0] が $8000)
//   chr_banks: PPU $0000〜$1FFF の 1KB 窓 8 つそれぞれの 1KB 単位の番号 (7bit x 8、[6:0] が $0000)
//   mirror:    0 = 水平, 1 = 垂直, 2 = 1 画面 (下側 NT), 3 = 1 画面 (上側 NT)
// 番号は ROM の大きさで折り返す (マスク)。PRG は最大 256KB、CHR は最大 128KB。
//
// 【cfg = AXI の CTRL [15:0]】
//   [2] 垂直ミラー (配線で決まるマッパー用)  [3] CHR-RAM
//   [7:4] マッパー番号  [11:8] PRG の 16KB 個数 - 1  [15:12] CHR の 8KB 個数 - 1
//
// 【対応】0 NROM / 1 MMC1 (SxROM) / 2 UxROM / 3 CNROM / 4 MMC3 (TxROM) / 7 AxROM
//   MMC1: 5 回の書き込みで 1 つのレジスタ。bit7 で途中リセット。続けて 2 サイクル書くと 2 回目は無視
//         (読み書き命令の空書きに反応しないため。実機と同じ)
//   MMC3: ライン割り込みは PPU のアドレス線 A12 の立ち上がりで数える (10 ドット以上 0 のあとだけ)。
//         数え方は新しい版 (Sharp): 0 か再読込指示なら latch を入れ、それ以外は 1 減らし、0 なら IRQ
//   バスの衝突 (UxROM/CNROM で ROM の値と書いた値の AND になる) は真似しない

module mapper (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce,           // cpu_ce
    input  wire [15:0] cfg,
    input  wire        wr,           // $8000-$FFFF への書き込み (サイクルの終わり、ce と同じクロック)
    input  wire [15:0] addr,
    input  wire [7:0]  wdata,
    input  wire        ppu_ce,       // PPU の 1 ドット
    input  wire        a12,          // PPU のアドレス線 A12 (MMC3 の数え)
    output reg  [19:0] prg_banks,
    output reg  [55:0] chr_banks,
    output reg  [1:0]  mirror,
    output wire        irq
);
    wire [3:0] mapper_no = cfg[7:4];
    wire [3:0] last16    = cfg[11:8];               // 最後の 16KB バンク
    wire [4:0] pmask     = {cfg[11:8], 1'b1};        // 8KB 単位のマスク
    wire [6:0] cmask     = {cfg[15:12], 3'b111};     // 1KB 単位のマスク

    // ---------------- レジスタ ----------------
    reg [7:0] latch;                                 // UxROM / CNROM / AxROM
    reg [4:0] m1_sh, m1_ctrl, m1_chr0, m1_chr1;      // MMC1
    reg [3:0] m1_prg;
    reg       prev_wr;
    reg [7:0] m3_sel, m3_r [0:7];                    // MMC3
    reg       m3_mir;
    reg [7:0] irq_latch, irq_cnt;
    reg       irq_reload, irq_en, irq_flag;
    reg [7:0] cnt_next;
    reg       a12_d;
    reg [3:0] a12_low;                               // A12 が 0 だった PPU ドット数 (15 で止める)
    integer   i;

    // A12 の立ち上がり。直前に 10 ドット以上 0 だったときだけ数える
    // (背景とスプライトで $0000/$1000 を行き来する短い 0 は数えない。Mesen と同じ閾値)
    wire a12_rise = a12 && !a12_d && (a12_low >= 4'd10);

    assign irq = irq_flag;

    always @(posedge clk) begin
        if (rst) begin
            latch <= 8'd0;
            m1_sh <= 5'b10000; m1_ctrl <= 5'h0C; m1_chr0 <= 5'd0; m1_chr1 <= 5'd0; m1_prg <= 4'd0;
            prev_wr <= 1'b0;
            m3_sel <= 8'd0; m3_mir <= 1'b0;
            for (i = 0; i < 8; i = i + 1) m3_r[i] <= 8'd0;
            irq_latch <= 8'd0; irq_cnt <= 8'd0; irq_reload <= 1'b0; irq_en <= 1'b0; irq_flag <= 1'b0;
            a12_d <= 1'b0; a12_low <= 4'd0;
        end else begin
            a12_d <= a12;
            if (a12)                               a12_low <= 4'd0;
            else if (ppu_ce && a12_low != 4'd15)   a12_low <= a12_low + 4'd1;
            if (ce) begin
                prev_wr <= wr;
                if (wr) begin
                    case (mapper_no)
                    4'd2, 4'd3, 4'd7: latch <= wdata;
                    4'd1: if (!prev_wr) begin
                        if (wdata[7]) begin
                            m1_sh   <= 5'b10000;
                            m1_ctrl <= m1_ctrl | 5'h0C;           // PRG を「最後のバンク固定」に
                        end else if (m1_sh[0]) begin              // 5 回目: 印が bit0 まで来た
                            case (addr[14:13])
                            2'd0: m1_ctrl <= {wdata[0], m1_sh[4:1]};
                            2'd1: m1_chr0 <= {wdata[0], m1_sh[4:1]};
                            2'd2: m1_chr1 <= {wdata[0], m1_sh[4:1]};
                            2'd3: m1_prg  <= m1_sh[4:1];          // bit4 (PRG-RAM 禁止) は使わない
                            endcase
                            m1_sh <= 5'b10000;
                        end else
                            m1_sh <= {wdata[0], m1_sh[4:1]};      // 若いビットから右へ詰める
                    end
                    4'd4: case ({addr[14:13], addr[0]})
                        3'b000: m3_sel <= wdata;
                        3'b001: m3_r[m3_sel[2:0]] <= wdata;
                        3'b010: m3_mir <= wdata[0];
                        3'b100: irq_latch <= wdata;
                        3'b101: begin irq_cnt <= 8'd0; irq_reload <= 1'b1; end
                        3'b110: begin irq_en <= 1'b0; irq_flag <= 1'b0; end
                        3'b111: irq_en <= 1'b1;
                        default: ;                                // $A001 (PRG-RAM 保護) は使わない
                        endcase
                    default: ;
                    endcase
                end
            end
            // MMC3 のライン数え (A12 は PPU のドットか CPU の $2006/$2007 で変わる。
            // 同じクロックに CPU の $C001/$E000 が来ても数えの方を後に書くので、数えが勝つ)
            if (a12_rise && mapper_no == 4'd4) begin
                if (irq_cnt == 8'd0 || irq_reload) cnt_next = irq_latch;
                else                               cnt_next = irq_cnt - 8'd1;
                irq_cnt    <= cnt_next;
                irq_reload <= 1'b0;
                if (cnt_next == 8'd0 && irq_en) irq_flag <= 1'b1;
            end
        end
    end

    // ---------------- バンク番号 ----------------
    reg [4:0] p [0:3];
    reg [6:0] c [0:7];
    integer   j;
    always @(*) begin
        for (j = 0; j < 4; j = j + 1) p[j] = j;               // NROM: そのまま (マスクで 16KB は折り返す)
        for (j = 0; j < 8; j = j + 1) c[j] = j;
        mirror = cfg[2] ? 2'd1 : 2'd0;
        case (mapper_no)
        4'd1: begin
            case (m1_ctrl[3:2])
            2'd0, 2'd1: for (j = 0; j < 4; j = j + 1) p[j] = {m1_prg[3:1], j[1:0]};   // 32KB 切替
            2'd2: begin p[0] = 5'd0; p[1] = 5'd1;                                    // $8000 固定
                        p[2] = {m1_prg, 1'b0}; p[3] = {m1_prg, 1'b1}; end
            default: begin p[0] = {m1_prg, 1'b0}; p[1] = {m1_prg, 1'b1};             // $C000 固定
                        p[2] = {last16, 1'b0}; p[3] = {last16, 1'b1}; end
            endcase
            if (m1_ctrl[4])                                                          // 4KB x 2
                for (j = 0; j < 4; j = j + 1) begin c[j] = {m1_chr0, j[1:0]}; c[j+4] = {m1_chr1, j[1:0]}; end
            else                                                                     // 8KB
                for (j = 0; j < 8; j = j + 1) c[j] = {m1_chr0[4:1], j[2:0]};
            case (m1_ctrl[1:0])
            2'd0: mirror = 2'd2;
            2'd1: mirror = 2'd3;
            2'd2: mirror = 2'd1;
            default: mirror = 2'd0;
            endcase
        end
        4'd2: begin                                                                  // 16KB 切替 + 最後固定
            p[0] = {latch[3:0], 1'b0}; p[1] = {latch[3:0], 1'b1};
            p[2] = {last16, 1'b0};     p[3] = {last16, 1'b1};
        end
        4'd3: for (j = 0; j < 8; j = j + 1) c[j] = {latch[3:0], j[2:0]};          // CHR 8KB 切替
        4'd4: begin
            if (!m3_sel[6]) begin
                p[0] = m3_r[6][4:0]; p[1] = m3_r[7][4:0]; p[2] = pmask - 5'd1; p[3] = pmask;
            end else begin
                p[0] = pmask - 5'd1; p[1] = m3_r[7][4:0]; p[2] = m3_r[6][4:0]; p[3] = pmask;
            end
            // 2KB x 2 (R0, R1) と 1KB x 4 (R2〜R5)。bit7 で前後を入れ替える
            c[{m3_sel[7], 2'd0}] = {m3_r[0][6:1], 1'b0}; c[{m3_sel[7], 2'd1}] = {m3_r[0][6:1], 1'b1};
            c[{m3_sel[7], 2'd2}] = {m3_r[1][6:1], 1'b0}; c[{m3_sel[7], 2'd3}] = {m3_r[1][6:1], 1'b1};
            c[{~m3_sel[7], 2'd0}] = m3_r[2][6:0]; c[{~m3_sel[7], 2'd1}] = m3_r[3][6:0];
            c[{~m3_sel[7], 2'd2}] = m3_r[4][6:0]; c[{~m3_sel[7], 2'd3}] = m3_r[5][6:0];
            mirror = m3_mir ? 2'd0 : 2'd1;
        end
        4'd7: begin                                                                  // 32KB 切替 + 1 画面
            for (j = 0; j < 4; j = j + 1) p[j] = {latch[2:0], j[1:0]};
            mirror = latch[4] ? 2'd3 : 2'd2;
        end
        default: ;
        endcase
        for (j = 0; j < 4; j = j + 1) prg_banks[j*5 +: 5] = p[j] & pmask;
        for (j = 0; j < 8; j = j + 1) chr_banks[j*7 +: 7] = c[j] & cmask;
    end
endmodule
