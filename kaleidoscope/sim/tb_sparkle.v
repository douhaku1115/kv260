// ============================================================
//  tb_sparkle — きらめき層 (rtl/sparkle.v) を tools/sparkle_fx.py と照合する
//
//  tools/tb_sparkle_check.py が作る spk_vec.hex を 1 クロックに 1 行ずつ流し、
//  LAT クロック後の出力が正解と同じかを数える。
//  1 行 = {skip, cx[17:0], cy[17:0], en, lv[2:0], dens[7:0], k[15:0], base[7:0],
//          flash[7:0], tphase[7:0], r[8:0], g[8:0], b[8:0]}  (合計 132bit → 136bit)
//  skip = 1 の行は設定の切り替わりで新旧が混ざるので照合しない
// ============================================================
`timescale 1ns/1ps

module tb_sparkle;
  // 入力の元のレジスタ (scope_pipe の cxf_r) から数えて 10 クロック。
  // ここでは入力を受けたクロックから数えるので 1 少ない
  localparam LAT = 9;
  localparam N   = 20000;

  reg clk = 0;
  always #5 clk = ~clk;

  reg [135:0] vec [0:N-1];
  initial $readmemh("spk_vec.hex", vec);

  reg signed [17:0] cx, cy;
  reg        en;
  reg [2:0]  lv;
  reg [7:0]  dens, base, flash, tphase;
  reg [15:0] k;
  wire [8:0] r, g, b;

  // 色の表 16 個 (段7b)。tools/tb_sparkle_check.py が spk_cols.hex に書く
  reg [23:0] tc [0:15];
  initial $readmemh("spk_cols.hex", tc);
  wire [16*24-1:0] cols;
  genvar gi;
  generate for (gi = 0; gi < 16; gi = gi + 1) begin : g_cols
    assign cols[gi*24 +: 24] = tc[gi];
  end endgenerate

  sparkle dut (.clk(clk), .cx(cx), .cy(cy), .en(en), .lv(lv), .dens(dens), .k(k),
               .base(base), .flash(flash), .tphase(tphase), .cols(cols),
               .out_r(r), .out_g(g), .out_b(b));

  integer i, bad, nz;
  reg [135:0] v;
  initial begin
    bad = 0; nz = 0;
    for (i = 0; i < N + LAT; i = i + 1) begin
      if (i < N) begin
        v = vec[i];
        cx = v[130:113];  cy = v[112:95];  en = v[94];  lv = v[93:91];
        dens = v[90:83];  k = v[82:67];    base = v[66:59];  flash = v[58:51];
        tphase = v[50:43];
      end
      @(posedge clk); #1;
      if (i >= LAT && !vec[i - LAT][131]) begin     // bit131 = 設定の切り替わりで照合しない
        v = vec[i - LAT];
        if ({r, g, b} !== v[26:0]) begin
          if (bad < 10)
            $display("不一致 %0d: rtl %0d %0d %0d / 正解 %0d %0d %0d",
                     i - LAT, r, g, b, v[26:18], v[17:9], v[8:0]);
          bad = bad + 1;
        end
        if (v[26:0] != 0) nz = nz + 1;
      end
    end
    $display("照合 %0d 画素、不一致 %0d (光っている画素 %0d)", N, bad, nz);
    $finish;
  end
endmodule
