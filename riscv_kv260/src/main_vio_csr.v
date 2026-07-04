// ============================================================
// RISC-V on KV260 - 第2段 CSR/例外版 (5段 m_proc9 拡張)
//   KOZOS移植の第2段: 最小の CSR / 例外(ecall/mret) を追加する。
//   スコープA(最小):
//     命令 : csrrw(funct3=001) / csrrs(funct3=010) / ecall / mret
//     CSR  : mtvec(0x305) mepc(0x341) mcause(0x342) mscratch(0x340)
//     例外 : ecall で mepc<-PC, mcause<-11, PC<-mtvec (P2でトラップ)
//            mret  で PC<-mepc  (スコープAは mstatus 復元なし)
//   トラップは分岐解決と同じ P2(EX) 境界に相乗り。既存の分岐フラッシュ
//   経路(w_miss)を w_redir に拡張して P1/P2 を潰す。
//   CSR 命令は旧値を rd へ返す(P3_alu を w_csr_old で置換→既存WB経路)。
//   検証は asm_csr.txt: mtvec設定→ecall→ハンドラ→mret 往復。x30=11 を VIO で確認。
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
    `include "asm_csr.txt"
  end
endmodule

// ---- 5段パイプライン + CSR/例外(ecall/mret) ----
module m_proc_csr(w_clk, r_rslt, r_trapcnt);
  input wire w_clk;
  output reg [31:0] r_rslt=0;           // x30 の値(検証結果, 期待=11)
  output reg [31:0] r_trapcnt=0;        // トラップ(ecall)発生回数(期待=1)
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

  // ---- CSR ファイル(4本) ----
  reg [31:0] csr_mtvec=0, csr_mepc=0, csr_mcause=0, csr_mscratch=0;

  // ---- P1(ID)で SYSTEM 命令をデコード ----
  wire w_sys      = (P1_ir[6:2]==5'b11100);
  wire [2:0] w_f3 = P1_ir[14:12];
  wire w_ecall = w_sys & (w_f3==3'b000) & (P1_ir[31:20]==12'h000);
  wire w_mret  = w_sys & (w_f3==3'b000) & (P1_ir[31:20]==12'h302);
  wire w_csr   = w_sys & (w_f3!=3'b000);   // csrrw(001)/csrrs(010)
  wire [11:0] w_csraddr = P1_ir[31:20];

  // ---- P2 に運ぶ CSR/例外 制御 ----
  reg P2_csr=0, P2_ecall=0, P2_mret=0;
  reg [11:0] P2_csraddr=0;
  reg [2:0] P2_f3=0;

  // ---- CSR 読み出し(旧値) ----
  wire [31:0] w_csr_old =
       (P2_csraddr==12'h305) ? csr_mtvec :
       (P2_csraddr==12'h341) ? csr_mepc :
       (P2_csraddr==12'h342) ? csr_mcause :
       (P2_csraddr==12'h340) ? csr_mscratch : 32'd0;
  // CSR 書き込み新値: csrrs は OR、csrrw は上書き。rs1=x0 の csrrs は書かない。
  wire [31:0] w_csr_new = (P2_f3==3'b010) ? (w_csr_old | w_in1) : w_in1;
  wire w_csr_we = P2_csr & P2_v & ~((P2_f3==3'b010) & (P2_rs1==5'd0));

  // ---- トラップ/リダイレクト(P2境界) ----
  wire w_miss   = P2_b & w_tkn & P2_v;
  wire w_trap_e = P2_ecall & P2_v;      // ecall
  wire w_trap_r = P2_mret  & P2_v;      // mret
  wire w_redir  = w_miss | w_trap_e | w_trap_r;

  wire w_lduse = P3_v & P3_ld &
       ((P3_rd==P2_rs1) | ((P3_rd==P2_rs2) & (P2_r | P2_b | P2_s)));

  // PC選択: ecall->mtvec / mret->mepc / 分岐ミス->P2_tpc / それ以外->PC+4
  assign w_pcin = (w_trap_e) ? csr_mtvec :
                  (w_trap_r) ? csr_mepc  :
                  (w_miss)   ? P2_tpc    : w_npc;

  m_adder m2 (32'h4, r_pc, w_npc);
  m_am_imem m3 (r_pc, w_ir);
  m_gen_imm m4 (P1_ir, w_imm, w_r, w_i, w_s, w_b, w_u, w_j, w_ld);
  m_RF2 m5 (w_clk, P1_ir[19:15], P1_ir[24:20], w_r1, w_r2,
            P4_rd, !P4_s & !P4_b & P4_v, w_rt);
  m_adder m6 (w_imm, P1_pc, w_tpc);
  m_mux m7 (w_r2, w_imm, !w_r & !w_b, w_s2);

  // ---- IF/ID→EX パイプライン(lduse 時はストール) ----
  always @(posedge w_clk) if (!w_lduse) begin
    {P1_v, P2_v} <= {!w_redir, !w_redir & P1_v};      // 分岐/トラップで潰す
    {r_pc, P1_ir, P1_pc, P2_pc} <= {w_pcin, w_ir, r_pc, P1_pc};
    {P2_r1, P2_r2, P2_s2, P2_tpc} <= {w_r1, w_r2, w_s2, w_tpc};
    {P2_r, P2_s, P2_b, P2_ld} <= {w_r, w_s, w_b, w_ld};
    {P2_rs2, P2_rs1, P2_rd} <= {P1_ir[24:15], P1_ir[11:7]};
    {P2_csr, P2_ecall, P2_mret} <= {w_csr, w_ecall, w_mret};
    {P2_csraddr, P2_f3} <= {w_csraddr, w_f3};
  end else {P2_r1, P2_r2, P2_s2} <= {w_in1, w_in3, w_in2};

  // ---- EX→MEM→WB パイプライン ----
  always @(posedge w_clk) begin
    {P3_v, P4_v} <= {P2_v & !w_lduse, P3_v};
    {P3_pc, P3_ld, P3_r2, P3_in3} <= {P2_pc, P2_ld, P2_r2, w_in3};
    P3_alu <= P2_csr ? w_csr_old : w_alu;             // CSR命令は旧値を rd へ
    P3_rd  <= P2_rd;
    {P3_s, P3_b, P3_ld} <= {P2_s, P2_b, P2_ld};
    {P4_pc, P4_s, P4_b, P4_ld} <= {P3_pc, P3_s, P3_b, P3_ld};
    {P4_alu, P4_ldd, P4_rd} <= {P3_alu, w_ldd, P3_rd};
  end

  // ---- CSR 書き込み / 例外(P2, lduse でない時) ----
  always @(posedge w_clk) if (!w_lduse) begin
    if (w_trap_e) begin                  // ecall: 例外エントリ
      csr_mepc   <= P2_pc;               // トラップした命令(ecall)のPC
      csr_mcause <= 32'd11;              // Environment call from M-mode
    end else if (P2_csr & P2_v) begin    // csrrw / csrrs
      case (P2_csraddr)
        12'h305: if (w_csr_we) csr_mtvec    <= w_csr_new;
        12'h341: if (w_csr_we) csr_mepc     <= w_csr_new;
        12'h342: if (w_csr_we) csr_mcause   <= w_csr_new;
        12'h340: if (w_csr_we) csr_mscratch <= w_csr_new;
      endcase
    end
  end

  m_alu m8 (w_in1, w_in2, w_alu, w_tkn);
  m_am_dmem m9 (w_clk, P3_alu, P3_s & P3_v, P3_in3, w_ldd);
  m_mux m10 (P4_alu, P4_ldd, P4_ld, w_rt);

  // ---- フォワーディング ----
  wire w_f3f = !P3_s & !P3_b & |P3_rd & P3_v;
  wire w_f4f = !P4_s & !P4_b & |P4_rd & P4_v;
  wire w_fwd1_P3 = (w_f3f & P3_rd==P2_rs1);
  wire w_fwd1_P4 = (w_f4f & P4_rd==P2_rs1);
  wire w_fwd2_P3 = (w_f3f & P3_rd==P2_rs2 & (P2_r | P2_b));
  wire w_fwd2_P4 = (w_f4f & P4_rd==P2_rs2 & (P2_r | P2_b));
  wire w_fwd3_P3 = (w_f3f & P3_rd==P2_rs2);
  wire w_fwd3_P4 = (w_f4f & P4_rd==P2_rs2);
  assign w_in1 = (w_fwd1_P3) ? P3_alu : (w_fwd1_P4) ? w_rt : P2_r1;
  assign w_in2 = (w_fwd2_P3) ? P3_alu : (w_fwd2_P4) ? w_rt : P2_s2;
  assign w_in3 = (w_fwd3_P3) ? P3_alu : (w_fwd3_P4) ? w_rt : P2_r2;

  // ---- 検証用キャプチャ ----
  always @(posedge w_clk) begin
    if (!P4_s & !P4_b & P4_v & P4_rd==5'd30) r_rslt <= w_rt;  // x30
    if (!w_lduse & w_trap_e) r_trapcnt <= r_trapcnt + 1;
  end
endmodule

// ---- KV260 top: PSのpl_clk0 + m_proc_csr + VIO(結果/トラップ回数) ----
module m_top_kv260;
  wire w_clk;
  wire [31:0] w_rslt, w_trapcnt;
  clk_bd_wrapper m0 (.pl_clk0(w_clk));
  m_proc_csr m1 (w_clk, w_rslt, w_trapcnt);
  vio_0 m3 (w_clk, w_rslt, w_trapcnt);
endmodule
