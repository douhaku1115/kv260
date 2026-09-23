// ============================================================
//  ptrans — ピース演算器の「表を引く」側
//
//  log2 と exp2 の 2 枚の表だけで、次を全部まかなう。
//    RECIP  1/x          = exp2(   -log2(x))
//    SQRT   √x           = exp2( 0.5*log2(x))
//    POW    x^n          = exp2(   n*log2(x))
//    EXPN   exp(-x)      = exp2(-1.4427*x)        ← log2 を通さない
//    SSTEP  smoothstep   = (x-a)/(b-a) を丸めて t*t*(3-2t)
//                          割り算は 1/(b-a) として上の RECIP 経路を通る
//
//  専用の除算器も平方根器も要らない。ピースの 9 種が使う
//  除算 7 回・平方根 4 回・pow 5 回・exp 6 回がこの 1 台に集まる。
//
//  数の形式 S6.17 (24bit)。完全パイプライン (II=1)、遅延 12 クロック。
// ============================================================

module ptrans
  #(
    parameter W    = 24,
    parameter FRAC = 17,
    parameter LB   = 11,       // 表の索引ビット数 (2048 点)
    parameter VB   = 18        // 表の値のビット数
    )
  (
   input  wire                 clk,
   input  wire                 vin,
   input  wire [2:0]           op,      // 0=RECIP 1=SQRT 2=POW 3=EXPN 4=SSTEP
   input  wire signed [W-1:0]  ax,      // x
   input  wire signed [W-1:0]  ab,      // SSTEP の a
   input  wire signed [W-1:0]  ac,      // SSTEP の b、POW の n
   output wire                 vout,
   output wire signed [W-1:0]  res
   );

  localparam OP_RECIP = 3'd0, OP_SQRT = 3'd1, OP_POW = 3'd2,
             OP_EXPN  = 3'd3, OP_SSTEP = 3'd4;

  localparam signed [W-1:0] LOG2E = 189082;   // 1.442695 * 131072

  reg [VB-1:0] log2_tab [0:(1<<LB)-1];
  reg [VB-1:0] exp2_tab [0:(1<<LB)-1];
  initial begin
    $readmemh("log2_lut.hex", log2_tab);
    $readmemh("exp2_lut.hex", exp2_tab);
  end

  // ---------------- 段1: 入口 ----------------
  //  SSTEP は 1/(b-a) が要るので、表に入れるのは (b-a)。
  //  他は x をそのまま。EXPN だけ log2 を飛ばす。
  reg                 v1;
  reg [2:0]           op1;
  reg signed [W-1:0]  num1;          // SSTEP の (x-a)。他では使わない
  reg signed [W-1:0]  arg1;          // 表に入れる値
  reg signed [W-1:0]  coef1;         // log2 に掛ける係数

  always @(posedge clk) begin
    v1  <= vin;
    op1 <= op;
    num1 <= ax - ab;
    case (op)
      OP_RECIP: begin arg1 <= ax;      coef1 <= -(1 <<< FRAC);        end
      OP_SQRT:  begin arg1 <= ax;      coef1 <=  (1 <<< (FRAC-1));    end
      OP_POW:   begin arg1 <= ax;      coef1 <=  ac;                  end
      OP_EXPN:  begin arg1 <= ax;      coef1 <= -LOG2E;               end
      default:  begin arg1 <= ac - ab; coef1 <= -(1 <<< FRAC);        end  // SSTEP
    endcase
  end

  wire skip_log1 = (op1 == OP_EXPN);

  // ---------------- 段2: 正規化 (先頭の 1 を探す) ----------------
  wire [W-1:0] mag = arg1[W-1] ? (~arg1 + 1'b1) : arg1;

  reg [4:0] msb;
  integer b;
  always @* begin
    msb = 5'd0;
    for (b = 0; b < W; b = b + 1)
      if (mag[b]) msb = b[4:0];
  end

  // 仮数: 先頭の 1 を bit(W-1) へ寄せ、その下の LB ビットを取る。
  //   ★ ここを shifted[W*2-2 -: LB] と書くと 24bit ずれて表が別の場所を指す。
  //     x=0.5 で仮数 0 になり、log2 も 1/x も √x も全部狂う。
  wire [W*2-1:0] shifted = {{W{1'b0}}, mag} << (W - 1 - msb);
  wire [LB-1:0]  mant    = shifted[W-2 -: LB];

  // 指数部 (msb - FRAC) を S6.17 で。幅を先に W に広げてから引き算とシフトをする
  // (23bit のまま <<< すると上が落ちる)
  wire signed [W-1:0] msb_s  = {{(W-5){1'b0}}, msb};
  wire signed [W-1:0] expo_v = (msb_s - FRAC) <<< FRAC;

  reg                v2;
  reg [2:0]          op2;
  reg signed [W-1:0] num2, coef2;
  reg signed [W-1:0] expo2;          // 指数部 (msb - FRAC) を S6.17 で
  reg [LB-1:0]       mant2;
  reg                skip2;
  reg signed [W-1:0] raw2;           // EXPN 用に x をそのまま送る
  reg                zero2;

  always @(posedge clk) begin
    v2 <= v1;  op2 <= op1;  num2 <= num1;  coef2 <= coef1;
    mant2 <= mant;  skip2 <= skip_log1;  raw2 <= arg1;
    zero2 <= (mag == 0);
    expo2 <= expo_v;
  end


  // ---------------- 段3: log2 を引いて足す ----------------
  reg signed [W-1:0] lg3, coef3, num3, raw3;
  reg [2:0] op3;
  reg       v3, skip3, zero3;
  reg [VB-1:0] lg_q;

  always @(posedge clk) lg_q <= log2_tab[mant2];

  reg signed [W-1:0] expo3;
  reg [2:0] op3d;
  reg v3d, skip3d, zero3d;
  reg signed [W-1:0] coef3d, num3d, raw3d;
  always @(posedge clk) begin
    expo3 <= expo2; coef3d <= coef2; num3d <= num2; raw3d <= raw2;
    op3d <= op2; v3d <= v2; skip3d <= skip2; zero3d <= zero2;
  end

  always @(posedge clk) begin
    // log2(x) = 指数部 + 表(仮数)
    //   表は「1.0〜2.0 の log2」を VB=18 bit の小数で持っている。
    //   FRAC=17 に合わせるので 1 bit 右へ落とす。
    //   ★ ここを (1<<<(FRAC-VB+1))/2 と書くと整数割り算で 0 になり、
    //     表の中身が丸ごと消える。シフトで書くこと。
    lg3   <= expo3 + $signed({{(W-VB){1'b0}}, lg_q} >> (VB - FRAC));
    coef3 <= coef3d; num3 <= num3d; raw3 <= raw3d;
    op3   <= op3d;   v3 <= v3d;     skip3 <= skip3d;  zero3 <= zero3d;
  end

  // ---------------- 段4: 係数を掛ける ----------------
  wire signed [W-1:0] base = skip3 ? raw3 : lg3;
  wire signed [2*W-1:0] prod = base * coef3;

  reg signed [W+6-1:0] yv4;
  reg [2:0] op4;
  reg       v4, zero4;
  reg signed [W-1:0] num4;
  always @(posedge clk) begin
    yv4  <= prod >>> FRAC;
    op4  <= op3; v4 <= v3; num4 <= num3; zero4 <= zero3;
  end

  // ---------------- 段5: exp2 ----------------
  //  y = i + f  →  2^y = 2^i * (1 + 表(f))
  wire signed [W+6-1:0] y = yv4;
  wire signed [W-1:0]   yi = y >>> FRAC;                 // 整数部
  wire [LB-1:0]         yf = y[FRAC-1 -: LB];            // 小数部の上位 LB ビット

  reg [VB-1:0] ex_q;
  always @(posedge clk) ex_q <= exp2_tab[yf];

  reg signed [W-1:0] yi5, num5;
  reg [2:0] op5;
  reg       v5, zero5;
  always @(posedge clk) begin
    yi5 <= yi; op5 <= op4; v5 <= v4; num5 <= num4; zero5 <= zero4;
  end

  // 1 + 表(f) を S6.17 にして 2^i ぶんシフト
  //   {01, ex_q} は 1.f を VB=18 bit の小数で表したもの。FRAC=17 へ 1 bit 落とす
  wire [W+VB:0] mnt = {{(W-1){1'b0}}, 2'b01, ex_q} >> (VB - FRAC);
  wire signed [W+8-1:0] sh = (yi5 >= 0)
                           ? ($signed({{8{1'b0}}, mnt[W-1:0]}) <<< yi5[4:0])
                           : ($signed({{8{1'b0}}, mnt[W-1:0]}) >>> (-yi5[4:0]));

  wire ovf  = (yi5 >  6);
  wire udf  = (yi5 < -20) || zero5;
  wire signed [W-1:0] e2 = ovf ? {1'b0, {(W-1){1'b1}}} : (udf ? {W{1'b0}} : sh[W-1:0]);

  reg signed [W-1:0] e2r, num6;
  reg [2:0] op6;
  reg       v6;
  always @(posedge clk) begin
    e2r <= e2; op6 <= op5; v6 <= v5; num6 <= num5;
  end

  // ---------------- 段6: SSTEP の仕上げ ----------------
  //  t = clamp((x-a) * 1/(b-a), 0, 1) ;  結果 = t*t*(3-2t)
  wire signed [2*W-1:0] tprod = num6 * e2r;
  wire signed [W-1:0]   traw  = tprod >>> FRAC;
  wire signed [W-1:0]   tclp  = (traw < 0) ? {W{1'b0}}
                              : (traw > (1 <<< FRAC)) ? (1 <<< FRAC) : traw;

  reg signed [W-1:0] t7, e27;
  reg [2:0] op7;
  reg       v7;
  always @(posedge clk) begin
    t7 <= tclp; e27 <= e2r; op7 <= op6; v7 <= v6;
  end

  wire signed [2*W-1:0] t2p = t7 * t7;
  wire signed [W-1:0]   t2  = t2p >>> FRAC;
  wire signed [W-1:0]   u   = (3 <<< FRAC) - (t7 <<< 1);

  reg signed [W-1:0] t2_8, u8, e28;
  reg [2:0] op8;
  reg       v8;
  always @(posedge clk) begin
    t2_8 <= t2; u8 <= u; e28 <= e27; op8 <= op7; v8 <= v7;
  end

  wire signed [2*W-1:0] sp = t2_8 * u8;

  reg signed [W-1:0] r9;
  reg                v9;
  always @(posedge clk) begin
    v9 <= v8;
    r9 <= (op8 == OP_SSTEP) ? (sp >>> FRAC) : e28;
  end

  assign vout = v9;
  assign res  = r9;

endmodule
