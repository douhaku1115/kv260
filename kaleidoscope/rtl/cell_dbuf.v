// ============================================================
//  cell_dbuf — セル画像の二重バッファ (段5d-7)
//
//  奥層・手前層をそれぞれ 2 面持ち、「映す面」と「描く面」を分ける。
//  描き終えたら次のフレーム先頭で入れ替えるので、描いている途中の絵は
//  画面に出ない。
//
//  【1 回の描画の流れ】 (draw_req で始まる)
//    S_CLEAR  描く面を下地に戻す。奥層 = 油の地 (ROM から写す)、
//             手前層 = 0 (透明)。65536 クロック = 0.88ms
//    S_START  pdriver に描画開始を 1 クロック出す
//    S_DRAW   pdriver が表を配り終え、並び替え器が止まるまで待つ
//    S_SWAP   次のフレーム先頭で映す面を入れ替える
//    busy はこの間ずっと 1。PS は busy が下りてから次の表を書く。
//
//  【★ 油の地は BRAM の ROM に焼き込む】
//    前は PS が起動時に 65536 語を AXI で流し込んでいた (67ms = 4 フレーム)。
//    毎フレーム描き直すには毎回下地に戻す必要があり、それでは間に合わない。
//    URAM は初期値を持てないが BRAM は持てるので、油の地は BRAM に置いて
//    PL が描く面へ写す。BRAM 約 29 個。
//
//  【URAM の口の割り当て】 URAM は 1 拍に読みか書きのどちらかだけ
//    口A (映す面・描く面とも)   映像が引く。描く面の口A の値は捨てる
//    口B (描く面)               地の復元 / ピースの書き込み / 下の色の先読み
//    口B (映す面の手前層)       影用にずらした位置を読む
//  段5d-6 までは 1 面しかなく、描いている間は影を止めていた。
//  面を分けたので、影は描画中も止まらない。
//
//  読み出し遅延は 2 クロック (cell_uram と同じ)。
// ============================================================

