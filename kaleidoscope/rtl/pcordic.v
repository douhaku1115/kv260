// ============================================================
//  pcordic — ピース演算器の CORDIC
//
//  1 台で 2 つの仕事をする。
//    mode = 0 (ベクトル型)  (x,y) → 角 atan2(y,x) と 長さ hypot(x,y)
//    mode = 1 (回転型)      角 a  → cos(a) と sin(a)
//
//  ピースの 9 種が使う atan2 / hypot / sin / cos はこれで全部まかなえる。
//  乗算器を使わないので DSP を食わない（加算とシフトだけ）。
//
//  数の形式は S6.17 (24bit、±64、分解能 1/131072)。
//  16 段の完全パイプライン。1 クロックに 1 つ入れられる (II=1)。
//  遅延は 16 + 前後の処理で 19 クロック。レーンは 16 画素を束ねて流すので
//  この遅延は隠れる。
//
//  利得: ベクトル型の長さと回転型の出力は CORDIC の利得 K=1.6468 が乗る。
//  回転型は入力を 1/K = 0.60725 にしてから回すので出力はそのまま。
//  ベクトル型は最後に 1/K を掛けて返す (ここだけ乗算器を 1 個使う)。
// ============================================================

module pcordic
  #(
    parameter W    = 24,          // 数の幅
    parameter FRAC = 17,          // 小数部のビット数
    parameter N    = 16           // 段数
    )
  (
   input  wire                  clk,
   input  wire                  vin,      // 1 = この拍の入力は有効
   input  wire                  mode,     // 0 = ベクトル型, 1 = 回転型
   input  wire signed [W-1:0]   ax,       // ベクトル型: x    回転型: 角
   input  wire signed [W-1:0]   ay,       // ベクトル型: y    回転型: 使わない
   output wire                  vout,
   output wire signed [W-1:0]   oang,     // ベクトル型: 角   回転型: sin
   output wire signed [W-1:0]   olen      // ベクトル型: 長さ 回転型: cos
   );

  localparam EW = W + 3;                  // 途中は少し広く持つ (桁あふれ防止)
  localparam signed [EW-1:0] INV_K = 79594;   // 1/1.6468 を S6.17 で

  // 角度表 atan(2^-i)
  reg signed [W-1:0] atan_tab [0:19];
  initial $readmemh("atan_lut.hex", atan_tab);

  // π/2 と π と 2π を S6.17 で
  localparam signed [EW-1:0] HALF_PI = 205887;   // 1.5707963 * 131072
  localparam signed [EW-1:0] PI      = 411775;
  localparam signed [EW-1:0] TWO_PI  = 823550;
  localparam signed [EW-1:0] INV_2PI = 20861;    // 1/(2π) * 131072

  // ---------------- 段0: 角度を ±π に折り返す ----------------
  //  回転型の入力は 60 ラジアンにもなる (ラメの seed*60、天然石の seed*30)。
  //  CORDIC が回せるのは ±π/2 までなので、まず 2π の倍数を引いて落とす。
  //  ★ これが無いと、角度の大きい種類 (ラメ・天然石・丸い塊) だけが壊れる。
  //    角度の小さい種類 (色ガラス・六角柱) は合ってしまうので気づきにくい。
  wire signed [EW-1:0] ex_raw = {{3{ax[W-1]}}, ax};
  wire signed [EW+18-1:0] kq  = ex_raw * INV_2PI;
  wire signed [EW-1:0] kr     = (kq >>> FRAC) + (1 <<< (FRAC-1));   // 四捨五入のため半分足す
  wire signed [6:0]    kint   = kr >>> FRAC;                        // -11 〜 11
  wire signed [EW-1:0] ex_red = ex_raw - kint * TWO_PI;

  reg signed [EW-1:0] exr;
  reg signed [EW-1:0] eyr;
  reg                 vr, mr;
  always @(posedge clk) begin
    vr  <= vin;
    mr  <= mode;
    exr <= mode ? ex_red : ex_raw;      // ベクトル型は折り返さない (座標なので)
    eyr <= {{3{ay[W-1]}}, ay};
  end

  // ---------------- 入口: 象限をたたむ ----------------
  //  ベクトル型: x < 0 なら ±90度 回してから入れる (CORDIC は |角| < 100度 しか回せない)
  //  回転型:     角を [-90度, 90度] に折り、外なら符号を反転して戻す
  reg                  v0;
  reg signed [EW-1:0]  x0, y0, z0;
  reg                  m0, flip0;

  wire signed [EW-1:0] ex = exr;
  wire signed [EW-1:0] ey = eyr;
  wire                 mode_r = mr;

  always @(posedge clk) begin
    v0 <= vr;
    m0 <= mr;
    if (!mode_r) begin
      // ベクトル型
      if (ex >= 0) begin
        x0 <= ex;  y0 <= ey;  z0 <= 0;
      end else if (ey >= 0) begin
        x0 <= ey;  y0 <= -ex; z0 <= HALF_PI;     // +90度 回してから
      end else begin
        x0 <= -ey; y0 <= ex;  z0 <= -HALF_PI;    // -90度 回してから
      end
      flip0 <= 1'b0;
    end else begin
      // 回転型。|角| > 90度 なら 180度 ずらして符号を覚えておく
      if (ex > HALF_PI) begin
        x0 <= INV_K; y0 <= 0; z0 <= ex - PI;  flip0 <= 1'b1;
      end else if (ex < -HALF_PI) begin
        x0 <= INV_K; y0 <= 0; z0 <= ex + PI;  flip0 <= 1'b1;
      end else begin
        x0 <= INV_K; y0 <= 0; z0 <= ex;       flip0 <= 1'b0;
      end
    end
  end

  // ---------------- 本体: N 段 ----------------
  reg                 vp   [0:N];
  reg                 mp   [0:N];
  reg                 fp   [0:N];
  reg signed [EW-1:0] xp   [0:N];
  reg signed [EW-1:0] yp   [0:N];
  reg signed [EW-1:0] zp   [0:N];

  always @(posedge clk) begin
    vp[0] <= v0; mp[0] <= m0; fp[0] <= flip0;
    xp[0] <= x0; yp[0] <= y0; zp[0] <= z0;
  end

  genvar i;
  generate
    for (i = 0; i < N; i = i + 1) begin : stage
      // ベクトル型は y を 0 に寄せる、回転型は z を 0 に寄せる。
      // 回す向きだけが違い、あとは同じ回路
      wire dir = mp[i] ? (zp[i] >= 0) : (yp[i] < 0);
      wire signed [EW-1:0] xs = xp[i] >>> i;
      wire signed [EW-1:0] ys = yp[i] >>> i;
      wire signed [EW-1:0] at = {{3{atan_tab[i][W-1]}}, atan_tab[i]};

      always @(posedge clk) begin
        vp[i+1] <= vp[i];  mp[i+1] <= mp[i];  fp[i+1] <= fp[i];
        if (dir) begin
          xp[i+1] <= xp[i] - ys;
          yp[i+1] <= yp[i] + xs;
          zp[i+1] <= zp[i] - at;
        end else begin
          xp[i+1] <= xp[i] + ys;
          yp[i+1] <= yp[i] - xs;
          zp[i+1] <= zp[i] + at;
        end
      end
    end
  endgenerate

  // ---------------- 出口 ----------------
  //  ベクトル型: 長さに 1/K を掛ける。角はそのまま
  //  回転型:     x=cos, y=sin。180度 ずらしていたら符号を戻す
  wire signed [EW-1:0] fx = xp[N];
  wire signed [EW-1:0] fy = yp[N];
  wire signed [EW-1:0] fz = zp[N];

  wire signed [EW+18-1:0] len_k = fx * INV_K;         // ここだけ乗算器を使う
  wire signed [EW-1:0]    len   = len_k >>> FRAC;

  reg                 v1;
  reg signed [W-1:0]  r_ang, r_len;
  always @(posedge clk) begin
    v1 <= vp[N];
    if (!mp[N]) begin
      r_ang <= fz[W-1:0];
      r_len <= len[W-1:0];
    end else begin
      r_ang <= fp[N] ? -fy[W-1:0] : fy[W-1:0];        // sin
      r_len <= fp[N] ? -fx[W-1:0] : fx[W-1:0];        // cos
    end
  end

  assign vout = v1;
  assign oang = r_ang;
  assign olen = r_len;

endmodule
