// ============================================================
//  pdriver — 焼き込んだピースの表を順に並び替え器へ流す
//
//  pparts.hex に入れておいたピースを頭から 1 個ずつ pshade_seq へ渡し、
//  最後まで行ったら止まる。本番ではここが AXI のピース表になり、
//  物理演算の結果を毎フレーム受けて描き直す。
//
//  【★ 描き始めるのは PS が 0x1A0 DRAW_REQ を書いてから (段5d-6)】
//    前は起動後 4095 クロック (55μs) 待つだけだった。ところが PS の
//    セル流し込みは **67ms** かかる。PL は 10ms で 271 個を描き終えるので、
//    **PL が先に描き、あとから来る流し込みが全部上書きしていた。**
//    段5d-5 の実機で「操作画面は出るが絵が出ない」となって判明した。
//
//  【渡し方】
//    p_valid を立てて入口にピースを乗せておく。並び替え器が取り込むと
//    p_take が 1 クロック返ってくるので、次のピースを読み込んで出す。
//
//  【★ 表は 1 語ずつ読む (段5d-5 で直した)】
//    前は 24 語を `tab[base+0]` 〜 `tab[base+23]` と**同時に**引いていた。
//    64 個 (1536 語) のうちは収まっていたが、手前層も描くために
//    271 個 (6504 語) に増やしたら、**24 本ぶんの巨大なマルチプレクサ**に
//    なって LUT が 30769 個も増え、配置できなくなった。
//
//      ERROR: [Place 30-487] ... 9933 CLBs are available,
//             however, the unplaced instances require 10088 CLBs
//
//    BRAM は読み口が 2 本しかないので、24 本同時には引けない。
//    **1 語ずつ 24 クロックかけて読み、レジスタへ溜めてから渡す。**
//    1 枠は 1600 クロックほどなので、24 クロックは無視できる。
//
//  【表は種類ごとにまとまっていること】
//    1 つの枠には同じ種類のピースしか入れられない (プログラムが違う)。
//    tools/gen_pparts.py が種類ごとにまとめ、種類の中は z 順に並べてある。
//    並んでいないと詰まらず、ただ遅くなる (壊れはしない)。
//
//  1 個あたり 24 語 x 24bit。並びは tools/gen_pparts.py と揃えてある。
//  23 語目の bit0 = premul、bit1 = 手前層か。
// ============================================================

