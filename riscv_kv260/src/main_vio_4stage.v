// ============================================================
// RISC-V on KV260 - 4段パイプライン版 (教科書 m_proc9 / code6-27)
//   前回の3段(m_proc8_F)の枠組みを流用。
//   m_proc9 に結果出力 r_dout を追加:
//     プログラム末尾 HALT(addi x30,x10,0) で合計がx30に入る。
//     4段なのでライトバックはP4段 → P4でx30書込時に w_rt を capture。
//   結果はVIO(w_rslt)で 0x13BA(=5050) を確認。
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

module m_am_imem(w_pc, w_insn);
  input  wire [31:0] w_pc;
  output wire [31:0] w_insn;
  reg [31:0] mem [0:63];
  assign w_insn = mem[w_pc[7:2]];
  integer i; initial for (i=0; i<64; i=i+1) mem[i] = 32'd0;
  initial begin
    `define MM mem
    `include "asm.txt"
  end
endmodule

// ---- 4段パイプライン本体 (教科書 code6-27 の m_proc9 に r_dout を追加) ----
module m_proc9(w_clk, r_dout);
  input wire w_clk;
  output reg [31:0] r_dout=0;
  reg [31:0] P1_ir=32'h13, P1_pc=0, P2_pc=0, P3_pc=0, P4_pc=0;
  reg [31:0] P2_r1=0, P2_s2=0, P2_r2=0, P2_tpc=0, P3_r2=0;
  reg [31:0] P3_alu, P3_in3, P4_alu=0, P4_ldd=0;
  reg P2_r=0, P2_s=0, P2_b=0, P2_ld=0, P4_s=0, P4_b=0, P4_ld=0;
  reg P3_s=0, P3_b=0, P3_ld=0;
  reg [4:0] P2_rd=0, P2_rs1=0, P2_rs2=0, P3_rd=0, P4_rd=0;
  reg P1_v=0, P2_v=0, P3_v=0, P4_v=0;
  wire [31:0] w_npc, w_ir, w_imm, w_r1, w_r2, w_s2, w_rt;
  wire [31:0] w_alu, w_ldd, w_tpc, w_pcin, w_in1, w_in2, w_in3;
  wire w_r, w_i, w_s, w_b, w_u, w_j, w_ld, w_tkn;
  reg [31:0] r_pc = 0;
  // 結果出力: P4(ライトバック)段で x30 書込時に capture
  always @(posedge w_clk)
    r_dout <= (!P4_s & !P4_b & P4_v & P4_rd==30) ? w_rt : r_dout;
  wire w_miss = P2_b & w_tkn & P2_v;
  wire w_lduse = P3_v & P3_ld &
       ((P3_rd==P2_rs1) | ((P3_rd==P2_rs2) & (P2_r | P2_b | P2_s)));
  m_mux m0 (w_npc, P2_tpc, w_miss, w_pcin);
  m_adder m2 (32'h4, r_pc, w_npc);
  m_am_imem m3 (r_pc, w_ir);
  m_gen_imm m4 (P1_ir, w_imm, w_r, w_i, w_s, w_b, w_u, w_j, w_ld);
  m_RF2 m5 (w_clk, P1_ir[19:15], P1_ir[24:20], w_r1, w_r2,
            P4_rd, !P4_s & !P4_b & P4_v, w_rt);
  m_adder m6 (w_imm, P1_pc, w_tpc);
  m_mux m7 (w_r2, w_imm, !w_r & !w_b, w_s2);
  always @(posedge w_clk) if (!w_lduse) begin
    {P1_v, P2_v} <= {!w_miss, !w_miss & P1_v};
    {r_pc, P1_ir, P1_pc, P2_pc} <= {w_pcin, w_ir, r_pc, P1_pc};
    {P2_r1, P2_r2, P2_s2, P2_tpc} <= {w_r1, w_r2, w_s2, w_tpc};
    {P2_r, P2_s, P2_b, P2_ld} <= {w_r, w_s, w_b, w_ld};
    {P2_rs2, P2_rs1, P2_rd} <= {P1_ir[24:15], P1_ir[11:7]};
  end else {P2_r1, P2_r2, P2_s2} <= {w_in1, w_in3, w_in2};
  always @(posedge w_clk) begin
    {P3_v, P4_v} <= {P2_v & !w_lduse, P3_v};
    {P3_pc, P3_ld, P3_r2, P3_in3} <= {P2_pc, P2_ld, P2_r2, w_in3};
    {P3_alu, P3_rd} <= {w_alu, P2_rd};
    {P3_s, P3_b, P3_ld} <= {P2_s, P2_b, P2_ld};
    {P4_pc, P4_s, P4_b, P4_ld} <= {P3_pc, P3_s, P3_b, P3_ld};
    {P4_alu, P4_ldd, P4_rd} <= {P3_alu, w_ldd, P3_rd};
  end
  m_alu m8 (w_in1, w_in2, w_alu, w_tkn);
  m_am_dmem m9 (w_clk, P3_alu, P3_s & P3_v, P3_in3, w_ldd);
  m_mux m10 (P4_alu, P4_ldd, P4_ld, w_rt);
  wire w_f3 = !P3_s & !P3_b & |P3_rd & P3_v;
  wire w_f4 = !P4_s & !P4_b & |P4_rd & P4_v;
  wire w_fwd1_P3 = (w_f3 & P3_rd==P2_rs1);
  wire w_fwd1_P4 = (w_f4 & P4_rd==P2_rs1);
  wire w_fwd2_P3 = (w_f3 & P3_rd==P2_rs2 & (P2_r | P2_b));
  wire w_fwd2_P4 = (w_f4 & P4_rd==P2_rs2 & (P2_r | P2_b));
  wire w_fwd3_P3 = (w_f3 & P3_rd==P2_rs2);
  wire w_fwd3_P4 = (w_f4 & P4_rd==P2_rs2);
  assign w_in1 = (w_fwd1_P3) ? P3_alu : (w_fwd1_P4) ? w_rt : P2_r1;
  assign w_in2 = (w_fwd2_P3) ? P3_alu : (w_fwd2_P4) ? w_rt : P2_s2;
  assign w_in3 = (w_fwd3_P3) ? P3_alu : (w_fwd3_P4) ? w_rt : P2_r2;
endmodule

// ---- KV260 top: PSのpl_clk0 + m_proc9(4段) + VIO ----
module m_top_kv260();
  wire w_clk;
  wire [31:0] w_rslt;
  clk_bd_wrapper m0 (.pl_clk0(w_clk));
  m_proc9 m1 (w_clk, w_rslt);
  vio_0 m2 (w_clk, w_rslt);
endmodule
