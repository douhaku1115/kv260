// ============================================================
// datapath.v — データパス (単一サイクル MIPS)
// ============================================================
//
// 【1クロックの処理の流れ】
//
//   PC → imem → [命令デコード] → regfile(読み出し)
//        → ALU → dmem(lw/sw) → regfile(書き戻し) → PC更新
//
// 【PC更新ロジック (優先順位: jr > jump > branch > +4)】
//
//   jr    : PC ← rs レジスタの値 (jr $ra など)
//   j/jal : PC ← {PC+4[31:28], addr26, 2'b00}  (26bitアドレス)
//   beq   : PC ← PC+4 + sign_extend(imm16)<<2  (条件成立時)
//   bne   : PC ← PC+4 + sign_extend(imm16)<<2  (条件不成立時: rs≠rt)
//   通常  : PC ← PC + 4
//
// 【jal の特別処理】
//   jal は jump=1 かつ reg_write=1 で識別する (control.v参照)
//   - 書き込み先レジスタ: $31 (ra レジスタ) に固定
//   - 書き込みデータ:     PC+4 (関数呼び出しのリターンアドレス)
//   jr で $31 に戻ることで関数呼び出し/復帰が実現できる
//
// 【lui の特別処理】
//   lui は opcode=001111 で検出し、ALUをバイパスして
//   {imm16, 16'b0} を直接レジスタに書き戻す
//
// 【ori/andi/xori の即値ゼロ拡張】
//   addi/lw/sw は符号拡張 (sign_imm)、ori/andi/xori はゼロ拡張 (zero_imm)
//   imm_zero=1 のとき zero_imm を ALU 入力 B に使用する
//
// 【sll/srl/sra のシフト入力】
//   shift_instr=1 のとき ALU 入力を切り替え:
//     alu_a = rd2 (rt レジスタ = シフト対象の値)
//     alu_b = {27'b0, shamt} (5bit シフト量をゼロ拡張)
//
// 【sllv/srlv/srav の可変シフト入力】
//   var_shift_instr=1 のとき ALU 入力を切り替え:
//     alu_a = rd2 (rt レジスタ = シフト対象の値)
//     alu_b = rd1 (rs レジスタ = 可変シフト量: ALU は b[4:0] を使用)
//
// 【HI/LO レジスタ (mult/multu/div/divu/mfhi/mflo)】
//   HI/LO は regfile 外の専用 32bit レジスタ。
//   hilo_write=1 のクロックエッジで hilo_op に応じた演算結果を書き込む。
//   mfhilo=1 のとき write_data = sel_hi ? HI : LO としてレジスタへ読み出す。
//
// 【halt 信号】
//   halt=1 の間は PC が停止し、AXI経由でレジスタを安全に読み出せる

