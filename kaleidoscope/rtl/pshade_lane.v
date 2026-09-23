// ============================================================
//  pshade_lane — ピース描画の演算器 1 レーン
//
//  種類ごとのプログラムを 1 命令ずつ実行して、画素ごとに
//      A = 不透明度   K = 粒の色に掛ける係数   W = 白を足す量
//  の 3 つを出す。最終色は外で (粒の色 * K + W) * 奥行きの暗さ にする。
//  プログラムが色を扱わないので、RGB 3 本ぶんの演算が要らない。
//
//  【束ねて流す】
//    CORDIC は 19 クロック、表引きは 12 クロックかかる。次の命令が
//    その結果を待つと遅延がそのまま効いてしまうので、1 命令を
//    WARP 個の画素に対して続けて流してから次の命令に移る。
//    WARP > 遅延 なので、次の命令が来る頃には結果が出ている。
//    → 1 命令 1 クロック 1 画素の勘定になる。
//
//    レジスタは画素ごとに要るので、レジスタファイルは
//    32 本 x WARP 個 = 640 語。BRAM に載る。
//
//  命令とレジスタ番号は外の並び替え器 (pshade_seq) が配る。
//  8 レーンで同じ命令を共有するので、命令メモリと解読は 1 組で済む。
//
//  数の形式 S6.17 (24bit、±64、分解能 1/131072)。
// ============================================================

