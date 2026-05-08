// ============================================================
// datapath.v — データパス (単一サイクル MIPS)
// ============================================================
//
// 【1クロックの処理の流れ】
//
//   PC → imem → [命令デコード] → regfile(読み出し)
//        → ALU → dmem(lw/sw等) → regfile(書き戻し) → PC更新
//
// 【PC更新ロジック (優先順位: jr > jump > branch > +4)】
//
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

module datapath (
    input         clk,
    input         reset,
    input         halt,

    // 制御信号 (control.v から入力)
    input         reg_write,
    input         reg_dst,
    input         alu_src,
    input         branch,
    input         branch_ne,
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

    // ---- レジスタファイル ----
    wire [4:0]  write_reg = jal_instr ? 5'd31 : (reg_dst ? rd : rt);
    wire [31:0] rd1, rd2, dbg_rd3;
    wire [31:0] write_data;

    regfile rf (
        .clk(clk),
        .we3(reg_write),
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
        .zero(alu_zero)
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
                        mem_to_reg ? mem_data_final               :
                                     alu_result;

    // ---- PC 次値の計算 ----
    assign pc_branch = pc_plus4 + (sign_imm << 2);
    assign pc_jump   = {pc_plus4[31:28], addr26, 2'b00};

    wire branch_taken    = (branch & alu_zero) | (branch_ne & ~alu_zero);
    wire [31:0] pc_branch_mux = branch_taken ? pc_branch : pc_plus4;

    assign pc_next = jr   ? rd1     :
                     jump ? pc_jump :
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

endmodule
