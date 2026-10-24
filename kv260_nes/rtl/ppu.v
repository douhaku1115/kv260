// ============================================================
// ppu.v — NES の PPU (2C02)。段D1: 背景の描画・レジスタ・VBlank/NMI
// ============================================================
//
// clk (100MHz) で動き、ce=1 のクロックが PPU の 1 ドット。
// 1 画面 = 341 ドット x 262 ライン (0-239 表示 / 240 空き / 241-260 VBlank / 261 準備)。
//
// 【背景の読み出し】8 ドット周期で ネームテーブル → 属性 → パターン下位 → 上位 を読む。
//   RAM は 1 クロック遅れなので、偶数番目のドットで番地を出し、次のドットで受け取る。
//   シフトレジスタの読み込み・スクロールの加算・t→v の転送の時刻は olcNES と同じ。
//
// 【CPU のレジスタ】$2000-$2007 (reg_addr = 番地の下位 3bit)
//   reg_rd / reg_wr は CPU のサイクルの終わりに 1 クロックだけ立つ。
//   reg_rdata は副作用の前の値 (組み合わせ)。
//   スクロールと番地は loopy の v / t / x / w。
//   v: [14:12]=細かい Y, [11]=NT の Y, [10]=NT の X, [9:5]=粗い Y, [4:0]=粗い X
//
// 【スプライト (段D2)】表示ライン L で次のライン L+1 の分を用意する。
//   ドット 65〜128: OAM の 64 個を 1 ドットに 1 個調べ、L+1 に掛かる先頭 8 個を選ぶ
//                  (OAM の Y は「上端 - 1」なので、L - Y が 0〜高さ-1 なら掛かる)。
//                  9 個目が見つかったら溢れフラグ ($2002 bit5)。実機の溢れ判定のバグは真似しない
//   ドット 257〜320: 8 ドットに 1 個、模様の下位・上位を読む (左右反転はここで反転して持つ)
//   ドット 321: 読んだ 8 個を「表示中」に移す
//   画素: 8 個のうち不透明で番号の若いものが勝つ。背景と重なれば優先ビットで決める。
//   0 番ヒット: 0 番スプライトの不透明画素と背景の不透明画素が重なったら $2002 bit6
//   (x=255 は除く。左端 8 画素のマスク・描画オフで消えた画素では立たない)
// OAM DMA ($4014) は nes_core が $2004 への 256 回の書き込みとして行う。

