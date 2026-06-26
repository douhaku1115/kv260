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

module m_proc8_F(w_clk, r_dout);
  input wire w_clk;
  output reg [31:0] r_dout=0;
  reg [31:0] P1_ir=32'h13, P1_pc=0, P2_pc=0, P3_pc=0;
  reg [31:0] P2_r1=0, P2_s2=0, P2_r2=0, P2_tpc=0;
  reg [31:0] P3_alu=0, P3_ldd=0;
  reg P2_r=0, P2_s=0, P2_b=0, P2_ld=0, P3_s=0, P3_b=0, P3_ld=0;
  reg [4:0] P2_rd=0, P2_rs1=0, P2_rs2=0, P3_rd=0;
  reg P1_v=0, P2_v=0, P3_v=0;
  wire [31:0] w_npc, w_ir, w_imm, w_r1, w_r2, w_s2, w_rt;
  wire [31:0] w_alu, w_ldd, w_tpc, w_pcin, w_in1, w_in2, w_in3;
  wire w_r, w_i, w_s, w_b, w_u, w_j, w_ld, w_tkn;
  always @(posedge w_clk)
    r_dout <= (!P3_s & !P3_b & P3_v & P3_rd==30) ? w_rt : r_dout;
  reg [31:0] r_pc = 0;
  wire w_miss = P2_b & w_tkn & P2_v;
  m_mux m0 (w_npc, P2_tpc, w_miss, w_pcin);
  m_adder m2 (32'h4, r_pc, w_npc);
  m_am_imem m3 (r_pc, w_ir);
  m_gen_imm m4 (P1_ir, w_imm, w_r, w_i, w_s, w_b, w_u, w_j, w_ld);
  m_RF2 m5 (w_clk, P1_ir[19:15], P1_ir[24:20], w_r1, w_r2,
            P3_rd, !P3_s & !P3_b & P3_v, w_rt);
  m_adder m6 (w_imm, P1_pc, w_tpc);
  m_mux m7 (w_r2, w_imm, !w_r & !w_b, w_s2);
  always @(posedge w_clk) begin
    {P1_v, P2_v, P3_v} <= {!w_miss, !w_miss & P1_v, P2_v};
    {r_pc, P1_ir, P1_pc, P2_pc} <= {w_pcin, w_ir, r_pc, P1_pc};
    {P2_r1, P2_r2, P2_s2, P2_tpc} <= {w_r1, w_r2, w_s2, w_tpc};
    {P2_r, P2_s, P2_b, P2_ld} <= {w_r, w_s, w_b, w_ld};
    {P2_rs2, P2_rs1, P2_rd} <= {P1_ir[24:15], P1_ir[11:7]};
    {P3_pc, P3_ld} <= {P2_pc, P2_ld};
    {P3_alu, P3_ldd, P3_rd} <= {w_alu, w_ldd, P2_rd};
  end
  m_alu m8 (w_in1, w_in2, w_alu, w_tkn);
  m_am_dmem m9 (w_clk, w_alu, P2_s & P2_v, w_in3, w_ldd);
  m_mux m10 (P3_alu, P3_ldd, P3_ld, w_rt);
  wire w_f =!P3_s & !P3_b & |P3_rd & P3_v;
  m_mux m11 (P2_r1, w_rt, w_f & P2_rs1==P3_rd, w_in1);
  m_mux m12 (P2_s2, w_rt, w_f & P2_rs2==P3_rd & (P2_r|P2_b), w_in2);
  m_mux m13 (P2_r2, w_rt, w_f & P2_rs2==P3_rd, w_in3);
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

module m_top_kv260();
  wire w_clk;
  wire [31:0] w_rslt;
  clk_bd_wrapper m0 (.pl_clk0(w_clk));
  m_proc8_F m1 (w_clk, w_rslt);
  vio_0 m2 (w_clk, w_rslt);
endmodule
