// ============================================================
//  ppixgen — ピースの枠の中を走査して、レーンごとの座標を作る
//
//  1 つのピースの枠 (幅 w、高さ h) を「左上から右へ、行が尽きたら次の行」の
//  順に数えたとき、レーン k は k 番目・k+L 番目・k+2L 番目 … を受け持つ。
//  step を 1 回叩くと全レーンが L 画素ぶん進む。
//
//  【行をまたいで詰める】
//    行ごとに L 画素で区切ると、幅が L の倍数でないぶんが毎行こぼれる。
//    実測で無駄 8.7〜11.7% (ラメが 22%)。行をまたいで詰めると 0.5〜0.9%。
//    上限構成では 1.81 フレーム → 1.97 フレームの差になり、境界に触れる。
//
//  【幅は 8 以上に丸めてある】
//    x += L したときの行送りを「条件付きの引き算 1 回」で済ませるため、
//    並び替え器が w >= L にして渡す。代償は実測 +0.2〜0.3% だけ。
//
//  【座標は掛け算を使わず足し算で作る】
//    vqx は x が 1 進むごとに一定量 sx だけ増える。qx / qy も同じ
//    (qx は x 方向に ca*sx、y 方向に -sa*sx)。だから加算器だけで足りる。
//    回転の掛け算をプログラムに入れずに済む。
//
//  数の形式 S6.17 (24bit)。
// ============================================================

module ppixgen
  #(
    parameter W     = 24,
    parameter LANES = 8,
    parameter CB    = 9        // 枠の座標のビット数 (セル 256 なら 9 で足りる)
    )
  (
   input  wire                     clk,

   // ---- ピースを 1 つ読み込む ----
   input  wire                     load,
   input  wire [CB-1:0]            bw,        // 枠の幅 (LANES 以上)
   input  wire [2*CB-1:0]          npix,      // 枠の画素数 = bw * bh
   input  wire signed [W-1:0]      vqx0,      // 枠の左上の画素の値
   input  wire signed [W-1:0]      vqy0,
   input  wire signed [W-1:0]      qx0,
   input  wire signed [W-1:0]      qy0,
   input  wire signed [W-1:0]      sx_vqx,    // x が 1 進むときの増分
   input  wire signed [W-1:0]      sy_vqy,    // y が 1 進むときの増分
   input  wire signed [W-1:0]      sx_qx,     // qx の x 方向 ( ca*sx)
   input  wire signed [W-1:0]      sy_qx,     // qx の y 方向 (-sa*sy)
   input  wire signed [W-1:0]      sx_qy,     // qy の x 方向 ( sa*sx)
   input  wire signed [W-1:0]      sy_qy,     // qy の y 方向 ( ca*sy)

   // ---- 1 回叩くと全レーンが LANES 画素進む ----
   input  wire                     step,

   // ---- レーンごとの出口 ----
   output wire [LANES-1:0]              lane_valid,
   output wire [LANES*W-1:0]            lane_vqx,
   output wire [LANES*W-1:0]            lane_vqy,
   output wire [LANES*W-1:0]            lane_qx,
   output wire [LANES*W-1:0]            lane_qy,
   output wire [LANES*CB-1:0]           lane_x,   // 枠の中の位置。セルの番地に使う
   output wire [LANES*CB-1:0]           lane_y,
   output wire                          done      // 枠を配り終えた
   );

  reg [CB-1:0]     r_bw;
  reg [2*CB-1:0]   r_npix;

  // 行送りのときに引く量。x が w 戻り、y が 1 進む
  reg signed [W-1:0] wrap_vqx, wrap_qx, wrap_qy;

  // LANES 画素ぶん進む量
  reg signed [W-1:0] adv_vqx, adv_qx, adv_qy;

  always @(posedge clk) if (load) begin
    r_bw   <= bw;
    r_npix <= npix;
    // w 画素ぶん戻す量 (掛け算 1 個。ピースごとに 1 回だけなので安い)
    wrap_vqx <= $signed({{(W-CB){1'b0}}, bw}) * sx_vqx;
    wrap_qx  <= $signed({{(W-CB){1'b0}}, bw}) * sx_qx;
    wrap_qy  <= $signed({{(W-CB){1'b0}}, bw}) * sx_qy;
    adv_vqx  <= sx_vqx * LANES;
    adv_qx   <= sx_qx  * LANES;
    adv_qy   <= sx_qy  * LANES;
  end

  genvar k;
  generate
    for (k = 0; k < LANES; k = k + 1) begin : lane

      reg [CB-1:0]      x, y;
      reg [2*CB-1:0]    idx;
      reg signed [W-1:0] vqx, vqy, qx, qy;

      // 進んだ先が行の右端を越えたか。w >= LANES なので引き算は 1 回で足りる
      wire [CB:0]  xn   = {1'b0, x} + LANES;
      wire         wrap = (xn >= {1'b0, r_bw});
      wire [CB-1:0] xw  = wrap ? (xn - {1'b0, r_bw}) : xn[CB-1:0];

      always @(posedge clk) begin
        if (load) begin
          // レーン k は k 番目の画素から始める。w >= LANES なので必ず 0 行目
          x   <= k[CB-1:0];
          y   <= {CB{1'b0}};
          idx <= k[2*CB-1:0];
          vqx <= vqx0 + sx_vqx * k;
          vqy <= vqy0;
          qx  <= qx0  + sx_qx  * k;
          qy  <= qy0  + sx_qy  * k;
        end else if (step) begin
          x   <= xw;
          idx <= idx + LANES;
          if (wrap) y <= y + 1'b1;
          if (wrap) begin
            vqx <= vqx + adv_vqx - wrap_vqx;
            vqy <= vqy + sy_vqy;
            qx  <= qx  + adv_qx  - wrap_qx + sy_qx;
            qy  <= qy  + adv_qy  - wrap_qy + sy_qy;
          end else begin
            vqx <= vqx + adv_vqx;
            qx  <= qx  + adv_qx;
            qy  <= qy  + adv_qy;
          end
        end
      end

      assign lane_valid[k]              = (idx < r_npix);
      assign lane_x[(k+1)*CB-1 -: CB]   = x;
      assign lane_y[(k+1)*CB-1 -: CB]   = y;
      assign lane_vqx[(k+1)*W-1 -: W]   = vqx;
      assign lane_vqy[(k+1)*W-1 -: W]   = vqy;
      assign lane_qx [(k+1)*W-1 -: W]   = qx;
      assign lane_qy [(k+1)*W-1 -: W]   = qy;
    end
  endgenerate

  assign done = ~(|lane_valid);

endmodule