module datapath (
    input         clk,
    input         reset,
    input         halt,

    // 制御信号 (control.v から入力)
    input         reg_write,   // レジスタ書き込み許可
    input         reg_dst,     // 書き込み先: 1=rd, 0=rt
    input         alu_src,     // ALU入力B: 1=即値, 0=レジスタ
    input         branch,      // beq 分岐有効
    input         branch_ne,   // bne 分岐有効 (branch と排他的に使用)
    input         mem_write,   // データメモリ書き込み (sw)
    input         mem_to_reg,  // 書き戻し元: 1=メモリ, 0=ALU
    input         jump,        // j/jal ジャンプ
    input         jr,          // jr ジャンプレジスタ
    input         imm_zero,    // 1=ゼロ拡張即値 (ori), 0=符号拡張即値
    input  [3:0]  alu_control, // ALU演算種別
    input         hilo_write,  // 1=HI/LOに書き込む (mult/multu/div/divu)
    input  [1:0]  hilo_op,     // 00=mult,01=multu,10=div,11=divu
    input         mfhilo,      // 1=HI/LOからレジスタへ読み出す (mfhi/mflo)
    input         sel_hi,      // 1=HIレジスタ選択(mfhi), 0=LOレジスタ選択(mflo)

    // 命令メモリ (imem との接続)
    output [31:0] pc,
    input  [31:0] instr,

    // デバッグ用レジスタ読み出し (AXI経由でPS側から参照)
    input  [4:0]  dbg_reg_addr,
    output [31:0] dbg_reg_data
);

    // ---- HI/LO レジスタ ----
    reg [31:0] hi_reg, lo_reg;

    wire [63:0] mult_s  = $signed(rd1) * $signed(rd2);   // mult  (符号付き)
    wire [63:0] mult_u  = rd1 * rd2;                      // multu (符号なし)
    // div (符号付き除算) を $signed() ではなく abs値+符号なし除算で実装する。
    // $signed(a)/$signed(b) は符号付き除算器を合成し WNS=-22ns のタイミング違反を起こすが、
    // 符号なし除算器 (divu と同じパス) は動作周波数を満たすため共有する。
    wire [31:0] div_rs_abs   = rd1[31] ? (~rd1 + 1) : rd1;  // abs(rs)
    wire [31:0] div_rt_abs   = rd2[31] ? (~rd2 + 1) : rd2;  // abs(rt)
    // hilo_op==2'b10 (div) なら絶対値を入力、2'b11 (divu) ならそのまま
    wire [31:0] div_in1      = (hilo_op == 2'b10) ? div_rs_abs : rd1;
    wire [31:0] div_in2      = (hilo_op == 2'b10) ? div_rt_abs : rd2;
    wire [31:0] div_q_common = div_in1 / div_in2;            // 符号なし商 (共用)
    wire [31:0] div_r_common = div_in1 % div_in2;            // 符号なし余り (共用)
    // div: 商の符号 = rs XOR rt の符号; 余りの符号 = rs の符号
    wire [31:0] div_q_s = (rd1[31] ^ rd2[31]) ? (~div_q_common + 1) : div_q_common;
    wire [31:0] div_r_s = rd1[31]             ? (~div_r_common + 1) : div_r_common;
    wire [31:0] div_q_u = div_q_common;
    wire [31:0] div_r_u = div_r_common;

    // ---- PC レジスタ ----
    reg [31:0] pc_reg;
    wire [31:0] pc_next, pc_plus4, pc_branch, pc_jump;

    assign pc      = pc_reg;
    assign pc_plus4 = pc_reg + 32'd4;

    // ---- 命令フィールド分解 ----
    // MIPS 命令フォーマット:
    //   R型: [31:26]=opcode [25:21]=rs [20:16]=rt [15:11]=rd [10:6]=shamt [5:0]=funct
    //   I型: [31:26]=opcode [25:21]=rs [20:16]=rt [15:0]=imm16
    //   J型: [31:26]=opcode [25:0]=addr26
    wire [4:0]  rs    = instr[25:21];
    wire [4:0]  rt    = instr[20:16];
    wire [4:0]  rd    = instr[15:11];
    wire [4:0]  shamt = instr[10:6];   // シフト量 (sll/srl/sra で使用)
    wire [15:0] imm16  = instr[15:0];
    wire [25:0] addr26 = instr[25:0];

    // 即値の符号拡張 (addi, lw, sw, beq, bne で使用)
    wire [31:0] sign_imm = {{16{imm16[15]}}, imm16};
    // ゼロ拡張 (ori, andi, xori で使用: 上位16bitを0埋め)
    wire [31:0] zero_imm = {16'b0, imm16};

    // sll/srl/sra 検出: opcode=000000 かつ funct が 000000/000010/000011
    wire shift_instr = (instr[31:26] == 6'b000000) &&
                       ((instr[5:0] == 6'b000000) ||
                        (instr[5:0] == 6'b000010) ||
                        (instr[5:0] == 6'b000011));

    // sllv/srlv/srav 検出: opcode=000000 かつ funct が 000100/000110/000111
    // シフト量はシフト量フィールドではなく rs レジスタから取る
    wire var_shift_instr = (instr[31:26] == 6'b000000) &&
                           ((instr[5:0] == 6'b000100) ||
                            (instr[5:0] == 6'b000110) ||
                            (instr[5:0] == 6'b000111));

    // ---- jal/lui 識別 ----
    // jal: jump=1 かつ reg_write=1 (j は reg_write=0 なので区別できる)
    wire jal_instr = jump & reg_write;
    // lui: opcode=001111 (control.v で imm_zero=0 のまま処理するため datapath 側で識別)
    wire lui_instr = (instr[31:26] == 6'b001111);

    // ---- レジスタファイル ----
    // jal: 書き込み先を $31 (ra) に固定、書き込み値を PC+4 にする
    // 他:  reg_dst=1 なら rd (R型)、0 なら rt (I型)
    wire [4:0]  write_reg  = jal_instr ? 5'd31 : (reg_dst ? rd : rt);
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
    // shift_instr(sll/srl/sra) のとき: a=rd2(rt シフト対象), b={27'b0,shamt}
    // var_shift_instr(sllv/srlv/srav) のとき: a=rd2(rt シフト対象), b=rd1(rs 可変シフト量)
    // I型即値のとき: a=rd1(rs), b=zero_imm(ゼロ拡張) or sign_imm(符号拡張)
    // R型レジスタのとき: a=rd1(rs), b=rd2(rt)
    wire [31:0] alu_a      = (shift_instr | var_shift_instr) ? rd2 : rd1;
    wire [31:0] alu_b      = shift_instr     ? {27'b0, shamt}                   :
                             var_shift_instr  ? rd1                               :
                             alu_src          ? (imm_zero ? zero_imm : sign_imm) : rd2;
    wire [31:0] alu_result;
    wire        alu_zero;  // 結果=0 なら 1 (beq の分岐判定に使用)

    alu alu_inst (
        .a(alu_a),
        .b(alu_b),
        .alu_control(alu_control),
        .result(alu_result),
        .zero(alu_zero)
    );

    // ---- データメモリ (lw/sw) ----
    // アドレス = ALU結果 (ベースレジスタ + 符号拡張オフセット)
    // halt 中は書き込み禁止 (AXIデバッグ読み出し中の誤書き込み防止)
    wire [31:0] mem_read_data;

    dmem dmem_inst (
        .clk(clk),
        .mem_write(mem_write & ~halt),
        .addr(alu_result),
        .write_data(rd2),
        .read_data(mem_read_data)
    );

    // ---- レジスタ書き戻しデータの選択 ----
    // jal    : PC+4 (リターンアドレスを $31 に保存)
    // lui    : {imm16, 16'b0} (上位16bitに即値をセット、ALUバイパス)
    // mfhi/lo: HI または LO レジスタの値
    // lw     : メモリ読み出しデータ
    // その他 : ALU演算結果
    assign write_data = jal_instr  ? pc_plus4                   :
                        lui_instr  ? {imm16, 16'b0}              :
                        mfhilo     ? (sel_hi ? hi_reg : lo_reg)  :
                        mem_to_reg ? mem_read_data                :
                                     alu_result;

    // ---- PC 次値の計算 ----
    // beq: PC+4 + 符号拡張(imm16)<<2  (ワード単位オフセット)
    // j/jal: {PC+4の上位4bit, addr26, 2'b00}  (同一 256MB セグメント内)
    assign pc_branch = pc_plus4 + (sign_imm << 2);
    assign pc_jump   = {pc_plus4[31:28], addr26, 2'b00};

    // beq: rs==rt (alu_zero=1) のとき分岐
    // bne: rs!=rt (alu_zero=0) のとき分岐
    wire branch_taken = (branch & alu_zero) | (branch_ne & ~alu_zero);
    wire [31:0] pc_branch_mux = branch_taken ? pc_branch : pc_plus4;

    // PC選択 MUX (優先順位: jr > jump > branch/通常)
    assign pc_next = jr   ? rd1     :  // jr: PC = rs レジスタ
                     jump ? pc_jump :  // j/jal: 26bitアドレスジャンプ
                            pc_branch_mux; // beq or PC+4

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
                2'b00: {hi_reg, lo_reg} <= mult_s;                          // mult
                2'b01: {hi_reg, lo_reg} <= mult_u;                          // multu
                2'b10: begin hi_reg <= div_r_s; lo_reg <= div_q_s; end      // div
                2'b11: begin hi_reg <= div_r_u; lo_reg <= div_q_u; end      // divu
            endcase
        end
    end

endmodule
