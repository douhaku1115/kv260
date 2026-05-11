// ============================================================
// control.v — 制御ユニット (メインデコーダ + ALUデコーダ)
// ============================================================
//
// 【役割】
//   命令の opcode (31:26), rs (25:21), funct (5:0) を見て、データパスへの
//   制御信号を生成する。2段構成:
//     1. メインデコーダ: opcode → 制御信号ベクタ + alu_op
//     2. ALUデコーダ:   alu_op + funct → alu_control
//
// 【メインデコーダ 真理値表】
//
//   命令  | opcode   | IZ RW RD AS BR MW MR BN JP | alu_op | jr | HW HO MF SH | SZ SU | LT GE LE GT
//   ------+----------+-----------------------------+--------+----+-------------+-------+-----------
//   R型   | 000000   |  0  1  1  0  0  0  0  0  0 | 010    |  0 |  0  -  0  - | 10  - |  0  0  0  0
//   jr    | 000000   |  0  0  x  x  0  0  x  0  0 | 010    |  1 |  0  -  0  - | 10  - |  0  0  0  0
//   mult  | 000000   |  0  0  x  0  0  0  x  0  0 | 010    |  0 |  1 00  0  - | 10  - |  0  0  0  0
//   multu | 000000   |  0  0  x  0  0  0  x  0  0 | 010    |  0 |  1 01  0  - | 10  - |  0  0  0  0
//   div   | 000000   |  0  0  x  0  0  0  x  0  0 | 010    |  0 |  1 10  0  - | 10  - |  0  0  0  0
//   divu  | 000000   |  0  0  x  0  0  0  x  0  0 | 010    |  0 |  1 11  0  - | 10  - |  0  0  0  0
//   mfhi  | 000000   |  0  1  1  0  0  0  0  0  0 | 010    |  0 |  0  -  1  1 | 10  - |  0  0  0  0
//   mflo  | 000000   |  0  1  1  0  0  0  0  0  0 | 010    |  0 |  0  -  1  0 | 10  - |  0  0  0  0
//   syscall|000000   |  0  0  x  0  0  0  x  0  0 | 010    |  0 |  0  -  0  - | 10  - |  0  0  0  0
//
//   HW=hilo_write, HO=hilo_op[1:0], MF=mfhilo, SH=sel_hi
//   SZ=mem_size[1:0](00=byte/01=half/10=word), SU=mem_unsigned(1=ゼロ拡張)
//   LT=branch_ltz, GE=branch_gez, LE=branch_lez, GT=branch_gtz
//
//   addi  | 001000   |  0  1  0  1  0  0  0  0  0 | 000    |  0
//   addiu | 001001   |  0  1  0  1  0  0  0  0  0 | 000    |  0
//   slti  | 001010   |  0  1  0  1  0  0  0  0  0 | 110    |  0
//   sltiu | 001011   |  0  1  0  1  0  0  0  0  0 | 111    |  0
//   andi  | 001100   |  1  1  0  1  0  0  0  0  0 | 100    |  0
//   ori   | 001101   |  1  1  0  1  0  0  0  0  0 | 011    |  0
//   xori  | 001110   |  1  1  0  1  0  0  0  0  0 | 101    |  0
//   lui   | 001111   |  0  1  0  1  0  0  0  0  0 | 000    |  0
//   lw    | 100011   |  0  1  0  1  0  0  1  0  0 | 000    |  0
//   lb    | 100000   |  0  1  0  1  0  0  1  0  0 | 000    |  0
//   lbu   | 100100   |  0  1  0  1  0  0  1  0  0 | 000    |  0
//   lh    | 100001   |  0  1  0  1  0  0  1  0  0 | 000    |  0
//   lhu   | 100101   |  0  1  0  1  0  0  1  0  0 | 000    |  0
//   sw    | 101011   |  0  0  x  1  0  1  x  0  0 | 000    |  0
//   sb    | 101000   |  0  0  x  1  0  1  x  0  0 | 000    |  0
//   sh    | 101001   |  0  0  x  1  0  1  x  0  0 | 000    |  0
//   beq   | 000100   |  0  0  x  0  1  0  x  0  0 | 001    |  0
//   bne   | 000101   |  0  0  x  0  0  0  x  1  0 | 001    |  0
//   bltz  | 000001/0 |  0  0  x  0  0  0  x  0  0 | 000    |  0
//   bgez  | 000001/1 |  0  0  x  0  0  0  x  0  0 | 000    |  0
//   blez  | 000110   |  0  0  x  0  0  0  x  0  0 | 000    |  0
//   bgtz  | 000111   |  0  0  x  0  0  0  x  0  0 | 000    |  0
//   j     | 000010   |  0  0  x  x  0  0  x  0  1 | 000    |  0
//   jal   | 000011   |  0  1  x  x  0  0  x  0  1 | 000    |  0
//   mfc0  | 010000   |  0  1  0  0  0  0  0  0  0 | 000    |  0  (rs=00000)
//   mtc0  | 010000   |  0  0  x  0  0  0  x  0  0 | 000    |  0  (rs=00100)
//   eret  | 010000   |  0  0  x  0  0  0  x  0  0 | 000    |  0  (rs=10000)
//
//   IZ=imm_zero, RW=reg_write, RD=reg_dst, AS=alu_src, BR=branch,
//   MW=mem_write, MR=mem_to_reg, BN=branch_ne, JP=jump
//   bltz/bgez は opcode=000001 で rt[0] が 0=bltz / 1=bgez を区別する
//
// 【ALUデコーダ (3bit alu_op)】
//   alu_op=000 → ADD  (addi, addiu, lw, sw, lb, lbu, lh, lhu, sb, sh, lui)
//   alu_op=001 → SUB  (beq/bne)
//   alu_op=010 → funct フィールドで演算を決定 (R型)
//   alu_op=011 → OR   (ori)
//   alu_op=100 → AND  (andi)
//   alu_op=101 → XOR  (xori)
//   alu_op=110 → SLT  (slti)
//   alu_op=111 → SLTU (sltiu)
//
// 【controls ビット割り当て (9bit)】
//   [8] imm_zero  [7] reg_write  [6] reg_dst  [5] alu_src  [4] branch
//   [3] mem_write  [2] mem_to_reg  [1] branch_ne  [0] jump
//
// 【例外処理関連出力 (Step 11)】
//   is_mfc0:   mfc0 命令 (CP0 → GPR)
//   is_mtc0:   mtc0 命令 (GPR → CP0)
//   is_syscall: syscall 命令 (例外コード=8)
//   is_eret:   eret 命令 (PC ← EPC, SR.EXL ← 0)
//   exc_on_ov: オーバーフロー例外を発生させる命令 (add/addi/sub)

