// ============================================================
// mips_top_pipe.v — 5段パイプライン MIPS プロセッサ (Step 12a)
// ============================================================
//
// 【パイプライン構成】
//
//   IF → IF/ID → ID → ID/EX → EX → EX/MEM → MEM → MEM/WB → WB
//
//   IF:   imem 読み出し、PC 更新
//   ID:   命令デコード、regfile 読み出し
//   EX:   ALU 演算
//   MEM:  dmem アクセス (Step 12c 以降で実装)
//   WB:   regfile 書き戻し
//
// 【Step 12a スコープ】 (完了)
//   - 5段パイプライン構造を確立
//
// 【Step 12b スコープ】 (完了)
//   - フォワーディング追加 (EX/MEM → EX, MEM/WB → EX)
//   - WB→ID 同サイクルバイパス
//
// 【Step 12c スコープ】 (完了)
//   - メモリアクセス追加: lw (word), sw (word)
//   - ロードユースハザード検出 (1 サイクルストール)
//
// 【Step 12d スコープ】 (本ファイル)
//   - 分岐: beq, bne (EX 段で判定、taken 時 IF/ID と ID/EX をフラッシュ)
//   - ジャンプ: j (ID 段で判定、IF/ID をフラッシュ)
//   - リンク付きジャンプ: jal (j + $31 ← PC+4)
//   - レジスタジャンプ: jr (EX 段で判定、rs はフォワーディング適用)
//   - 例外なし (Step 13 で別途)
//
// 【フォワーディングロジック】
//   ID/EX.rs が EX/MEM のデスティネーションと一致 → ALU 入力 a に EX/MEM 結果を直送
//   ID/EX.rs が MEM/WB のデスティネーションと一致 → ALU 入力 a に MEM/WB 結果を直送
//   両方一致時は EX/MEM 側を優先 (より新しいデータ)
//   rt 側 (ALU 入力 b の rd2 側、および sw の書き込みデータ) も同様
//
// 【ロードユースハザード】
//   ID/EX が lw (mem_to_reg=1) で、ID 段の rs/rt が ID/EX.rt と一致する場合、
//   PC と IF/ID を凍結し、ID/EX に NOP バブルを挿入して 1 サイクル遅らせる。
//   lw 結果は MEM/WB → EX のフォワーディングで取得可能。
//
// 【halt 信号】
//   halt=1 でパイプライン全体を凍結。PC およびパイプラインレジスタを保持。
//
// 【reset 信号】
//   reset=1 で PC=0、パイプラインレジスタを全クリア (バブル状態)。

