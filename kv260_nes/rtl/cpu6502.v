// ============================================================
// cpu6502.v — NES 用 6502 CPU (2A03 の CPU 部、10 進モード無し)
// ============================================================
//
// 【バスの約束】
//   ce=1 のクロックが CPU の 1 サイクル。1 サイクルにメモリへ 1 回触る。
//   ce で addr/we/dout を出し、次の ce で din (その addr の読み値) を受け取る。
//   ce の間隔が 2 クロック以上あれば、BRAM の 1 クロック遅れの読み出しで間に合う。
//
// 【サイクル数】命令ごとのサイクル数は実機と同じ (ページまたぎ +1、分岐 2/3/4、
//   書込・RMW の空読み/空書きも同じ回数)。nestest.log の CYC と照合できる。
//
// 【状態の読み方】state は「いま終わったバスサイクル」を表す。
//   各状態の処理 = 終わったサイクルの読み値 din を使い、次のサイクルを出す。
//   命令の最後のサイクルが終わったときに演算し、同じ ce で次の命令の取り出しを出す。
//
// 【リセット】rst で BRK と同じ 7 サイクルの手順に入る (押し込みは読みに置換)。
//   S は 0x00 から 3 回減って 0xFD、P=0x24、PC は $FFFC/$FFFD から。
//
// 非公式命令は 2 サイクルの NOP として扱う。

