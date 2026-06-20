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
// 【Step 12d スコープ】 (完了)
//   - 分岐: beq, bne (EX 段で判定、taken 時 IF/ID と ID/EX をフラッシュ)
//   - ジャンプ: j (ID 段で判定、IF/ID をフラッシュ)
//   - リンク付きジャンプ: jal (j + $31 ← PC+4)
//   - レジスタジャンプ: jr (EX 段で判定、rs はフォワーディング適用)
//   - 例外なし (Step 13 で別途)
//
// 【Step 12e スコープ】 (本ファイル)
//   - ゼロ拡張即値: ori/andi/xori (ID 段で imm_zero により選択)
//   - lui: {imm16, 16'b0} を EX 段で生成し WB へ
//   - rs と 0 の比較分岐: bltz/bgez/blez/bgtz (EX 段, フォワーディング後 rs)
//   - シフト: sll/srl/sra (a=rt, b=shamt), sllv/srlv/srav (a=rt, b=rs)
//   - addiu/addu/subu/sltu/sltiu/nor は既存 ALU 経路でそのまま動作
//
// 【Step 12f スコープ】 (本ファイル)
//   - mult/multu/div/divu: EX 段で HI/LO レジスタに書き込み (フォワーディング後オペランド)
//   - mfhi/mflo: EX 段で HI/LO を読み ex_result 経由で WB へ
//     (mfhi/mflo は mult/div の 1 命令以上後に EX へ来るため専用フォワーディング不要)
//   - バイト/ハーフワード: lb/lbu/lh/lhu/sb/sh
//     MEM 段で mem_size + addr[1:0] から byte_en 生成、読出しはスライス+符号/ゼロ拡張
//
// 【Step 12g-1 スコープ】 (完了)
//   - CP0 レジスタ ($12 SR / $13 Cause / $14 EPC) と mfc0/mtc0
//     EX 段で CP0 書込み(mtc0)・読出し(mfc0)。HI/LO と同方式で専用FW不要
//
// 【Step 12g-2 スコープ】 (完了)
//   - 例外発生: syscall(ExcCode=8) / add,addi,sub のオーバーフロー(ExcCode=12)
//     EX 段で検出。EPC←例外命令PC(=pc_plus4-4), Cause←ExcCode, SR.EXL←1,
//     PC←0x80(EXC_VEC)。
//   - 例外時フラッシュ: IF/ID と ID/EX を潰し、例外命令の reg/mem/HILO 書込みを抑止
//
// 【Step 12g-3 スコープ】 (本ファイル)
//   - eret: EX 段で PC←EPC, SR.EXL←0。jr と同じく EX で解決し IF/ID,ID/EX フラッシュ
//     ハンドラの mtc0(EPC更新) の 1 命令後に eret が EX へ来るため、cp0_epc は
//     書込み済みで専用フォワーディング不要 (mtc0→mfc0 と同じパターン)
//   - PC 優先順位: 例外 > eret > 分岐/jr > ジャンプ > +4
//
// 【OS-prep1: 統一メモリ (von Neumann)】 (本ファイル)
//   imem/dmem を unified_mem.v に統合し、命令とデータを単一16KB空間に。
//   IF(命令フェッチ)と MEM(lw/sw)が同じメモリを共有するため、lw/sw でコード
//   領域も読み書きでき、自己書き換えコードが動く (OS でタスクをロード/実行する前提)。
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

    // OS-prep1: 統一メモリ (von Neumann)。命令とデータが同一空間。
    //   IF ポート  = pc_reg / if_instr
    //   MEM ポート = MEM 段の信号 (mem_byte_en/ex_mem_alu_result/... を前方参照)
    //   PS ポート  = AXI 経由のプログラムロード (imem_we/waddr/wdata)
    unified_mem unified_mem_inst (
        .if_addr(pc_reg),
        .if_instr(if_instr),
        .clk(clk),
        .byte_en(mem_byte_en),
        .mem_addr(ex_mem_alu_result),
        .mem_wdata(mem_write_data),
        .mem_rdata(mem_read_data),
        .ps_we(imem_we),
        .ps_waddr(imem_waddr),
        .ps_wdata(imem_wdata)
    );

    // 後段で定義する信号の forward declaration
    wire load_use_stall;
    wire ex_take_branch;        // EX 段で beq/bne 成立 or jr
    wire id_take_jump;          // ID 段で j/jal
    wire [31:0] ex_branch_target;
    wire [31:0] ex_jr_target;
    wire [31:0] id_jump_target;
    wire        id_ex_jr_w;     // EX 段の jr フラグを参照するためのワイヤ
    wire        ex_exception;   // Step 12g-2: EX 段で例外発生 (syscall/overflow)
    wire        ex_eret;        // Step 12g-3: EX 段で eret (PC←EPC)
    wire [31:0] ex_epc;         // Step 12g-3: eret の戻り先 (cp0_epc)

    localparam EXC_VEC = 32'h00000080;  // 例外ベクタ (imem word 32)

    // PC 次値選択 (優先度: 例外 > eret > EX 段の分岐/jr > ID 段のジャンプ > PC+4)
    wire [31:0] pc_next_select =
        ex_exception   ? EXC_VEC :
        ex_eret        ? ex_epc  :
        ex_take_branch ? (id_ex_jr_w ? ex_jr_target : ex_branch_target) :
        id_take_jump   ? id_jump_target :
                         pc_plus4;

    // フラッシュ信号 (例外/eret 時も若い命令を潰す)
    wire flush_if_id = id_take_jump | ex_take_branch | ex_exception | ex_eret;
    wire flush_id_ex = ex_take_branch | ex_exception | ex_eret;

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

    // Step 12e: lui / シフト命令検出 + ゼロ拡張即値
    wire id_lui_instr = (id_opcode == 6'b001111);
    wire id_shift_instr = (id_opcode == 6'b000000) &&
                          ((id_funct == 6'b000000) ||   // sll
                           (id_funct == 6'b000010) ||   // srl
                           (id_funct == 6'b000011));    // sra
    wire id_var_shift_instr = (id_opcode == 6'b000000) &&
                          ((id_funct == 6'b000100) ||   // sllv
                           (id_funct == 6'b000110) ||   // srlv
                           (id_funct == 6'b000111));    // srav
    // ori/andi/xori はゼロ拡張、それ以外は符号拡張
    wire [31:0] id_imm_ext = id_imm_zero ? {16'b0, id_imm16} : id_sign_imm;

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
    reg        id_ex_branch_ltz;   // Step 12e: bltz
    reg        id_ex_branch_gez;   // Step 12e: bgez
    reg        id_ex_branch_lez;   // Step 12e: blez
    reg        id_ex_branch_gtz;   // Step 12e: bgtz
    reg        id_ex_lui_instr;    // Step 12e: lui
    reg        id_ex_shift;        // Step 12e: sll/srl/sra
    reg        id_ex_var_shift;    // Step 12e: sllv/srlv/srav
    reg        id_ex_hilo_write;   // Step 12f: mult/multu/div/divu
    reg [1:0]  id_ex_hilo_op;      // Step 12f: 00=mult,01=multu,10=div,11=divu
    reg        id_ex_mfhilo;       // Step 12f: mfhi/mflo
    reg        id_ex_sel_hi;       // Step 12f: 1=HI(mfhi), 0=LO(mflo)
    reg [1:0]  id_ex_mem_size;     // Step 12f: 00=byte,01=half,10=word
    reg        id_ex_mem_unsigned; // Step 12f: lbu/lhu=1
    reg        id_ex_is_mfc0;      // Step 12g-1: mfc0 (CP0→GPR)
    reg        id_ex_is_mtc0;      // Step 12g-1: mtc0 (GPR→CP0)
    reg        id_ex_is_syscall;   // Step 12g-2: syscall (ExcCode=8)
    reg        id_ex_exc_on_ov;    // Step 12g-2: add/addi/sub のオーバーフロー例外対象
    reg        id_ex_is_eret;      // Step 12g-3: eret (PC←EPC, SR.EXL←0)

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
            id_ex_branch_ltz  <= 1'b0;
            id_ex_branch_gez  <= 1'b0;
            id_ex_branch_lez  <= 1'b0;
            id_ex_branch_gtz  <= 1'b0;
            id_ex_lui_instr   <= 1'b0;
            id_ex_shift       <= 1'b0;
            id_ex_var_shift   <= 1'b0;
            id_ex_hilo_write  <= 1'b0;
            id_ex_hilo_op     <= 2'b0;
            id_ex_mfhilo      <= 1'b0;
            id_ex_sel_hi      <= 1'b0;
            id_ex_mem_size    <= 2'b10;
            id_ex_mem_unsigned<= 1'b0;
            id_ex_is_mfc0     <= 1'b0;
            id_ex_is_mtc0     <= 1'b0;
            id_ex_is_syscall  <= 1'b0;
            id_ex_exc_on_ov   <= 1'b0;
            id_ex_is_eret     <= 1'b0;
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
                id_ex_branch_ltz  <= 1'b0;
                id_ex_branch_gez  <= 1'b0;
                id_ex_branch_lez  <= 1'b0;
                id_ex_branch_gtz  <= 1'b0;
                id_ex_lui_instr   <= 1'b0;
                id_ex_shift       <= 1'b0;
                id_ex_var_shift   <= 1'b0;
                id_ex_hilo_write  <= 1'b0;   // バブル中は HI/LO 書込み禁止
                id_ex_hilo_op     <= 2'b0;
                id_ex_mfhilo      <= 1'b0;
                id_ex_sel_hi      <= 1'b0;
                id_ex_mem_size    <= 2'b10;
                id_ex_mem_unsigned<= 1'b0;
                id_ex_is_mfc0     <= 1'b0;
                id_ex_is_mtc0     <= 1'b0;   // バブル中は CP0 書込み禁止
                id_ex_is_syscall  <= 1'b0;   // バブル中は例外を起こさない
                id_ex_exc_on_ov   <= 1'b0;
                id_ex_is_eret     <= 1'b0;   // バブル中は eret を発火させない
            end else begin
                id_ex_reg_write   <= id_reg_write;
                id_ex_reg_dst     <= id_reg_dst;
                id_ex_alu_src     <= id_alu_src;
                id_ex_alu_control <= id_alu_control;
                id_ex_rd1         <= id_rd1_bypassed;
                id_ex_rd2         <= id_rd2_bypassed;
                id_ex_sign_imm    <= id_imm_ext;   // Step 12e: imm_zero でゼロ/符号拡張を選択
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
                id_ex_branch_ltz  <= id_branch_ltz;
                id_ex_branch_gez  <= id_branch_gez;
                id_ex_branch_lez  <= id_branch_lez;
                id_ex_branch_gtz  <= id_branch_gtz;
                id_ex_lui_instr   <= id_lui_instr;
                id_ex_shift       <= id_shift_instr;
                id_ex_var_shift   <= id_var_shift_instr;
                id_ex_hilo_write  <= id_hilo_write;
                id_ex_hilo_op     <= id_hilo_op;
                id_ex_mfhilo      <= id_mfhilo;
                id_ex_sel_hi      <= id_sel_hi;
                id_ex_mem_size    <= id_mem_size;
                id_ex_mem_unsigned<= id_mem_unsigned;
                id_ex_is_mfc0     <= id_is_mfc0;
                id_ex_is_mtc0     <= id_is_mtc0;
                id_ex_is_syscall  <= id_is_syscall;
                id_ex_exc_on_ov   <= id_exc_on_ov;
                id_ex_is_eret     <= id_is_eret;
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

    // Step 12e: シフト命令はオペランドを入れ替える (datapath.v と同じ規約)
    //   sll/srl/sra:    a = rt,  b = shamt(=imm[10:6])
    //   sllv/srlv/srav: a = rt,  b = rs
    //   それ以外:        a = rs,  b = (alu_src ? imm : rt)
    wire [31:0] ex_alu_a = (id_ex_shift | id_ex_var_shift) ? alu_in_rt : alu_in_a;
    wire [31:0] ex_alu_b = id_ex_shift     ? {27'b0, id_ex_sign_imm[10:6]} :
                           id_ex_var_shift ? alu_in_a                       :
                           id_ex_alu_src   ? id_ex_sign_imm                 :
                                             alu_in_rt;

    wire [31:0] ex_alu_result;
    wire        ex_alu_zero;
    wire        ex_alu_overflow;

    alu alu_inst (
        .a(ex_alu_a),
        .b(ex_alu_b),
        .alu_control(id_ex_alu_control),
        .result(ex_alu_result),
        .zero(ex_alu_zero),
        .overflow(ex_alu_overflow)
    );

    // ============================================================
    // Step 12f: mult/div → HI/LO レジスタ (EX 段、フォワーディング後オペランド)
    // ============================================================
    // HI/LO は EX 段でレジスタ書き込み。後続の mfhi/mflo は 1 命令以上後に
    // EX へ来るため、書き込み済みの HI/LO を読める (専用フォワーディング不要)。
    wire [31:0] hilo_a = alu_in_a;   // rs (フォワーディング後)
    wire [31:0] hilo_b = alu_in_rt;  // rt (フォワーディング後)

    wire [63:0] mult_s = $signed(hilo_a) * $signed(hilo_b);
    wire [63:0] mult_u = hilo_a * hilo_b;
    wire [31:0] div_rs_abs = hilo_a[31] ? (~hilo_a + 1) : hilo_a;
    wire [31:0] div_rt_abs = hilo_b[31] ? (~hilo_b + 1) : hilo_b;
    wire [31:0] div_in1 = (id_ex_hilo_op == 2'b10) ? div_rs_abs : hilo_a;
    wire [31:0] div_in2 = (id_ex_hilo_op == 2'b10) ? div_rt_abs : hilo_b;
    wire [31:0] div_q_common = div_in1 / div_in2;
    wire [31:0] div_r_common = div_in1 % div_in2;
    wire [31:0] div_q_s = (hilo_a[31] ^ hilo_b[31]) ? (~div_q_common + 1) : div_q_common;
    wire [31:0] div_r_s = hilo_a[31]                ? (~div_r_common + 1) : div_r_common;

    reg [31:0] hi_reg, lo_reg;
    always @(posedge clk) begin
        if (reset) begin
            hi_reg <= 32'b0;
            lo_reg <= 32'b0;
        end else if (id_ex_hilo_write & ~halt & ~ex_exception) begin
            case (id_ex_hilo_op)
                2'b00: {hi_reg, lo_reg} <= mult_s;          // mult
                2'b01: {hi_reg, lo_reg} <= mult_u;          // multu
                2'b10: begin hi_reg <= div_r_s;      lo_reg <= div_q_s;      end // div
                2'b11: begin hi_reg <= div_r_common; lo_reg <= div_q_common; end // divu
            endcase
        end
    end

    // ============================================================
    // Step 12g-1/12g-2: CP0 レジスタ + mfc0/mtc0 + 例外処理 (EX 段)
    // ============================================================
    //   $12 SR / $13 Cause / $14 EPC。
    //   mtc0: EX 段で CP0[id_ex_rd] ← GPR[rt] (フォワーディング後 alu_in_rt)
    //   mfc0: EX 段で CP0[id_ex_rd] を読み ex_result 経由で WB へ
    //   mtc0 の 1 命令以上後に mfc0 が EX へ来るため専用フォワーディング不要
    //
    // 【Step 12g-2: 例外発生】(EX 段で検出)
    //   syscall (ExcCode=8) または add/addi/sub のオーバーフロー (ExcCode=12)
    //   発生時: EPC ← 例外命令の PC, Cause ← ExcCode, SR.EXL ← 1, PC ← 0x80
    //   例外命令自身の reg_write/CP0書込み/HI-LO書込みは抑止する。
    //   EPC は伝搬済み pc_plus4 から -4 で導出 (専用 PC レジスタ不要)。
    reg [31:0] cp0_sr, cp0_cause, cp0_epc;

    // 例外検出 (EX 段)。jr/分岐より「同じ命令で」優先評価される。
    wire ex_exc_overflow = id_ex_exc_on_ov & ex_alu_overflow;
    assign ex_exception  = (id_ex_is_syscall | ex_exc_overflow) & ~halt;
    wire [4:0] ex_exc_code = id_ex_is_syscall ? 5'd8 : 5'd12; // 8=Syscall,12=Overflow
    wire [31:0] ex_exc_pc  = id_ex_pc_plus4 - 32'd4;          // 例外命令の PC

    // Step 12g-3: eret (EX 段)。PC←EPC, SR.EXL←0。jr と同じく EX で解決+フラッシュ
    assign ex_eret = id_ex_is_eret & ~halt;
    assign ex_epc  = cp0_epc;

    always @(posedge clk) begin
        if (reset) begin
            cp0_sr    <= 32'b0;
            cp0_cause <= 32'b0;
            cp0_epc   <= 32'b0;
        end else if (ex_exception) begin
            // 例外発生が最優先 (mtc0/eret より優先)
            cp0_epc   <= ex_exc_pc;
            cp0_cause <= {25'b0, ex_exc_code, 2'b0}; // Cause[6:2] = ExcCode
            cp0_sr    <= {cp0_sr[31:1], 1'b1};       // EXL = 1
        end else if (ex_eret) begin
            // eret: EXL = 0 (PC は pc_next_select 側で EPC に戻す)
            cp0_sr    <= {cp0_sr[31:1], 1'b0};
        end else if (id_ex_is_mtc0 & ~halt) begin
            case (id_ex_rd)
                5'd12: cp0_sr    <= alu_in_rt;
                5'd13: cp0_cause <= alu_in_rt;
                5'd14: cp0_epc   <= alu_in_rt;
                default: ;
            endcase
        end
    end

    wire [31:0] cp0_read = (id_ex_rd == 5'd12) ? cp0_sr    :
                           (id_ex_rd == 5'd13) ? cp0_cause :
                           (id_ex_rd == 5'd14) ? cp0_epc   : 32'b0;

    // 書き戻しデータ: lui → mfc0 → mfhi/mflo → 通常 ALU の順で選択
    wire [31:0] ex_result = id_ex_lui_instr ? {id_ex_sign_imm[15:0], 16'b0}     :
                            id_ex_is_mfc0   ? cp0_read                          :
                            id_ex_mfhilo    ? (id_ex_sel_hi ? hi_reg : lo_reg)  :
                                              ex_alu_result;

    // jal の write_reg は $31, それ以外は通常通り
    wire [4:0] ex_write_reg = id_ex_jal_instr ? 5'd31 :
                              id_ex_reg_dst   ? id_ex_rd : id_ex_rt;

    // Step 12d/12e: 分岐/jr 判定 (EX 段)
    // beq: branch=1 && rs==rt (alu_zero)
    // bne: branch_ne=1 && rs!=rt (~alu_zero)
    // bltz/bgez/blez/bgtz: rs と 0 の比較 (フォワーディング後の rs = alu_in_a)
    // jr:  jr=1 (常に taken)
    wire ex_rs_neg  = alu_in_a[31];
    wire ex_rs_zero = (alu_in_a == 32'b0);
    wire ex_branch_taken = (id_ex_branch     &  ex_alu_zero)             |
                           (id_ex_branch_ne  & ~ex_alu_zero)             |
                           (id_ex_branch_ltz &  ex_rs_neg)               |
                           (id_ex_branch_gez & ~ex_rs_neg)               |
                           (id_ex_branch_lez & (ex_rs_neg | ex_rs_zero)) |
                           (id_ex_branch_gtz & ~ex_rs_neg & ~ex_rs_zero);
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
    reg [1:0]  ex_mem_mem_size;      // Step 12f: byte/half/word
    reg        ex_mem_mem_unsigned;  // Step 12f: lbu/lhu

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
            ex_mem_mem_size   <= 2'b10;
            ex_mem_mem_unsigned <= 1'b0;
        end else if (!halt) begin
            // Step 12g-2: 例外発生時は当該命令の reg_write/mem_write を抑止
            ex_mem_reg_write  <= id_ex_reg_write & ~ex_exception;
            ex_mem_alu_result <= ex_result;       // Step 12e: lui 結果も含む
            ex_mem_write_reg  <= ex_write_reg;
            ex_mem_mem_write  <= id_ex_mem_write & ~ex_exception;
            ex_mem_mem_to_reg <= id_ex_mem_to_reg;
            ex_mem_rd2        <= alu_in_rt;
            ex_mem_jal_instr  <= id_ex_jal_instr;
            ex_mem_pc_plus4   <= id_ex_pc_plus4;
            ex_mem_mem_size   <= id_ex_mem_size;
            ex_mem_mem_unsigned <= id_ex_mem_unsigned;
        end
    end

    // ============================================================
    // MEM 段: dmem アクセス
    // ============================================================

    // Step 12f: byte_en 生成 (mem_size + addr[1:0], ビッグエンディアン)
    //           halt 中は書き込み禁止
    reg [3:0] mem_byte_en;
    always @(*) begin
        if (!(ex_mem_mem_write & ~halt))
            mem_byte_en = 4'b0000;
        else case (ex_mem_mem_size)
            2'b00: // sb
                case (ex_mem_alu_result[1:0])
                    2'b00: mem_byte_en = 4'b1000; // offset 0 → mem[31:24]
                    2'b01: mem_byte_en = 4'b0100;
                    2'b10: mem_byte_en = 4'b0010;
                    2'b11: mem_byte_en = 4'b0001; // offset 3 → mem[7:0]
                endcase
            2'b01: // sh
                mem_byte_en = ex_mem_alu_result[1] ? 4'b0011 : 4'b1100;
            default: // sw
                mem_byte_en = 4'b1111;
        endcase
    end

    // 書き込みデータのバイト/ハーフ複製 (byte_en で必要バイトのみ確定)
    wire [31:0] mem_write_data = (ex_mem_mem_size == 2'b00) ? {4{ex_mem_rd2[7:0]}}  : // sb
                                 (ex_mem_mem_size == 2'b01) ? {2{ex_mem_rd2[15:0]}} : // sh
                                                              ex_mem_rd2;             // sw

    // OS-prep1: MEM 読出しデータは unified_mem_inst (IF 段付近) の mem_rdata で駆動。
    //   dmem は廃止し命令メモリと統合 (von Neumann)。
    wire [31:0] mem_read_data;

    // Step 12f: 読み出しデータのスライス + 符号/ゼロ拡張 (ビッグエンディアン)
    wire [7:0] mem_byte_sel =
        (ex_mem_alu_result[1:0] == 2'b00) ? mem_read_data[31:24] :
        (ex_mem_alu_result[1:0] == 2'b01) ? mem_read_data[23:16] :
        (ex_mem_alu_result[1:0] == 2'b10) ? mem_read_data[15: 8] :
                                            mem_read_data[ 7: 0];
    wire [15:0] mem_half_sel =
        ex_mem_alu_result[1] ? mem_read_data[15:0] : mem_read_data[31:16];

    wire [31:0] mem_data_final =
        (ex_mem_mem_size == 2'b00) ? (ex_mem_mem_unsigned ? {24'b0,             mem_byte_sel}
                                                          : {{24{mem_byte_sel[7]}},  mem_byte_sel}) :
        (ex_mem_mem_size == 2'b01) ? (ex_mem_mem_unsigned ? {16'b0,             mem_half_sel}
                                                          : {{16{mem_half_sel[15]}}, mem_half_sel}) :
                                      mem_read_data;

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
            mem_wb_mem_data   <= mem_data_final;   // Step 12f: スライス+拡張済み
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