module cell_dbuf
  #(
    parameter AW       = 16,
    parameter OIL_FILE = "cell_oil.hex"
    )
  (
   input  wire              clk,
   input  wire              reset,

   // ---- 映す面を引く (映像) ----
   input  wire [AW-1:0]     back_addr,
   input  wire [AW-1:0]     front_addr,
   input  wire [AW-1:0]     shadow_addr,
   output wire [15:0]       back_d,
   output wire [31:0]       front_d,
   output wire [31:0]       shadow_d,

   // ---- 描く面 (並び替え器) ----
   input  wire              d_we_back,
   input  wire              d_we_front,
   input  wire [AW-1:0]     d_waddr,
   input  wire [AW-1:0]     d_raddr,
   input  wire [31:0]       d_wdata,
   output wire [15:0]       d_rdata_back,
   output wire [31:0]       d_rdata_front,

   // ---- 制御 ----
   input  wire              draw_req,     // 1 クロック。描き直しの開始
   input  wire              frame_start,  // フレーム先頭で 1 クロック
   input  wire              draw_idle,    // pdriver が配り終え、並び替え器も止まった
   output reg               drv_start,    // pdriver へ描画開始 (1 クロック)
   output wire              busy,
   output reg               show_buf      // いま映している面 (0 / 1)
   );

  localparam N = 1 << AW;

  // ---- 状態 ----
  localparam S_IDLE  = 3'd0,
             S_CLEAR = 3'd1,
             S_FLUSH = 3'd2,
             S_START = 3'd3,
             S_WAIT  = 3'd4,
             S_DRAW  = 3'd5,
             S_SWAP  = 3'd6;

  reg [2:0]    st;
  reg [AW-1:0] clr;          // 復元する番地
  reg [1:0]    wcnt;

  assign busy = (st != S_IDLE);

  // ---- 油の地 (BRAM の ROM)。読み出し 2 クロック ----
  (* rom_style = "block" *)
  reg [15:0] oil [0:N-1];
  initial $readmemh(OIL_FILE, oil);

  reg [15:0]   oil_q0, oil_q1;
  reg          clr_v0, clr_v1;      // 復元の書き込みが有効か (ROM の遅れに合わせる)
  reg [AW-1:0] clr_a0, clr_a1;
  wire         clr_issue = (st == S_CLEAR);

  always @(posedge clk) begin
    oil_q0 <= oil[clr];
    oil_q1 <= oil_q0;
    clr_v0 <= clr_issue;
    clr_v1 <= clr_v0;
    clr_a0 <= clr;
    clr_a1 <= clr_a0;
  end

  always @(posedge clk) begin
    drv_start <= 1'b0;
    if (reset) begin
      st       <= S_IDLE;
      clr      <= {AW{1'b0}};
      show_buf <= 1'b0;
      wcnt     <= 2'd0;
    end else begin
      case (st)
        S_IDLE:  if (draw_req) begin
                   clr <= {AW{1'b0}};
                   st  <= S_CLEAR;
                 end
        S_CLEAR: begin
                   // 番地を 1 つずつ出す。書き込みは ROM の 2 クロック遅れで追いかける
                   clr <= clr + 1'b1;
                   if (clr == N - 1) st <= S_FLUSH;
                 end
        S_FLUSH: if (!clr_v1) st <= S_START;      // 最後の書き込みが済んだ
        S_START: begin
                   drv_start <= 1'b1;
                   wcnt      <= 2'd0;
                   st        <= S_WAIT;
                 end
        S_WAIT:  begin
                   // pdriver が動き出して draw_idle が下りるまで数クロック置く
                   wcnt <= wcnt + 2'd1;
                   if (wcnt == 2'd3) st <= S_DRAW;
                 end
        S_DRAW:  if (draw_idle) st <= S_SWAP;
        S_SWAP:  if (frame_start) begin
                   show_buf <= ~show_buf;
                   st       <= S_IDLE;
                 end
        default: st <= S_IDLE;
      endcase
    end
  end

  // ---- 描く面の口B ----
  //   復元中は ROM の値 (奥層) と 0 (手前層) を書く。それ以外は並び替え器
  wire        clearing = clr_v1;
  wire        hb_we    = clearing | d_we_back;
  wire        hf_we    = clearing | d_we_front;
  wire [AW-1:0] hb_addr = clearing ? clr_a1 : (d_we_back  ? d_waddr : d_raddr);
  wire [AW-1:0] hf_addr = clearing ? clr_a1 : (d_we_front ? d_waddr : d_raddr);
  wire [15:0] hb_din  = clearing ? oil_q1 : d_wdata[15:0];
  wire [31:0] hf_din  = clearing ? 32'd0  : d_wdata;

  // 面 i が描く面か
  wire draw0 =  show_buf;     // show_buf=1 なら面 0 を描く
  wire draw1 = ~show_buf;

  // ---- 奥層 2 面 ----
  wire [15:0] b0_a, b1_a, b0_b, b1_b;
  cell_uram #(.DATA_W(16), .AW(AW)) back0_i
    (.clk(clk), .a_addr(back_addr), .a_dout(b0_a),
     .b_addr(hb_addr), .b_we(draw0 & hb_we), .b_din(hb_din), .b_dout(b0_b));
  cell_uram #(.DATA_W(16), .AW(AW)) back1_i
    (.clk(clk), .a_addr(back_addr), .a_dout(b1_a),
     .b_addr(hb_addr), .b_we(draw1 & hb_we), .b_din(hb_din), .b_dout(b1_b));

  // ---- 手前層 2 面。映す面の口B は影を読む ----
  wire [31:0] f0_a, f1_a, f0_b, f1_b;
  cell_uram #(.DATA_W(32), .AW(AW)) front0_i
    (.clk(clk), .a_addr(front_addr), .a_dout(f0_a),
     .b_addr(draw0 ? hf_addr : shadow_addr), .b_we(draw0 & hf_we), .b_din(hf_din),
     .b_dout(f0_b));
  cell_uram #(.DATA_W(32), .AW(AW)) front1_i
    (.clk(clk), .a_addr(front_addr), .a_dout(f1_a),
     .b_addr(draw1 ? hf_addr : shadow_addr), .b_we(draw1 & hf_we), .b_din(hf_din),
     .b_dout(f1_b));

  // ---- 出口を選ぶ。読み出しの 2 クロック遅れに合わせて選択も遅らせる ----
  reg show_d0, show_d1;
  always @(posedge clk) begin
    show_d0 <= show_buf;
    show_d1 <= show_d0;
  end

  assign back_d   = show_d1 ? b1_a : b0_a;
  assign front_d  = show_d1 ? f1_a : f0_a;
  assign shadow_d = show_d1 ? f1_b : f0_b;

  // 描く面は入れ替えの直前まで変わらない (S_SWAP 中は描かない) ので遅らせなくてよい
  assign d_rdata_back  = show_buf ? b0_b : b1_b;
  assign d_rdata_front = show_buf ? f0_b : f1_b;

endmodule
