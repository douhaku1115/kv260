// ============================================================
//  kaleido_axi_slave — 万華鏡のパラメータを PS から受け取る AXI4-Lite スレーブ
//
//  ベースアドレス 0xA0000000、範囲 2KB。
//  レジスタは 0x10 刻みで並べる (kv260_i2s2 で 4 バイト刻みだと
//  アドレスデコードが噛み合わず届かなかったことがあるため)。
//
//  【レジスタマップ】
//    0x000  CTRL        bit0 = mirror2 (1 = 2枚鏡)  bit1 = 文字を出す
//    0x010  KX          2^26 / (2 * 720 * focal)        画角
//    0x020  Z_MIRROR    Q16  のぞき穴 → 鏡の手前の端 (cm)
//    0x030  REMAIN0     Q14  Z_CELL - Z_MIRROR (cm)
//    0x040  INV_TUBE_R  Q16  1 / 筒の半径
//    0x050  COS_T       Q15  セルの回転 cos
//    0x060  SIN_T       Q15  セルの回転 sin
//    0x070  NX0         Q16 ┐
//    0x080  NY0         Q16 │ 鏡 0 (長い鏡)
//    0x090  WD0         Q14 ┘
//    0x0A0  NX1 / 0x0B0 NY1 / 0x0C0 WD1    鏡 1 (長い鏡)
//    0x0D0  NX2 / 0x0E0 NY2 / 0x0F0 WD2    鏡 2 (底辺)
//    0x100  VX0 / 0x110 VY0                頂点 0 (合わせ目用) Q15
//    0x120  VX1 / 0x130 VY1
//    0x140  VX2 / 0x150 VY2
//    0x160  COMMIT      書くと、その時点の値を一括で映像側へ渡す
//    0x170  FRAME_CNT   読み出し専用。PL が数えたフレーム数
//    0x180  CELL_CTRL   bit1:0 = 書き込み先。2 = ピースの表 (段5d-7)。
//                       書くと番地が 0 に戻る。
//                       (0=奥層 1=手前層 は段5d-6 までのセルの流し込み。
//                        段5d-7 で油の地を PL の ROM に移したので、もう使わない)
//    0x190  CELL_DATA   書くと「いまの番地」に入り、番地が 1 進む。
//                       ピースの表は 1 個 24 語。書いた語数ぶんを描く
//    0x1A0  DRAW_REQ    書くと PL が描き直す (描く面を下地に戻す → 表を描く
//                       → 次のフレーム先頭で映す面と入れ替える)。
//                       読むと bit0 = 描き直しの途中 (段5d-7)。
//                       ★ bit0 が 0 になってから表を書き、DRAW_REQ を書くこと。
//                         描いている途中に表を書き換えると、描きかけが混ざる
//
//    0x400 + i*0x10   画面に出す文字 (i = 0〜63)。1 ワードに 4 文字。
//                     下位バイトが左端。32 桁 x 8 行 = 256 文字。
//                     ASCII 0x20〜0x7E。それ以外は空白として描かれる。
//
//  【クロックの渡し方】
//    レジスタは AXI クロック領域にある。映像クロック領域へは
//      PS が値を全部書く → COMMIT に書く → PL がトグルを立てる
//      → 映像側でトグルを 2 段同期 → 次のフレーム先頭で一括コピー
//    という手順で渡す。1 フレームの途中で値が入れ替わらないので、
//    cos と sin がちぐはぐになって模様が揺れることがない。
// ============================================================

