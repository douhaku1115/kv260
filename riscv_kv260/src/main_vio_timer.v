// ============================================================
// RISC-V on KV260 - 完全RV32I + CSR/例外 統合コア (5段)  [第2段+第3段の合流]
//   第3段の完全RV32I に 第2段のCSR/例外(csrrw/csrrs/ecall/mret)を統合。
//   CSR=mtvec(0x305)/mepc(0x341)/mcause(0x342)/mscratch(0x340)。
//   ecall: mepc<-PC,mcause<-11,PC<-mtvec / mret: PC<-mepc。
//   トラップは分岐/ジャンプと同じ P2境界で処理(w_redir に相乗り)。KOZOS/割込みの土台。
// --- 以下 第3段RV32Iコアの説明 ---
//   教科書 m_proc9(最小)を拡張し RV32I(base整数)を全実装:
//     - ALU: add/sub/sll/slt/sltu/xor/srl/sra/or/and (R+I)
//     - 分岐: beq/bne/blt/bge/bltu/bgeu
//     - ジャンプ: jal/jalr (rd<-pc+4)
//     - lui/auipc
//     - ロード/ストア: lb/lh/lw/lbu/lhu / sb/sh/sw (バイトイネーブル)
//   メモリマップ(Harvard):
//     IMEM(text)  : 0x0000_0000.. (4096語=16KB, フェッチ)
//     DMEM(data)  : 0x0001_0000.. (4096語=16KB, load/store)  is_dmem=adr[31:16]==0x0001
//     RESULT port : 0x0002_0000    (storeで結果を捕捉→VIO r_rslt, r_done)
//   命令メモリは include で焼く(既定 asm_gcc.txt。手テストは -DPROG で差替)。
//   ※CSR/例外(第2段 main_vio_csr.v)は未統合。KOZOS本番で合流。
// ============================================================

