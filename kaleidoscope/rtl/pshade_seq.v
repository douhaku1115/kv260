// ============================================================
//  pshade_seq — ピース描画の並び替え器
//
//  ピース表から 1 個ずつ取り、枠の中を走査してセル画像へ描く。
//  **1 つの枠に同じ種類のピースを 4 個まで詰める**（段5d-2）。
//
//  【PS がやること・PL がやること】
//    枠の大きさ・座標の増分・1/r・sin/cos は **PS が計算して渡す**。
//    PL に三角関数も除算も置かずに済む。625 個でも PS 側は 1 フレームに
//    0.3ms 程度で、A53 には軽い。
//
//  【1 枠の流れ】
//    TAKE  入口のピースを自分のレジスタへ取り込み、次のピースを要求する
//    PRE   毎画素の初期値をレーンのレジスタへ書く (種類ごとに 2〜4 個)
//          1 スロットぶんを続けて書いてから座標を 1 つ進める
//          いまのピースが尽きたら、同じ種類の次のピースを同じ枠に混ぜる
//    EXEC  プログラムを 1 命令ずつ、WARP 画素ぶん続けて発行する
//    DRAIN パイプラインが空くまで待つ
//    BLEND 出てきた A/K/W から色を作ってセルへ重ねる (1 画素ずつ)
//
//  【なぜ詰めるのか】(tools/pshade_sched.py で実測)
//    1 枠は LANES*WARP = 192 画素ぶんある。ラメは 1 個 112 画素しかないので、
//    詰めないと枠の 42% が空で回る。全体では無駄 19.3%、上限構成では
//    2.14 フレーム = 20Hz にしかならない。
//
//      枠に混ぜる   既定 271 個        上限 625 個
//        1 個       0.67 本 / 19.3%   2.17 本 / 12.3% → 20Hz
//        2 個       0.54 本 /  4.5%   1.88 本 /  2.3% → 30Hz
//        4 個       0.52 本 /  1.6%   1.84 本 /  0.7% → 30Hz
//        8 個       変わらず           変わらず
//
//    4 個で頭打ちなので 4 個にした。
//
//  【ピースの切り替えはスロット境界だけ】
//    1 スロット = LANES 画素を 8 レーンが同時に処理する。1 つのスロットに
//    2 個のピースを混ぜると、ピースごとの定数 (seed/e/rot・色・奥行きの
//    暗さ) の選択が**レーンごと**に要る。それを避けるため、ピースの
//    画素数をスロット単位に切り上げる。端数 (平均 4 画素/ピース) は
//    lane_valid を落として捨てる。上の表はこの端数を含めて測ったもの。
//
//  【ピースごとの定数は 4 個ぶんのバンクに持つ】
//    枠に 4 個混ざるので、スロットごとに「どのピースか」を 2bit で覚え
//    (cPS)、発行する拍にバンクから選んでレーンへ渡す。
//    レーン側 (pshade_lane.v) は pick() を 1 段遅らせて受ける。
//
//  【まだ割り切っているところ】
//    ・二重バッファ無し → 描き換え中の絵が映る (ちらつく)
//    ・合成が 1 画素ずつ → 1 枠あたり LANES*WARP クロック余計にかかる
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
    parameter CELLB = 8,        // セルの一辺のビット数 (256)
    parameter PMIX  = 4         // 1 つの枠に混ぜられるピースの数
    )
  (
   input  wire                  clk,
   input  wire                  resetn,

   // ---- ピースの供給元から (pdriver / AXI のピース表) ----
   //   p_valid が立っている間、入口には「次に描くピース」が乗っている。
   //   こちらが取り込んだ拍に p_take を 1 クロック返すので、
   //   供給元はその次の拍から**さらに次のピース**を出すこと。
   input  wire                  p_valid,
   output reg                   p_take,
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

  // ============ いま走査しているピース ============
  //  入口の値は p_take のあと「次のピース」に変わってしまうので、
  //  取り込んで自分で持つ。ppixgen と枠の左上の座標はこちらを使う。
  reg [CB-1:0]       cp_bw;
  reg [2*CB-1:0]     cp_npix;
  reg [CELLB-1:0]    cp_x0, cp_y0;
  reg signed [W-1:0] cp_vqx0, cp_vqy0, cp_qx0, cp_qy0;
  reg signed [W-1:0] cp_sx_vqx, cp_sy_vqy, cp_sx_qx, cp_sy_qx, cp_sx_qy, cp_sy_qy;

  // ============ ピースごとの定数バンク (枠に混ざる 4 個ぶん) ============
  reg signed [W-1:0] pb_seed [0:PMIX-1];
  reg signed [W-1:0] pb_e    [0:PMIX-1];
  reg signed [W-1:0] pb_rot  [0:PMIX-1];
  reg signed [W-1:0] pb_time [0:PMIX-1];
  reg [7:0]          pb_cr   [0:PMIX-1];
  reg [7:0]          pb_cg   [0:PMIX-1];
  reg [7:0]          pb_cb   [0:PMIX-1];
  reg signed [W-1:0] pb_depth[0:PMIX-1];
  reg [PMIX-1:0]     pb_premul;

  // ============ 座標を作る ============
  wire [LANES-1:0]      lv;
  wire [LANES*W-1:0]    lvqx, lvqy, lqx, lqy;
  wire [LANES*CB-1:0]   lx, ly;
  // ★ ppixgen を進める信号は「組み合わせ」で出すこと。
  //   レジスタ越しに出すと進むのが 1 拍遅れ、次のスロットが
  //   前のスロットと同じ座標を受け取る。絵は「似ているが形が違う」になる。
  wire                  pg_load, pg_step;

  ppixgen #(.W(W), .LANES(LANES), .CB(CB)) pix_i
    (.clk(clk), .load(pg_load), .bw(cp_bw), .npix(cp_npix),
     .vqx0(cp_vqx0), .vqy0(cp_vqy0), .qx0(cp_qx0), .qy0(cp_qy0),
     .sx_vqx(cp_sx_vqx), .sy_vqy(cp_sy_vqy),
     .sx_qx(cp_sx_qx), .sy_qx(cp_sy_qx), .sx_qy(cp_sx_qy), .sy_qy(cp_sy_qy),
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
  // いま発行しているスロットのピースの定数 (バンクから選んで渡す)
  reg signed [W-1:0]   l_seed, l_e, l_rot, l_time;

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
         .pc_seed(l_seed), .pc_z(24'sd0), .pc_e(l_e),
         .pc_rot(l_rot), .pc_time(l_time),
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
  // スロットごとに「どのピースか」。合成と命令発行の両方で引く。
  // bi_d2 が WARP を少し超えるところまで引くので 32 個とっておく
  reg [1:0]          cPS [0:31];

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
  localparam S_IDLE  = 4'd0, S_TAKE  = 4'd1, S_LOADX = 4'd2, S_LOAD = 4'd3,
             S_PRE   = 4'd4, S_EXEC  = 4'd5, S_DRAIN = 4'd6, S_BLEND = 4'd7,
             S_NEXT  = 4'd8;

  reg [3:0]  st;
  reg [15:0] pc, pc_end;
  reg [4:0]  slot;
  reg [1:0]  pre_i;         // いま何番目のレジスタを入れているか
  reg [3:0]  pmask;
  reg [3:0]  r_type;        // この枠で流すプログラムの種類
  reg [7:0]  drain;
  reg [8:0]  bi;            // 合成の進み (0〜LANES*WARP-1)
  reg [8:0]  bgi;           // 下の色の先読みの進み (S_EXEC 中・段5d-3)
  reg [1:0]  npiece;        // バンクの何番を使っているか (枠をまたいで回る)
  reg [2:0]  nmix;          // この枠に詰めたピースの数
  reg        cur_done;      // いまのピースを配り終えた

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

  // このスロットに配る画素があるか。無ければ、いまのピースは配り終えた
  wire have_pix = |lv;

  // 座標を進めるのは「このスロットの最後の初期値を入れる拍」。組み合わせで出す
  assign pg_step = (st == S_PRE) && have_pix && ({1'b0, pre_i} + 3'd1 >= pre_n);
  // ppixgen の読み込みは取り込みの次の拍 (cp_* が確定してから)
  assign pg_load = (st == S_LOADX);

  // 次のピースを同じ枠に混ぜられるか
  wire can_mix = p_valid && (p_type == r_type) && (nmix + 1 < PMIX);

  integer j;
  always @(posedge clk) begin
    l_issue   <= 1'b0;
    l_preload <= 1'b0;
    p_take    <= 1'b0;
    // cell_we は下の合成のブロックだけが駆動する (2 箇所から書くと多重駆動になる)

    if (!resetn) begin
      st <= S_IDLE;
    end else case (st)

      // ---- 新しい種類のピースから始める ----
      S_IDLE: if (p_valid) begin
        r_type  <= p_type;
        pmask   <= pre_mask[p_type];
        pc      <= prog_base[p_type];
        pc_end  <= prog_base[p_type] + prog_len[p_type];
        npiece  <= 2'd0;
        nmix    <= 3'd0;
        st      <= S_TAKE;
      end

      // ---- 入口のピースを取り込み、次を要求する ----
      //   ここで取り込まないと、p_take のあと入口が変わって
      //   枠の左上の座標 (cAD の元) が次のピースのものになってしまう
      S_TAKE: begin
        cp_bw     <= p_bw;
        cp_npix   <= p_npix;
        cp_x0     <= p_x0;
        cp_y0     <= p_y0;
        cp_vqx0   <= p_vqx0;
        cp_vqy0   <= p_vqy0;
        cp_qx0    <= p_qx0;
        cp_qy0    <= p_qy0;
        cp_sx_vqx <= p_sx_vqx;
        cp_sy_vqy <= p_sy_vqy;
        cp_sx_qx  <= p_sx_qx;
        cp_sy_qx  <= p_sy_qx;
        cp_sx_qy  <= p_sx_qy;
        cp_sy_qy  <= p_sy_qy;
        // ピースごとの定数はバンクへ
        pb_seed [npiece] <= p_seed;
        pb_e    [npiece] <= p_e;
        pb_rot  [npiece] <= p_rot;
        pb_time [npiece] <= p_time;
        pb_cr   [npiece] <= p_cr;
        pb_cg   [npiece] <= p_cg;
        pb_cb   [npiece] <= p_cb;
        pb_depth[npiece] <= p_depth;
        pb_premul[npiece] <= p_premul;
        p_take   <= 1'b1;
        cur_done <= 1'b0;
        st       <= S_LOADX;
      end

      // pg_load をこの拍に出す (cp_* はもう確定している)
      S_LOADX: st <= S_LOAD;

      // ppixgen が値を出すまで 1 クロック置く
      S_LOAD: begin
        pre_i <= 2'd0;
        // ★ 新しい枠のときだけ slot を 0 に戻し、有効ビットを落とす。
        //   ピースを混ぜて戻ってきたとき (nmix > 0) に 0 に戻すと、
        //   いままで埋めたスロットを上書きしてしまう。
        //   cVD も同じで、落とすと前のピースのぶんが消える。
        if (nmix == 3'd0) begin
          slot <= 5'd0;
          cVD  <= {(LANES*WARP){1'b0}};
        end
        st <= S_PRE;
      end

      // ---- 毎画素の初期値を入れる ----
      //   1 スロットぶん (2〜4 個) 入れてから座標を 1 つ進める
      S_PRE: begin
        if (!have_pix) begin
          // このピースは配り終えた。同じ種類の次のピースを同じ枠に混ぜる
          cur_done <= 1'b1;
          if (can_mix) begin
            npiece <= npiece + 2'd1;      // バンクの次の場所へ (枠をまたいで回る)
            nmix   <= nmix + 3'd1;
            st     <= S_TAKE;
          end else begin
            slot <= 5'd0;
            bgi  <= 9'd0;                 // 下の色の先読みを頭から
            st   <= S_EXEC;               // 枠を途中で打ち切って流す
          end
        end else begin
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
            // このスロットの画素の番地・有効かどうか・どのピースかを控える
            for (j = 0; j < LANES; j = j + 1) begin
              cAD[{slot, j[2:0]}] <=
                {(cp_y0 + lyw[j][CELLB-1:0]), (cp_x0 + lxw[j][CELLB-1:0])};
              cVD[{slot, j[2:0]}] <= lv[j];
            end
            cPS[slot] <= npiece;
            pre_i     <= 2'd0;
            if (slot == WARP - 1) begin
              slot <= 5'd0;
              bgi  <= 9'd0;               // 下の色の先読みを頭から
              st   <= S_EXEC;
            end else begin
              slot <= slot + 5'd1;
            end
          end
        end
      end

      // ---- プログラムを流す ----
      //   このあいだに下の色を 192 画素ぶん先読みして cBG へ溜める
      //   (読み出し遅延 2 拍ぶん余分に回す)
      S_EXEC: begin
        if (bgi < LANES*WARP + 2) bgi <= bgi + 9'd1;
        l_issue <= 1'b1;
        l_op    <= ins[63:58];
        l_rd    <= ins[57:53];
        l_ra    <= ins[52:48];
        l_rb    <= ins[28:24];
        l_imm0  <= ins[47:24];
        l_rc    <= ins[4:0];
        l_imm1  <= ins[23:0];
        l_slot  <= slot;
        // このスロットのピースの定数をバンクから選んで渡す。
        // レーン側は pick() を 1 段遅らせて受ける (pshade_lane.v)
        l_seed  <= pb_seed[cPS[slot]];
        l_e     <= pb_e   [cPS[slot]];
        l_rot   <= pb_rot [cPS[slot]];
        l_time  <= pb_time[cPS[slot]];
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
      // 番地の遅れ (bi → bi_d1 → bi_d2) が 2 拍、合成が 2 段 (段5d-4 で
      // 1 段足した) あるので、LANES*WARP より多めに回す。
      // 足りないと枠ごとに末尾の画素が落ちる
      S_BLEND: begin
        if (bi == LANES*WARP + 7) begin
          st <= S_NEXT;
        end else begin
          bi <= bi + 9'd1;
        end
      end

      S_NEXT: begin
        pc <= prog_base[r_type];
        if (!cur_done) begin
          // いまのピースがまだ残っている。新しい枠で続ける。
          // ppixgen は進んだ状態のままなので読み込み直さない
          nmix <= 3'd0;
          st   <= S_LOAD;
        end else begin
          // このピースは描き終えた。次のピースは種類が違うかもしれないので
          // S_IDLE へ戻ってプログラムを引き直す (p_valid が無ければそこで待つ)
          st <= S_IDLE;
        end
      end

    endcase
  end

  // ---- 合成 ----
  //   色 = (粒の色 * K + W) * 奥行きの暗さ、それに α を掛けて重ねる
  //   読みは 1 クロック遅れるので、bi-2 の画素を書く
  reg [8:0] bi_d1, bi_d2;
  always @(posedge clk) begin bi_d1 <= bi; bi_d2 <= bi_d1; end

  // ---- 下の色は S_EXEC 中に先読みして溜めておく (段5d-3) ----
  //
  //  ★ URAM は同じ拍で読むか書くかのどちらかしかできない。合成 (S_BLEND) は
  //    192 画素を連続して**書く**ので、同じ口で読みながら書けない。
  //    S_BLEND を 2 拍に 1 画素にすれば読めるが、上限構成が
  //    1.84 本 → 2.24 本になり **30Hz から 20Hz に落ちる**
  //    (段5d-2 の改善が吹き飛ぶ)。
  //
  //  そこで **S_EXEC 中に 192 画素ぶんを先に読んでレジスタへ溜める**。
  //  S_EXEC は命令数 x WARP 拍あり、いちばん短い三日月でも 432 拍なので
  //  192+2 拍の読みが紛れ込む。**クロックは 1 拍も増えない。**
  //  代わりに 192 x 16bit = 3072 FF を使う。
  //
  //  ★ 読み出し遅延は **2 拍**。cell_uram の口B は b_q0 → b_q1 と
  //    2 段持っている (URAM は出力段を持たせた方が速い)。
  //    1 拍だと思って繋ぐと下の絵が 1 画素ずれる。
  //
  //  【割り切り】同じ枠の中で 2 つのピースが重なると、後のピースは
  //    先のピースの書き込みを見ない (先読みなので)。段5d-2 の時点でも
  //    読みと書きが 1 拍ずれていて同じ制約があった。重なる画素だけの話。
  reg [15:0] cBG [0:LANES*WARP-1];
  reg [8:0]  bgi_d1, bgi_d2;

  always @(posedge clk) begin
    bgi_d1 <= bgi;
    bgi_d2 <= bgi_d1;
    if (st == S_EXEC && bgi_d2 < LANES*WARP) cBG[bgi_d2] <= cell_rdata;
  end

  // 読む番地。S_EXEC 以外の拍に出しても害はない (rtl_top が
  // 書き込みのない拍だけ URAM に渡す)
  assign cell_raddr = (bgi < LANES*WARP) ? cAD[bgi[7:0]] : {AB{1'b0}};

  wire [15:0] bg_px = cBG[bi_d2];

  wire signed [W-1:0] bA = cA[bi_d2];
  wire signed [W-1:0] bK = cK[bi_d2];
  wire signed [W-1:0] bW = cW[bi_d2];

  // この画素がどのピースのものか。色と奥行きの暗さをバンクから選ぶ
  wire [1:0]          bsel    = cPS[bi_d2[8:3]];
  wire [7:0]          b_cr    = pb_cr[bsel];
  wire [7:0]          b_cg    = pb_cg[bsel];
  wire [7:0]          b_cb    = pb_cb[bsel];
  wire signed [W-1:0] b_depth = pb_depth[bsel];
  wire                b_premul = pb_premul[bsel];

  // ---- 色を作る ----
  //   参照実装は (色*K + W) に奥行きの暗さを掛けてから 1.0 で切る。
  //   ★ 先に 255 で切ってから暗さを掛けると、白飛びすべき画素が暗くなる。
  //     青が 255 のはずの所が 206 になって見つけた。順番を守ること。
  //   積は必ず幅を持った wire に受けてから切り出す。
  wire signed [W+10-1:0] kr_m = $signed({1'b0, b_cr}) * bK;
  wire signed [W+10-1:0] kg_m = $signed({1'b0, b_cg}) * bK;
  wire signed [W+10-1:0] kb_m = $signed({1'b0, b_cb}) * bK;
  wire signed [W+10-1:0] tr_q = (kr_m + ($signed(bW) <<< 8)) >>> FRAC;   // 255 超あり
  wire signed [W+10-1:0] tg_q = (kg_m + ($signed(bW) <<< 8)) >>> FRAC;
  wire signed [W+10-1:0] tb_q = (kb_m + ($signed(bW) <<< 8)) >>> FRAC;

  // α。0〜1 を 0〜256 に
  wire [8:0] al = (bA < 0) ? 9'd0 : (bA > (1 <<< FRAC)) ? 9'd256 : bA[FRAC:FRAC-8];

  // ============ ここで 1 段切る (段5d-4) ============
  //
  //  ★ 切らないと「配列の読み (LUTRAM) → 粒の色 x K → + W → x 奥行き →
  //    x α → + 下の色 x (1-α) → 丸め」が **1 本のパス**になる。
  //    段5d-3 の実測で最悪パスは
  //      bi_d2 → cell_wdata   論理段数 32 (DSP 15 + CARRY8 6)、遅延 13.142ns
  //    となり、WNS が +0.045ns しか残らなかった。
  //
  //  合成ログの
  //    RAM Pipeline Warning: Read Address Register Found For RAM cBG_reg.
  //    We will not be able to pipeline it.
  //  もこれが理由。読む番地がレジスタなので Vivado が勝手に段を入れられない。
  //
  //  **「粒の色 x K + W」まで作ったところでレジスタに受ける。**
  //  掛け算 3 段が 2 段と 1 段に分かれ、配列の読みも別の段になる。
  //  S_BLEND が 1 拍伸びるだけで、枠あたり 192 拍は変わらない。
  reg signed [W+10-1:0] tr_1, tg_1, tb_1;   // (粒の色 x K + W)
  reg signed [W-1:0]    dep_1;              // 奥行きの暗さ
  reg [8:0]             al_1;               // α (0〜256)
  reg                   pre_1;              // α をすでに掛けた色か
  reg [15:0]            bgp_1;              // 下の色 (RGB565)
  reg [AB-1:0]          bad_1;              // 書き込み先
  reg                   act_1;              // この画素を書くか

  always @(posedge clk) begin
    tr_1  <= tr_q;
    tg_1  <= tg_q;
    tb_1  <= tb_q;
    dep_1 <= b_depth;
    al_1  <= al;
    pre_1 <= b_premul;
    bgp_1 <= bg_px;
    bad_1 <= cAD[bi_d2];
    act_1 <= (st == S_BLEND) && (bi_d2 < LANES*WARP) && cVD[bi_d2];
  end

  wire [8:0] ia_1 = 9'd256 - al_1;

  // ---- 合成 段2: 奥行きの暗さを掛けて、下の色に重ねる ----
  //   ★ ここではまだ 255 で切らない。
  //     参照実装 (WebGL) が 1.0 に切るのは「色 x α」を書き込むときで、
  //     色そのものではない。先に色を切ると、飽和する画素だけ暗くなる
  //     (青が 331 になる画素で 195.5 のはずが 150.6 になって見つけた)。
  wire signed [W+28-1:0] dr_m = tr_1 * $signed({1'b0, dep_1});
  wire signed [W+28-1:0] dg_m = tg_1 * $signed({1'b0, dep_1});
  wire signed [W+28-1:0] db_m = tb_1 * $signed({1'b0, dep_1});
  wire signed [W+28-1:0] dr_q = dr_m >>> FRAC;
  wire signed [W+28-1:0] dg_q = dg_m >>> FRAC;
  wire signed [W+28-1:0] db_q = db_m >>> FRAC;
  // 負だけ落とし、上は掛け算があふれない範囲 (0〜4095) に収める
  wire [11:0] dr = (dr_q < 0) ? 12'd0 : (dr_q > 4095) ? 12'd4095 : dr_q[11:0];
  wire [11:0] dg = (dg_q < 0) ? 12'd0 : (dg_q > 4095) ? 12'd4095 : dg_q[11:0];
  wire [11:0] db = (db_q < 0) ? 12'd0 : (db_q > 4095) ? 12'd4095 : db_q[11:0];

  // 手前の色に α を掛ける (ラメと気泡は掛けない。α を織り込んだ色が出てくる)
  wire [20:0] pr = pre_1 ? dr * 9'd256 : dr * al_1;
  wire [20:0] pg = pre_1 ? dg * 9'd256 : dg * al_1;
  wire [20:0] pb = pre_1 ? db * 9'd256 : db * al_1;

  // 下の色 (RGB565 から戻す)
  wire [7:0] br_ = {bgp_1[15:11], bgp_1[15:13]};
  wire [7:0] bg_ = {bgp_1[10:5],  bgp_1[10:9]};
  wire [7:0] bb_ = {bgp_1[4:0],   bgp_1[4:2]};

  // 重ねてから 255 相当 (65280) で切る。ここが参照実装の切る場所と同じ
  wire [21:0] mr_w = pr + br_ * ia_1;
  wire [21:0] mg_w = pg + bg_ * ia_1;
  wire [21:0] mb_w = pb + bb_ * ia_1;
  wire [16:0] mr = (mr_w > 22'd65535) ? 17'd65535 : mr_w[16:0];
  wire [16:0] mg = (mg_w > 22'd65535) ? 17'd65535 : mg_w[16:0];
  wire [16:0] mb = (mb_w > 22'd65535) ? 17'd65535 : mb_w[16:0];

  always @(posedge clk) begin
    cell_addr  <= bad_1;
    cell_wdata <= {mr[15:11], mg[15:10], mb[15:11]};
    cell_we    <= act_1;
  end

endmodule
