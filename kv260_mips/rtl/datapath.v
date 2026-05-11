// ============================================================
// datapath.v — データパス (単一サイクル MIPS)
// ============================================================
//
// 【1クロックの処理の流れ】
//
//   PC → imem → [命令デコード] → regfile(読み出し)
//        → ALU → dmem(lw/sw等) → regfile(書き戻し) → PC更新
//
// 【PC更新ロジック (優先順位: exception > eret > jr > jump > branch > +4)】
//
//   exception: PC ← EXC_VEC (0x00000080, imem内の固定例外ベクタ)
//   eret  : PC ← CP0_EPC
//   jr    : PC ← rs レジスタの値
//   j/jal : PC ← {PC+4[31:28], addr26, 2'b00}
//   beq   : PC ← PC+4 + sign_extend(imm16)<<2  (条件成立時)
//   bne   : PC ← PC+4 + sign_extend(imm16)<<2  (条件不成立時: rs≠rt)
//   通常  : PC ← PC + 4
//
// 【jal の特別処理】
//   jal は jump=1 かつ reg_write=1 で識別する。
//   書き込み先: $31, 書き込みデータ: PC+4
//
// 【lui の特別処理】
//   opcode=001111 で検出し、{imm16, 16'b0} を直接書き戻す。
//
// 【HI/LO レジスタ (mult/multu/div/divu/mfhi/mflo)】
//   hilo_write=1 のクロックエッジで演算結果を書き込む。
//   mfhilo=1 のとき write_data = sel_hi ? HI : LO。
//
// 【バイト/ハーフワードアクセス (lb/lbu/lh/lhu/sb/sh) — ビッグエンディアン】
//   書き込み (sb/sh):
//     write_data_mem: バイト/ハーフワードを4回/2回複製して渡す
//     byte_en: alu_result[1:0] と mem_size から生成
//       sb addr[1:0]=00 → byte_en=4'b1000 (mem[31:24])
//       sb addr[1:0]=01 → byte_en=4'b0100
//       sb addr[1:0]=10 → byte_en=4'b0010
//       sb addr[1:0]=11 → byte_en=4'b0001 (mem[7:0])
//       sh addr[1]=0    → byte_en=4'b1100 (mem[31:16])
//       sh addr[1]=1    → byte_en=4'b0011 (mem[15:0])
//   読み出し (lb/lbu/lh/lhu):
//     dmem から常にワード読み出し後、addr[1:0]/addr[1] でスライス+符号拡張
//
// 【halt 信号】
//   halt=1 の間は PC が停止し、byte_en=0 で書き込みも禁止する。
//
// 【CP0 レジスタと例外処理 (Step 11)】
//   実装する CP0 レジスタ:
//     $12 = Status Register (SR):   bit0 = EXL (例外処理中フラグ)
//     $13 = Cause Register:         bits[6:2] = ExcCode
//     $14 = EPC (Exception PC):     例外発生命令のアドレス
//
//   例外発生条件:
//     - syscall 命令: ExcCode = 8
//     - add/addi/sub の符号付きオーバーフロー: ExcCode = 12
//
//   例外発生時の動作 (1クロック):
//     EPC    ← 例外発生命令のPC
//     Cause  ← {24'b0, ExcCode, 2'b0}
//     SR.EXL ← 1
//     PC     ← EXC_VEC (0x0000_0080)
//     reg_write は強制 0 (デスティネーションへの書き込み抑制)
//
//   eret の動作:
//     PC     ← EPC
//     SR.EXL ← 0
//
//   mfc0 rt, $Cn: GPR[rt] ← CP0[Cn]  ($12/$13/$14 のみ対応)
//   mtc0 rt, $Cn: CP0[Cn] ← GPR[rt]
//
//   例外ベクタ: EXC_VEC = 32'h0000_0080 (imem word 32)
//   例外ハンドラをここに配置すること。