module kaleido_axi_slave #(
    parameter C_S_AXI_DATA_WIDTH = 32,
    parameter C_S_AXI_ADDR_WIDTH = 11,  // 2KB (0x400 以降に文字を置くため)
    parameter TEXT_COLS = 32,
    parameter TEXT_ROWS = 8
)(
    input  wire                            S_AXI_ACLK,
    input  wire                            S_AXI_ARESETN,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]   S_AXI_AWADDR,
    input  wire [2:0]                      S_AXI_AWPROT,
    input  wire                            S_AXI_AWVALID,
    output wire                            S_AXI_AWREADY,

    input  wire [C_S_AXI_DATA_WIDTH-1:0]   S_AXI_WDATA,
    input  wire [C_S_AXI_DATA_WIDTH/8-1:0] S_AXI_WSTRB,
    input  wire                            S_AXI_WVALID,
    output wire                            S_AXI_WREADY,

    output wire [1:0]                      S_AXI_BRESP,
    output wire                            S_AXI_BVALID,
    input  wire                            S_AXI_BREADY,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0]   S_AXI_ARADDR,
    input  wire [2:0]                      S_AXI_ARPROT,
    input  wire                            S_AXI_ARVALID,
    output wire                            S_AXI_ARREADY,

    output wire [C_S_AXI_DATA_WIDTH-1:0]   S_AXI_RDATA,
    output wire [1:0]                      S_AXI_RRESP,
    output wire                            S_AXI_RVALID,
    input  wire                            S_AXI_RREADY,

    // ---- 映像クロック領域 ----
    input  wire                            clkv,
    input  wire                            frame_start,  // フレーム先頭で 1 クロック
    output reg  [17:0]                     v_kx,
    output reg  [17:0]                     v_z_mirror,
    output reg  [19:0]                     v_remain0,
    output reg  [17:0]                     v_inv_tr,
    output reg  [17:0]                     v_cos_t,
    output reg  [17:0]                     v_sin_t,
    output reg  [17:0]                     v_nx0, v_ny0, v_wd0,
    output reg  [17:0]                     v_nx1, v_ny1, v_wd1,
    output reg  [17:0]                     v_nx2, v_ny2, v_wd2,
    output reg  [17:0]                     v_vx0, v_vy0,
    output reg  [17:0]                     v_vx1, v_vy1,
    output reg  [17:0]                     v_vx2, v_vy2,
    output reg                             v_mirror2,
    output reg                             v_text_on,   // CTRL bit1

    // きらめき層 (段7、rtl/sparkle.v)。0x1B0〜0x1E0 に書き、COMMIT で他と一緒に取り込む
    //   0x1B0 SPK_CTRL  bit0 = 出す、bit3:1 = 格子 2^lv マス、bit11:4 = 点がある割合 /256
    //   0x1C0 SPK_K     (1 マスの画面画素 / 点の半径)^2  Q8
    //   0x1D0 SPK_GAIN  bit7:0 = いつもの明るさ、bit15:8 = キラッと光るとき (128 = 1.0)
    //   0x1E0 SPK_TIME  時刻 (256 で 1 周)。PS が毎フレーム進める
    output reg                             v_spk_en,
    output reg  [2:0]                      v_spk_lv,
    output reg  [7:0]                      v_spk_dens,
    output reg  [15:0]                     v_spk_k,
    output reg  [7:0]                      v_spk_base,
    output reg  [7:0]                      v_spk_flash,
    output reg  [7:0]                      v_spk_tphase,
    //   0x1F0〜0x2E0 SPK_COL0〜15  点の色の表 {R, G, B} (24bit)。点ごとにハッシュで 16 個から選ぶ。
    //   PS は 8 色を割合に応じて 16 個へ振り分けて書く (割合は 1/16 刻み)
    output reg  [16*24-1:0]                v_spk_cols,

    // 画面に出す文字。映像側から読む (書き込みは AXI 側、読み出しは映像側の
    // 単純デュアルポート RAM。PS が書いた文字がそのまま画面に出る)
    input  wire [10:0]                     text_addr,   // 文字番号 0〜TEXT_COLS*TEXT_ROWS-1
    output reg  [7:0]                      text_ch,

    // ピースの表への書き込み (段6b。**AXI クロック領域のまま**出す)。
    //   表の RAM (pdriver) は書き込み口を AXI クロック、読み出し口を映像クロックで
    //   動かすので、映像クロックへ乗り換えなくてよい。段5d-7 まではトグル 1 本を
    //   2 段同期して渡していたが、PS の書き込みが 1 語 80ns まで詰まると取りこぼした
    output reg                             a_tw_we,
    output reg  [15:0]                     a_tw_addr,
    output reg  [23:0]                     a_tw_data,
    //  表に入っている語数 (最後に書いた番地 + 1)。映像側の pdriver が読むが、
    //  PS は書き終えてから DRAW_REQ を書き、pdriver はそのあと油の地を写す
    //  65541 クロックを経てから読むので、乗り換えなしで落ち着いている
    output reg  [15:0]                     a_tw_words,
    //  ★ 描画開始 (段5d-6)。段5d-7 からは描き直しの開始
    output reg                             v_draw_req,
    //  描き直しの途中か (段5d-7。映像クロック領域から。0x1A0 で読める)
    input  wire                            v_draw_busy
);

    localparam NREG = 23;          // 0x000 〜 0x160

    reg                          axi_awready, axi_wready, axi_bvalid;
    reg                          axi_arready, axi_rvalid;
    reg [1:0]                    axi_bresp, axi_rresp;
    reg [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;

    assign S_AXI_AWREADY = axi_awready;
    assign S_AXI_WREADY  = axi_wready;
    assign S_AXI_BRESP   = axi_bresp;
    assign S_AXI_BVALID  = axi_bvalid;
    assign S_AXI_ARREADY = axi_arready;
    assign S_AXI_RDATA   = axi_rdata;
    assign S_AXI_RRESP   = axi_rresp;
    assign S_AXI_RVALID  = axi_rvalid;

    // ---- レジスタ本体 (AXI クロック領域) ----
    reg [19:0] regs [0:NREG-1];
    reg        commit_tgl;

    // きらめき層の設定 (段7)。0x1B0 = 27 番から 4 つ
    localparam [6:0] SPK_BASE = 7'd27;
    reg [15:0] spk_regs [0:3];
    initial begin
        spk_regs[0] = 16'd0;       // 出さない (PS が設定してから出す)
        spk_regs[1] = 16'd0;
        spk_regs[2] = 16'd0;
        spk_regs[3] = 16'd0;
    end
    // 点の色の表 (0x1F0 = 31 番から 16 個)。既定は段7 の 4 色 (白・白・金・淡い青) の繰り返し
    localparam [6:0] SPKC_BASE = 7'd31;
    reg [23:0] spkc_regs [0:15];
    integer ci;
    initial begin
        for (ci = 0; ci < 16; ci = ci + 1)
            spkc_regs[ci] = (ci % 4 == 2) ? 24'hFFE08C : (ci % 4 == 3) ? 24'hBFD9FF : 24'hFFFFFF;
    end

    // 電源投入時の既定値: ポイント数 8、3枚鏡、回転なし
    //   tools/ref_scope.py の mirror_geometry(8) と同じ値
    integer j;
    initial begin
        for (j = 0; j < NREG; j = j + 1) regs[j] = 20'd0;
        regs[0]  = 20'd0;                        // CTRL       3枚鏡
        regs[1]  = 20'd54828;                    // KX         focal 0.85 (zoom=1.0)
        regs[2]  = 20'd19661;                    // Z_MIRROR   0.3 cm
        regs[3]  = 20'd194970;                   // REMAIN0    11.9 cm
        regs[4]  = 20'd29127;                    // INV_TUBE_R 1/2.25
        regs[5]  = 20'd32768;                    // COS_T      1.0
        regs[6]  = 20'd0;                        // SIN_T      0.0
        regs[7]  = 20'hF04EB;  regs[8]  = 20'h031F1;  regs[9]  = 20'h01999;  // 鏡0
        regs[10] = 20'h0FB15;  regs[11] = 20'h031F1;  regs[12] = 20'h01999;  // 鏡1
        regs[13] = 20'h00000;  regs[14] = 20'hF0000;  regs[15] = 20'h07937;  // 鏡2
        regs[16] = 20'h00000;  regs[17] = 20'h10666;                         // 頂点0
        regs[18] = 20'hF9B95;  regs[19] = 20'hF0D93;                         // 頂点1
        regs[20] = 20'h0646B;  regs[21] = 20'hF0D93;                         // 頂点2
        commit_tgl = 1'b0;
    end

    // ---- AXI 書き込み ----
    reg aw_en;
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_awready <= 1'b0;
            aw_en <= 1'b1;
        end else if (~axi_awready && S_AXI_AWVALID && S_AXI_WVALID && aw_en) begin
            axi_awready <= 1'b1;
            aw_en <= 1'b0;
            axi_awaddr <= S_AXI_AWADDR;
        end else begin
            axi_awready <= 1'b0;
            if (S_AXI_BREADY && axi_bvalid) aw_en <= 1'b1;
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            axi_wready <= 1'b0;
        else if (~axi_wready && S_AXI_WVALID && S_AXI_AWVALID && aw_en)
            axi_wready <= 1'b1;
        else
            axi_wready <= 1'b0;
    end

    wire       wr_en   = axi_wready && S_AXI_WVALID && axi_awready && S_AXI_AWVALID;
    wire [6:0] wr_unit = axi_awaddr[10:4];     // 0x10 刻み。0〜127

    // ---- 画面に出す文字の置き場 ----
    //   0x400 + i*0x10 に 4 文字ずつ書く (i = 0〜TEXT_WORDS-1)
    //   下位バイトが左端の文字。
    localparam TEXT_CHARS = TEXT_COLS * TEXT_ROWS;      // 32*8 = 256
    localparam TEXT_WORDS = TEXT_CHARS / 4;             // 64
    localparam TEXT_BASE  = 7'd64;                      // 0x400 >> 4
    localparam TEXT_AW    = $clog2(TEXT_CHARS);         // 文字番号の幅 (256 字なら 8)
    // ★ 番地の都合で TEXT_WORDS は 64 まで (0x400〜0x7F0)。
    //   文字数を増やすときは番地の割り当てから見直すこと。
    wire [6:0]         tw_off = wr_unit - TEXT_BASE;                 // 何語目か
    wire [TEXT_AW-3:0] tw_idx = tw_off[TEXT_AW-3:0];                 // 4 文字単位の番号

    (* ram_style = "block" *)
    reg [7:0] text_ram [0:TEXT_CHARS-1];

    integer t;
    initial for (t = 0; t < TEXT_CHARS; t = t + 1) text_ram[t] = 8'h20;   // 空白

    // ---- ピースの表への書き込み (AXI クロック領域) ----
    //   番地は自分で進める。PS は CELL_CTRL=2 で番地を 0 に戻し、
    //   あとは CELL_DATA に 個数 x 24 回書くだけでよい。
    reg [1:0]  cw_sel;
    reg [15:0] cw_addr;
    reg        dr_tgl;                 // 描画開始 (段5d-6)
    initial begin cw_sel = 2'd0; cw_addr = 16'd0; dr_tgl = 1'b0; end
    initial begin a_tw_we = 1'b0; a_tw_addr = 16'd0; a_tw_data = 24'd0; a_tw_words = 16'd0; end

    wire tw_hit = wr_en && (wr_unit == 7'd25) && (cw_sel == 2'd2);
    always @(posedge S_AXI_ACLK) begin
        a_tw_we   <= tw_hit;
        a_tw_addr <= cw_addr;              // この語を入れる番地
        a_tw_data <= S_AXI_WDATA[23:0];
        if (tw_hit) a_tw_words <= cw_addr + 16'd1;
    end

    always @(posedge S_AXI_ACLK) begin
        if (wr_en) begin
            if (wr_unit == 7'd22)              // 0x160 COMMIT
                commit_tgl <= ~commit_tgl;
            else if (wr_unit == 7'd24) begin   // 0x180 CELL_CTRL
                cw_sel  <= S_AXI_WDATA[1:0];
                cw_addr <= 16'd0;
            end
            else if (wr_unit == 7'd25)         // 0x190 CELL_DATA (書くのは上の always)
                cw_addr <= cw_addr + 16'd1;
            else if (wr_unit == 7'd26)         // 0x1A0 DRAW_REQ
                dr_tgl <= ~dr_tgl;
            else if (wr_unit < NREG-1)
                regs[wr_unit] <= S_AXI_WDATA[19:0];
            else if (wr_unit >= SPK_BASE && wr_unit < SPK_BASE + 7'd4)   // 0x1B0〜0x1E0
                spk_regs[wr_unit[1:0] - SPK_BASE[1:0]] <= S_AXI_WDATA[15:0];
            else if (wr_unit >= SPKC_BASE && wr_unit < SPKC_BASE + 7'd16)  // 0x1F0〜0x2E0
                spkc_regs[wr_unit - SPKC_BASE] <= S_AXI_WDATA[23:0];
            else if (wr_unit >= TEXT_BASE && wr_unit < TEXT_BASE + TEXT_WORDS) begin
                text_ram[{tw_idx, 2'd0}]         <= S_AXI_WDATA[7:0];
                text_ram[{tw_idx, 2'd0} + 3'd1]  <= S_AXI_WDATA[15:8];
                text_ram[{tw_idx, 2'd0} + 3'd2]  <= S_AXI_WDATA[23:16];
                text_ram[{tw_idx, 2'd0} + 3'd3]  <= S_AXI_WDATA[31:24];
            end
        end
    end

    // ---- 描画開始を映像クロック側へ渡す ----
    //   トグルを 2 段同期し、変化を見たらその拍で 1 クロックのパルスにする。
    reg d0, d1, d2;
    always @(posedge clkv) begin
        d0 <= dr_tgl;  d1 <= d0;  d2 <= d1;
        v_draw_req <= (d1 != d2);
    end

    // 映像クロック側から読む。書き込みは AXI クロック側。
    // 文字は PS が静かに書いてから使うだけなので、普通の単純デュアルポートでよい。
    always @(posedge clkv) text_ch <= text_ram[text_addr[TEXT_AW-1:0]];

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_bvalid <= 1'b0;
            axi_bresp  <= 2'b0;
        end else if (axi_awready && S_AXI_AWVALID && ~axi_bvalid && axi_wready && S_AXI_WVALID) begin
            axi_bvalid <= 1'b1;
            axi_bresp  <= 2'b0;
        end else if (S_AXI_BREADY && axi_bvalid) begin
            axi_bvalid <= 1'b0;
        end
    end

    // ---- AXI 読み出し ----
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN)
            axi_arready <= 1'b0;
        else if (~axi_arready && S_AXI_ARVALID)
            axi_arready <= 1'b1;
        else
            axi_arready <= 1'b0;
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            axi_rvalid <= 1'b0;
            axi_rresp  <= 2'b0;
        end else if (axi_arready && S_AXI_ARVALID && ~axi_rvalid) begin
            axi_rvalid <= 1'b1;
            axi_rresp  <= 2'b0;
        end else if (axi_rvalid && S_AXI_RREADY) begin
            axi_rvalid <= 1'b0;
        end
    end

    // フレーム数 (映像側で数えて AXI 側へ渡す)。PS が描画の間合いを取るのに使う
    reg [31:0] frame_cnt_v;
    always @(posedge clkv) if (frame_start) frame_cnt_v <= frame_cnt_v + 32'd1;

    reg [31:0] frame_cnt_a0, frame_cnt_a;
    reg        busy_a0, busy_a;        // 描き直しの途中か (2 段同期)
    //  ★ DRAW_REQ を書いた直後は、映像側の busy がまだ AXI 側に届いていない
    //    (トグル同期 + 2 段同期で数十 ns)。その間に 0 を返すと、PS が
    //    「終わった」と思って描いている最中の表を書き換えてしまう。
    //    要求を出してから busy が 1 回見えるまでは req_pend で 1 を返す。
    reg        req_pend;
    initial req_pend = 1'b0;
    always @(posedge S_AXI_ACLK) begin
        frame_cnt_a0 <= frame_cnt_v;
        frame_cnt_a  <= frame_cnt_a0;
        busy_a0      <= v_draw_busy;
        busy_a       <= busy_a0;
        if (wr_en && wr_unit == 7'd26) req_pend <= 1'b1;
        else if (busy_a)               req_pend <= 1'b0;
    end

    wire [6:0] rd_unit = S_AXI_ARADDR[10:4];

    always @(posedge S_AXI_ACLK) begin
        if (~axi_rvalid && S_AXI_ARVALID) begin
            if (rd_unit == 7'd23)
                axi_rdata <= frame_cnt_a;
            else if (rd_unit == 7'd26)                 // 0x1A0 描き直しの途中か
                axi_rdata <= {31'd0, busy_a | req_pend};
            else if (rd_unit < NREG-1)
                axi_rdata <= {12'd0, regs[rd_unit]};
            else
                axi_rdata <= 32'd0;
        end
    end

    // ---- 映像クロック領域へ渡す ----
    //   COMMIT のトグルを 2 段同期して、変化を見たら次のフレーム先頭で一括コピー
    reg t0, t1, t2;
    always @(posedge clkv) begin
        t0 <= commit_tgl;
        t1 <= t0;
        t2 <= t1;
    end
    wire pending_w = (t1 != t2);

    reg pending;
    always @(posedge clkv) begin
        if (pending_w)        pending <= 1'b1;
        else if (frame_start) pending <= 1'b0;
    end

    wire load = frame_start & (pending | pending_w);

    initial begin
        v_mirror2  = 1'b0;
        v_text_on  = 1'b0;
        v_kx       = 18'd54828;
        v_z_mirror = 18'd19661;
        v_remain0  = 20'd194970;
        v_inv_tr   = 18'd29127;
        v_cos_t    = 18'd32768;
        v_sin_t    = 18'd0;
        v_nx0 = 18'h304EB; v_ny0 = 18'h031F1; v_wd0 = 18'h01999;
        v_nx1 = 18'h0FB15; v_ny1 = 18'h031F1; v_wd1 = 18'h01999;
        v_nx2 = 18'h00000; v_ny2 = 18'h30000; v_wd2 = 18'h07937;
        v_vx0 = 18'h00000; v_vy0 = 18'h10666;
        v_vx1 = 18'h39B95; v_vy1 = 18'h30D93;
        v_vx2 = 18'h0646B; v_vy2 = 18'h30D93;
        v_spk_en = 1'b0;  v_spk_lv = 3'd5;  v_spk_dens = 8'd0;  v_spk_k = 16'd0;
        v_spk_base = 8'd0;  v_spk_flash = 8'd0;  v_spk_tphase = 8'd0;
        for (j = 0; j < 16; j = j + 1)
            v_spk_cols[j*24 +: 24] = (j % 4 == 2) ? 24'hFFE08C : (j % 4 == 3) ? 24'hBFD9FF : 24'hFFFFFF;
    end

    integer cl;
    always @(posedge clkv) begin
        if (load) begin
            v_mirror2  <= regs[0][0];
            v_text_on  <= regs[0][1];
            v_kx       <= regs[1][17:0];
            v_z_mirror <= regs[2][17:0];
            v_remain0  <= regs[3];
            v_inv_tr   <= regs[4][17:0];
            v_cos_t    <= regs[5][17:0];
            v_sin_t    <= regs[6][17:0];
            v_nx0 <= regs[7][17:0];  v_ny0 <= regs[8][17:0];  v_wd0 <= regs[9][17:0];
            v_nx1 <= regs[10][17:0]; v_ny1 <= regs[11][17:0]; v_wd1 <= regs[12][17:0];
            v_nx2 <= regs[13][17:0]; v_ny2 <= regs[14][17:0]; v_wd2 <= regs[15][17:0];
            v_vx0 <= regs[16][17:0]; v_vy0 <= regs[17][17:0];
            v_vx1 <= regs[18][17:0]; v_vy1 <= regs[19][17:0];
            v_vx2 <= regs[20][17:0]; v_vy2 <= regs[21][17:0];
            v_spk_en     <= spk_regs[0][0];
            v_spk_lv     <= spk_regs[0][3:1];
            v_spk_dens   <= spk_regs[0][11:4];
            v_spk_k      <= spk_regs[1];
            v_spk_base   <= spk_regs[2][7:0];
            v_spk_flash  <= spk_regs[2][15:8];
            v_spk_tphase <= spk_regs[3][7:0];
            for (cl = 0; cl < 16; cl = cl + 1)
                v_spk_cols[cl*24 +: 24] <= spkc_regs[cl];
        end
    end

endmodule
