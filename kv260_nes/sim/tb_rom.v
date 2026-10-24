// ============================================================
// tb_rom.v — 段D2〜: NROM のテスト ROM を nes_core だけで回す (AXI と 720p 表示は省く)
// ============================================================
//
// 先に python tools/rom_prep.py ROM.nes [フレーム数] で roms/rom_*.hex を作る。
// PRG/CHR をポートから直接書き、CPU を走らせ、PPU のフレーム数が指定に達したら
//   ・画面を frame.ppm に書く (tools/ppm2png.py で PNG に)
//   ・ネームテーブル 0 の 30 行を文字として表示する (blargg のテストは結果を文字で出す)
`timescale 1ns/1ps

module tb_rom;
  reg clk = 0;
  always #5 clk = ~clk;

  reg         run = 0;
  // ミラー / フレーム数 / ボタン / 押すフレーム / ボタン2 / フレーム2 (rom_prep.py が作る)
  reg  [31:0] cfg [0:5];
  reg         prg_we = 0, chr_we = 0;
  reg  [15:0] prg_waddr = 0;
  reg  [16:0] chr_waddr = 0;
  reg  [31:0] prg_wdata = 0;
  reg  [7:0]  chr_wdata = 0;
  wire        pix_we;
  wire [7:0]  pix_x, pix_y;
  wire [5:0]  pix_c;
  wire [31:0] ppu_frames, cpu_cycles;
  wire [15:0] pc;
  // コントローラ: 指定フレームから 5 フレームだけ押す (2 回まで)
  wire [7:0]  pad = ((ppu_frames >= cfg[3] && ppu_frames < cfg[3] + 5) ? cfg[2][7:0] : 8'd0)
                  | ((ppu_frames >= cfg[5] && ppu_frames < cfg[5] + 5) ? cfg[4][7:0] : 8'd0);

  nes_core core
    (.clk(clk), .run(run), .cart(cfg[0][15:0]), .pad(pad),
     .chr_we(chr_we), .chr_waddr(chr_waddr), .chr_wdata(chr_wdata),
     .pix_we(pix_we), .pix_x(pix_x), .pix_y(pix_y), .pix_c(pix_c), .ppu_frames(ppu_frames),
     .prg_we(prg_we), .prg_waddr(prg_waddr), .prg_wdata(prg_wdata),
     .wram_raddr(11'd0), .wram_rdata(),
     .dbg_pc(pc), .cpu_cycles(cpu_cycles), .cpu_sync(), .cpu_addr());

  // 画面 (PPU の 1 画素書きを受ける)
  reg [5:0] scr [0:61439];
  always @(posedge clk) if (pix_we) scr[{pix_y, pix_x}] <= pix_c;

  // 画面が止まったら早く終える: 1 フレームの画素から作る値 (hacc) が、描画中のまま 30 フレーム同じなら終了
  // (Holy Mapperel のように結果を出したあと同じ画面を出し続けるテスト向け)
  reg [31:0] hacc = 0, hprev = 0, hsame = 0, hframe = 0;
  always @(posedge clk) begin
    if (pix_we) hacc <= {hacc[30:0], hacc[31]} ^ {pix_y, pix_x, 10'd0, pix_c};
    if (ppu_frames != hframe) begin
      hframe <= ppu_frames;
      hsame  <= (hacc == hprev && core.ppu0.rendering) ? hsame + 1 : 0;
      hprev  <= hacc;
      hacc   <= 0;
    end
  end

  // 色表
  reg  [5:0]  pidx = 0;
  wire [23:0] prgb;
  reg  [23:0] ptab [0:63];
  nes_palette pref (.clk(clk), .idx(pidx), .rgb(prgb));

  reg [31:0] prg32 [0:65535];   // PRG 256KB まで
  reg [7:0]  chr8  [0:131071];  // CHR 128KB まで (CHR-RAM なら 0 のまま)
  reg [5:0]  c;
  reg [7:0]  ch;
  integer i, f, x, y, last;

  initial begin
    for (i = 0; i < 64; i = i + 1) begin
      pidx = i; @(posedge clk); @(posedge clk); #1 ptab[i] = prgb;
    end
    // ROM より後ろは 0 (読ませないが、x を BRAM に入れないため)
    for (i = 0; i < 65536;  i = i + 1) prg32[i] = 32'd0;
    for (i = 0; i < 131072; i = i + 1) chr8[i]  = 8'd0;
    $readmemh("rom_cfg.hex", cfg);
    $readmemh("rom_prg.hex", prg32);
    $readmemh("rom_chr.hex", chr8);
    $display("CTRL=%h (マッパー %0d, PRG %0dKB, CHR %0dKB%s)", cfg[0][15:0], cfg[0][7:4],
             (cfg[0][11:8] + 1) * 16, (cfg[0][15:12] + 1) * 8, cfg[0][3] ? " RAM" : "");
    for (i = 0; i < 65536; i = i + 1) begin
      @(posedge clk); prg_we <= 1; prg_waddr <= i; prg_wdata <= prg32[i];
    end
    @(posedge clk); prg_we <= 0;
    for (i = 0; i < 131072; i = i + 1) begin
      @(posedge clk); chr_we <= 1; chr_waddr <= i; chr_wdata <= chr8[i];
    end
    @(posedge clk); chr_we <= 0;
    @(posedge clk); run <= 1;

    // blargg の新しいテストは $6000 = 状態 ($80 実行中 / $00 合格 / 他は失敗番号)、
    // $6001-$6003 = DE B0 61 (目印)、$6004〜 = 結果の文章。目印があって実行中でなければ早く終える
    last = 0;
    while (ppu_frames < cfg[1] && hsame < 30 &&
           !(core.prgram[1] == 8'hDE && core.prgram[2] == 8'hB0 && core.prgram[3] == 8'h61 &&
             core.prgram[0] != 8'h80)) begin
      @(posedge clk);
      if (ppu_frames != last && ppu_frames % 10 == 0) begin
        $display("frame %0d PC=%h", ppu_frames, pc);
      end
      last = ppu_frames;
    end
    repeat (100) @(posedge clk);

    if (core.prgram[1] == 8'hDE && core.prgram[2] == 8'hB0 && core.prgram[3] == 8'h61) begin
      $display("$6000 status = %h", core.prgram[0]);
      $write("$6004 text: ");
      for (i = 4; i < 1000 && core.prgram[i] != 8'h00; i = i + 1) begin
        ch = core.prgram[i];
        if (ch == 8'h0A) $write(" / "); else $write("%c", ch);
      end
      $write("\n");
    end

    for (y = 0; y < 30; y = y + 1) begin
      $write("|");
      for (x = 0; x < 32; x = x + 1) begin
        ch = core.ppu0.nt[y*32 + x];
        if (ch >= 8'h20 && ch < 8'h7F) $write("%c", ch); else $write(".");
      end
      $write("|\n");
    end

    f = $fopen("frame.ppm", "w");
    $fwrite(f, "P3\n256 240\n255\n");
    for (y = 0; y < 240; y = y + 1)
      for (x = 0; x < 256; x = x + 1) begin
        c = scr[y*256 + x];
        if (^c === 1'bx) c = 6'h0F;
        $fwrite(f, "%0d %0d %0d\n", ptab[c][23:16], ptab[c][15:8], ptab[c][7:0]);
      end
    $fclose(f);
    $display("DONE frames=%0d PC=%h CYC=%0d%s", ppu_frames, pc, cpu_cycles,
             hsame >= 30 ? " (画面が 30 フレーム不変で終了)" : "");
    $finish;
  end
endmodule
