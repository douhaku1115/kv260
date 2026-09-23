// ============================================================
//  pshade_seq — ピース描画の並び替え器（最小版）
//
//  PS が AXI でピースを 1 個書いて start を立てると、PL が枠の中を走査して
//  その 1 個をセル画像へ描く。段5c を実機で見るための最小構成で、
//  本番で要る「枠に 4 個まで詰める」「二重バッファ」「URAM」は入っていない。
//
//  【PS がやること・PL がやること】
//    枠の大きさ・座標の増分・1/r・sin/cos は **PS が計算して渡す**。
//    PL に三角関数も除算も置かずに済む。625 個でも PS 側は 1 フレームに
//    0.3ms 程度で、A53 には軽い。
//
//  【1 枠の流れ】
//    PRE   毎画素の初期値をレーンのレジスタへ書く (種類ごとに 2〜4 個)
//          1 スロットぶんを続けて書いてから座標を 1 つ進める
//    EXEC  プログラムを 1 命令ずつ、WARP 画素ぶん続けて発行する
//    DRAIN パイプラインが空くまで待つ
//    BLEND 出てきた A/K/W から色を作ってセルへ重ねる (1 画素ずつ)
//
//  【最小版で割り切ったところ】
//    ・枠にピースを詰めない → 小さいピースで枠が余る（実測 8〜12% の無駄）
//    ・合成が 1 画素ずつ → 1 枠あたり LANES*WARP クロック余計にかかる
//    ・二重バッファなし → 描き換え中の絵が映る（ちらつく）
//    どれも本番で直す。まず「PL がピースを描いて HDMI に出る」ことを確かめる。
// ============================================================

