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

`ifndef UARTDIV
  `define UARTDIV 868          // 100MHz / 115200 (合成用)。simは -DUARTDIV=8 等で上書き
`endif

// ---- UART TX: ボーレート生成 + 16段FIFO + シフトレジスタ(8N1) ----
module m_uart_tx(w_clk, w_we, w_din, w_tx, w_full);
  input  wire w_clk, w_we;
  input  wire [7:0] w_din;
  output wire w_tx, w_full;
  parameter DIV = 868;
  reg [7:0] fifo [0:15];
  reg [3:0] wp=0, rp=0;
  reg [4:0] cnt=0;
  wire empty = (cnt==0);
  assign w_full = (cnt==16);
  reg [9:0] sh = 10'h3ff;
  reg [3:0] nbit = 0;
  reg [15:0] baud = 0;
  reg busy = 0;
  assign w_tx = sh[0];
  wire do_push = w_we & ~w_full;
  wire do_pop  = ~busy & ~empty;
  always @(posedge w_clk) begin
    if (do_push) begin fifo[wp] <= w_din; wp <= wp + 1; end
    if (do_pop) begin
      sh   <= {1'b1, fifo[rp], 1'b0};
      rp   <= rp + 1;
      busy <= 1; nbit <= 10; baud <= DIV-1;
    end else if (busy) begin
      if (baud==0) begin
        baud <= DIV-1;
        sh   <= {1'b1, sh[9:1]};
        nbit <= nbit - 1;
        if (nbit==1) busy <= 0;
      end else baud <= baud - 1;
    end
    case ({do_push, do_pop})
      2'b10: cnt <= cnt + 1;
      2'b01: cnt <= cnt - 1;
      default: cnt <= cnt;
    endcase
  end
endmodule

// ---- UART RX: start検出→1.5bit待ち→8bitサンプル(LSB first)→16段FIFOへ格納(8N1) ----
module m_uart_rx(w_clk, w_rx, w_rd, r_dout, r_valid);
  input  wire w_clk, w_rx, w_rd;
  output wire [7:0] r_dout;
  output wire r_valid;
  parameter DIV = 868;
  reg r0=1, r1=1;
  reg st=0;                              // 0=idle, 1=受信中
  reg [15:0] baud=0;
  reg [3:0] cnt=0;
  reg [7:0] sh=0;
  reg [7:0] fifo [0:15];                 // 受信FIFO(取りこぼし防止)
  reg [3:0] wp=0, rp=0;
  reg [4:0] fcnt=0;                      // FIFO内バイト数 0..16
  wire w_done = (st==1) & (baud==0) & (cnt==8);  // 1バイト揃った
  wire w_push = w_done & (fcnt!=5'd16);
  wire w_pop  = w_rd & (fcnt!=5'd0);
  assign r_valid = (fcnt!=5'd0);
  assign r_dout  = fifo[rp];
  always @(posedge w_clk) begin
    r0 <= w_rx; r1 <= r0;               // 2段同期
    case (st)
      0: if (r1==0) begin st<=1; baud<=DIV+DIV/2-1; cnt<=0; end  // start検出→bit0中央へ
      1: if (baud==0) begin
           baud <= DIV-1;
           if (cnt==8) st <= 0;                                   // 8bit完了
           else begin sh <= {r1, sh[7:1]}; cnt <= cnt + 1; end    // LSB first
         end else baud <= baud - 1;
    endcase
    if (w_push) begin fifo[wp] <= sh; wp <= wp + 1; end
    if (w_pop)  rp <= rp + 1;
    case ({w_push, w_pop})
      2'b10: fcnt <= fcnt + 1;
      2'b01: fcnt <= fcnt - 1;
      default: fcnt <= fcnt;
    endcase
  end
endmodule

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
module m_am_imem(w_pc, w_insn, w_dadr, w_ddata);
  input  wire [31:0] w_pc, w_dadr;
  output wire [31:0] w_insn, w_ddata;
  reg [31:0] mem [0:4095];
  assign w_insn  = mem[w_pc[13:2]];
  assign w_ddata = mem[w_dadr[13:2]];       // データ読み出しポート(rodata/文字列リテラル用)
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
module m_am_dmem(w_clk, w_adr, w_we, w_be, w_wd, w_rd, w_fadr, w_finsn);
  input  wire w_clk, w_we;
  input  wire [3:0]  w_be;
  input  wire [31:0] w_adr, w_wd, w_fadr;
  output wire [31:0] w_rd, w_finsn;
  reg [31:0] mem [0:4095];
  wire [11:0] idx = w_adr[13:2];
  assign w_rd    = mem[idx];
  assign w_finsn = mem[w_fadr[13:2]];      // フェッチ用ポート(DMEM上のプログラム実行)
  always @(posedge w_clk) if (w_we) begin
    if (w_be[0]) mem[idx][7:0]   <= w_wd[7:0];
    if (w_be[1]) mem[idx][15:8]  <= w_wd[15:8];
    if (w_be[2]) mem[idx][23:16] <= w_wd[23:16];
    if (w_be[3]) mem[idx][31:24] <= w_wd[31:24];
  end
  integer i; initial for (i=0; i<4096; i=i+1) mem[i] = 32'd0;
endmodule

// ---- BTB(分岐先キャッシュ): 64エントリ index=pc[7:2], tag=pc[31:8] ----
//   tag+indexでフルPC[31:2]一致=精密(非分岐PCへの誤ヒット無し)。分岐コミット時に書込。
module m_btb(w_clk, w_rpc, w_hit, w_tgt, w_wpc, w_we, w_wtgt);
  input  wire w_clk, w_we;
  input  wire [31:0] w_rpc, w_wpc, w_wtgt;
  output wire w_hit;
  output wire [31:0] w_tgt;
  reg [56:0] mem [0:63];                    // {valid(1), tag=pc[31:8](24), target(32)}
  always @(posedge w_clk) if (w_we) mem[w_wpc[7:2]] <= {1'b1, w_wpc[31:8], w_wtgt};
  wire w_v; wire [23:0] w_tag; wire [31:0] w_data;
  assign {w_v, w_tag, w_data} = mem[w_rpc[7:2]];
  assign w_hit = w_v & (w_tag == w_rpc[31:8]);
  assign w_tgt = w_data;
  integer i; initial for (i=0;i<64;i=i+1) mem[i]=0;
endmodule

// ---- gshare 予測器: 64エントリPHT(2bit飽和), index=pc[7:2]^BHR(6bit) ----
//   予測=cnt[1]。分岐解決(w_tkn)でカウンタ更新+BHRシフト。初期値1(weakly not-taken)。
module m_gshare(w_clk, w_rpc, w_pred, w_wpc, w_we, w_tkn);
  input  wire w_clk, w_we;
  input  wire [31:0] w_rpc, w_wpc;
  input  wire w_tkn;
  output wire w_pred;
  reg [1:0] mem [0:63];
  reg [5:0] r_bhr = 0;
  wire [5:0] w_ridx = w_rpc[7:2] ^ r_bhr;
  wire [5:0] w_widx = w_wpc[7:2] ^ r_bhr;
  assign w_pred = mem[w_ridx][1];
  wire [1:0] w_cnt = mem[w_widx];
  always @(posedge w_clk) if (w_we) begin
    mem[w_widx] <= (w_cnt<3 & w_tkn) ? w_cnt+2'd1 : (w_cnt>0 & !w_tkn) ? w_cnt-2'd1 : w_cnt;
    r_bhr <= {w_tkn, r_bhr[5:1]};
  end
  integer i; initial for (i=0;i<64;i=i+1) mem[i]=2'd1;
endmodule

// ============================================================
// 5段パイプライン 完全RV32I
// ============================================================
module m_proc_console(w_clk, r_rslt, r_done, uart_tx, uart_rx);
  input  wire w_clk;
  output reg [31:0] r_rslt = 0;    // RESULT port(0x20000)に書かれた値
  output reg [31:0] r_done = 0;    // 結果書込みで1(以後保持), VIO liveness
  output wire uart_tx;             // PL UART 送信(PMODへ)
  input  wire uart_rx;             // PL UART 受信(PMODから)

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
  reg P2_m=0;                       // RV32M命令(EX段)
  // ---- RV32M 除算器(多サイクル反復)の状態 ----
  reg        r_dbusy=0, r_ddone=0;
  reg [5:0]  r_dcnt=0;
  reg [31:0] r_acc=0, r_q=0, r_dvsr=0, r_dividend=0;
  reg        r_qneg=0, r_rneg=0, r_wantrem=0, r_div0=0;
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
  wire w_muldiv = w_r & P1_ir[25];              // RV32M: R形式 funct7=0000001(bit25)

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
       (P2_csraddr==12'h344) ? {20'd0, w_meip, 3'd0, w_mtip, 7'd0} :  // mip: bit11=MEIP,bit7=MTIP
                               32'd0;
  wire [31:0] w_csr_new = (P2_f3==3'b010) ? (w_csr_old | w_in1) : w_in1;  // csrrs=OR / csrrw=上書
  wire w_csr_we = P2_csr & P2_v & ~((P2_f3==3'b010) & (P2_rs1==5'd0));

  // 除算がEX段で計算中はパイプラインを停止(結果完了 r_ddone まで)
  wire w_div_stall = P2_m & P2_f3[2] & P2_v & ~r_ddone;

  // ---- 分岐予測(BTB+gshare): 条件分岐をフェッチ段で予測 ----
  reg  r_bp_en = 1'b1;                  // 予測ON/OFF(A/B測定, MMIO 0x0005_0000で書換)
  reg  [31:0] r_bp_miss=0, r_bp_brn=0;  // 観測: ミス予測回数 / コミット分岐回数
  wire w_brcond;                        // m_bru の分岐条件(後段でassign)
  wire w_bp_hit, w_bp_pred;  wire [31:0] w_bp_tgt;
  wire w_br_commit = P2_b & P2_v & !w_stall;     // 分岐が1回処理される
  m_btb    mbtb (w_clk, r_pc, w_bp_hit, w_bp_tgt, P2_pc, w_br_commit, P2_tpc);
  m_gshare mgsh (w_clk, r_pc, w_bp_pred, P2_pc, w_br_commit, w_brcond);
  wire w_bp_tkn = r_bp_en & w_bp_hit & w_bp_pred;             // 投機taken
  wire [31:0] w_br_truepc = (P2_b & P2_v & w_brcond) ? P2_tpc : (P2_pc + 32'd4);
  wire w_bmiss = P2_b & P2_v & P1_v & (P1_pc != w_br_truepc); // 予測ミス(P1の実フェッチ先≠真の次PC)

  // ---- リダイレクト(P2境界): 割込み > 分岐ミス/ジャンプ/トラップ ----
  wire w_take_jal  = P2_jal & P2_v;
  wire w_take_jalr = P2_jalr& P2_v;
  wire w_trap_e    = P2_ecall & P2_v;               // ecall
  wire w_trap_r    = P2_mret  & P2_v;               // mret
  // 割込み: MIE & ((MTIE&MTIP) | (MEIE&MEIP))。MEIP=UART RX有(rx_valid)。
  wire w_meip      = w_rx_valid;                     // 外部割込み保留(UART RX)
  wire w_ext_pend  = csr_mie[11] & w_meip;           // 外部(UART)割込み
  wire w_tmr_pend  = csr_mie[7]  & w_mtip;           // タイマ割込み
  wire w_irq       = csr_mstatus[3] & (w_ext_pend | w_tmr_pend);
  wire w_take_irq  = w_irq & P2_v & ~P2_ecall & ~P2_mret & ~w_div_stall;  // 除算中は保留(完了後に受理)
  wire w_redir     = w_take_irq | w_bmiss | w_take_jal | w_take_jalr | w_trap_e | w_trap_r;
  assign w_pcin = (w_take_irq | w_trap_e)  ? csr_mtvec :          // 割込み/ecall: ->mtvec
                  (w_trap_r)               ? csr_mepc :           // mret : ->mepc
                  (w_take_jalr)            ? (w_alu & ~32'd1) :    // jalr: (rs1+imm)&~1
                  (w_take_jal)             ? P2_tpc :             // jal: pc+imm(予測対象外)
                  (w_bmiss)                ? w_br_truepc :        // 分岐ミス回復: 真の次PCへ
                  (w_bp_tkn)               ? w_bp_tgt :           // 投機: 予測taken先へ
                                             w_npc;               // pc+4(逐次/予測not-taken)
  // ---- 観測カウンタ(0x0005_0004書込でリセット) ----
  always @(posedge w_clk) begin
    if (w_st & (P3_alu==32'h0005_0004)) begin r_bp_miss<=0; r_bp_brn<=0; end
    else begin
      if (w_bmiss & !w_stall) r_bp_miss <= r_bp_miss + 32'd1;
      if (w_br_commit)        r_bp_brn  <= r_bp_brn  + 32'd1;
    end
  end

  wire w_lduse = P3_v & P3_ld &
       ((P3_rd==P2_rs1) | ((P3_rd==P2_rs2) & (P2_r | P2_b | P2_s)));
  wire w_stall = w_lduse | w_div_stall;         // ロード使用ハザード or 除算中

  wire [31:0] w_imem_word, w_imem_insn, w_dmem_insn;
  m_adder   m2 (32'h4, r_pc, w_npc);
  m_am_imem m3 (r_pc, w_imem_insn, P3_alu, w_imem_word);   // 第2ポート=データ読み(P3_alu)
  // フェッチ: PCがDMEM領域(0x0001_xxxx)ならDMEMから、それ以外はIMEMから命令を取る
  assign w_ir = (r_pc[31:16]==16'h0001) ? w_dmem_insn : w_imem_insn;
  m_gen_imm m4 (P1_ir, w_imm, w_r, w_i, w_s, w_b, w_u, w_j);
  m_RF2     m5 (w_clk, P1_ir[19:15], P1_ir[24:20], w_r1, w_r2,
                P4_rd, !P4_s & !P4_b & P4_v, w_rt);
  m_adder   m6 (w_imm, P1_pc, w_tpc);                 // pc+imm (branch/jal target)
  m_mux     m7 (w_r2, w_imm, !w_r & !w_b, w_s2);      // ALU in2 = (R|B)?rs2:imm

  // ---- IF/ID -> EX ----
  always @(posedge w_clk) if (!w_stall) begin
    {P1_v, P2_v} <= {!w_redir, !w_redir & P1_v};
    {r_pc, P1_ir, P1_pc, P2_pc} <= {w_pcin, w_ir, r_pc, P1_pc};
    {P2_r1, P2_r2, P2_s2, P2_tpc} <= {w_r1, w_r2, w_s2, w_tpc};
    {P2_r, P2_s, P2_b, P2_ld} <= {w_r, w_s, w_b, w_ld};
    {P2_rs2, P2_rs1, P2_rd} <= {P1_ir[24:15], P1_ir[11:7]};
    {P2_f3, P2_sub, P2_sra, P2_usef3} <= {w_f3, w_sub, w_sra, w_usef3};
    {P2_jal, P2_jalr, P2_lui, P2_auipc} <= {w_jal, w_jalr, w_lui, w_auipc};
    {P2_csr, P2_ecall, P2_mret, P2_csraddr} <= {w_csr, w_ecall, w_mret, w_csraddr};
    P2_m <= w_muldiv;
  end else if (w_lduse) {P2_r1, P2_r2, P2_s2} <= {w_in1, w_in3, w_in2};

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
    {P3_v, P4_v} <= {P2_v & !w_stall & !w_take_irq, P3_v};  // ストール/割込み中はP3へ通さない(バブル)
    {P3_pc, P3_ld, P3_in3, P3_f3} <= {P2_pc, P2_ld, w_in3, P2_f3};
    // WB値: CSR命令->旧値 / jump->pc+4 / M命令->乗除算結果 / それ以外->ALU
    P3_alu <= P2_csr ? w_csr_old : (w_jump ? (P2_pc + 32'd4) : (P2_m ? w_m_out : w_alu));
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
  m_am_dmem m9 (w_clk, P3_alu, w_st & w_is_dmem, w_be, w_wdata, w_word, r_pc, w_dmem_insn);
  // ---- タイマMMIO(0x0003_xxxx): 64bitを上下2ワードで, lw/sw前提 ----
  wire w_is_timer = (P3_alu[31:16]==16'h0003);
  wire [31:0] w_timer_rd =
       (P3_alu==32'h0003_0000) ? mtimecmp[31:0]  :
       (P3_alu==32'h0003_0004) ? mtimecmp[63:32] :
       (P3_alu==32'h0003_0008) ? mtime[31:0]     :
       (P3_alu==32'h0003_000C) ? mtime[63:32]    : 32'd0;
  // ロード対象の生ワード: text/rodata領域(0x0000_xxxx)はIMEM, DMEM領域はDMEM
  wire w_is_imem = (P3_alu[31:16]==16'h0000);
  wire [31:0] w_ld_word = w_is_imem ? w_imem_word : w_word;
  // 幅/符号拡張(imem/dmem共通)。タイマ領域はワード。
  wire [31:0] w_sh = w_ld_word >> (8*w_boff);
  wire [31:0] w_ldd_mem =
                 (P3_f3==3'b000) ? {{24{w_sh[7]}},  w_sh[7:0]}  :   // lb
                 (P3_f3==3'b100) ? {24'd0,          w_sh[7:0]}  :   // lbu
                 (P3_f3==3'b001) ? {{16{w_sh[15]}}, w_sh[15:0]} :   // lh
                 (P3_f3==3'b101) ? {16'd0,          w_sh[15:0]} :   // lhu
                                    w_ld_word;                      // lw
  // ---- UART MMIO(0x0004_xxxx): TX=0x40000(w), STAT=0x40004(r), RX=0x40008(r) ----
  wire w_is_uart   = (P3_alu[31:16]==16'h0004);
  wire w_tx_full, w_rx_valid;
  wire [7:0] w_rx_byte;
  wire w_uart_tx_we = w_st & (P3_alu==32'h0004_0000);          // TX書き込み
  wire w_uart_rx_rd = P3_ld & P3_v & (P3_alu==32'h0004_0008);  // RX読み出しでpop
  wire [31:0] w_uart_rd =
       (P3_alu==32'h0004_0004) ? {30'd0, w_tx_full, w_rx_valid} :  // STAT: bit0=rx有, bit1=tx満杯
       (P3_alu==32'h0004_0008) ? {24'd0, w_rx_byte}             :  // RXバイト
                                 32'd0;
  m_uart_tx #(.DIV(`UARTDIV)) u_tx (w_clk, w_uart_tx_we, P3_in3[7:0], uart_tx, w_tx_full);
  m_uart_rx #(.DIV(`UARTDIV)) u_rx (w_clk, uart_rx, w_uart_rx_rd, w_rx_byte, w_rx_valid);

  // ---- 分岐予測 MMIO(0x0005_xxxx): en書換/カウンタ読出(A/B測定用) ----
  wire w_is_bp = (P3_alu[31:16]==16'h0005);
  wire [31:0] w_bp_rd =
       (P3_alu==32'h0005_0000) ? {31'd0, r_bp_en} :   // 予測ON/OFF
       (P3_alu==32'h0005_0004) ? r_bp_miss        :   // ミス予測回数
       (P3_alu==32'h0005_0008) ? r_bp_brn         :   // コミット分岐回数
                                 32'd0;

  assign w_ldd = w_is_uart ? w_uart_rd : w_is_timer ? w_timer_rd : w_is_bp ? w_bp_rd : w_ldd_mem;

  // ---- mtime 自走 + mtimecmp ストア + 分岐予測制御 ----
  always @(posedge w_clk) begin
    mtime <= mtime + 64'd1;
    if (w_st & (P3_alu==32'h0003_0000)) mtimecmp[31:0]  <= P3_in3;   // mtimecmp lo
    if (w_st & (P3_alu==32'h0003_0004)) mtimecmp[63:32] <= P3_in3;   // mtimecmp hi
    if (w_st & (P3_alu==32'h0005_0000)) r_bp_en <= P3_in3[0];        // 予測ON/OFF書換
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

  // ================= RV32M: 乗算(組合せ/DSP) / 除算(多サイクル反復) =================
  // 乗算: 符号有無に応じ33bitへ拡張し 33x33 積の上位/下位を取る(MUL/MULH/MULHSU/MULHU)
  wire w_ms1 = (P2_f3==3'b001) | (P2_f3==3'b010);        // MULH/MULHSU: rs1 符号付
  wire w_ms2 = (P2_f3==3'b001);                          // MULH: rs2 符号付
  wire signed [32:0] w_mopa = {w_ms1 & w_in1[31], w_in1};
  wire signed [32:0] w_mopb = {w_ms2 & w_in2[31], w_in2};
  wire signed [65:0] w_mprod = w_mopa * w_mopb;
  wire [31:0] w_mul_out = (P2_f3==3'b000) ? w_mprod[31:0] : w_mprod[63:32];

  // 除算: DIV(100)/DIVU(101)/REM(110)/REMU(111)。被除数/除数の絶対値で無符号除算し符号を後付け。
  wire w_divop   = P2_m & P2_f3[2];
  wire w_dsigned = ~P2_f3[0];                            // 100/110=符号付, 101/111=無し
  wire w_dn1 = w_dsigned & w_in1[31];
  wire w_dn2 = w_dsigned & w_in2[31];
  wire [31:0] w_absn = w_dn1 ? (~w_in1 + 32'd1) : w_in1; // |被除数|
  wire [31:0] w_absd = w_dn2 ? (~w_in2 + 32'd1) : w_in2; // |除数|
  wire [31:0] w_shifted = {r_acc[30:0], r_q[31]};        // 剰余を1bit左シフト+次桁導入
  wire w_ge = (w_shifted >= r_dvsr);
  wire w_div_start = w_divop & P2_v & ~r_dbusy & ~r_ddone & ~w_lduse;

  always @(posedge w_clk) begin
    if (w_div_start) begin                               // 除算開始:オペランド取り込み
      r_dbusy<=1; r_dcnt<=0; r_acc<=0;
      r_q<=w_absn; r_dvsr<=w_absd;
      r_qneg<=w_dn1^w_dn2; r_rneg<=w_dn1;                // 商符号=被除数^除数, 剰余符号=被除数
      r_wantrem<=P2_f3[1]; r_div0<=(w_in2==32'd0); r_dividend<=w_in1;
    end else if (r_dbusy) begin                          // 32回の反復
      if (r_dcnt==6'd32) begin r_dbusy<=0; r_ddone<=1; end
      else begin
        r_acc <= w_ge ? (w_shifted - r_dvsr) : w_shifted;
        r_q   <= {r_q[30:0], w_ge};
        r_dcnt<= r_dcnt + 6'd1;
      end
    end
    if (r_ddone & ~w_lduse) r_ddone<=0;                  // コミット後にクリア
  end

  // 除算結果(符号適用 + 特殊ケース: 0除算は DIV->-1 / REM->被除数)
  wire [31:0] w_div_q = r_qneg ? (~r_q   + 32'd1) : r_q;
  wire [31:0] w_div_r = r_rneg ? (~r_acc + 32'd1) : r_acc;
  wire [31:0] w_div_out = r_div0 ? (r_wantrem ? r_dividend : 32'hFFFFFFFF)
                                 : (r_wantrem ? w_div_r : w_div_q);
  wire [31:0] w_m_out = w_divop ? w_div_out : w_mul_out;

  // ---- CSR 書き込み / トラップ(P2, lduse でない時) ----
  //   優先: 割込み > ecall > mret > csr書込。割込み/ecallは MPIE<-MIE,MIE<-0。
  always @(posedge w_clk) if (!w_lduse) begin
    if (w_take_irq) begin                // 割込みエントリ(P2命令に相乗り→復帰点)
      csr_mepc      <= P2_pc;            // 割込まれた命令のPC(再実行する)
      csr_mcause    <= w_ext_pend ? 32'h8000_000B : 32'h8000_0007;  // 外部(UART)=11 / タイマ=7
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

// ---- KV260 top: PSのpl_clk0 + m_proc_console + UART(PMOD) + VIO ----
module m_top_kv260(uart_tx, uart_rx);
  output wire uart_tx;
  input  wire uart_rx;
  wire w_clk;
  wire [31:0] w_rslt, w_done;
  clk_bd_wrapper m0 (.pl_clk0(w_clk));
  m_proc_console m1 (w_clk, w_rslt, w_done, uart_tx, uart_rx);
  vio_0 m3 (w_clk, w_rslt, w_done);
endmodule