module cpu6502 (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce,
    output reg  [15:0] addr,
    output reg  [7:0]  dout,
    output reg         we,
    input  wire [7:0]  din,
    input  wire        nmi,      // 1 になった瞬間に受け付ける (立ち上がり)
    input  wire        irq,      // 1 の間、I=0 なら受け付ける
    output reg         sync,     // 1 = いまのサイクルは命令の取り出し
    // 観測用
    output wire [15:0] dbg_pc,
    output wire [7:0]  dbg_a,
    output wire [7:0]  dbg_x,
    output wire [7:0]  dbg_y,
    output wire [7:0]  dbg_s,
    output wire [7:0]  dbg_p
);

    // ---------------- レジスタ ----------------
    reg [15:0] pc;
    reg [7:0]  a, x, y, s;
    reg        fn, fv, fd, fi, fz, fc;          // N V D I Z C
    wire [7:0] p = {fn, fv, 1'b1, 1'b0, fd, fi, fz, fc};

    assign dbg_pc = pc;  assign dbg_a = a;  assign dbg_x = x;
    assign dbg_y  = y;   assign dbg_s = s;  assign dbg_p = p;

    // ---------------- 作業用 ----------------
    reg [7:0]  op;
    reg [4:0]  st;
    reg [7:0]  lo, hi, ptr, data;
    reg [15:0] ea;
    reg        carry;                            // 添字加算の桁上がり
    reg [1:0]  ik;                               // 割り込みの種類
    reg        nmi_d, nmi_pend;

    localparam IK_BRK = 2'd0, IK_IRQ = 2'd1, IK_NMI = 2'd2, IK_RST = 2'd3;

    // アドレッシングモード
    localparam M_IMP = 5'd0,  M_IMM = 5'd1,  M_ZP  = 5'd2,  M_ZPX = 5'd3,
               M_ZPY = 5'd4,  M_ABS = 5'd5,  M_ABX = 5'd6,  M_ABY = 5'd7,
               M_IZX = 5'd8,  M_IZY = 5'd9,  M_REL = 5'd10, M_JMP = 5'd11,
               M_JMI = 5'd12, M_JSR = 5'd13, M_RTS = 5'd14, M_RTI = 5'd15,
               M_BRK = 5'd16, M_PSH = 5'd17, M_PUL = 5'd18;
    // 種類
    localparam K_RD = 2'd0, K_WR = 2'd1, K_RMW = 2'd2;

    // 状態 (= いま終わったサイクル)
    localparam S_OP   = 5'd0,  S_IMP  = 5'd1,  S_IMM  = 5'd2,  S_ZP1  = 5'd3,
               S_ZPI  = 5'd4,  S_AB1  = 5'd5,  S_AB2  = 5'd6,  S_ABF  = 5'd7,
               S_IX1  = 5'd8,  S_IX2  = 5'd9,  S_IX3  = 5'd10, S_IX4  = 5'd11,
               S_IY1  = 5'd12, S_IY2  = 5'd13, S_RD   = 5'd14, S_RMW1 = 5'd15,
               S_WR   = 5'd16, S_BR1  = 5'd17, S_BR2  = 5'd18, S_BR3  = 5'd19,
               S_J1   = 5'd20, S_J2   = 5'd21, S_J3   = 5'd22, S_J4   = 5'd23,
               S_J5   = 5'd24, S_STK1 = 5'd25, S_STK2 = 5'd26, S_STK3 = 5'd27,
               S_STK4 = 5'd28, S_STK5 = 5'd29, S_BK1  = 5'd30, S_BK2  = 5'd31;
    // BRK の後半は S_BK2 の中で ptr を数えて回す (状態番号が 5bit に収まるように)

    // ---------------- 命令の分類 ----------------
    // 戻り値 {mode[4:0], kind[1:0]}
    function [6:0] decode(input [7:0] o);
        reg [4:0] m; reg [1:0] k;
        begin
            m = M_IMP; k = K_RD;
            case (o[1:0])
            2'b01: begin                                     // ORA AND EOR ADC STA LDA CMP SBC
                case (o[4:2])
                3'd0: m = M_IZX; 3'd1: m = M_ZP;  3'd2: m = M_IMM; 3'd3: m = M_ABS;
                3'd4: m = M_IZY; 3'd5: m = M_ZPX; 3'd6: m = M_ABY; 3'd7: m = M_ABX;
                endcase
                if (o[7:5] == 3'b100) k = K_WR;              // STA
                if (o == 8'h89) m = M_IMP;                   // 非公式
            end
            2'b10: begin                                     // ASL ROL LSR ROR STX LDX DEC INC
                k = (o[7:5] == 3'b100) ? K_WR : (o[7:5] == 3'b101) ? K_RD : K_RMW;
                case (o[4:2])
                3'd0: m = (o == 8'hA2) ? M_IMM : M_IMP;      // LDX #
                3'd1: m = M_ZP;
                3'd2: m = M_IMP;                             // ASL A 等, TXA TAX DEX NOP
                3'd3: m = M_ABS;
                3'd5: m = (o[7:6] == 2'b10) ? M_ZPY : M_ZPX; // STX/LDX は zp,Y
                3'd7: m = (o == 8'h9E) ? M_IMP : (o == 8'hBE) ? M_ABY : M_ABX;
                default: m = M_IMP;                          // TXS TSX ほか
                endcase
                if (m == M_IMP) k = K_RD;
            end
            2'b00: begin
                case (o)
                8'h00: m = M_BRK; 8'h20: m = M_JSR; 8'h40: m = M_RTI; 8'h60: m = M_RTS;
                8'hA0, 8'hC0, 8'hE0: m = M_IMM;
                8'h24, 8'hA4, 8'hC4, 8'hE4: m = M_ZP;
                8'h84: begin m = M_ZP; k = K_WR; end
                8'h08, 8'h48: m = M_PSH;
                8'h28, 8'h68: m = M_PUL;
                8'h2C, 8'hAC, 8'hCC, 8'hEC: m = M_ABS;
                8'h8C: begin m = M_ABS; k = K_WR; end
                8'h4C: m = M_JMP; 8'h6C: m = M_JMI;
                8'h10, 8'h30, 8'h50, 8'h70, 8'h90, 8'hB0, 8'hD0, 8'hF0: m = M_REL;
                8'hB4: m = M_ZPX;
                8'h94: begin m = M_ZPX; k = K_WR; end
                8'hBC: m = M_ABX;
                default: m = M_IMP;                          // 88 A8 C8 E8 18 38 ... と非公式
                endcase
            end
            default: m = M_IMP;                              // cc=11 は全部非公式
            endcase
            decode = {m, k};
        end
    endfunction

    wire [4:0] dmode = decode(op) >> 2;
    wire [1:0] dkind = decode(op);

    // 書き込む値 (STA/STX/STY)
    wire [7:0] st_val = (op[1:0] == 2'b01) ? a : (op[1:0] == 2'b10) ? x : y;
    // 添字 (abs,X / abs,Y / (zp),Y)
    wire [7:0] idx = (dmode == M_ABX) ? x : y;

    // 分岐の条件: op[7:6] で旗を選び、op[5] と一致すれば分岐
    reg br_flag;
    always @(*) begin
        case (op[7:6])
        2'b00: br_flag = fn;
        2'b01: br_flag = fv;
        2'b10: br_flag = fc;
        default: br_flag = fz;
        endcase
    end
    wire br_take = (br_flag == op[5]);

    // ---------------- バス操作 ----------------
    task bus_rd(input [15:0] ad);
        begin addr <= ad; we <= 1'b0; sync <= 1'b0; end
    endtask
    task bus_wr(input [15:0] ad, input [7:0] d);
        begin addr <= ad; dout <= d; we <= 1'b1; sync <= 1'b0; end
    endtask
    // 次の命令の取り出し。割り込みが待っていれば、取り出しは空読みにして割り込みへ
    task fetch_at(input [15:0] ad);
        begin
            addr <= ad; we <= 1'b0; st <= S_OP;
            if (nmi_pend) begin
                ik <= IK_NMI; nmi_pend <= 1'b0; pc <= ad; sync <= 1'b0;
            end else if (irq && !fi) begin
                ik <= IK_IRQ; pc <= ad; sync <= 1'b0;
            end else begin
                ik <= IK_BRK; pc <= ad + 16'd1; sync <= 1'b1;
            end
        end
    endtask

    // 実効アドレスへの読み/書き (書込命令は書く、他は読む)
    task access(input [15:0] ad);
        begin
            ea <= ad;
            if (dkind == K_WR) begin bus_wr(ad, st_val); st <= S_WR; end
            else               begin bus_rd(ad);         st <= S_RD; end
        end
    endtask

    // ---------------- 演算 ----------------
    reg [8:0] sum;
    reg [7:0] r;

    // 読み命令 (LDA ADC CMP BIT ...) の実行
    task exec_read(input [7:0] v);
        begin
            case (op)
            // cc=01
            8'h01,8'h05,8'h09,8'h0D,8'h11,8'h15,8'h19,8'h1D: begin r = a | v; a <= r; fn <= r[7]; fz <= (r == 0); end
            8'h21,8'h25,8'h29,8'h2D,8'h31,8'h35,8'h39,8'h3D: begin r = a & v; a <= r; fn <= r[7]; fz <= (r == 0); end
            8'h41,8'h45,8'h49,8'h4D,8'h51,8'h55,8'h59,8'h5D: begin r = a ^ v; a <= r; fn <= r[7]; fz <= (r == 0); end
            8'h61,8'h65,8'h69,8'h6D,8'h71,8'h75,8'h79,8'h7D: begin
                sum = {1'b0, a} + {1'b0, v} + {8'd0, fc};
                a <= sum[7:0]; fc <= sum[8]; fn <= sum[7]; fz <= (sum[7:0] == 0);
                fv <= (~(a[7] ^ v[7])) & (a[7] ^ sum[7]);
            end
            8'hA1,8'hA5,8'hA9,8'hAD,8'hB1,8'hB5,8'hB9,8'hBD: begin a <= v; fn <= v[7]; fz <= (v == 0); end
            8'hC1,8'hC5,8'hC9,8'hCD,8'hD1,8'hD5,8'hD9,8'hDD: begin
                sum = {1'b0, a} - {1'b0, v};
                fc <= (a >= v); fn <= sum[7]; fz <= (sum[7:0] == 0);
            end
            8'hE1,8'hE5,8'hE9,8'hED,8'hF1,8'hF5,8'hF9,8'hFD: begin
                sum = {1'b0, a} + {1'b0, ~v} + {8'd0, fc};
                a <= sum[7:0]; fc <= sum[8]; fn <= sum[7]; fz <= (sum[7:0] == 0);
                fv <= (a[7] ^ v[7]) & (a[7] ^ sum[7]);
            end
            // LDX / LDY
            8'hA2,8'hA6,8'hAE,8'hB6,8'hBE: begin x <= v; fn <= v[7]; fz <= (v == 0); end
            8'hA0,8'hA4,8'hAC,8'hB4,8'hBC: begin y <= v; fn <= v[7]; fz <= (v == 0); end
            // CPX / CPY
            8'hE0,8'hE4,8'hEC: begin sum = {1'b0, x} - {1'b0, v}; fc <= (x >= v); fn <= sum[7]; fz <= (sum[7:0] == 0); end
            8'hC0,8'hC4,8'hCC: begin sum = {1'b0, y} - {1'b0, v}; fc <= (y >= v); fn <= sum[7]; fz <= (sum[7:0] == 0); end
            // BIT
            8'h24,8'h2C: begin fz <= ((a & v) == 0); fn <= v[7]; fv <= v[6]; end
            default: ;
            endcase
        end
    endtask

    // 読み変え書き (ASL LSR ROL ROR INC DEC) の新しい値。旗も更新する
    task exec_rmw(input [7:0] v, output [7:0] res);
        begin
            case (op[7:5])
            3'b000: begin res = {v[6:0], 1'b0}; fc <= v[7]; end   // ASL
            3'b001: begin res = {v[6:0], fc};   fc <= v[7]; end   // ROL
            3'b010: begin res = {1'b0, v[7:1]}; fc <= v[0]; end   // LSR
            3'b011: begin res = {fc, v[7:1]};   fc <= v[0]; end   // ROR
            3'b110: res = v - 8'd1;                               // DEC
            default: res = v + 8'd1;                              // INC
            endcase
            fn <= res[7]; fz <= (res == 0);
        end
    endtask

    // 暗黙・アキュムレータ命令
    task exec_imp;
        reg [7:0] t;
        begin
            case (op)
            8'h0A, 8'h2A, 8'h4A, 8'h6A: begin exec_rmw(a, t); a <= t; end
            8'hAA: begin x <= a; fn <= a[7]; fz <= (a == 0); end          // TAX
            8'hA8: begin y <= a; fn <= a[7]; fz <= (a == 0); end          // TAY
            8'h8A: begin a <= x; fn <= x[7]; fz <= (x == 0); end          // TXA
            8'h98: begin a <= y; fn <= y[7]; fz <= (y == 0); end          // TYA
            8'hBA: begin x <= s; fn <= s[7]; fz <= (s == 0); end          // TSX
            8'h9A: s <= x;                                                // TXS
            8'hE8: begin t = x + 8'd1; x <= t; fn <= t[7]; fz <= (t == 0); end
            8'hC8: begin t = y + 8'd1; y <= t; fn <= t[7]; fz <= (t == 0); end
            8'hCA: begin t = x - 8'd1; x <= t; fn <= t[7]; fz <= (t == 0); end
            8'h88: begin t = y - 8'd1; y <= t; fn <= t[7]; fz <= (t == 0); end
            8'h18: fc <= 1'b0; 8'h38: fc <= 1'b1;
            8'h58: fi <= 1'b0; 8'h78: fi <= 1'b1;
            8'hB8: fv <= 1'b0;
            8'hD8: fd <= 1'b0; 8'hF8: fd <= 1'b1;
            default: ;                                                    // NOP と非公式
            endcase
        end
    endtask

    // ---------------- 本体 ----------------
    reg [7:0] nv;           // RMW の新しい値
    reg [8:0] s9;           // 添字の加算

    always @(posedge clk) begin
        if (rst) begin
            pc <= 16'd0; a <= 8'd0; x <= 8'd0; y <= 8'd0; s <= 8'd0;
            fn <= 1'b0; fv <= 1'b0; fd <= 1'b0; fi <= 1'b1; fz <= 1'b0; fc <= 1'b0;
            addr <= 16'd0; we <= 1'b0; dout <= 8'd0; sync <= 1'b0;
            st <= S_OP; ik <= IK_RST; op <= 8'h00;
            nmi_d <= 1'b0; nmi_pend <= 1'b0;
        end else begin
            // NMI の立ち上がりを覚える (ce に関係なく)
            nmi_d <= nmi;
            if (nmi && !nmi_d) nmi_pend <= 1'b1;

            if (ce) begin
                case (st)
                // ---- 取り出し終了 ----
                S_OP: begin
                    if (ik != IK_BRK) begin
                        // 割り込み・リセット: 取り出した値は捨て、BRK の手順へ
                        op <= 8'h00;
                        bus_rd(pc);
                        st <= S_BK1;
                    end else begin
                        op <= din;
                        case (decode(din) >> 2)
                        M_IMP: begin bus_rd(pc); st <= S_IMP; end
                        M_REL: begin bus_rd(pc); pc <= pc + 16'd1; st <= S_BR1; end
                        M_BRK: begin bus_rd(pc); pc <= pc + 16'd1; st <= S_BK1; end
                        M_PSH, M_PUL, M_RTS, M_RTI:
                               begin bus_rd(pc); st <= S_STK1; end
                        M_JSR: begin bus_rd(pc); pc <= pc + 16'd1; st <= S_J1; end
                        default: begin bus_rd(pc); pc <= pc + 16'd1;           // 1 バイト目のオペランド
                                 case (decode(din) >> 2)
                                 M_IMM: st <= S_IMM;
                                 M_ZP, M_ZPX, M_ZPY: st <= S_ZP1;
                                 M_IZX: st <= S_IX1;
                                 M_IZY: st <= S_IY1;
                                 default: st <= S_AB1;                         // ABS ABX ABY JMP JMI
                                 endcase
                        end
                        endcase
                    end
                end

                S_IMP: begin exec_imp; fetch_at(pc); end
                S_IMM: begin exec_read(din); fetch_at(pc); end

                // ---- ゼロページ ----
                S_ZP1: begin
                    lo <= din;
                    if (dmode == M_ZP) access({8'h00, din});
                    else begin bus_rd({8'h00, din}); st <= S_ZPI; end         // 空読み
                end
                S_ZPI: access({8'h00, lo + ((dmode == M_ZPX) ? x : y)});

                // ---- 絶対 (JMP 系も lo/hi はここで読む) ----
                S_AB1: begin lo <= din; bus_rd(pc); pc <= pc + 16'd1; st <= S_AB2; end
                S_AB2: begin
                    if (dmode == M_JMP)      fetch_at({din, lo});
                    else if (dmode == M_JMI) begin ea <= {din, lo}; ptr <= 8'h00; bus_rd({din, lo}); st <= S_J4; end
                    else if (dmode == M_ABS) access({din, lo});
                    else begin
                        // ABX / ABY / (zp),Y の 3 サイクル目
                        s9 = {1'b0, lo} + {1'b0, idx};
                        hi <= din; carry <= s9[8]; lo <= s9[7:0];
                        if (dkind == K_RD && !s9[8]) access({din, s9[7:0]});
                        else begin bus_rd({din, s9[7:0]}); st <= S_ABF; end    // 桁上げ前の番地を空読み
                    end
                end
                S_ABF: access({hi + {7'd0, carry}, lo});

                // ---- (zp,X) ----
                S_IX1: begin ptr <= din; bus_rd({8'h00, din}); st <= S_IX2; end
                S_IX2: begin ptr <= ptr + x; bus_rd({8'h00, ptr + x}); st <= S_IX3; end
                S_IX3: begin lo <= din; bus_rd({8'h00, ptr + 8'd1}); st <= S_IX4; end
                S_IX4: access({din, lo});

                // ---- (zp),Y ----
                S_IY1: begin ptr <= din; bus_rd({8'h00, din}); st <= S_IY2; end
                S_IY2: begin lo <= din; bus_rd({8'h00, ptr + 8'd1}); st <= S_AB2; end

                // ---- 実効アドレスの読み/書き ----
                S_RD: begin
                    if (dkind == K_RMW) begin
                        data <= din; bus_wr(ea, din); st <= S_RMW1;            // 元の値を空書き
                    end else begin
                        exec_read(din); fetch_at(pc);
                    end
                end
                S_RMW1: begin exec_rmw(data, nv); bus_wr(ea, nv); st <= S_WR; end
                S_WR:   fetch_at(pc);

                // ---- 分岐 ----
                S_BR1: begin
                    if (!br_take) fetch_at(pc);
                    else begin
                        ea <= pc + {{8{din[7]}}, din};
                        bus_rd(pc); st <= S_BR2;                               // 空読み
                    end
                end
                S_BR2: begin
                    if (ea[15:8] == pc[15:8]) fetch_at(ea);
                    else begin bus_rd({pc[15:8], ea[7:0]}); st <= S_BR3; end   // ページ違いで +1
                end
                S_BR3: fetch_at(ea);

                // ---- JSR: lo 取得 → スタック空読み → PCH → PCL → hi 取得 ----
                S_J1: begin lo <= din; bus_rd({8'h01, s}); st <= S_J2; end
                S_J2: begin bus_wr({8'h01, s}, pc[15:8]); s <= s - 8'd1; st <= S_J3; end
                S_J3: begin bus_wr({8'h01, s}, pc[7:0]);  s <= s - 8'd1; st <= S_J5; end
                S_J5: begin
                    if (we) begin bus_rd(pc); end                              // hi を読みに行く
                    else    fetch_at({din, lo});
                end

                // ---- JMP (ind): 上位は桁上げしない (6502 の癖) ----
                S_J4: begin
                    if (ptr == 8'hFF) begin                                    // 2 回目: hi を受け取った
                        fetch_at({din, lo});
                    end else begin
                        lo <= din; ptr <= 8'hFF;
                        bus_rd({ea[15:8], ea[7:0] + 8'd1});
                    end
                end

                // ---- スタック系 (PHA PHP PLA PLP RTS RTI) ----
                S_STK1: begin
                    case (dmode)
                    M_PSH: begin
                        bus_wr({8'h01, s}, (op == 8'h48) ? a : (p | 8'h30));   // PHP は B=1
                        s <= s - 8'd1; st <= S_WR;
                    end
                    default: begin bus_rd({8'h01, s}); st <= S_STK2; end       // 空読み
                    endcase
                end
                S_STK2: begin s <= s + 8'd1; bus_rd({8'h01, s + 8'd1}); st <= S_STK3; end
                S_STK3: begin
                    case (dmode)
                    M_PUL: begin
                        if (op == 8'h68) begin a <= din; fn <= din[7]; fz <= (din == 0); end
                        else {fn, fv, fd, fi, fz, fc} <= {din[7:6], din[3:0]};
                        fetch_at(pc);
                    end
                    M_RTI: begin
                        {fn, fv, fd, fi, fz, fc} <= {din[7:6], din[3:0]};
                        ptr <= 8'h00;                                          // S_STK4 の目印を消す
                        s <= s + 8'd1; bus_rd({8'h01, s + 8'd1}); st <= S_STK4;
                    end
                    default: begin                                             // RTS: PCL
                        lo <= din; s <= s + 8'd1; bus_rd({8'h01, s + 8'd1}); st <= S_STK4;
                    end
                    endcase
                end
                S_STK4: begin
                    if (dmode == M_RTI && ptr != 8'hEE) begin                  // RTI: PCL
                        lo <= din; ptr <= 8'hEE;
                        s <= s + 8'd1; bus_rd({8'h01, s + 8'd1});
                    end else if (dmode == M_RTI) begin                          // RTI: PCH → 戻る
                        ptr <= 8'h00;
                        fetch_at({din, lo});
                    end else begin                                             // RTS: PCH
                        pc <= {din, lo}; bus_rd({din, lo}); st <= S_STK5;      // 空読み
                    end
                end
                S_STK5: fetch_at(pc + 16'd1);

                // ---- BRK / 割り込み / リセット ----
                // S_BK1: PCH を積む、S_BK2: ptr で数えて PCL → P → ベクタ lo → ベクタ hi
                S_BK1: begin
                    if (ik == IK_RST) bus_rd({8'h01, s});
                    else              bus_wr({8'h01, s}, pc[15:8]);
                    s <= s - 8'd1; ptr <= 8'd0; st <= S_BK2;
                end
                S_BK2: begin
                    case (ptr)
                    8'd0: begin
                        if (ik == IK_RST) bus_rd({8'h01, s});
                        else              bus_wr({8'h01, s}, pc[7:0]);
                        s <= s - 8'd1; ptr <= 8'd1;
                    end
                    8'd1: begin
                        if (ik == IK_RST) bus_rd({8'h01, s});
                        else              bus_wr({8'h01, s}, (ik == IK_BRK) ? (p | 8'h30) : (p | 8'h20));
                        s <= s - 8'd1; ptr <= 8'd2;
                    end
                    8'd2: begin
                        fi <= 1'b1;
                        ea <= (ik == IK_NMI) ? 16'hFFFA : (ik == IK_RST) ? 16'hFFFC : 16'hFFFE;
                        bus_rd((ik == IK_NMI) ? 16'hFFFA : (ik == IK_RST) ? 16'hFFFC : 16'hFFFE);
                        ptr <= 8'd3;
                    end
                    8'd3: begin lo <= din; bus_rd(ea + 16'd1); ptr <= 8'd4; end
                    default: begin ptr <= 8'd0; ik <= IK_BRK; fetch_at({din, lo}); end
                    endcase
                end

                default: fetch_at(pc);
                endcase
            end
        end
    end
endmodule