module m_get_type(opcode5, r, i, s, b, u, j);
  input  wire [4:0] opcode5;
  output wire r, i, s, b, u, j;
  assign j = (opcode5==5'b11011);          // jal
  assign b = (opcode5==5'b11000);          // branch
  assign s = (opcode5==5'b01000);          // store
  assign r = (opcode5==5'b01100);          // OP (R-type)
  assign u = (opcode5==5'b01101 || opcode5==5'b00101);  // lui / auipc
  assign i = ~(j | b | s | r | u);         // OP-IMM / load / jalr / system
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

module m_gen_imm(w_ir, w_imm, w_r, w_i, w_s, w_b, w_u, w_j);
  input  wire [31:0] w_ir;
  output wire [31:0] w_imm;
  output wire w_r, w_i, w_s, w_b, w_u, w_j;
  m_get_type m1 (w_ir[6:2], w_r, w_i, w_s, w_b, w_u, w_j);
  m_get_imm  m2 (w_ir, w_i, w_s, w_b, w_u, w_j, w_imm);
endmodule

// ---- 完全ALU (R/I) : funct3 + sub + sra で全演算 ----
module m_alu(w_in1, w_in2, w_f3, w_sub, w_sra, w_out);
  input  wire [31:0] w_in1, w_in2;
  input  wire [2:0]  w_f3;
  input  wire w_sub, w_sra;
  output reg  [31:0] w_out;
  wire [4:0]  sh   = w_in2[4:0];
  // シフトは別wireに分離(三項の符号混在で >>> が論理化するのを防ぐ)
  wire [31:0] w_srl = w_in1 >> sh;                 // 論理右
  wire [31:0] w_sar = $signed(w_in1) >>> sh;       // 算術右(自己決定で符号付き)
  always @(*) case (w_f3)
    3'b000: w_out = w_sub ? (w_in1 - w_in2) : (w_in1 + w_in2);          // add/sub
    3'b001: w_out = w_in1 << sh;                                        // sll
    3'b010: w_out = ($signed(w_in1) < $signed(w_in2)) ? 32'd1 : 32'd0;  // slt
    3'b011: w_out = (w_in1 < w_in2) ? 32'd1 : 32'd0;                    // sltu
    3'b100: w_out = w_in1 ^ w_in2;                                      // xor
    3'b101: w_out = w_sra ? w_sar : w_srl;                              // srl/sra
    3'b110: w_out = w_in1 | w_in2;                                      // or
    3'b111: w_out = w_in1 & w_in2;                                      // and
  endcase
endmodule

// ---- 分岐条件 (funct3) ----
module m_bru(w_in1, w_in2, w_f3, w_tkn);
  input  wire [31:0] w_in1, w_in2;
  input  wire [2:0]  w_f3;
  output reg  w_tkn;
  always @(*) case (w_f3)
    3'b000: w_tkn = (w_in1 == w_in2);                       // beq
    3'b001: w_tkn = (w_in1 != w_in2);                       // bne
    3'b100: w_tkn = ($signed(w_in1) <  $signed(w_in2));     // blt
    3'b101: w_tkn = ($signed(w_in1) >= $signed(w_in2));     // bge
    3'b110: w_tkn = (w_in1 <  w_in2);                       // bltu
    3'b111: w_tkn = (w_in1 >= w_in2);                       // bgeu
    default: w_tkn = 1'b0;
  endcase
endmodule

// ---- 命令メモリ(4096語=16KB), reset=0 から実行 ----
module m_am_imem(w_pc, w_insn);
  input  wire [31:0] w_pc;
  output wire [31:0] w_insn;
  reg [31:0] mem [0:4095];
  assign w_insn = mem[w_pc[13:2]];
  integer i; initial for (i=0; i<4096; i=i+1) mem[i] = 32'd0;
`ifndef PROG
  `define PROG "asm_gcc.txt"
`endif
  initial begin
    `define MM mem
    `include `PROG
  end
endmodule

// ---- データメモリ(4096語=16KB) バイトイネーブル書き込み ----
module m_am_dmem(w_clk, w_adr, w_we, w_be, w_wd, w_rd);
  input  wire w_clk, w_we;
  input  wire [3:0]  w_be;
  input  wire [31:0] w_adr, w_wd;
  output wire [31:0] w_rd;
  reg [31:0] mem [0:4095];
  wire [11:0] idx = w_adr[13:2];
  assign w_rd = mem[idx];
  always @(posedge w_clk) if (w_we) begin
    if (w_be[0]) mem[idx][7:0]   <= w_wd[7:0];
    if (w_be[1]) mem[idx][15:8]  <= w_wd[15:8];
    if (w_be[2]) mem[idx][23:16] <= w_wd[23:16];
    if (w_be[3]) mem[idx][31:24] <= w_wd[31:24];
  end
  integer i; initial for (i=0; i<4096; i=i+1) mem[i] = 32'd0;
endmodule

// ============================================================
// 5段パイプライン 完全RV32I
// ============================================================
module m_proc_timer(w_clk, r_rslt, r_done);
  input  wire w_clk;
  output reg [31:0] r_rslt = 0;    // RESULT port(0x20000)に書かれた値
  output reg [31:0] r_done = 0;    // 結果書込みで1(以後保持), VIO liveness

  reg [31:0] P1_ir=32'h13, P1_pc=0, P2_pc=0, P3_pc=0, P4_pc=0;
  reg [31:0] P2_r1=0, P2_s2=0, P2_r2=0, P2_tpc=0;
  reg [31:0] P3_alu, P3_in3, P4_alu=0, P4_ldd=0;
  reg P2_r=0, P2_s=0, P2_b=0, P2_ld=0, P4_s=0, P4_b=0, P4_ld=0;
  reg P3_s=0, P3_b=0, P3_ld=0;
  reg P2_sub=0, P2_sra=0, P2_jal=0, P2_jalr=0, P2_lui=0, P2_auipc=0, P2_usef3=0;
  reg P2_csr=0, P2_ecall=0, P2_mret=0;          // CSR/例外(第2段統合)
  reg [11:0] P2_csraddr=0;
  reg [2:0] P2_f3=0, P3_f3=0;
  // ---- CSR ファイル ----
  reg [31:0] csr_mtvec=0, csr_mepc=0, csr_mcause=0, csr_mscratch=0;
  reg [31:0] csr_mstatus=0;      // bit3=MIE, bit7=MPIE
  reg [31:0] csr_mie=0;          // bit7=MTIE
  // ---- マシンタイマ(64bit, メモリマップド) ----
  reg [63:0] mtime=0;            // 自走カウンタ(毎サイクル+1)
  reg [63:0] mtimecmp=64'hFFFF_FFFF_FFFF_FFFF;
  wire w_mtip = (mtime >= mtimecmp);            // mip.MTIP
  reg [4:0] P2_rd=0, P2_rs1=0, P2_rs2=0, P3_rd=0, P4_rd=0;
  reg P1_v=0, P2_v=0, P3_v=0, P4_v=0;
  reg [31:0] r_pc = 0;

  wire [31:0] w_npc, w_ir, w_imm, w_r1, w_r2, w_s2, w_rt;
  wire [31:0] w_alu, w_ldd, w_tpc, w_pcin, w_in1, w_in2, w_in3, w_alu_in1;
  wire w_r, w_i, w_s, w_b, w_u, w_j;

  // ---- P1(ID) デコード ----
  wire [4:0] w_op5 = P1_ir[6:2];
  wire [2:0] w_f3  = P1_ir[14:12];
  wire w_ld    = (w_op5==5'b00000);              // load
  wire w_jal   = (w_op5==5'b11011);
  wire w_jalr  = (w_op5==5'b11001);
  wire w_lui   = (w_op5==5'b01101);
  wire w_auipc = (w_op5==5'b00101);
  wire w_sub   = w_r & (w_f3==3'b000) & P1_ir[30];   // R-type sub
  wire w_sra   = (w_f3==3'b101) & P1_ir[30];         // srl/sra 判別
  // ALU が funct3 を使うのは OP(R形式)と OP-IMM のみ。
  // ロード/ストア/lui/auipc/jal/jalr はアドレス・リンク計算=常に加算。
  wire w_usef3 = w_r | (w_op5==5'b00100);

  // ---- SYSTEM命令(CSR/例外)のデコード ----
  wire w_sys      = (w_op5==5'b11100);
  wire w_ecall    = w_sys & (w_f3==3'b000) & (P1_ir[31:20]==12'h000);
  wire w_mret     = w_sys & (w_f3==3'b000) & (P1_ir[31:20]==12'h302);
  wire w_csr      = w_sys & (w_f3!=3'b000);          // csrrw(001)/csrrs(010)
  wire [11:0] w_csraddr = P1_ir[31:20];

  // ---- CSR 読み出し(旧値)/書き込み新値 ----
  wire [31:0] w_csr_old =
       (P2_csraddr==12'h305) ? csr_mtvec :
       (P2_csraddr==12'h341) ? csr_mepc :
       (P2_csraddr==12'h342) ? csr_mcause :
       (P2_csraddr==12'h340) ? csr_mscratch :
       (P2_csraddr==12'h300) ? csr_mstatus :
       (P2_csraddr==12'h304) ? csr_mie :
       (P2_csraddr==12'h344) ? {24'd0, w_mtip, 7'd0} :   // mip: bit7=MTIP
                               32'd0;
  wire [31:0] w_csr_new = (P2_f3==3'b010) ? (w_csr_old | w_in1) : w_in1;  // csrrs=OR / csrrw=上書
  wire w_csr_we = P2_csr & P2_v & ~((P2_f3==3'b010) & (P2_rs1==5'd0));

  // ---- リダイレクト(P2境界): 割込み > 分岐/ジャンプ/トラップ ----
  wire w_brcond;
  wire w_take_b    = P2_b   & w_brcond & P2_v;
  wire w_take_jal  = P2_jal & P2_v;
  wire w_take_jalr = P2_jalr& P2_v;
  wire w_trap_e    = P2_ecall & P2_v;               // ecall
  wire w_trap_r    = P2_mret  & P2_v;               // mret
  // タイマ割込み: MIE & MTIE & MTIP。P2の有効命令(ecall/mret以外)に相乗り。
  wire w_irq       = csr_mstatus[3] & csr_mie[7] & w_mtip;
  wire w_take_irq  = w_irq & P2_v & ~P2_ecall & ~P2_mret;
  wire w_redir     = w_take_irq | w_take_b | w_take_jal | w_take_jalr | w_trap_e | w_trap_r;
  assign w_pcin = (w_take_irq | w_trap_e)  ? csr_mtvec :          // 割込み/ecall: ->mtvec
                  (w_trap_r)               ? csr_mepc :           // mret : ->mepc
                  (w_take_jalr)            ? (w_alu & ~32'd1) :    // jalr: (rs1+imm)&~1
                  (w_take_b | w_take_jal)  ? P2_tpc :             // branch/jal: pc+imm
                                             w_npc;               // pc+4

  wire w_lduse = P3_v & P3_ld &
       ((P3_rd==P2_rs1) | ((P3_rd==P2_rs2) & (P2_r | P2_b | P2_s)));

  m_adder   m2 (32'h4, r_pc, w_npc);
  m_am_imem m3 (r_pc, w_ir);
  m_gen_imm m4 (P1_ir, w_imm, w_r, w_i, w_s, w_b, w_u, w_j);
  m_RF2     m5 (w_clk, P1_ir[19:15], P1_ir[24:20], w_r1, w_r2,
                P4_rd, !P4_s & !P4_b & P4_v, w_rt);
  m_adder   m6 (w_imm, P1_pc, w_tpc);                 // pc+imm (branch/jal target)
  m_mux     m7 (w_r2, w_imm, !w_r & !w_b, w_s2);      // ALU in2 = (R|B)?rs2:imm

  // ---- IF/ID -> EX ----
  always @(posedge w_clk) if (!w_lduse) begin
    {P1_v, P2_v} <= {!w_redir, !w_redir & P1_v};
    {r_pc, P1_ir, P1_pc, P2_pc} <= {w_pcin, w_ir, r_pc, P1_pc};
    {P2_r1, P2_r2, P2_s2, P2_tpc} <= {w_r1, w_r2, w_s2, w_tpc};
    {P2_r, P2_s, P2_b, P2_ld} <= {w_r, w_s, w_b, w_ld};
    {P2_rs2, P2_rs1, P2_rd} <= {P1_ir[24:15], P1_ir[11:7]};
    {P2_f3, P2_sub, P2_sra, P2_usef3} <= {w_f3, w_sub, w_sra, w_usef3};
    {P2_jal, P2_jalr, P2_lui, P2_auipc} <= {w_jal, w_jalr, w_lui, w_auipc};
    {P2_csr, P2_ecall, P2_mret, P2_csraddr} <= {w_csr, w_ecall, w_mret, w_csraddr};
  end else {P2_r1, P2_r2, P2_s2} <= {w_in1, w_in3, w_in2};

  // ---- ALU入力1: lui->0, auipc->pc, それ以外->rs1 ----
  assign w_alu_in1 = (P2_lui) ? 32'd0 : (P2_auipc) ? P2_pc : w_in1;
  // ALU実効演算: OP/OP-IMM は funct3、それ以外は加算(アドレス/リンク計算)
  wire [2:0] w_ef3  = P2_usef3 ? P2_f3  : 3'b000;
  wire       w_esub = P2_usef3 & P2_sub;
  wire       w_esra = P2_usef3 & P2_sra;
  m_alu m8  (w_alu_in1, w_in2, w_ef3, w_esub, w_esra, w_alu);
  m_bru m8b (w_in1, w_in2, P2_f3, w_brcond);

  wire w_jump = P2_jal | P2_jalr;

  // ---- EX -> MEM -> WB ----
  always @(posedge w_clk) begin
    {P3_v, P4_v} <= {P2_v & !w_lduse & !w_take_irq, P3_v};  // 割込まれたP2命令はcommitさせない(二重実行防止)
    {P3_pc, P3_ld, P3_in3, P3_f3} <= {P2_pc, P2_ld, w_in3, P2_f3};
    // WB値: CSR命令->旧値 / jump->pc+4 / それ以外->ALU
    P3_alu <= P2_csr ? w_csr_old : (w_jump ? (P2_pc + 32'd4) : w_alu);
    P3_rd  <= P2_rd;
    {P3_s, P3_b, P3_ld} <= {P2_s, P2_b, P2_ld};
    {P4_pc, P4_s, P4_b, P4_ld} <= {P3_pc, P3_s, P3_b, P3_ld};
    {P4_alu, P4_ldd, P4_rd} <= {P3_alu, w_ldd, P3_rd};
  end

  // ---- MEM: アドレスデコード + バイト/ハーフ ld/st ----
  wire [1:0] w_boff = P3_alu[1:0];
  wire w_is_dmem   = (P3_alu[31:16]==16'h0001);           // 0x0001_xxxx
  wire w_is_result = (P3_alu==32'h0002_0000);
  wire w_st        = P3_s & P3_v;
  wire [31:0] w_wdata = P3_in3 << (8*w_boff);             // ストアデータを該当レーンへ
  wire [3:0]  w_be0 = (P3_f3==3'b000) ? 4'b0001 :         // sb
                      (P3_f3==3'b001) ? 4'b0011 :         // sh
                                        4'b1111;          // sw
  wire [3:0]  w_be  = (w_be0 << w_boff);
  wire [31:0] w_word;
  m_am_dmem m9 (w_clk, P3_alu, w_st & w_is_dmem, w_be, w_wdata, w_word);
  // ---- タイマMMIO(0x0003_xxxx): 64bitを上下2ワードで, lw/sw前提 ----
  wire w_is_timer = (P3_alu[31:16]==16'h0003);
  wire [31:0] w_timer_rd =
       (P3_alu==32'h0003_0000) ? mtimecmp[31:0]  :
       (P3_alu==32'h0003_0004) ? mtimecmp[63:32] :
       (P3_alu==32'h0003_0008) ? mtime[31:0]     :
       (P3_alu==32'h0003_000C) ? mtime[63:32]    : 32'd0;
  // ロード: タイマ領域はワード, それ以外は幅/符号拡張
  wire [31:0] w_sh = w_word >> (8*w_boff);
  wire [31:0] w_ldd_dmem =
                 (P3_f3==3'b000) ? {{24{w_sh[7]}},  w_sh[7:0]}  :   // lb
                 (P3_f3==3'b100) ? {24'd0,          w_sh[7:0]}  :   // lbu
                 (P3_f3==3'b001) ? {{16{w_sh[15]}}, w_sh[15:0]} :   // lh
                 (P3_f3==3'b101) ? {16'd0,          w_sh[15:0]} :   // lhu
                                    w_word;                         // lw
  assign w_ldd = w_is_timer ? w_timer_rd : w_ldd_dmem;

  // ---- mtime 自走 + mtimecmp ストア ----
  always @(posedge w_clk) begin
    mtime <= mtime + 64'd1;
    if (w_st & (P3_alu==32'h0003_0000)) mtimecmp[31:0]  <= P3_in3;   // mtimecmp lo
    if (w_st & (P3_alu==32'h0003_0004)) mtimecmp[63:32] <= P3_in3;   // mtimecmp hi
  end

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

  // ---- CSR 書き込み / トラップ(P2, lduse でない時) ----
  //   優先: 割込み > ecall > mret > csr書込。割込み/ecallは MPIE<-MIE,MIE<-0。
  always @(posedge w_clk) if (!w_lduse) begin
    if (w_take_irq) begin                // タイマ割込みエントリ(P2命令に相乗り→復帰点)
      csr_mepc      <= P2_pc;            // 割込まれた命令のPC(再実行する)
      csr_mcause    <= 32'h8000_0007;    // Interrupt + code7(machine timer)
      csr_mstatus[7]<= csr_mstatus[3];   // MPIE <- MIE
      csr_mstatus[3]<= 1'b0;             // MIE  <- 0
    end else if (w_trap_e) begin         // ecall: 例外エントリ
      csr_mepc      <= P2_pc;            // ecall のPC(ハンドラで+4して復帰)
      csr_mcause    <= 32'd11;           // Environment call from M-mode
      csr_mstatus[7]<= csr_mstatus[3];
      csr_mstatus[3]<= 1'b0;
    end else if (w_trap_r) begin         // mret: 復帰
      csr_mstatus[3]<= csr_mstatus[7];   // MIE  <- MPIE
      csr_mstatus[7]<= 1'b1;             // MPIE <- 1
    end else if (P2_csr & P2_v) begin    // csrrw / csrrs
      case (P2_csraddr)
        12'h305: if (w_csr_we) csr_mtvec    <= w_csr_new;
        12'h341: if (w_csr_we) csr_mepc     <= w_csr_new;
        12'h342: if (w_csr_we) csr_mcause   <= w_csr_new;
        12'h340: if (w_csr_we) csr_mscratch <= w_csr_new;
        12'h300: if (w_csr_we) csr_mstatus  <= w_csr_new;   // mstatus
        12'h304: if (w_csr_we) csr_mie      <= w_csr_new;   // mie
        // mip(0x344): MTIP はHW制御。書込みは無視
      endcase
    end
  end

  // ---- 結果ポート捕捉 ----
  always @(posedge w_clk) if (w_st & w_is_result) begin
    r_rslt <= P3_in3;
    r_done <= 1;
  end
endmodule

// ---- KV260 top: PSのpl_clk0 + m_proc_timer + VIO(結果/done) ----
module m_top_kv260;
  wire w_clk;
  wire [31:0] w_rslt, w_done;
  clk_bd_wrapper m0 (.pl_clk0(w_clk));
  m_proc_timer m1 (w_clk, w_rslt, w_done);
  vio_0 m3 (w_clk, w_rslt, w_done);
endmodule
