// ============================================================
// tb_cpu_nestest.v — 6502 を nestest の正解ログと 1 命令ずつ照合 (段B)
// ============================================================
//
// メモリ: $0000-$1FFF = 2KB RAM (ミラー)、$8000-$FFFF = PRG 16KB (ミラー)、他は 0
// リセットベクタを $C000 に差し替えて自動モードで走らせる。
// 命令の取り出し (sync=1) のたびに PC A X Y P SP と経過サイクル数を照合する。
// 入力ファイルは tools/nestest_prep.py が roms/ に作る。
`timescale 1ns/1ps

module tb_cpu_nestest;
  reg clk = 0;
  always #5 clk = ~clk;

  reg rst = 1;
  reg ce  = 0;
  reg [1:0] div = 0;
  always @(posedge clk) begin                 // 3 クロックに 1 回 ce
    div <= (div == 2) ? 2'd0 : div + 2'd1;
    ce  <= (div == 2);
  end

  wire [15:0] addr;
  wire [7:0]  dout;
  wire        we, sync;
  wire [15:0] dpc;
  wire [7:0]  da, dx, dy, ds, dp;
  reg  [7:0]  din;

  cpu6502 cpu (.clk(clk), .rst(rst), .ce(ce), .addr(addr), .dout(dout), .we(we), .din(din),
               .nmi(1'b0), .irq(1'b0), .sync(sync),
               .dbg_pc(dpc), .dbg_a(da), .dbg_x(dx), .dbg_y(dy), .dbg_s(ds), .dbg_p(dp));

  reg [7:0]  ram [0:2047];
  reg [7:0]  prg [0:16383];
  reg [87:0] exp_tab [0:8999];

  // 読み: 番地が変わればすぐ出る (次の ce までに確定していればよい)
  always @(*) begin
    if (addr < 16'h2000)       din = ram[addr[10:0]];
    else if (addr >= 16'h8000) din = prg[addr[13:0]];
    else                       din = 8'h00;
  end
  // 書き: サイクルの終わり (ce) で書く
  always @(posedge clk)
    if (ce && we && addr < 16'h2000) ram[addr[10:0]] <= dout;

  integer i, n, cyc, errs;
  reg [87:0] e;

  initial begin
    for (i = 0; i < 2048; i = i + 1) ram[i] = 8'h00;
    for (i = 0; i < 9000; i = i + 1) exp_tab[i] = 88'hx;
    $readmemh("nestest_prg.hex", prg);
    $readmemh("nestest_exp.hex", exp_tab);
    n = 0;
    while (exp_tab[n] !== 88'hx) n = n + 1;
    $display("expected lines %0d", n);
    prg[14'h3FFC] = 8'h00;                    // リセットベクタ → $C000
    prg[14'h3FFD] = 8'hC0;

    repeat (5) @(posedge clk);
    rst = 0;
  end

  // ce の数 = 経過サイクル。sync のサイクルで照合
  initial begin
    cyc = 0; i = 0; errs = 0;
    @(negedge rst);
    while (i < n) begin
      @(posedge clk);
      if (ce) begin
        if (sync) begin
          e = exp_tab[i];
          if ({cyc[31:0], addr, da, dx, dy, dp, ds} !== e) begin
            $display("NG line %0d", i + 1);
            $display("  exp: PC=%h A=%h X=%h Y=%h P=%h SP=%h CYC=%0d",
                     e[55:40], e[39:32], e[31:24], e[23:16], e[15:8], e[7:0], e[87:56]);
            $display("  got: PC=%h A=%h X=%h Y=%h P=%h SP=%h CYC=%0d",
                     addr, da, dx, dy, dp, ds, cyc);
            if (i > 0)
              $display("  prev: PC=%h (CYC %0d)", exp_tab[i-1][55:40], exp_tab[i-1][87:56]);
            errs = errs + 1;
            i = n;                            // 最初の不一致で止める
          end else
            i = i + 1;
        end
        cyc = cyc + 1;
      end
    end
    if (errs == 0) begin
      $display("all %0d instructions matched (CYC up to %0d)", n, cyc - 1);
      $display("nestest result $02=%h $03=%h (00 = official ops OK)", ram[2], ram[3]);
      if (ram[2] == 8'h00 && ram[3] == 8'h00) $display("PASS"); else $display("FAIL result code");
    end else
      $display("FAIL");
    $finish;
  end

  // 暴走よけ
  initial begin
    #50_000_000;
    $display("FAIL timeout at line %0d", i + 1);
    $finish;
  end
endmodule