module pdriver
  #(
    parameter W      = 24,
    parameter WORDS  = 24,          // 1 個あたりの語数
    parameter NPIECE = 271,         // 表に入っている個数
    parameter CB     = 9,
    parameter CELLB  = 8
    )
  (
   input  wire                  clk,
   input  wire                  resetn,
   input  wire                  p_take,     // 並び替え器が 1 個取り込んだ
   input  wire                  draw_req,   // 1 クロック。これが来たら描き始める

   output wire                  p_valid,    // 入口にピースが乗っている
   output wire [3:0]            p_type,
   output wire [CB-1:0]         p_bw,
   output wire [2*CB-1:0]       p_npix,
   output wire [CELLB-1:0]      p_x0,
   output wire [CELLB-1:0]      p_y0,
   output wire signed [W-1:0]   p_vqx0, p_vqy0, p_qx0, p_qy0,
   output wire signed [W-1:0]   p_sx_vqx, p_sy_vqy,
   output wire signed [W-1:0]   p_sx_qx, p_sy_qx, p_sx_qy, p_sy_qy,
   output wire signed [W-1:0]   p_seed, p_e, p_rot, p_time,
   output wire [7:0]            p_cr, p_cg, p_cb,
   output wire signed [W-1:0]   p_depth,
   output wire                  p_premul,
   output wire                  p_front,    // 1 = 手前層のピース
   output wire                  all_done
   );

  (* rom_style = "block" *)
  reg [W-1:0] tab [0:NPIECE*WORDS-1];
  initial $readmemh("pparts.hex", tab);

  // 読み出しは 1 本だけ。これなら BRAM に載る
  //  ★ 番地は**組み合わせ**で作ること。レジスタにすると番地が 1 拍遅れ、
  //    溜める拍 (wi_d1) とずれて 1 語ぶん前の値が入る。
  reg  [W-1:0]  rdata;
  reg  [15:0]   idx;
  reg  [4:0]    wi;
  wire [17:0]   raddr = idx * WORDS + wi;
  always @(posedge clk) rdata <= tab[raddr];

  // 24 語を溜める場所。ここは普通のレジスタ (小さい)
  reg [W-1:0] cur [0:WORDS-1];

  reg [4:0]  wi_d1;            // 溜める先 (読み出しが 1 拍遅れるぶん)
  reg        rd_v_d1;
  reg        warm_done;        // PS から描画開始が来た
  reg        ready;            // 24 語そろった

  wire done = (idx >= NPIECE);

  //  ★ 読み出し中かどうかは**組み合わせ**で出すこと。
  //    レジスタにすると 1 拍遅れて立ち、**最初の語 (cur[0]) を取りこぼす**。
  //    症状: p_type だけが x のまま (他の語は 1 つずれずに合っている)
  wire rd_v = warm_done && !done && !ready;

  assign p_valid  = ready && !done;
  assign all_done = done;

  always @(posedge clk) begin
    wi_d1    <= wi;
    rd_v_d1  <= rd_v;
    if (rd_v_d1) cur[wi_d1] <= rdata;      // 読めた語を溜める

    if (!resetn) begin
      idx <= 16'd0; wi <= 5'd0; ready <= 1'b0;
      warm_done <= 1'b0;
    end else if (!warm_done) begin
      // ★ 起動しただけでは描き始めない。**PS が 0x1A0 を書くまで待つ。**
      //   前は 4095 クロック (55μs) 待つだけだったが、PS のセル流し込みは
      //   67ms かかる。PL が先に 10ms で描き終わってしまい、あとから来る
      //   流し込みに**全部上書きされていた** (段5d-5 の実機で判明)。
      if (draw_req) warm_done <= 1'b1;
    end else if (done) begin
      ready <= 1'b0;
    end else if (!ready) begin
      // 24 語を順に読む。番地は組み合わせ (raddr) なので、
      // 出した次の拍に rdata が来て cur[wi_d1] へ入る
      if (wi == WORDS - 1) begin
        // 最後の語が溜まったら終わり
        if (rd_v_d1 && wi_d1 == WORDS - 1) ready <= 1'b1;
      end else begin
        wi <= wi + 5'd1;
      end
    end else if (p_take) begin
      idx   <= idx + 16'd1;
      wi    <= 5'd0;
      ready <= 1'b0;
    end
  end

  // 溜めた 24 語をそのまま並び替え器の入り口へつなぐ
  assign p_type   = cur[ 0][3:0];
  assign p_bw     = cur[ 1][CB-1:0];
  assign p_npix   = cur[ 2][2*CB-1:0];
  assign p_x0     = cur[ 3][CELLB-1:0];
  assign p_y0     = cur[ 4][CELLB-1:0];
  assign p_vqx0   = cur[ 5];
  assign p_vqy0   = cur[ 6];
  assign p_qx0    = cur[ 7];
  assign p_qy0    = cur[ 8];
  assign p_sx_vqx = cur[ 9];
  assign p_sy_vqy = cur[10];
  assign p_sx_qx  = cur[11];
  assign p_sy_qx  = cur[12];
  assign p_sx_qy  = cur[13];
  assign p_sy_qy  = cur[14];
  assign p_seed   = cur[15];
  assign p_e      = cur[16];
  assign p_rot    = cur[17];
  assign p_time   = cur[18];
  assign p_cr     = cur[19][7:0];
  assign p_cg     = cur[20][7:0];
  assign p_cb     = cur[21][7:0];
  assign p_depth  = cur[22];
  assign p_premul = cur[23][0];
  assign p_front  = cur[23][1];

endmodule