module pshade_lane
  #(
    parameter W     = 24,
    parameter FRAC  = 17,
    // 束ねる画素数。書き戻しは発行から LAT+1 = 23 段目なので、
    // 次の命令が同じ画素を読みに来る WARP 段目がそれより後でなければならない。
    // WARP >= 24。24 なら レジスタ 32 本 x 24 画素 x 24bit = 18432bit で
    // RAMB18 にちょうど収まる。
    parameter WARP  = 24,
    parameter RBITS = 5,         // レジスタ 32 本
    parameter LAT   = 22         // 全命令をこの遅延にそろえる
    )
  (
   input  wire                  clk,

   // ---- 命令 (8 レーン共通) ----
   input  wire                  issue,       // 1 = この拍に 1 画素ぶん発行
   input  wire [5:0]            op,
   input  wire [RBITS-1:0]      rd, ra, rb, rc,
   input  wire signed [W-1:0]   imm0, imm1,
   input  wire [4:0]            slot,        // WARP の何番目か

   // ---- 画素ごとの入り口 (レジスタの初期値を入れるとき) ----
   input  wire                  preload,
   input  wire signed [W-1:0]   pre_val,

   // ---- ピースごとに一定の値 ----
   //   seed / z / e / rot / time は 1 つのピースの中では変わらない。
   //   レジスタファイルへ画素ごとに書くと、それだけで 4 命令ぶん損をする。
   //   r4〜r8 の読み出しをここへ振り向けて、書き込みを無くす。
   input  wire signed [W-1:0]   pc_seed,   // r4
   input  wire signed [W-1:0]   pc_z,      // r5
   input  wire signed [W-1:0]   pc_e,      // r6
   input  wire signed [W-1:0]   pc_rot,    // r7
   input  wire signed [W-1:0]   pc_time,   // r8

   // ---- 出口 ----
   output wire signed [W-1:0]   out_val,
   output wire                  out_we,
   output wire [RBITS-1:0]      out_rd,
   output wire [4:0]            out_slot
   );

  localparam OP_NOP=6'd0,  OP_MOV=6'd1,  OP_LDI=6'd2,  OP_ADD=6'd3,
             OP_SUB=6'd4,  OP_MUL=6'd5,  OP_MADD=6'd6, OP_ADDI=6'd7,
             OP_MULI=6'd8, OP_MADDI=6'd9,OP_MADDC=6'd10,OP_MIN=6'd11,
             OP_MAX=6'd12, OP_MINI=6'd13,OP_MAXI=6'd14, OP_ABS=6'd15,
             OP_NEG=6'd16, OP_FLOOR=6'd17,OP_CLAMP=6'd18,
             OP_LEN=6'd19, OP_ATAN=6'd20, OP_SIN=6'd21, OP_COS=6'd22,
             OP_RECIP=6'd23,OP_SQRT=6'd24,OP_POW=6'd25,OP_EXPN=6'd26,
             OP_SSTEP=6'd27,OP_SSTEPI=6'd28;

  //  番地は {レジスタ番号, スロット番号} をそのままつなぐ。
  //  スロットは 5bit なので、WARP が 24 でも 32 個ぶんの場所を取る。
  //  掛け算で詰めると番地の計算が高くつくので、余らせたまま使う。
  localparam AW = RBITS + 5;
  localparam NW = 1 << AW;                   // 1024 語

  // ============ レジスタファイル ============
  //  読みが 3 本要る (MADD が a,b,c を同時に読む) ので、同じ中身を 3 枚持つ。
  //  書きは 3 枚すべてに同時にする。BRAM の 1 書き 1 読みの形に素直に載る。
  (* ram_style = "block" *) reg signed [W-1:0] rf0 [0:NW-1];
  (* ram_style = "block" *) reg signed [W-1:0] rf1 [0:NW-1];
  (* ram_style = "block" *) reg signed [W-1:0] rf2 [0:NW-1];

  wire [AW-1:0] adr_a = {ra, slot};
  wire [AW-1:0] adr_b = {rb, slot};
  wire [AW-1:0] adr_c = {rc, slot};

  reg signed [W-1:0] va_r, vb_r, vc_r;
  reg [RBITS-1:0]    ra_r, rb_r, rc_r;
  always @(posedge clk) begin
    va_r <= rf0[adr_a];
    vb_r <= rf1[adr_b];
    vc_r <= rf2[adr_c];
    ra_r <= ra;  rb_r <= rb;  rc_r <= rc;
  end

  // r4〜r8 はピースごとの定数。レジスタファイルの値を捨ててこちらを使う
  function signed [W-1:0] pick;
    input [RBITS-1:0]    n;
    input signed [W-1:0] rf;
    begin
      case (n)
        5'd4:    pick = pc_seed;
        5'd5:    pick = pc_z;
        5'd6:    pick = pc_e;
        5'd7:    pick = pc_rot;
        5'd8:    pick = pc_time;
        default: pick = rf;
      endcase
    end
  endfunction

  wire signed [W-1:0] va = pick(ra_r, va_r);
  wire signed [W-1:0] vb = pick(rb_r, vb_r);
  wire signed [W-1:0] vc = pick(rc_r, vc_r);

  // ============ 段1: 発行を 1 段そろえる ============
  reg                v1;
  reg [5:0]          op1;
  reg [RBITS-1:0]    rd1;
  reg [4:0]          slot1;
  reg signed [W-1:0] i0_1, i1_1;
  always @(posedge clk) begin
    v1 <= issue;  op1 <= op;  rd1 <= rd;  slot1 <= slot;
    i0_1 <= imm0; i1_1 <= imm1;
  end

  // ============ 算術 ============
  //  即値を使う命令は b と c の代わりに imm を入れる。掛け算は 1 本で済む。
  wire use_imm_mul = (op1 == OP_MULI) || (op1 == OP_MADDI) || (op1 == OP_MADDC);
  wire signed [W-1:0] mul_x = va;
  wire signed [W-1:0] mul_y = use_imm_mul ? i0_1 : vb;
  wire signed [2*W-1:0] mul_p = mul_x * mul_y;              // ここが DSP
  wire signed [W-1:0]   mul_s = mul_p >>> FRAC;

  wire signed [W-1:0] add_y =
       (op1 == OP_ADDI)  ? i0_1 :
       (op1 == OP_MADDI) ? i1_1 :
       (op1 == OP_MADDC) ? vc   :
       (op1 == OP_MADD)  ? vc   : vb;

  wire signed [W-1:0] cmp_y = ((op1 == OP_MINI) || (op1 == OP_MAXI)) ? i0_1 : vb;

  reg signed [W-1:0] alu2;
  reg                v2;
  reg [5:0]          op2;
  reg [RBITS-1:0]    rd2;
  reg [4:0]          slot2;

  always @(posedge clk) begin
    v2 <= v1;  op2 <= op1;  rd2 <= rd1;  slot2 <= slot1;
    case (op1)
      OP_MOV:   alu2 <= va;
      OP_LDI:   alu2 <= i0_1;
      OP_ADD:   alu2 <= va + vb;
      OP_SUB:   alu2 <= va - vb;
      OP_ADDI:  alu2 <= va + i0_1;
      OP_MUL,
      OP_MULI:  alu2 <= mul_s;
      OP_MADD,
      OP_MADDI,
      OP_MADDC: alu2 <= mul_s + add_y;
      OP_MIN,
      OP_MINI:  alu2 <= (va < cmp_y) ? va : cmp_y;
      OP_MAX,
      OP_MAXI:  alu2 <= (va > cmp_y) ? va : cmp_y;
      OP_ABS:   alu2 <= va[W-1] ? (~va + 1'b1) : va;
      OP_NEG:   alu2 <= ~va + 1'b1;
      OP_FLOOR: alu2 <= {va[W-1:FRAC], {FRAC{1'b0}}};
      OP_CLAMP: alu2 <= (va < i0_1) ? i0_1 : ((va > i1_1) ? i1_1 : va);
      default:  alu2 <= va;
    endcase
  end

  // ============ CORDIC ============
  wire is_cord = (op1 == OP_LEN) || (op1 == OP_ATAN) ||
                 (op1 == OP_SIN) || (op1 == OP_COS);
  wire cord_mode = (op1 == OP_SIN) || (op1 == OP_COS);

  wire               cd_v;
  wire signed [W-1:0] cd_ang, cd_len;
  pcordic #(.W(W), .FRAC(FRAC), .N(16)) cord_i
    (.clk(clk), .vin(v1 & is_cord), .mode(cord_mode),
     .ax(va), .ay(vb), .vout(cd_v), .oang(cd_ang), .olen(cd_len));

  // ============ 表引き ============
  wire is_trans = (op1 >= OP_RECIP) && (op1 <= OP_SSTEPI);
  wire [2:0] tr_op =
       (op1 == OP_RECIP) ? 3'd0 :
       (op1 == OP_SQRT)  ? 3'd1 :
       (op1 == OP_POW)   ? 3'd2 :
       (op1 == OP_EXPN)  ? 3'd3 : 3'd4;
  wire signed [W-1:0] tr_b = (op1 == OP_SSTEPI) ? i0_1 : vb;
  wire signed [W-1:0] tr_c = (op1 == OP_POW)    ? i0_1 :
                             (op1 == OP_SSTEPI) ? i1_1 : vc;

  wire               tr_v;
  wire signed [W-1:0] tr_r;
  ptrans #(.W(W), .FRAC(FRAC)) trans_i
    (.clk(clk), .vin(v1 & is_trans), .op(tr_op),
     .ax(va), .ab(tr_b), .ac(tr_c), .vout(tr_v), .res(tr_r));

  // ============ 遅延をそろえる ============
  //  発行を 0 段目として、各ユニットの結果が出るのは
  //    算術 alu2   … 2 段目
  //    表引き tr_r … 11 段目 (ptrans の中で 10 段 + 入口の 1 段)
  //    CORDIC      … 21 段目 (角度の折り返し 1 + 本体 19 + 入口の 1)
  //  書き戻しは制御信号に合わせて LAT+1 = 23 段目。遅延線の長さは
  //  「結果が出る段 + 1 + (長さ-1) = LAT+1」から決まる。
  //  ★ CORDIC に段を足したらここも必ず直すこと。1 段ずれると
  //    スロット 0 が未定義になり、残りは 1 画素ぶん前の値になる。
  localparam DA = LAT - 1;      // 21
  localparam DT = LAT - 10;     // 12
  localparam DC = LAT - 20;     //  2

  reg signed [W-1:0] dly_a [0:DA-1];
  reg signed [W-1:0] dly_t [0:DT-1];
  reg signed [W-1:0] dly_c_ang [0:DC-1];
  reg signed [W-1:0] dly_c_len [0:DC-1];

  integer k;
  always @(posedge clk) begin
    dly_a[0] <= alu2;
    for (k = 1; k < DA; k = k + 1) dly_a[k] <= dly_a[k-1];
    dly_t[0] <= tr_r;
    for (k = 1; k < DT; k = k + 1) dly_t[k] <= dly_t[k-1];
    dly_c_ang[0] <= cd_ang;  dly_c_len[0] <= cd_len;
    for (k = 1; k < DC; k = k + 1) begin
      dly_c_ang[k] <= dly_c_ang[k-1];
      dly_c_len[k] <= dly_c_len[k-1];
    end
  end

  // 命令の種別と書き先も同じだけ遅らせる
  reg [5:0]       op_d  [0:LAT-1];
  reg [RBITS-1:0] rd_d  [0:LAT-1];
  reg [4:0]       sl_d  [0:LAT-1];
  reg             v_d   [0:LAT-1];
  always @(posedge clk) begin
    op_d[0] <= op1;  rd_d[0] <= rd1;  sl_d[0] <= slot1;  v_d[0] <= v1;
    for (k = 1; k < LAT; k = k + 1) begin
      op_d[k] <= op_d[k-1];  rd_d[k] <= rd_d[k-1];
      sl_d[k] <= sl_d[k-1];  v_d[k]  <= v_d[k-1];
    end
  end

  wire [5:0] fop = op_d[LAT-1];
  wire signed [W-1:0] fres =
       (fop == OP_LEN)  ? dly_c_len[DC-1] :
       (fop == OP_ATAN) ? dly_c_ang[DC-1] :
       (fop == OP_SIN)  ? dly_c_ang[DC-1] :
       (fop == OP_COS)  ? dly_c_len[DC-1] :
       ((fop >= OP_RECIP) && (fop <= OP_SSTEPI)) ? dly_t[DT-1] : dly_a[DA-1];

  wire fwe = v_d[LAT-1] && (fop != OP_NOP);

  // ============ 書き戻し ============
  wire [AW-1:0] wadr = preload ? {rd, slot} : {rd_d[LAT-1], sl_d[LAT-1]};
  wire signed [W-1:0] wval = preload ? pre_val : fres;
  wire we = preload | fwe;

  always @(posedge clk) if (we) begin
    rf0[wadr] <= wval;
    rf1[wadr] <= wval;
    rf2[wadr] <= wval;
  end

  assign out_val  = fres;
  assign out_we   = fwe;
  assign out_rd   = rd_d[LAT-1];
  assign out_slot = sl_d[LAT-1];

endmodule