module datapath (
    input         clk,
    input         reset,
    input         halt,

    // 制御信号 (control.v から入力)
    input         reg_write,
    input         reg_dst,
    input         alu_src,
    input         branch,
    input         branch_ne,   // bne
    input         branch_ltz,  // bltz: rs < 0
    input         branch_gez,  // bgez: rs >= 0
    input         branch_lez,  // blez: rs <= 0
    input         branch_gtz,  // bgtz: rs > 0
    input         mem_write,
    input         mem_to_reg,
    input         jump,
    input         jr,
    input         imm_zero,
    input  [3:0]  alu_control,
    input         hilo_write,
    input  [1:0]  hilo_op,
    input         mfhilo,
    input         sel_hi,
    input  [1:0]  mem_size,      // 00=byte, 01=halfword, 10=word
    input         mem_unsigned,  // 1=ゼロ拡張ロード (lbu/lhu), 0=符号拡張 (lb/lh)
    // 例外処理 (Step 11)
    input         is_mfc0,
    input         is_mtc0,
    input         is_syscall,
    input         is_eret,
    input         exc_on_ov,

    // 命令メモリ
    output [31:0] pc,
    input  [31:0] instr,

    // デバッグ用レジスタ読み出し
    input  [4:0]  dbg_reg_addr,
    output [31:0] dbg_reg_data
);

    // ---- HI/LO レジスタ ----
    reg [31:0] hi_reg, lo_reg;

    wire [63:0] mult_s  = $signed(rd1) * $signed(rd2);
    wire [63:0] mult_u  = rd1 * rd2;
    wire [31:0] div_rs_abs   = rd1[31] ? (~rd1 + 1) : rd1;
    wire [31:0] div_rt_abs   = rd2[31] ? (~rd2 + 1) : rd2;
    wire [31:0] div_in1      = (hilo_op == 2'b10) ? div_rs_abs : rd1;
    wire [31:0] div_in2      = (hilo_op == 2'b10) ? div_rt_abs : rd2;
    wire [31:0] div_q_common = div_in1 / div_in2;
    wire [31:0] div_r_common = div_in1 % div_in2;
    wire [31:0] div_q_s = (rd1[31] ^ rd2[31]) ? (~div_q_common + 1) : div_q_common;
    wire [31:0] div_r_s = rd1[31]             ? (~div_r_common + 1) : div_r_common;
    wire [31:0] div_q_u = div_q_common;
    wire [31:0] div_r_u = div_r_common;

    // ---- CP0 レジスタ (Step 11) ----
    reg  [31:0] cp0_sr;    // $12: bit0 = EXL
    reg  [31:0] cp0_cause; // $13: bits[6:2] = ExcCode
    reg  [31:0] cp0_epc;   // $14: 例外発生命令のPC

    localparam EXC_VEC = 32'h00000080; // 例外ベクタ (imem word 32)

    // ---- PC レジスタ ----
    reg [31:0] pc_reg;
    wire [31:0] pc_next, pc_plus4, pc_branch, pc_jump;

    assign pc       = pc_reg;
    assign pc_plus4 = pc_reg + 32'd4;

    // ---- 命令フィールド分解 ----
    wire [4:0]  rs    = instr[25:21];
    wire [4:0]  rt    = instr[20:16];
    wire [4:0]  rd    = instr[15:11];
    wire [4:0]  shamt = instr[10:6];
    wire [15:0] imm16  = instr[15:0];
    wire [25:0] addr26 = instr[25:0];

    wire [31:0] sign_imm = {{16{imm16[15]}}, imm16};
    wire [31:0] zero_imm = {16'b0, imm16};

    // sll/srl/sra 検出
    wire shift_instr = (instr[31:26] == 6'b000000) &&
                       ((instr[5:0] == 6'b000000) ||
                        (instr[5:0] == 6'b000010) ||
                        (instr[5:0] == 6'b000011));

    // sllv/srlv/srav 検出
    wire var_shift_instr = (instr[31:26] == 6'b000000) &&
                           ((instr[5:0] == 6'b000100) ||
                            (instr[5:0] == 6'b000110) ||
                            (instr[5:0] == 6'b000111));

    // ---- jal/lui 識別 ----
    wire jal_instr = jump & reg_write;
    wire lui_instr = (instr[31:26] == 6'b001111);

    // ---- 例外検出 (Step 11) ----
    wire alu_overflow; // ALU から
    wire exception = (is_syscall | (exc_on_ov & alu_overflow)) & ~halt;
    wire [4:0] exc_code = is_syscall ? 5'd8 : 5'd12; // 8=Syscall, 12=Overflow

    // ---- CP0 読み出し (mfc0) ----
    wire [31:0] cp0_read_data = (rd == 5'd12) ? cp0_sr    :
                                (rd == 5'd13) ? cp0_cause :
                                (rd == 5'd14) ? cp0_epc   : 32'b0;

    // ---- レジスタファイル ----
    // 例外発生時はデスティネーションへの書き込みを抑制する
    wire reg_write_actual = reg_write & ~exception;
    wire [4:0]  write_reg = jal_instr ? 5'd31 : (reg_dst ? rd : rt);
    wire [31:0] rd1, rd2, dbg_rd3;
    wire [31:0] write_data;

    regfile rf (
        .clk(clk),
        .we3(reg_write_actual),
        .ra1(rs),
        .ra2(rt),
        .ra3(dbg_reg_addr),
        .wa3(write_reg),
        .wd3(write_data),
        .rd1(rd1),
        .rd2(rd2),
        .rd3(dbg_rd3)
    );

    assign dbg_reg_data = dbg_rd3;

    // ---- ALU ----
    wire [31:0] alu_a = (shift_instr | var_shift_instr) ? rd2 : rd1;
    wire [31:0] alu_b = shift_instr    ? {27'b0, shamt}                   :
                        var_shift_instr ? rd1                               :
                        alu_src         ? (imm_zero ? zero_imm : sign_imm) : rd2;
    wire [31:0] alu_result;
    wire        alu_zero;

    alu alu_inst (
        .a(alu_a),
        .b(alu_b),
        .alu_control(alu_control),
        .result(alu_result),
        .zero(alu_zero),
        .overflow(alu_overflow)
    );

    // ---- データメモリ (lw/sw/lb/lbu/lh/lhu/sb/sh) ----

    // byte_en 生成 (ビッグエンディアン)
    // halt 中は書き込み禁止
    reg [3:0] byte_en;
    always @(*) begin
        if (!(mem_write & ~halt))
            byte_en = 4'b0000;
        else case (mem_size)
            2'b00: // sb: バイト単位
                case (alu_result[1:0])
                    2'b00: byte_en = 4'b1000; // offset 0 → mem[31:24]
                    2'b01: byte_en = 4'b0100; // offset 1 → mem[23:16]
                    2'b10: byte_en = 4'b0010; // offset 2 → mem[15:8]
                    2'b11: byte_en = 4'b0001; // offset 3 → mem[7:0]
                endcase
            2'b01: // sh: ハーフワード単位
                byte_en = alu_result[1] ? 4'b0011 : 4'b1100;
            default: // sw: ワード
                byte_en = 4'b1111;
        endcase
    end

    // 書き込みデータのバイト複製 (byte_en で必要なバイトのみ確定)
    wire [31:0] write_data_mem = (mem_size == 2'b00) ? {4{rd2[7:0]}}  : // sb
                                 (mem_size == 2'b01) ? {2{rd2[15:0]}} : // sh
                                                        rd2;             // sw

    wire [31:0] mem_read_data;

    dmem dmem_inst (
        .clk(clk),
        .byte_en(byte_en),
        .addr(alu_result),
        .write_data(write_data_mem),
        .read_data(mem_read_data)
    );

    // 読み出しデータのスライスと符号/ゼロ拡張 (ビッグエンディアン)
    wire [7:0] mem_byte =
        (alu_result[1:0] == 2'b00) ? mem_read_data[31:24] :
        (alu_result[1:0] == 2'b01) ? mem_read_data[23:16] :
        (alu_result[1:0] == 2'b10) ? mem_read_data[15: 8] :
                                      mem_read_data[ 7: 0];

    wire [15:0] mem_half =
        alu_result[1] ? mem_read_data[15:0] : mem_read_data[31:16];

    wire [31:0] mem_data_final =
        (mem_size == 2'b00) ? (mem_unsigned ? {24'b0,          mem_byte}
                                            : {{24{mem_byte[7]}}, mem_byte}) :
        (mem_size == 2'b01) ? (mem_unsigned ? {16'b0,          mem_half}
                                            : {{16{mem_half[15]}}, mem_half}) :
                               mem_read_data;

    // ---- レジスタ書き戻しデータの選択 ----
    assign write_data = jal_instr  ? pc_plus4                   :
                        lui_instr  ? {imm16, 16'b0}              :
                        mfhilo     ? (sel_hi ? hi_reg : lo_reg)  :
                        is_mfc0    ? cp0_read_data               :
                        mem_to_reg ? mem_data_final               :
                                     alu_result;

    // ---- PC 次値の計算 ----
    assign pc_branch = pc_plus4 + (sign_imm << 2);
    assign pc_jump   = {pc_plus4[31:28], addr26, 2'b00};

    wire alu_neg     = rd1[31];
    wire rs_zero     = (rd1 == 32'b0);
    wire branch_taken = (branch     &  alu_zero)              // beq
                      | (branch_ne  & ~alu_zero)              // bne
                      | (branch_ltz &  alu_neg)               // bltz: rs<0
                      | (branch_gez & ~alu_neg)               // bgez: rs>=0
                      | (branch_lez & (alu_neg | rs_zero))    // blez: rs<=0
                      | (branch_gtz & ~alu_neg & ~rs_zero);   // bgtz: rs>0
    wire [31:0] pc_branch_mux = branch_taken ? pc_branch : pc_plus4;

    // 例外が最優先。eret は jr/jump より優先。
    assign pc_next = exception ? EXC_VEC     :
                     is_eret   ? cp0_epc     :
                     jr        ? rd1         :
                     jump       ? pc_jump    :
                                  pc_branch_mux;

    // ---- PC レジスタ更新 ----
    always @(posedge clk) begin
        if (reset)
            pc_reg <= 32'b0;
        else if (!halt)
            pc_reg <= pc_next;
    end

    // ---- HI/LO レジスタ更新 ----
    always @(posedge clk) begin
        if (reset) begin
            hi_reg <= 32'b0;
            lo_reg <= 32'b0;
        end else if (hilo_write & ~halt) begin
            case (hilo_op)
                2'b00: {hi_reg, lo_reg} <= mult_s;
                2'b01: {hi_reg, lo_reg} <= mult_u;
                2'b10: begin hi_reg <= div_r_s; lo_reg <= div_q_s; end
                2'b11: begin hi_reg <= div_r_u; lo_reg <= div_q_u; end
            endcase
        end
    end

    // ---- CP0 レジスタ更新 (Step 11) ----
    always @(posedge clk) begin
        if (reset) begin
            cp0_sr    <= 32'b0;
            cp0_cause <= 32'b0;
            cp0_epc   <= 32'b0;
        end else if (exception) begin
            // 例外発生: EPC保存, Cause設定, EXL=1
            cp0_epc   <= pc_reg;
            cp0_cause <= {24'b0, exc_code, 2'b0}; // Cause[6:2] = ExcCode
            cp0_sr    <= {cp0_sr[31:1], 1'b1};    // EXL=1
        end else if (is_eret & ~halt) begin
            // eret: EXL=0
            cp0_sr <= {cp0_sr[31:1], 1'b0};
        end else if (is_mtc0 & ~halt) begin
            // mtc0: CP0[rd] ← GPR[rt]
            case (rd)
                5'd12: cp0_sr    <= rd2;
                5'd13: cp0_cause <= rd2;
                5'd14: cp0_epc   <= rd2;
                default: ;
            endcase
        end
    end

endmodule
