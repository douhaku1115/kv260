// ============================================================
// RISC-V on KV260 - 命令キャッシュ版 (4段 m_proc8_c2 + 直接マップ m_cache1 + 遅延主記憶)
//   教科書8章: メモリ階層。
//     m_imem    (code8-2)  : D_DELAYサイクル遅延の主記憶(プログラムを焼込み)
//     m_cache1  (code8-7)  : 直接マップ命令キャッシュ(32エントリ)
//     m_proc8_c2(code8-8)  : 4段プロセッサ+キャッシュ。ヒット=即/ミス=主記憶待ちでストール
//
//   ※ キャッシュを入れても計算結果(5050)は変わらない。
//     効果は「総サイクル数」で観測する:
//       ヒットすればループ2周目以降は1命令/サイクル、ミスは主記憶待ち(D_DELAY+1)。
//   VIOに3本: w_rslt(結果) / w_cyc(HALTまでの総サイクル) / w_miss(キャッシュミス回数)
// ============================================================

module m_get_type(opcode5, r, i, s, b, u, j);
  input  wire [4:0] opcode5;
  output wire r, i, s, b, u, j;
  assign j = (opcode5==5'b11011);
  assign b = (opcode5==5'b11000);
  assign s = (opcode5==5'b01000);
  assign r = (opcode5==5'b01100);
  assign u = (opcode5==5'b01101 || opcode5==5'b00101);
  assign i = ~(j | b | s | r | u);
endmodule

module m_get_imm(ir, i, s, b, u, j, imm);
  input wire [31:0] ir;
  input wire i, s, b, u, j;
  output wire [31:0] imm;
  assign imm= (i) ? {{20{ir[31]}},ir[31:20]} :
              (s) ? {{20{ir[31]}},ir[31:25],ir[11:7]} :
              (b) ? {{20{ir[31]}},ir[7],ir[30:25],ir[11:8],1'b0} :
              (u) ? {ir[31:12],12'b0} :
              (j) ? {{12{ir[31]}},ir[19:12],ir[20],ir[30:21],1'b0} : 0;
endmodule

module m_adder(w_in1, w_in2, w_out);
  input  wire [31:0] w_in1, w_in2;
  output wire [31:0] w_out;
  assign w_out = w_in1 + w_in2;
endmodule

module m_mux(w_in1, w_in2, w_s, w_out);
  input  wire [31:0] w_in1, w_in2;
  input  wire w_s;
  output wire [31:0] w_out;
  assign w_out = (w_s) ? w_in2 : w_in1;
endmodule

module m_RF2(w_clk, w_ra1, w_ra2, w_rd1, w_rd2, w_wa, w_we, w_wd);
  input  wire w_clk, w_we;
  input  wire [4:0] w_ra1, w_ra2, w_wa;
  output wire [31:0] w_rd1, w_rd2;
  input  wire [31:0] w_wd;
  reg [31:0] mem [0:31];
  wire w_bp1 = (w_we & w_ra1==w_wa);
  wire w_bp2 = (w_we & w_ra2==w_wa);
  assign w_rd1 = (w_ra1==5'd0) ? 32'd0 : (w_bp1) ? w_wd : mem[w_ra1];
  assign w_rd2 = (w_ra2==5'd0) ? 32'd0 : (w_bp2) ? w_wd : mem[w_ra2];
  always @(posedge w_clk) if (w_we) mem[w_wa] <= w_wd;
  integer i; initial for (i=0; i<32; i=i+1) mem[i] = 32'd0;
endmodule

module m_gen_imm(w_ir, w_imm, w_r, w_i, w_s, w_b, w_u, w_j, w_ld);
  input  wire [31:0] w_ir;
  output wire [31:0] w_imm;
  output wire w_r, w_i, w_s, w_b, w_u, w_j, w_ld;
  m_get_type m1 (w_ir[6:2], w_r, w_i, w_s, w_b, w_u, w_j);
  m_get_imm m2 (w_ir, w_i, w_s, w_b, w_u, w_j, w_imm);
  assign w_ld = (w_ir[6:2]==0);
endmodule

module m_am_dmem(w_clk, w_adr, w_we, w_wd, w_rd);
  input  wire w_clk, w_we;
  input  wire [31:0] w_adr, w_wd;
  output wire [31:0] w_rd;
  reg [31:0] mem [0:63];
  assign w_rd = mem[w_adr[7:2]];
  always @(posedge w_clk) if (w_we) mem[w_adr[7:2]] <= w_wd;
  integer i; initial for (i=0; i<64; i=i+1) mem[i] = 32'd0;
endmodule

module m_alu(w_in1, w_in2, w_out, w_tkn);
  input  wire [31:0] w_in1, w_in2;
  output wire [31:0] w_out;
  output wire w_tkn;
  assign w_out = w_in1 + w_in2;
  assign w_tkn = w_in1 != w_in2;
endmodule

// ---- 遅延つき主記憶 (教科書 code8-2, D_DELAYサイクル待ち) ----
//   プログラムは include で焼込み。w_re でリクエスト、D_DELAY後に r_oe=1 で r_insn を返す。
`define D_DELAY 5
module m_imem(w_clk, w_pc, w_re, r_insn, r_oe);
  input  wire w_clk, w_re;
  input  wire [31:0] w_pc;
  output reg  [31:0] r_insn = 0;
  output reg  r_oe = 0;
  reg [31:0] mem [0:2047];
  reg [31:0] r_c=1, r_pc=0;
  always@(posedge w_clk) begin
    r_pc <= (r_c==1 & w_re) ? w_pc : r_pc;
    r_c <= (r_c==1 & w_re) ? 2 : (r_c==1 | r_c==`D_DELAY) ? 1 : r_c+1;
    r_oe <= (r_c==`D_DELAY-1);
    r_insn <= (r_c==`D_DELAY-1) ? mem[r_pc[12:2]] : 0;
  end
  integer i; initial for (i=0; i<2048; i=i+1) mem[i] = 32'd0;
  initial begin
    `define MM mem
    `include "asm.txt"
  end
endmodule

// ---- 直接マップ命令キャッシュ (教科書 code8-7) ----
//   mem[adr[6:2]] = {valid(1), tag=adr[31:7](25), data(32)} = 58bit
module m_cache1(w_clk, w_adr, w_hit, w_dout, w_wadr, w_we, w_wd);
  input  wire w_clk, w_we;
  input  wire [31:0] w_adr;
  input  wire [4:0] w_wadr;
  input  wire [57:0] w_wd;
  output wire w_hit;
  output wire [31:0] w_dout;
  wire w_v;
  wire [24:0] w_tag;
  reg [57:0] mem [0:31];
  always @(posedge w_clk) if (w_we) mem[w_wadr] <= w_wd;
  assign {w_v, w_tag, w_dout} = mem[w_adr[6:2]];
  assign w_hit = w_v & (w_tag==w_adr[31:7]);
  integer i; initial for (i=0; i<32; i=i+1) mem[i] = 0;
endmodule

// ---- 4段プロセッサ + 命令キャッシュ (教科書 code8-8 m_proc8_c2 に観測機構を追加) ----
module m_proc8_c2(w_clk, r_pc, w_ir_in, w_oe, w_re, r_dout, r_cyc, r_miss);
  input wire w_clk, w_oe;
  input wire [31:0] w_ir_in;
  output reg [31:0] r_pc = 0;
  output wire w_re;
  output reg [31:0] r_dout=0;   // 計算結果 (x30, 期待 0x13BA=5050)
  output reg [31:0] r_cyc=0;    // HALTまでの総サイクル数
  output reg [31:0] r_miss=0;   // キャッシュミス回数(主記憶アクセス回数)
  reg [31:0] P1_ir=32'h13, P1_pc=0, P2_pc=0, P3_pc=0;
  reg [31:0] P2_r1=0, P2_s2=0, P2_r2=0, P2_tpc=0;
  reg [31:0] P3_alu=0, P3_ldd=0;
  reg P2_r=0, P2_s=0, P2_b=0, P2_ld=0, P3_s=0, P3_b=0, P3_ld=0;
  reg [4:0] P2_rd=0, P2_rs1=0, P2_rs2=0, P3_rd=0;
  reg P1_v=0, P2_v=0, P3_v=0;
  wire [31:0] w_npc, w_imm, w_r1, w_r2, w_s2, w_rt;
  wire [31:0] w_alu, w_ldd, w_tpc, w_pcin, w_in1, w_in2, w_in3;
  wire w_r, w_i, w_s, w_b, w_u, w_j, w_ld, w_tkn;
  wire w_miss = P2_b & w_tkn & P2_v;
  // ---- 命令キャッシュ ----
  wire w_hit;
  wire [31:0] w_dout;
  wire [57:0] w_wd = {1'b1, r_pc[31:7], w_ir_in};
  m_cache1 m3 (w_clk, r_pc, w_hit, w_dout, r_pc[6:2], w_oe, w_wd);
  wire [31:0] w_ir = w_hit ? w_dout : w_ir_in;
  wire w_stall = !w_hit;     // ミス中はストール
  assign w_re = !w_hit;      // ミス中は主記憶をリクエスト

  // ---- 結果capture / 真HALT / 観測カウンタ ----
  //   4段なのでライトバックはP3段。x30書込がコミット(!w_stall)した時にcapture。
  wire w_wb30 = !P3_s & !P3_b & P3_v & !w_stall & P3_rd==30;
  reg r_halt = 0;
  always @(posedge w_clk) begin
    if (w_wb30) r_dout <= w_rt;
    if (w_wb30) r_halt <= 1;
    if (!r_halt) r_cyc <= r_cyc + 1;         // HALTまで毎サイクル加算
    if (w_oe & !r_halt) r_miss <= r_miss + 1; // 主記憶が返すたび=1ミス
  end

  m_mux m0 (w_npc, P2_tpc, w_miss, w_pcin);
  m_adder m2 (32'h4, r_pc, w_npc);
  m_gen_imm m4 (P1_ir, w_imm, w_r, w_i, w_s, w_b, w_u, w_j, w_ld);
  m_RF2 m5 (w_clk, P1_ir[19:15], P1_ir[24:20], w_r1, w_r2,
            P3_rd, !P3_s & !P3_b & P3_v & !w_stall, w_rt);
  m_adder m6 (w_imm, P1_pc, w_tpc);
  m_mux m7 (w_r2, w_imm, !w_r & !w_b, w_s2);
  always @(posedge w_clk) if (!w_stall) begin
    {P1_v, P2_v, P3_v} <= {!w_miss & !r_halt, !w_miss & P1_v, P2_v};
    {r_pc, P1_ir, P1_pc, P2_pc} <= {r_halt ? r_pc : w_pcin, w_ir, r_pc, P1_pc};
    {P2_r1, P2_r2, P2_s2, P2_tpc} <= {w_r1, w_r2, w_s2, w_tpc};
    {P2_r, P2_s, P2_b, P2_ld} <= {w_r, w_s, w_b, w_ld};
    {P2_rs2, P2_rs1, P2_rd} <= {P1_ir[24:15], P1_ir[11:7]};
    {P3_pc, P3_ld} <= {P2_pc, P2_ld};
    {P3_alu, P3_ldd, P3_rd} <= {w_alu, w_ldd, P2_rd};
    {P3_s, P3_b} <= {P2_s, P2_b};
  end
  m_alu m8 (w_in1, w_in2, w_alu, w_tkn);
  m_am_dmem m9 (w_clk, w_alu, P2_s & P2_v & !w_stall, w_in3, w_ldd);
  m_mux m10 (P3_alu, P3_ldd, P3_ld, w_rt);
  wire w_f =!P3_s & !P3_b & |P3_rd & P3_v;
  m_mux m11 (P2_r1, w_rt, w_f & P2_rs1==P3_rd, w_in1);
  m_mux m12 (P2_s2, w_rt, w_f & P2_rs2==P3_rd & (P2_r|P2_b), w_in2);
  m_mux m13 (P2_r2, w_rt, w_f & P2_rs2==P3_rd, w_in3);
endmodule

// ---- KV260 top: PSのpl_clk0 + m_proc8_c2 + 遅延主記憶 + VIO ----
module m_top_kv260();
  wire w_clk;
  wire [31:0] w_pc, w_ir, w_rslt, w_cyc, w_miss;
  wire w_re, w_oe;
  clk_bd_wrapper m0 (.pl_clk0(w_clk));
  m_proc8_c2 m1 (w_clk, w_pc, w_ir, w_oe, w_re, w_rslt, w_cyc, w_miss);
  m_imem     m2 (w_clk, w_pc, w_re, w_ir, w_oe);
  vio_0      m3 (w_clk, w_rslt, w_cyc, w_miss);
endmodule