module control (
    input  [5:0] opcode,
    input  [5:0] funct,
    input  [4:0] rs,          // COP0 サブオペコード判別に使用
    input  [4:0] rt,          // REGIMM (bltz/bgez) の区別に使用
    output       reg_write,
    output       reg_dst,
    output       alu_src,
    output       branch,
    output       branch_ne,   // bne 専用フラグ
    output       branch_ltz,  // bltz: rs < 0 なら分岐
    output       branch_gez,  // bgez: rs >= 0 なら分岐
    output       branch_lez,  // blez: rs <= 0 なら分岐
    output       branch_gtz,  // bgtz: rs > 0 なら分岐
    output       mem_write,
    output       mem_to_reg,
    output       jump,
    output       jr,
    output       imm_zero,    // 1=ゼロ拡張即値 (ori用)
    output [3:0] alu_control,
    output       hilo_write,  // 1=HI/LO へ書き込む (mult/multu/div/divu)
    output [1:0] hilo_op,     // 00=mult, 01=multu, 10=div, 11=divu
    output       mfhilo,      // 1=HI/LO からレジスタへ読み出す (mfhi/mflo)
    output       sel_hi,      // 1=HI 選択 (mfhi), 0=LO 選択 (mflo)
    output [1:0] mem_size,    // 00=byte, 01=halfword, 10=word
    output       mem_unsigned, // 1=ゼロ拡張ロード (lbu/lhu), 0=符号拡張 (lb/lh)
    // 例外処理 (Step 11)
    output       is_mfc0,
    output       is_mtc0,
    output       is_syscall,
    output       is_eret,
    output       exc_on_ov
);

    reg [8:0] controls;
    reg [2:0] alu_op;
    reg [1:0] mem_size_r;
    reg       mem_unsigned_r;

    // メインデコーダ
    always @(*) begin
        // デフォルト: ワードアクセス, 符号拡張 (ロード命令以外は don't care)
        mem_size_r     = 2'b10;
        mem_unsigned_r = 1'b0;
        case (opcode)
            6'b000000: begin
                if (funct == 6'b001000 ||                              // jr
                    funct == 6'b011000 || funct == 6'b011001 ||       // mult/multu
                    funct == 6'b011010 || funct == 6'b011011 ||       // div/divu
                    funct == 6'b001100)                                // syscall
                    controls = 9'b000000000;
                else
                    controls = 9'b011000000;
                alu_op = 3'b010;
            end
            6'b001000: begin controls = 9'b010100000; alu_op = 3'b000; end // addi
            6'b001001: begin controls = 9'b010100000; alu_op = 3'b000; end // addiu
            6'b001010: begin controls = 9'b010100000; alu_op = 3'b110; end // slti
            6'b001011: begin controls = 9'b010100000; alu_op = 3'b111; end // sltiu
            6'b001100: begin controls = 9'b110100000; alu_op = 3'b100; end // andi
            6'b001101: begin controls = 9'b110100000; alu_op = 3'b011; end // ori
            6'b001110: begin controls = 9'b110100000; alu_op = 3'b101; end // xori
            6'b001111: begin controls = 9'b010100000; alu_op = 3'b000; end // lui
            6'b100011: begin controls = 9'b010100100; alu_op = 3'b000; end // lw
            6'b100000: begin controls = 9'b010100100; alu_op = 3'b000; // lb
                        mem_size_r = 2'b00; mem_unsigned_r = 1'b0; end
            6'b100100: begin controls = 9'b010100100; alu_op = 3'b000; // lbu
                        mem_size_r = 2'b00; mem_unsigned_r = 1'b1; end
            6'b100001: begin controls = 9'b010100100; alu_op = 3'b000; // lh
                        mem_size_r = 2'b01; mem_unsigned_r = 1'b0; end
            6'b100101: begin controls = 9'b010100100; alu_op = 3'b000; // lhu
                        mem_size_r = 2'b01; mem_unsigned_r = 1'b1; end
            6'b101011: begin controls = 9'b000101000; alu_op = 3'b000; end // sw
            6'b101000: begin controls = 9'b000101000; alu_op = 3'b000; // sb
                        mem_size_r = 2'b00; end
            6'b101001: begin controls = 9'b000101000; alu_op = 3'b000; // sh
                        mem_size_r = 2'b01; end
            6'b000100: begin controls = 9'b000010000; alu_op = 3'b001; end // beq
            6'b000101: begin controls = 9'b000000010; alu_op = 3'b001; end // bne
            6'b000001: begin controls = 9'b000000000; alu_op = 3'b000; end // bltz/bgez
            6'b000110: begin controls = 9'b000000000; alu_op = 3'b000; end // blez
            6'b000111: begin controls = 9'b000000000; alu_op = 3'b000; end // bgtz
            6'b000010: begin controls = 9'b000000001; alu_op = 3'b000; end // j
            6'b000011: begin controls = 9'b010000001; alu_op = 3'b000; end // jal
            6'b010000: begin // COP0: mfc0/mtc0/eret
                // mfc0 (rs=00000): GPR[rt] ← CP0[rd], reg_write=1
                if (rs == 5'b00000)
                    controls = 9'b010000000;
                else
                    controls = 9'b000000000;
                alu_op = 3'b000;
            end
            default:   begin controls = 9'b000000000; alu_op = 3'b000; end
        endcase
    end

    assign imm_zero    = controls[8];
    assign reg_write   = controls[7];
    assign reg_dst     = controls[6];
    assign alu_src     = controls[5];
    assign branch      = controls[4];
    assign mem_write   = controls[3];
    assign mem_to_reg  = controls[2];
    assign branch_ne   = controls[1];
    assign jump        = controls[0];

    assign jr = (opcode == 6'b000000) && (funct == 6'b001000);

    assign branch_ltz = (opcode == 6'b000001) && (rt == 5'b00000); // bltz
    assign branch_gez = (opcode == 6'b000001) && (rt == 5'b00001); // bgez
    assign branch_lez = (opcode == 6'b000110);                     // blez
    assign branch_gtz = (opcode == 6'b000111);                     // bgtz

    assign hilo_write = (opcode == 6'b000000) &&
                        ((funct == 6'b011000) || (funct == 6'b011001) ||
                         (funct == 6'b011010) || (funct == 6'b011011));
    assign hilo_op    = funct[1:0];
    assign mfhilo     = (opcode == 6'b000000) &&
                        ((funct == 6'b010000) || (funct == 6'b010010));
    assign sel_hi     = (funct == 6'b010000);

    assign mem_size     = mem_size_r;
    assign mem_unsigned = mem_unsigned_r;

    // 例外処理制御信号 (Step 11)
    wire cop0 = (opcode == 6'b010000);
    assign is_mfc0    = cop0 && (rs == 5'b00000);
    assign is_mtc0    = cop0 && (rs == 5'b00100);
    assign is_eret    = cop0 && (rs == 5'b10000) && (funct == 6'b011000);
    assign is_syscall = (opcode == 6'b000000) && (funct == 6'b001100);
    // add(funct=100000)/sub(funct=100010)/addi(opcode=001000) でオーバーフロー例外
    assign exc_on_ov  = ((opcode == 6'b000000) &&
                         ((funct == 6'b100000) || (funct == 6'b100010))) ||
                        (opcode == 6'b001000);

    // ALUデコーダ
    reg [3:0] alu_ctrl_r;
    always @(*) begin
        case (alu_op)
            3'b000: alu_ctrl_r = 4'b0010; // ADD
            3'b001: alu_ctrl_r = 4'b0110; // SUB
            3'b010: begin
                case (funct)
                    6'b100000: alu_ctrl_r = 4'b0010; // add
                    6'b100001: alu_ctrl_r = 4'b0010; // addu
                    6'b100010: alu_ctrl_r = 4'b0110; // sub
                    6'b100011: alu_ctrl_r = 4'b0110; // subu
                    6'b100100: alu_ctrl_r = 4'b0000; // and
                    6'b100101: alu_ctrl_r = 4'b0001; // or
                    6'b100111: alu_ctrl_r = 4'b1101; // nor
                    6'b101010: alu_ctrl_r = 4'b0111; // slt
                    6'b101011: alu_ctrl_r = 4'b1100; // sltu
                    6'b000000: alu_ctrl_r = 4'b1001; // sll
                    6'b000010: alu_ctrl_r = 4'b1010; // srl
                    6'b000011: alu_ctrl_r = 4'b1011; // sra
                    6'b000100: alu_ctrl_r = 4'b1001; // sllv
                    6'b000110: alu_ctrl_r = 4'b1010; // srlv
                    6'b000111: alu_ctrl_r = 4'b1011; // srav
                    default:   alu_ctrl_r = 4'b0000;
                endcase
            end
            3'b011: alu_ctrl_r = 4'b0001; // OR  (ori)
            3'b100: alu_ctrl_r = 4'b0000; // AND (andi)
            3'b101: alu_ctrl_r = 4'b1000; // XOR (xori)
            3'b110: alu_ctrl_r = 4'b0111; // SLT (slti)
            3'b111: alu_ctrl_r = 4'b1100; // SLTU (sltiu)
            default: alu_ctrl_r = 4'b0010;
        endcase
    end

    assign alu_control = alu_ctrl_r;

endmodule