module ppu (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce,
    // CPU のレジスタ
    input  wire [2:0]  reg_addr,
    input  wire        reg_rd,
    input  wire        reg_wr,
    input  wire [7:0]  reg_wdata,
    output reg  [7:0]  reg_rdata,
    output wire        nmi,
    // カートリッジ (マッパーから)
    input  wire [1:0]  mirror,       // 0 = 水平, 1 = 垂直, 2 = 1 画面 (下), 3 = 1 画面 (上)
    input  wire [55:0] chr_banks,    // 1KB 窓 8 つの番号 (7bit x 8)
    input  wire        chr_ram,      // 1 = CHR-RAM ($2007 で書ける)
    output wire        a12,          // PPU のアドレス線 A12 (MMC3 のライン数えに使う)
    input  wire        chr_axi_we,   // PS から CHR を書く (CPU 停止中)
    input  wire [16:0] chr_axi_addr, // CHR 全体 128KB の番地
    input  wire [7:0]  chr_axi_data,
    // 画素の出力
    output reg         pix_we,
    output reg  [7:0]  pix_x,
    output reg  [7:0]  pix_y,
    output reg  [5:0]  pix_c,
    output reg  [31:0] frame_cnt
);
    // ---------------- レジスタ ----------------
    reg [7:0]  ctrl, mask;
    reg        vbl, sp0, ovf;
    reg [7:0]  oamaddr;
    reg [14:0] v, t;
    reg [2:0]  fx;
    reg        w;
    reg [7:0]  rbuf;

    reg [8:0]  dot, line;
    reg        odd;

    wire rendering = mask[3] | mask[4];
    wire [14:0] vinc = ctrl[2] ? 15'd32 : 15'd1;
    wire [14:0] vnext = v + vinc;                    // $2007 で触ったあとの番地

    assign nmi = vbl & ctrl[7];

    // ネームテーブルの番地 (2KB) — ミラーは引数で渡す
    function [10:0] ntmap(input [13:0] a, input [1:0] m);
        case (m)
        2'd0:    ntmap = {a[11], a[9:0]};        // 水平
        2'd1:    ntmap = {a[10], a[9:0]};        // 垂直
        2'd2:    ntmap = {1'b0,  a[9:0]};        // 1 画面 (下)
        default: ntmap = {1'b1,  a[9:0]};        // 1 画面 (上)
        endcase
    endfunction
    // CHR の番地 (128KB): 1KB 窓 a[12:10] のバンク番号 + 窓の中 a[9:0]。番号は引数で渡す
    function [16:0] chrmap(input [12:0] a, input [55:0] b);
        chrmap = {b[a[12:10]*7 +: 7], a[9:0]};
    endfunction
    // パレットの番地: $3F10/14/18/1C は $3F00/04/08/0C と同じ
    function [4:0] palmap(input [4:0] a);
        palmap = (a[1:0] == 2'b00) ? {1'b0, a[3:0]} : a;
    endfunction

    // ---------------- メモリ ----------------
    (* ram_style = "block" *) reg [7:0] chr [0:131071];
    (* ram_style = "block" *) reg [7:0] nt  [0:2047];
    reg [5:0] pal [0:31];
    reg [7:0] oam [0:255];

    integer k;
    initial begin
        for (k = 0; k < 131072; k = k + 1) chr[k] = 8'h00;
        for (k = 0; k < 2048; k = k + 1) nt[k]  = 8'h00;
        for (k = 0; k < 32;   k = k + 1) pal[k] = 6'h00;
        for (k = 0; k < 256;  k = k + 1) oam[k] = 8'h00;
    end

    // 口A: 描画の読み出し (番地 ra)。口B: CPU の $2007 (番地 v) と PS の CHR 書き込み
    reg  [13:0] ra;
    reg  [7:0]  chr_qa, nt_qa, chr_qb, nt_qb;
    wire [7:0]  rdat = ra[13] ? nt_qa : chr_qa;

    // アドレス線 A12: 描画中は読み出し番地 ra。描画していない間は、最後に CPU が
    // $2006 (2 回目) / $2007 で触った番地 (v) が出たまま (実機と同じ。テストは $2006 で A12 を上げ下げする)
    reg  a12_idle;
    wire render_act = rendering && (line < 9'd240 || line == 9'd261);
    assign a12 = render_act ? ra[12] : a12_idle;

    wire is_pal   = (v[13:8] == 6'h3F);
    wire wr2007   = reg_wr && (reg_addr == 3'd7);
    wire nt_we    = wr2007 && v[13] && !is_pal;
    wire chr_we   = wr2007 && !v[13] && chr_ram;       // CHR-ROM には書かない
    wire [16:0] chr_pb = chr_axi_we ? chr_axi_addr : chrmap(v[12:0], chr_banks);

    always @(posedge clk) begin
        chr_qa <= chr[chrmap(ra[12:0], chr_banks)];
        nt_qa  <= nt[ntmap(ra, mirror)];
    end
    always @(posedge clk) begin
        if (chr_axi_we)  chr[chr_pb] <= chr_axi_data;
        else if (chr_we) chr[chr_pb] <= reg_wdata;
        chr_qb <= chr[chr_pb];
    end
    always @(posedge clk) begin
        if (nt_we) nt[ntmap(v[13:0], mirror)] <= reg_wdata;
        nt_qb <= nt[ntmap(v[13:0], mirror)];
    end
    always @(posedge clk) begin
        if (wr2007 && is_pal) pal[palmap(v[4:0])] <= reg_wdata[5:0];
        if (reg_wr && reg_addr == 3'd4) oam[oamaddr] <= reg_wdata;
    end

    // CPU の読み (副作用の前の値)
    always @(*) begin
        case (reg_addr)
        3'd2:    reg_rdata = {vbl, sp0, ovf, rbuf[4:0]};
        3'd4:    reg_rdata = oam[oamaddr];
        3'd7:    reg_rdata = is_pal ? {2'b00, pal[palmap(v[4:0])]} : rbuf;
        default: reg_rdata = rbuf;
        endcase
    end

    // ---------------- 背景の作業用 ----------------
    reg [7:0]  tile, at_bits, p_lo, p_hi;
    reg [1:0]  at_sel;
    reg [15:0] sh_lo, sh_hi, sh_alo, sh_ahi;

    // always の中で順に使う一時変数 (olcNES と同じ順で「加算→読み込み→画素」を回す)
    reg [15:0] nlo, nhi, nalo, nahi;
    reg [14:0] vv;
    reg [2:0]  ph;
    reg        fetch_win;
    reg [15:0] mux;
    reg [1:0]  bpix, bpal;
    reg [5:0]  col;

    // ---------------- スプライトの作業用 ----------------
    // s_*: 評価で選んだ分 (このラインの評価結果)。n_*: 模様を読んだ分。c_*: 表示中のライン
    reg [3:0]  s_cnt;
    reg        s_has0, c_has0;                 // 0 番スプライトが入っているか
    reg [7:0]  s_tile [0:7];
    reg [7:0]  s_attr [0:7];
    reg [7:0]  s_x    [0:7];
    reg [3:0]  s_row  [0:7];                   // スプライトの中の何行目か (反転前)
    reg [7:0]  n_lo [0:7], n_hi [0:7], n_attr [0:7], n_x [0:7];
    reg [7:0]  c_lo [0:7], c_hi [0:7], c_attr [0:7], c_x [0:7];

    reg [8:0]  sd, dm1;
    reg [5:0]  sn;
    reg [2:0]  sl;
    reg [3:0]  sr;
    reg [13:0] sa;
    reg [7:0]  px, so;
    reg [1:0]  spix, spal, sb;
    reg        sprio, s0pix;
    integer    si;

    initial
        for (k = 0; k < 8; k = k + 1) begin
            c_lo[k] = 8'd0; c_hi[k] = 8'd0; c_attr[k] = 8'd0; c_x[k] = 8'hFF;
            n_lo[k] = 8'd0; n_hi[k] = 8'd0; n_attr[k] = 8'd0; n_x[k] = 8'hFF;
        end

    // 左右反転用 (引数だけを使う)
    function [7:0] rev8(input [7:0] b);
        rev8 = {b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7]};
    endfunction

    always @(posedge clk) begin
        pix_we    <= 1'b0;
        if (rst) begin
            a12_idle <= 1'b0;
            ctrl <= 8'd0; mask <= 8'd0; vbl <= 1'b0; sp0 <= 1'b0; ovf <= 1'b0;
            oamaddr <= 8'd0; v <= 15'd0; t <= 15'd0; fx <= 3'd0; w <= 1'b0; rbuf <= 8'd0;
            dot <= 9'd0; line <= 9'd0; odd <= 1'b0; frame_cnt <= 32'd0;
            ra <= 14'd0; sh_lo <= 16'd0; sh_hi <= 16'd0; sh_alo <= 16'd0; sh_ahi <= 16'd0;
            s_cnt <= 4'd0; s_has0 <= 1'b0; c_has0 <= 1'b0;
        end else begin
            // ---------- CPU のレジスタ (cpu_ce のクロック。ce とは重ならない) ----------
            if (reg_wr) begin
                case (reg_addr)
                3'd0: begin ctrl <= reg_wdata; t[11:10] <= reg_wdata[1:0]; end
                3'd1: mask <= reg_wdata;
                3'd3: oamaddr <= reg_wdata;
                3'd4: oamaddr <= oamaddr + 8'd1;
                3'd5: begin
                    if (!w) begin t[4:0] <= reg_wdata[7:3]; fx <= reg_wdata[2:0]; end
                    else    begin t[14:12] <= reg_wdata[2:0]; t[9:5] <= reg_wdata[7:3]; end
                    w <= ~w;
                end
                3'd6: begin
                    if (!w) t[14:8] <= {1'b0, reg_wdata[5:0]};
                    else begin t[7:0] <= reg_wdata; v <= {t[14:8], reg_wdata}; a12_idle <= t[12]; end
                    w <= ~w;
                end
                3'd7: begin v <= vnext; a12_idle <= vnext[12]; end
                default: ;
                endcase
            end
            if (reg_rd) begin
                case (reg_addr)
                3'd2: begin vbl <= 1'b0; w <= 1'b0; end
                3'd7: begin
                    // バッファは常に $2xxx 以下の中身で補充 (パレットの下はネームテーブル)
                    rbuf <= v[13] ? nt_qb : chr_qb;
                    v <= vnext;
                    a12_idle <= vnext[12];
                end
                default: ;
                endcase
            end

            // ---------- 1 ドット ----------
            if (ce) begin
                vv = v; nlo = sh_lo; nhi = sh_hi; nalo = sh_alo; nahi = sh_ahi;
                ph = dot[2:0] - 3'd1;                      // (dot-1) % 8
                fetch_win = (line < 9'd240 || line == 9'd261) &&
                            ((dot >= 9'd2 && dot <= 9'd257) || (dot >= 9'd321 && dot <= 9'd337));

                if (fetch_win) begin
                    if (mask[3]) begin                     // シフト
                        nlo = {nlo[14:0], 1'b0};  nhi = {nhi[14:0], 1'b0};
                        nalo = {nalo[14:0], 1'b0}; nahi = {nahi[14:0], 1'b0};
                    end
                    case (ph)
                    3'd0: begin
                        // 前の 8 ドットで読んだタイルを下位 8bit に入れる
                        nlo  = {nlo[15:8], p_lo};  nhi  = {nhi[15:8], p_hi};
                        nalo = {nalo[15:8], {8{at_sel[0]}}};
                        nahi = {nahi[15:8], {8{at_sel[1]}}};
                        ra <= {2'b10, vv[11:0]};           // ネームテーブル
                    end
                    3'd1: tile <= rdat;
                    3'd2: ra <= {2'b10, vv[11:10], 4'b1111, vv[9:7], vv[4:2]};     // $23C0 + 属性
                    3'd3: begin
                        // 4x4 タイルのどの 2x2 か: 粗い Y の bit1 で 4bit、粗い X の bit1 で 2bit ずらす
                        case ({vv[6], vv[1]})
                        2'b00: at_sel <= rdat[1:0];
                        2'b01: at_sel <= rdat[3:2];
                        2'b10: at_sel <= rdat[5:4];
                        2'b11: at_sel <= rdat[7:6];
                        endcase
                    end
                    3'd4: ra <= {1'b0, ctrl[4], tile, 1'b0, vv[14:12]};          // パターン下位
                    3'd5: p_lo <= rdat;
                    3'd6: ra <= {1'b0, ctrl[4], tile, 1'b1, vv[14:12]};          // パターン上位
                    3'd7: begin
                        p_hi <= rdat;
                        if (rendering) begin                                     // 粗い X を進める
                            if (vv[4:0] == 5'd31) begin vv[4:0] = 5'd0; vv[10] = ~vv[10]; end
                            else vv[4:0] = vv[4:0] + 5'd1;
                        end
                    end
                    endcase
                end

                if ((line < 9'd240 || line == 9'd261) && rendering) begin
                    if (dot == 9'd256) begin                                     // Y を進める
                        if (vv[14:12] != 3'd7) vv[14:12] = vv[14:12] + 3'd1;
                        else begin
                            vv[14:12] = 3'd0;
                            if (vv[9:5] == 5'd29) begin vv[9:5] = 5'd0; vv[11] = ~vv[11]; end
                            else if (vv[9:5] == 5'd31) vv[9:5] = 5'd0;
                            else vv[9:5] = vv[9:5] + 5'd1;
                        end
                    end
                    if (dot == 9'd257) begin                                     // X を t から戻す
                        nlo  = {nlo[15:8], p_lo};  nhi  = {nhi[15:8], p_hi};
                        nalo = {nalo[15:8], {8{at_sel[0]}}};
                        nahi = {nahi[15:8], {8{at_sel[1]}}};
                        vv[10] = t[10]; vv[4:0] = t[4:0];
                    end
                    if (line == 9'd261 && dot >= 9'd280 && dot <= 9'd304) begin  // Y を t から戻す
                        vv[14:11] = t[14:11]; vv[9:5] = t[9:5];
                    end
                    if (dot >= 9'd257 && dot <= 9'd320) oamaddr <= 8'd0;     // 実機と同じく 0 に戻る
                end

                // ---------- スプライトの評価 (表示ライン、ドット 65〜128) ----------
                if (dot == 9'd0) begin s_cnt <= 4'd0; s_has0 <= 1'b0; end
                if (line < 9'd240 && rendering && dot >= 9'd65 && dot <= 9'd128) begin
                    sn = dot[5:0] - 6'd1;                                        // 65→0 … 128→63
                    sd = {1'b0, line[7:0]} - {1'b0, oam[{sn, 2'b00}]};
                    if (!sd[8] && sd[7:0] < (ctrl[5] ? 8'd16 : 8'd8)) begin
                        if (s_cnt != 4'd8) begin
                            s_tile[s_cnt[2:0]] <= oam[{sn, 2'b01}];
                            s_attr[s_cnt[2:0]] <= oam[{sn, 2'b10}];
                            s_x[s_cnt[2:0]]    <= oam[{sn, 2'b11}];
                            s_row[s_cnt[2:0]]  <= sd[3:0];
                            s_cnt <= s_cnt + 4'd1;
                            if (sn == 6'd0) s_has0 <= 1'b1;
                        end else
                            ovf <= 1'b1;
                    end
                end

                // ---------- スプライトの模様 (ドット 257〜320、1 個 8 ドット) ----------
                if ((line < 9'd240 || line == 9'd261) && dot >= 9'd257 && dot <= 9'd320) begin
                    dm1 = dot - 9'd1;
                    sl  = dm1[5:3];
                    sr  = s_row[sl];
                    if (s_attr[sl][7]) sr = (ctrl[5] ? 4'd15 : 4'd7) - sr;      // 上下反転
                    sa  = ctrl[5] ? {1'b0, s_tile[sl][0], s_tile[sl][7:1], sr[3], 1'b0, sr[2:0]}
                                  : {1'b0, ctrl[3], s_tile[sl], 1'b0, sr[2:0]};
                    case (ph)
                    3'd4: ra <= sa;
                    3'd5: n_lo[sl] <= ({1'b0, sl} < s_cnt) ? (s_attr[sl][6] ? rev8(rdat) : rdat) : 8'd0;
                    3'd6: ra <= sa | 14'd8;
                    3'd7: begin
                        n_hi[sl]   <= ({1'b0, sl} < s_cnt) ? (s_attr[sl][6] ? rev8(rdat) : rdat) : 8'd0;
                        n_attr[sl] <= s_attr[sl];
                        n_x[sl]    <= s_x[sl];
                    end
                    default: ;
                    endcase
                end
                if (dot == 9'd321) begin                                         // 次のラインの表示用へ
                    for (si = 0; si < 8; si = si + 1) begin
                        c_lo[si] <= n_lo[si]; c_hi[si] <= n_hi[si];
                        c_attr[si] <= n_attr[si]; c_x[si] <= n_x[si];
                    end
                    c_has0 <= s_has0 && (line < 9'd240);
                end

                // 画素 (表示ライン、ドット 1〜256 → x = dot-1)
                if (line < 9'd240 && dot >= 9'd1 && dot <= 9'd256) begin
                    mux  = 16'h8000 >> fx;
                    bpix = {|(nhi & mux), |(nlo & mux)};
                    bpal = {|(nahi & mux), |(nalo & mux)};
                    if (!mask[3] || (!mask[1] && dot <= 9'd8)) bpix = 2'b00;

                    // スプライト: 番号の大きい方から見て上書き → 最後に残るのが若い番号
                    px = dot[7:0] - 8'd1;
                    spix = 2'b00; spal = 2'b00; sprio = 1'b0; s0pix = 1'b0;
                    for (si = 7; si >= 0; si = si - 1) begin
                        // スプライトの中の列。9bit で引いて、右端から左端へ折り返さないようにする
                        sd = {1'b0, px} - {1'b0, c_x[si]};
                        so = sd[7:0];
                        if (!sd[8] && so < 8'd8) begin
                            sb = {c_hi[si][3'd7 - so[2:0]], c_lo[si][3'd7 - so[2:0]]};
                            if (sb != 2'b00) begin spix = sb; spal = c_attr[si][1:0]; sprio = c_attr[si][5]; end
                            if (si == 0) s0pix = (sb != 2'b00);
                        end
                    end
                    if (!mask[4] || (!mask[2] && dot <= 9'd8)) begin spix = 2'b00; s0pix = 1'b0; end

                    if (c_has0 && s0pix && bpix != 2'b00 && px != 8'd255) sp0 <= 1'b1;

                    if (spix != 2'b00 && (bpix == 2'b00 || !sprio)) col = pal[{1'b1, spal, spix}];
                    else if (bpix != 2'b00)                          col = pal[{1'b0, bpal, bpix}];
                    else                                             col = pal[0];
                    if (mask[0]) col = col & 6'h30;                              // 白黒
                    pix_we <= 1'b1;
                    pix_x  <= dot[7:0] - 8'd1;
                    pix_y  <= line[7:0];
                    pix_c  <= col;
                end

                // VBlank
                if (line == 9'd241 && dot == 9'd1) begin vbl <= 1'b1; frame_cnt <= frame_cnt + 32'd1; end
                if (line == 9'd261 && dot == 9'd1) begin vbl <= 1'b0; sp0 <= 1'b0; ovf <= 1'b0; end

                v <= vv; sh_lo <= nlo; sh_hi <= nhi; sh_alo <= nalo; sh_ahi <= nahi;

                // ドットとラインを進める (奇数フレームは準備ラインの最後の 1 ドットを飛ばす)
                if (line == 9'd261 && dot == 9'd339 && odd && rendering) begin
                    dot <= 9'd0; line <= 9'd0; odd <= ~odd;
                end else if (dot == 9'd340) begin
                    dot <= 9'd0;
                    if (line == 9'd261) begin line <= 9'd0; odd <= ~odd; end
                    else line <= line + 9'd1;
                end else
                    dot <= dot + 9'd1;
            end
        end
    end
endmodule