module mips_top_pipe (
    input         clk,
    input         reset,
    input         halt,

    // 命令メモリ書き込みポート
    input         imem_we,
    input  [11:0] imem_waddr,
    input  [31:0] imem_wdata,

    // デバッグ出力
    output [31:0] pc,
    input  [4:0]  dbg_reg_addr,
    output [31:0] dbg_reg_data
);

    // ============================================================
    // IF 段: 命令フェッチ
    // ============================================================

    reg  [31:0] pc_reg;
    wire [31:0] pc_plus4 = pc_reg + 32'd4;
    wire [31:0] if_instr;

    imem imem_inst (
        .addr_a(pc_reg),
        .instr(if_instr),
        .clk_b(clk),
        .we_b(imem_we),
        .addr_b(imem_waddr),
        .din_b(imem_wdata)
    );

    // 後段で定義する信号の forward declaration
    wire load_use_stall;
    wire ex_take_branch;        // EX 段で beq/bne 成立 or jr
    wire id_take_jump;          // ID 段で j/jal
    wire [31:0] ex_branch_target;
    wire [31:0] ex_jr_target;
    wire [31:0] id_jump_target;
    wire        id_ex_jr_w;     // EX 段の jr フラグを参照するためのワイヤ

    // PC 次値選択 (優先度: EX 段の分岐/jr > ID 段のジャンプ > PC+4)
    wire [31:0] pc_next_select =
        ex_take_branch ? (id_ex_jr_w ? ex_jr_target : ex_branch_target) :
        id_take_jump   ? id_jump_target :
                         pc_plus4;

    // フラッシュ信号
    wire flush_if_id = id_take_jump | ex_take_branch;
    wire flush_id_ex = ex_take_branch;

    // PC レジスタ更新 (stall 中は据え置き、分岐/ジャンプ時はターゲットへ)
    always @(posedge clk) begin
        if (reset)
            pc_reg <= 32'b0;
        else if (!halt && !load_use_stall)
            pc_reg <= pc_next_select;
    end

    assign pc = pc_reg;

    // ============================================================
    // IF/ID パイプラインレジスタ (stall 中は据え置き、flush 時は NOP)
    // ============================================================

    reg [31:0] if_id_instr;
    reg [31:0] if_id_pc_plus4;

    always @(posedge clk) begin
        if (reset) begin
            if_id_instr    <= 32'b0;
            if_id_pc_plus4 <= 32'b0;
        end else if (!halt && !load_use_stall) begin
            if (flush_if_id) begin
                if_id_instr    <= 32'b0;  // NOP
                if_id_pc_plus4 <= 32'b0;
            end else begin
                if_id_instr    <= if_instr;
                if_id_pc_plus4 <= pc_plus4;
            end
        end
    end

    // ============================================================
    // ID 段: 命令デコード + regfile 読み出し
    // ============================================================

    wire [5:0]  id_opcode = if_id_instr[31:26];
    wire [4:0]  id_rs     = if_id_instr[25:21];
    wire [4:0]  id_rt     = if_id_instr[20:16];
    wire [4:0]  id_rd     = if_id_instr[15:11];
    wire [5:0]  id_funct  = if_id_instr[5:0];
    wire [15:0] id_imm16  = if_id_instr[15:0];
    wire [31:0] id_sign_imm = {{16{id_imm16[15]}}, id_imm16};

    // 制御信号 (control.v からデコード。Step 12a で使うのは reg_write/reg_dst/alu_src/alu_control のみ)
    wire id_reg_write, id_reg_dst, id_alu_src;
    wire id_branch, id_branch_ne, id_branch_ltz, id_branch_gez, id_branch_lez, id_branch_gtz;
    wire id_mem_write, id_mem_to_reg, id_jump, id_jr, id_imm_zero;
    wire [3:0] id_alu_control;
    wire id_hilo_write, id_mfhilo, id_sel_hi;
    wire [1:0] id_hilo_op;
    wire [1:0] id_mem_size;
    wire id_mem_unsigned;
    wire id_is_mfc0, id_is_mtc0, id_is_syscall, id_is_eret, id_exc_on_ov;

    control ctrl (
        .opcode(id_opcode),
        .funct(id_funct),
        .rs(id_rs),
        .rt(id_rt),
        .reg_write(id_reg_write),
        .reg_dst(id_reg_dst),
        .alu_src(id_alu_src),
        .branch(id_branch),
        .branch_ne(id_branch_ne),
        .branch_ltz(id_branch_ltz),
        .branch_gez(id_branch_gez),
        .branch_lez(id_branch_lez),
        .branch_gtz(id_branch_gtz),
        .mem_write(id_mem_write),
        .mem_to_reg(id_mem_to_reg),
        .jump(id_jump),
        .jr(id_jr),
        .imm_zero(id_imm_zero),
        .alu_control(id_alu_control),
        .hilo_write(id_hilo_write),
        .hilo_op(id_hilo_op),
        .mfhilo(id_mfhilo),
        .sel_hi(id_sel_hi),
        .mem_size(id_mem_size),
        .mem_unsigned(id_mem_unsigned),
        .is_mfc0(id_is_mfc0),
        .is_mtc0(id_is_mtc0),
        .is_syscall(id_is_syscall),
        .is_eret(id_is_eret),
        .exc_on_ov(id_exc_on_ov)
    );

    // レジスタファイル (WB 段から書き込み)
    wire [31:0] id_rd1, id_rd2;
    wire wb_reg_write;
    wire [4:0] wb_write_reg;
    wire [31:0] wb_write_data;

    regfile rf (
        .clk(clk),
        .we3(wb_reg_write),
        .ra1(id_rs),
        .ra2(id_rt),
        .ra3(dbg_reg_addr),
        .wa3(wb_write_reg),
        .wd3(wb_write_data),
        .rd1(id_rd1),
        .rd2(id_rd2),
        .rd3(dbg_reg_data)
    );

    // WB→ID 同サイクル書き込み/読み出しバイパス (Step 12b)
    // WB 段の書き込みと ID 段の読み出しが同一クロックで発生した場合、
    // regfile の組み合わせ読みは旧値を返すため、書き込み中データを直送する。
    wire wb_rs_match = wb_reg_write && (wb_write_reg != 5'b0) && (wb_write_reg == id_rs);
    wire wb_rt_match = wb_reg_write && (wb_write_reg != 5'b0) && (wb_write_reg == id_rt);

    wire [31:0] id_rd1_bypassed = wb_rs_match ? wb_write_data : id_rd1;
    wire [31:0] id_rd2_bypassed = wb_rt_match ? wb_write_data : id_rd2;

    // Step 12d: ID 段でジャンプ検出
    wire id_jal_instr = id_jump & id_reg_write;       // jal は jump=1 かつ reg_write=1
    assign id_take_jump  = id_jump;                    // j と jal の両方
    assign id_jump_target = {if_id_pc_plus4[31:28], if_id_instr[25:0], 2'b00};

    // ============================================================
    // ID/EX パイプラインレジスタ
    // ============================================================

    reg        id_ex_reg_write;
    reg        id_ex_reg_dst;
    reg        id_ex_alu_src;
    reg [3:0]  id_ex_alu_control;
    reg [31:0] id_ex_rd1, id_ex_rd2, id_ex_sign_imm;
    reg [4:0]  id_ex_rs, id_ex_rt, id_ex_rd;
    reg        id_ex_mem_write;   // Step 12c: sw
    reg        id_ex_mem_to_reg;  // Step 12c: lw → regfile
    reg        id_ex_branch;       // Step 12d: beq
    reg        id_ex_branch_ne;    // Step 12d: bne
    reg        id_ex_jr;           // Step 12d: jr
    reg        id_ex_jal_instr;    // Step 12d: jal ($31 ← PC+4)
    reg [31:0] id_ex_pc_plus4;     // Step 12d: jal の書き戻し用

    assign id_ex_jr_w = id_ex_jr;  // forward declaration の wire と接続

    // ロードユースハザード検出 (ID 段の rs/rt が ID/EX.rt (lw のデスト) と一致)
    assign load_use_stall = id_ex_mem_to_reg && (id_ex_rt != 5'b0) &&
                            ((id_ex_rt == id_rs) || (id_ex_rt == id_rt));

    always @(posedge clk) begin
        if (reset) begin
            id_ex_reg_write   <= 1'b0;
            id_ex_reg_dst     <= 1'b0;
            id_ex_alu_src     <= 1'b0;
            id_ex_alu_control <= 4'b0;
            id_ex_rd1         <= 32'b0;
            id_ex_rd2         <= 32'b0;
            id_ex_sign_imm    <= 32'b0;
            id_ex_rs          <= 5'b0;
            id_ex_rt          <= 5'b0;
            id_ex_rd          <= 5'b0;
            id_ex_mem_write   <= 1'b0;
            id_ex_mem_to_reg  <= 1'b0;
            id_ex_branch      <= 1'b0;
            id_ex_branch_ne   <= 1'b0;
            id_ex_jr          <= 1'b0;
            id_ex_jal_instr   <= 1'b0;
            id_ex_pc_plus4    <= 32'b0;
        end else if (!halt) begin
            if (load_use_stall || flush_id_ex) begin
                // バブル挿入 / フラッシュ: 制御信号を全 0 にする (NOP)
                id_ex_reg_write   <= 1'b0;
                id_ex_reg_dst     <= 1'b0;
                id_ex_alu_src     <= 1'b0;
                id_ex_alu_control <= 4'b0;
                id_ex_rd1         <= 32'b0;
                id_ex_rd2         <= 32'b0;
                id_ex_sign_imm    <= 32'b0;
                id_ex_rs          <= 5'b0;
                id_ex_rt          <= 5'b0;
                id_ex_rd          <= 5'b0;
                id_ex_mem_write   <= 1'b0;
                id_ex_mem_to_reg  <= 1'b0;
                id_ex_branch      <= 1'b0;
                id_ex_branch_ne   <= 1'b0;
                id_ex_jr          <= 1'b0;
                id_ex_jal_instr   <= 1'b0;
                id_ex_pc_plus4    <= 32'b0;
            end else begin
                id_ex_reg_write   <= id_reg_write;
                id_ex_reg_dst     <= id_reg_dst;
                id_ex_alu_src     <= id_alu_src;
                id_ex_alu_control <= id_alu_control;
                id_ex_rd1         <= id_rd1_bypassed;
                id_ex_rd2         <= id_rd2_bypassed;
                id_ex_sign_imm    <= id_sign_imm;
                id_ex_rs          <= id_rs;
                id_ex_rt          <= id_rt;
                id_ex_rd          <= id_rd;
                id_ex_mem_write   <= id_mem_write;
                id_ex_mem_to_reg  <= id_mem_to_reg;
                id_ex_branch      <= id_branch;
                id_ex_branch_ne   <= id_branch_ne;
                id_ex_jr          <= id_jr;
                id_ex_jal_instr   <= id_jal_instr;
                id_ex_pc_plus4    <= if_id_pc_plus4;
            end
        end
    end

    // ============================================================
    // EX 段: フォワーディング + ALU 演算
    // ============================================================

    // フォワーディングユニット (Step 12b)
    // 2'b00: ID/EX のレジスタ値をそのまま使用
    // 2'b10: EX/MEM の ALU 結果を直送 (1 命令前)
    // 2'b01: MEM/WB の書き戻しデータを直送 (2 命令前)
    reg [1:0] forward_a, forward_b;

    always @(*) begin
        // ForwardA (ALU 入力 a, rs 側)
        if (ex_mem_reg_write && (ex_mem_write_reg != 5'b0) && (ex_mem_write_reg == id_ex_rs))
            forward_a = 2'b10;
        else if (mem_wb_reg_write && (mem_wb_write_reg != 5'b0) && (mem_wb_write_reg == id_ex_rs))
            forward_a = 2'b01;
        else
            forward_a = 2'b00;

        // ForwardB (ALU 入力 b の rt 側, alu_src=0 のとき有効)
        if (ex_mem_reg_write && (ex_mem_write_reg != 5'b0) && (ex_mem_write_reg == id_ex_rt))
            forward_b = 2'b10;
        else if (mem_wb_reg_write && (mem_wb_write_reg != 5'b0) && (mem_wb_write_reg == id_ex_rt))
            forward_b = 2'b01;
        else
            forward_b = 2'b00;
    end

    wire [31:0] alu_in_a  = (forward_a == 2'b10) ? ex_mem_alu_result :
                            (forward_a == 2'b01) ? wb_write_data     :
                                                   id_ex_rd1;
    wire [31:0] alu_in_rt = (forward_b == 2'b10) ? ex_mem_alu_result :
                            (forward_b == 2'b01) ? wb_write_data     :
                                                   id_ex_rd2;
    wire [31:0] ex_alu_b  = id_ex_alu_src ? id_ex_sign_imm : alu_in_rt;

    wire [31:0] ex_alu_result;
    wire        ex_alu_zero;
    wire        ex_alu_overflow;

    alu alu_inst (
        .a(alu_in_a),
        .b(ex_alu_b),
        .alu_control(id_ex_alu_control),
        .result(ex_alu_result),
        .zero(ex_alu_zero),
        .overflow(ex_alu_overflow)
    );

    // jal の write_reg は $31, それ以外は通常通り
    wire [4:0] ex_write_reg = id_ex_jal_instr ? 5'd31 :
                              id_ex_reg_dst   ? id_ex_rd : id_ex_rt;

    // Step 12d: 分岐/jr 判定 (EX 段)
    // beq: branch=1 && rs==rt (alu_zero)
    // bne: branch_ne=1 && rs!=rt (~alu_zero)
    // jr:  jr=1 (常に taken)
    wire ex_branch_taken = (id_ex_branch    &  ex_alu_zero) |
                           (id_ex_branch_ne & ~ex_alu_zero);
    assign ex_take_branch = ex_branch_taken | id_ex_jr;
    assign ex_branch_target = id_ex_pc_plus4 + (id_ex_sign_imm << 2);
    assign ex_jr_target = alu_in_a;  // フォワーディング後の rs 値

    // ============================================================
    // EX/MEM パイプラインレジスタ
    // ============================================================

    reg        ex_mem_reg_write;
    reg [31:0] ex_mem_alu_result;
    reg [4:0]  ex_mem_write_reg;
    reg        ex_mem_mem_write;
    reg        ex_mem_mem_to_reg;
    reg [31:0] ex_mem_rd2;
    reg        ex_mem_jal_instr;     // Step 12d
    reg [31:0] ex_mem_pc_plus4;      // Step 12d: jal の書き戻しデータ

    always @(posedge clk) begin
        if (reset) begin
            ex_mem_reg_write  <= 1'b0;
            ex_mem_alu_result <= 32'b0;
            ex_mem_write_reg  <= 5'b0;
            ex_mem_mem_write  <= 1'b0;
            ex_mem_mem_to_reg <= 1'b0;
            ex_mem_rd2        <= 32'b0;
            ex_mem_jal_instr  <= 1'b0;
            ex_mem_pc_plus4   <= 32'b0;
        end else if (!halt) begin
            ex_mem_reg_write  <= id_ex_reg_write;
            ex_mem_alu_result <= ex_alu_result;
            ex_mem_write_reg  <= ex_write_reg;
            ex_mem_mem_write  <= id_ex_mem_write;
            ex_mem_mem_to_reg <= id_ex_mem_to_reg;
            ex_mem_rd2        <= alu_in_rt;
            ex_mem_jal_instr  <= id_ex_jal_instr;
            ex_mem_pc_plus4   <= id_ex_pc_plus4;
        end
    end

    // ============================================================
    // MEM 段: dmem アクセス
    // ============================================================

    // byte_en: Step 12c では word アクセスのみ。sw 時のみ 4'b1111、それ以外は 0
    //          halt 中は書き込み禁止
    wire [3:0] mem_byte_en = (ex_mem_mem_write & ~halt) ? 4'b1111 : 4'b0000;

    wire [31:0] mem_read_data;

    dmem dmem_inst (
        .clk(clk),
        .byte_en(mem_byte_en),
        .addr(ex_mem_alu_result),
        .write_data(ex_mem_rd2),
        .read_data(mem_read_data)
    );

    // ============================================================
    // MEM/WB パイプラインレジスタ
    // ============================================================

    reg        mem_wb_reg_write;
    reg [31:0] mem_wb_alu_result;
    reg [4:0]  mem_wb_write_reg;
    reg        mem_wb_mem_to_reg;
    reg [31:0] mem_wb_mem_data;
    reg        mem_wb_jal_instr;   // Step 12d
    reg [31:0] mem_wb_pc_plus4;    // Step 12d

    always @(posedge clk) begin
        if (reset) begin
            mem_wb_reg_write  <= 1'b0;
            mem_wb_alu_result <= 32'b0;
            mem_wb_write_reg  <= 5'b0;
            mem_wb_mem_to_reg <= 1'b0;
            mem_wb_mem_data   <= 32'b0;
            mem_wb_jal_instr  <= 1'b0;
            mem_wb_pc_plus4   <= 32'b0;
        end else if (!halt) begin
            mem_wb_reg_write  <= ex_mem_reg_write;
            mem_wb_alu_result <= ex_mem_alu_result;
            mem_wb_write_reg  <= ex_mem_write_reg;
            mem_wb_mem_to_reg <= ex_mem_mem_to_reg;
            mem_wb_mem_data   <= mem_read_data;
            mem_wb_jal_instr  <= ex_mem_jal_instr;
            mem_wb_pc_plus4   <= ex_mem_pc_plus4;
        end
    end

    // ============================================================
    // WB 段: regfile 書き戻し (jal は PC+4、lw は mem_data、それ以外は alu_result)
    // ============================================================

    assign wb_reg_write  = mem_wb_reg_write;
    assign wb_write_reg  = mem_wb_write_reg;
    assign wb_write_data = mem_wb_jal_instr   ? mem_wb_pc_plus4 :
                           mem_wb_mem_to_reg  ? mem_wb_mem_data :
                                                mem_wb_alu_result;

endmodule