module pshade_seq
  #(
    parameter W     = 24,
    parameter FRAC  = 17,
    parameter LANES = 8,
    parameter WARP  = 24,
    parameter LAT   = 22,
    parameter CB    = 9,        // 枠の中の座標
    parameter AB    = 16,       // セルの番地 (256x256 = 65536)
    parameter CELLB = 8         // セルの一辺のビット数 (256)
    )
  (
   input  wire                  clk,
   input  wire                  resetn,

   // ---- PS から (AXI スレーブ経由) ----
   input  wire                  start,      // 1 クロック。ピースを 1 個描く
   input  wire [3:0]            p_type,
   input  wire [CB-1:0]         p_bw,
   input  wire [2*CB-1:0]       p_npix,
   input  wire [CELLB-1:0]      p_x0,       // 枠の左上のセル座標
   input  wire [CELLB-1:0]      p_y0,
   input  wire signed [W-1:0]   p_vqx0, p_vqy0, p_qx0, p_qy0,
   input  wire signed [W-1:0]   p_sx_vqx, p_sy_vqy,
   input  wire signed [W-1:0]   p_sx_qx, p_sy_qx, p_sx_qy, p_sy_qy,
   input  wire signed [W-1:0]   p_seed, p_e, p_rot, p_time,
   input  wire [7:0]            p_cr, p_cg, p_cb,   // 粒の色
   input  wire signed [W-1:0]   p_depth,            // 奥行きの暗さ 0.65〜1.0
   input  wire                  p_premul,           // 1 = すでに α を掛けた色を出す種類
   output wire                  busy,

   // ---- セル画像への書き込み ----
   output reg                   cell_we,
   output reg  [AB-1:0]         cell_addr,
   output reg  [15:0]           cell_wdata,   // RGB565
   input  wire [15:0]           cell_rdata,   // 重ねるために読む
   output wire [AB-1:0]         cell_raddr
   );

  // ---- プログラムの表 ----
  localparam NPROG = 512;
  (* rom_style = "block" *) reg [63:0] prog [0:NPROG-1];
  reg [15:0] prog_base [0:15];
  reg [15:0] prog_len  [0:15];
  initial begin
    $readmemh("pprog.hex", prog);
    $readmemh("pprog_base.hex", prog_base);
    $readmemh("pprog_len.hex",  prog_len);
  end

  // 種類ごとに「毎画素どのレジスタを入れるか」。r0=qx r1=qy r2=vqx r3=vqy
  //   tools/pshade_sched.py の measure_preload() が数えたものと同じ
  reg [3:0] pre_mask [0:15];
  initial $readmemh("pprog_pre.hex", pre_mask);

  // ============ 座標を作る ============
  wire [LANES-1:0]      lv;
  wire [LANES*W-1:0]    lvqx, lvqy, lqx, lqy;
  wire [LANES*CB-1:0]   lx, ly;
  // ★ ppixgen を進める信号は「組み合わせ」で出すこと。
  //   レジスタ越しに出すと進むのが 1 拍遅れ、次のスロットが
  //   前のスロットと同じ座標を受け取る。絵は「似ているが形が違う」になる。
  wire                  pg_load, pg_step;

  ppixgen #(.W(W), .LANES(LANES), .CB(CB)) pix_i
    (.clk(clk), .load(pg_load), .bw(p_bw), .npix(p_npix),
     .vqx0(p_vqx0), .vqy0(p_vqy0), .qx0(p_qx0), .qy0(p_qy0),
     .sx_vqx(p_sx_vqx), .sy_vqy(p_sy_vqy),
     .sx_qx(p_sx_qx), .sy_qx(p_sy_qx), .sx_qy(p_sx_qy), .sy_qy(p_sy_qy),
     .step(pg_step),
     .lane_valid(lv), .lane_vqx(lvqx), .lane_vqy(lvqy),
     .lane_qx(lqx), .lane_qy(lqy), .lane_x(lx), .lane_y(ly), .done());

  // ============ 演算器 ============
  reg                  l_issue, l_preload;
  reg [5:0]            l_op;
  reg [4:0]            l_rd, l_ra, l_rb, l_rc;
  reg signed [W-1:0]   l_imm0, l_imm1;
  reg [4:0]            l_slot;
  reg signed [W-1:0]   l_pre [0:LANES-1];

  wire signed [W-1:0]  o_val  [0:LANES-1];
  wire [LANES-1:0]     o_we;
  wire [4:0]           o_rd   [0:LANES-1];
  wire [4:0]           o_slot [0:LANES-1];

  // 部分選択の結果をさらに切り出すことは Verilog では書けないので、
  // レーンごとの値をいったん受けておく
  wire [CB-1:0]      lxw  [0:LANES-1];
  wire [CB-1:0]      lyw  [0:LANES-1];
  wire signed [W-1:0] vqxw [0:LANES-1];
  wire signed [W-1:0] vqyw [0:LANES-1];
  wire signed [W-1:0] qxw  [0:LANES-1];
  wire signed [W-1:0] qyw  [0:LANES-1];

  genvar g;
  generate
    for (g = 0; g < LANES; g = g + 1) begin : split
      assign lxw[g]  = lx  [(g+1)*CB-1 -: CB];
      assign lyw[g]  = ly  [(g+1)*CB-1 -: CB];
      assign vqxw[g] = lvqx[(g+1)*W-1  -: W];
      assign vqyw[g] = lvqy[(g+1)*W-1  -: W];
      assign qxw[g]  = lqx [(g+1)*W-1  -: W];
      assign qyw[g]  = lqy [(g+1)*W-1  -: W];
    end
  endgenerate

  generate
    for (g = 0; g < LANES; g = g + 1) begin : lanes
      pshade_lane #(.W(W), .FRAC(FRAC), .WARP(WARP), .LAT(LAT)) lane_i
        (.clk(clk), .issue(l_issue), .op(l_op),
         .rd(l_rd), .ra(l_ra), .rb(l_rb), .rc(l_rc),
         .imm0(l_imm0), .imm1(l_imm1), .slot(l_slot),
         .preload(l_preload), .pre_val(l_pre[g]),
         .pc_seed(p_seed), .pc_z(24'sd0), .pc_e(p_e),
         .pc_rot(p_rot), .pc_time(p_time),
         .out_val(o_val[g]), .out_we(o_we[g]),
         .out_rd(o_rd[g]), .out_slot(o_slot[g]));
    end
  endgenerate

  // ============ 結果を受ける ============
  //  A(r29) K(r30) W(r31) と、書き込み先のセル番地・有効かどうかを
  //  レーンとスロットごとに覚えておく
  reg signed [W-1:0] cA [0:LANES*WARP-1];
  reg signed [W-1:0] cK [0:LANES*WARP-1];
  reg signed [W-1:0] cW [0:LANES*WARP-1];
  reg [AB-1:0]       cAD [0:LANES*WARP-1];
  reg [LANES*WARP-1:0] cVD;

  integer gi;
  always @(posedge clk) begin
    for (gi = 0; gi < LANES; gi = gi + 1) begin
      if (o_we[gi]) begin
        if (o_rd[gi] == 5'd29) cA[{o_slot[gi], gi[2:0]}] <= o_val[gi];
        if (o_rd[gi] == 5'd30) cK[{o_slot[gi], gi[2:0]}] <= o_val[gi];
        if (o_rd[gi] == 5'd31) cW[{o_slot[gi], gi[2:0]}] <= o_val[gi];
      end
    end
  end

  // ============ 本体の状態機械 ============
  localparam S_IDLE  = 3'd0, S_LOAD = 3'd1, S_PRE = 3'd2,
             S_EXEC  = 3'd3, S_DRAIN = 3'd4, S_BLEND = 3'd5, S_NEXT = 3'd6;

  reg [2:0]  st;
  reg [15:0] pc, pc_end;
  reg [4:0]  slot;
  reg [1:0]  pre_i;         // いま何番目のレジスタを入れているか
  reg [3:0]  pmask;
  reg [7:0]  drain;
  reg [8:0]  bi;            // 合成の進み (0〜LANES*WARP-1)
  reg [2*CB-1:0] emitted;   // この枠までに配った画素数
  reg        last_group;

  assign busy = (st != S_IDLE);

  wire [63:0] ins = prog[pc[8:0]];

  // 入れるレジスタの番号: マスクの立っているビットを若い順に n 番目
  //   ★ 場合分けを手で書くと 4 個入れる種類 (天然石・ラメ) で
  //     4 個目が 3 個目と同じになり、vqy が未定義のまま残る。
  //     数えて選ぶ形にしておくこと。
  wire [3:0] m = pmask;

  function [4:0] nth_set;
    input [3:0] mk;
    input [1:0] n;
    integer i, c;
    begin
      nth_set = 5'd3;
      c = 0;
      for (i = 0; i < 4; i = i + 1)
        if (mk[i]) begin
          if (c == n) nth_set = i[4:0];
          c = c + 1;
        end
    end
  endfunction

  wire [4:0] pre_reg = nth_set(m, pre_i);
  wire [2:0] pre_n = {2'b0, m[0]} + {2'b0, m[1]} + {2'b0, m[2]} + {2'b0, m[3]};

  // 座標を進めるのは「このスロットの最後の初期値を入れる拍」。組み合わせで出す
  assign pg_step = (st == S_PRE) && ({1'b0, pre_i} + 3'd1 >= pre_n);
  assign pg_load = (st == S_IDLE) && start;

  integer j;
  always @(posedge clk) begin
    l_issue   <= 1'b0;
    l_preload <= 1'b0;
    // cell_we は下の合成のブロックだけが駆動する (2 箇所から書くと多重駆動になる)

    if (!resetn) begin
      st <= S_IDLE;
    end else case (st)

      S_IDLE: if (start) begin
        pmask   <= pre_mask[p_type];
        pc      <= prog_base[p_type];
        pc_end  <= prog_base[p_type] + prog_len[p_type];
        emitted <= {(2*CB){1'b0}};
        st      <= S_LOAD;
      end

      // ppixgen が値を出すまで 1 クロック置く
      S_LOAD: begin
        slot  <= 5'd0;
        pre_i <= 2'd0;
        cVD   <= {(LANES*WARP){1'b0}};
        st    <= S_PRE;
      end

      // ---- 毎画素の初期値を入れる ----
      //   1 スロットぶん (2〜4 個) 入れてから座標を 1 つ進める
      S_PRE: begin
        l_preload <= 1'b1;
        l_rd      <= pre_reg;
        l_slot    <= slot;
        for (j = 0; j < LANES; j = j + 1)
          l_pre[j] <= (pre_reg == 5'd0) ? qxw[j] :
                      (pre_reg == 5'd1) ? qyw[j] :
                      (pre_reg == 5'd2) ? vqxw[j] : vqyw[j];

        if (pre_i + 1 < pre_n) begin
          pre_i <= pre_i + 2'd1;
        end else begin
          // このスロットの画素の番地と有効かどうかを控える
          for (j = 0; j < LANES; j = j + 1) begin
            cAD[{slot, j[2:0]}] <=
              {(p_y0 + lyw[j][CELLB-1:0]), (p_x0 + lxw[j][CELLB-1:0])};
            cVD[{slot, j[2:0]}] <= lv[j];
          end
          pre_i   <= 2'd0;
          emitted <= emitted + LANES;
          if (slot == WARP - 1) begin
            slot <= 5'd0;
            st   <= S_EXEC;
          end else begin
            slot <= slot + 5'd1;
          end
        end
      end

      // ---- プログラムを流す ----
      S_EXEC: begin
        l_issue <= 1'b1;
        l_op    <= ins[63:58];
        l_rd    <= ins[57:53];
        l_ra    <= ins[52:48];
        l_rb    <= ins[28:24];
        l_imm0  <= ins[47:24];
        l_rc    <= ins[4:0];
        l_imm1  <= ins[23:0];
        l_slot  <= slot;
        if (slot == WARP - 1) begin
          slot <= 5'd0;
          if (pc + 1 == pc_end) begin
            drain <= LAT + 8;
            st    <= S_DRAIN;
          end else begin
            pc <= pc + 16'd1;
          end
        end else begin
          slot <= slot + 5'd1;
        end
      end

      S_DRAIN: begin
        if (drain == 0) begin
          bi <= 9'd0;
          st <= S_BLEND;
        end else drain <= drain - 8'd1;
      end

      // ---- セルへ重ねる (1 画素ずつ) ----
      // 読み出しが 1 拍、番地の遅れが 2 拍あるので、数えるのは
      // LANES*WARP より 3 多く回す。そうしないと枠ごとに末尾が落ちる
      S_BLEND: begin
        if (bi == LANES*WARP + 6) begin
          st <= S_NEXT;
        end else begin
          bi <= bi + 9'd1;
        end
      end

      S_NEXT: begin
        if (emitted >= p_npix) begin
          st <= S_IDLE;                       // このピースは描き終えた
        end else begin
          pc   <= prog_base[p_type];
          slot <= 5'd0;
          pre_i <= 2'd0;
          cVD  <= {(LANES*WARP){1'b0}};
          st   <= S_PRE;                      // 次の枠へ
        end
      end

    endcase
  end

  // ---- 合成 ----
  //   色 = (粒の色 * K + W) * 奥行きの暗さ、それに α を掛けて重ねる
  //   読みは 1 クロック遅れるので、bi-2 の画素を書く
  reg [8:0] bi_d1, bi_d2;
  always @(posedge clk) begin bi_d1 <= bi; bi_d2 <= bi_d1; end

  // 背景の読み出し。メモリの遅延が 1 拍なので、使う拍 (bi_d2) の
  // 1 つ前 (bi_d1) の番地を出す。ここがずれると下の絵と混ざる位置が狂う
  assign cell_raddr = cAD[bi_d1];


  wire signed [W-1:0] bA = cA[bi_d2];
  wire signed [W-1:0] bK = cK[bi_d2];
  wire signed [W-1:0] bW = cW[bi_d2];

  // ---- 色を作る ----
  //   参照実装は (色*K + W) に奥行きの暗さを掛けてから 1.0 で切る。
  //   ★ 先に 255 で切ってから暗さを掛けると、白飛びすべき画素が暗くなる。
  //     青が 255 のはずの所が 206 になって見つけた。順番を守ること。
  //   積は必ず幅を持った wire に受けてから切り出す。
  wire signed [W+10-1:0] kr_m = $signed({1'b0, p_cr}) * bK;
  wire signed [W+10-1:0] kg_m = $signed({1'b0, p_cg}) * bK;
  wire signed [W+10-1:0] kb_m = $signed({1'b0, p_cb}) * bK;
  wire signed [W+10-1:0] tr_q = (kr_m + ($signed(bW) <<< 8)) >>> FRAC;   // 255 超あり
  wire signed [W+10-1:0] tg_q = (kg_m + ($signed(bW) <<< 8)) >>> FRAC;
  wire signed [W+10-1:0] tb_q = (kb_m + ($signed(bW) <<< 8)) >>> FRAC;

  // 奥行きの暗さを掛ける。★ ここではまだ 255 で切らない。
  //   参照実装 (WebGL) が 1.0 に切るのは「色 x α」を書き込むときで、
  //   色そのものではない。先に色を切ると、飽和する画素だけ暗くなる
  //   (青が 331 になる画素で 195.5 のはずが 150.6 になって見つけた)。
  wire signed [W+28-1:0] dr_m = tr_q * $signed({1'b0, p_depth});
  wire signed [W+28-1:0] dg_m = tg_q * $signed({1'b0, p_depth});
  wire signed [W+28-1:0] db_m = tb_q * $signed({1'b0, p_depth});
  wire signed [W+28-1:0] dr_q = dr_m >>> FRAC;
  wire signed [W+28-1:0] dg_q = dg_m >>> FRAC;
  wire signed [W+28-1:0] db_q = db_m >>> FRAC;
  // 負だけ落とし、上は掛け算があふれない範囲 (0〜4095) に収める
  wire [11:0] dr = (dr_q < 0) ? 12'd0 : (dr_q > 4095) ? 12'd4095 : dr_q[11:0];
  wire [11:0] dg = (dg_q < 0) ? 12'd0 : (dg_q > 4095) ? 12'd4095 : dg_q[11:0];
  wire [11:0] db = (db_q < 0) ? 12'd0 : (db_q > 4095) ? 12'd4095 : db_q[11:0];

  // α。0〜1 を 0〜256 に
  wire [8:0] al = (bA < 0) ? 9'd0 : (bA > (1 <<< FRAC)) ? 9'd256 : bA[FRAC:FRAC-8];
  wire [8:0] ia = 9'd256 - al;

  // 手前の色に α を掛ける (ラメと気泡は掛けない。α を織り込んだ色が出てくる)
  wire [20:0] pr = p_premul ? dr * 9'd256 : dr * al;
  wire [20:0] pg = p_premul ? dg * 9'd256 : dg * al;
  wire [20:0] pb = p_premul ? db * 9'd256 : db * al;

  // 下の色 (RGB565 から戻す)
  wire [7:0] br_ = {cell_rdata[15:11], cell_rdata[15:13]};
  wire [7:0] bg_ = {cell_rdata[10:5],  cell_rdata[10:9]};
  wire [7:0] bb_ = {cell_rdata[4:0],   cell_rdata[4:2]};

  // 重ねてから 255 相当 (65280) で切る。ここが参照実装の切る場所と同じ
  wire [21:0] mr_w = pr + br_ * ia;
  wire [21:0] mg_w = pg + bg_ * ia;
  wire [21:0] mb_w = pb + bb_ * ia;
  wire [16:0] mr = (mr_w > 22'd65535) ? 17'd65535 : mr_w[16:0];
  wire [16:0] mg = (mg_w > 22'd65535) ? 17'd65535 : mg_w[16:0];
  wire [16:0] mb = (mb_w > 22'd65535) ? 17'd65535 : mb_w[16:0];

  always @(posedge clk) begin
    cell_addr  <= cAD[bi_d2];
    cell_wdata <= {mr[15:11], mg[15:10], mb[15:11]};
    cell_we    <= (st == S_BLEND) && (bi_d2 < LANES*WARP) && cVD[bi_d2];
  end

endmodule
