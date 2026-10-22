// ============================================================
// apu.v — NES の APU (2A03 の音源部)。段F
// ============================================================
//
// clk (100MHz) で動き、ce (= cpu_ce) が CPU の 1 サイクル。
// 音源: 矩形波 x2 ($4000-$4007) / 三角波 ($4008-$400B) / ノイズ ($400C-$400F) / DMC ($4010-$4013)
// 制御: $4015 (書: 各音源の有効 / 読: 状態と IRQ) / $4017 (書: フレームカウンタ)
//
// 【タイマ】矩形波は 2 サイクルに 1 回 (APU サイクル)、三角波・ノイズ・DMC は毎サイクル進める。
//   周波数: 矩形波 = CPU/(16*(t+1))、三角波 = CPU/(32*(t+1))
// 【フレームカウンタ】CPU サイクルで数え、
//   4 ステップ: 7457 Q / 14913 QH / 22371 Q / 29829 QH、IRQ は 29828〜29830、29830 で 0 に戻る
//   5 ステップ: 7457 Q / 14913 QH / 22371 Q / 37281 QH、37282 で 0 に戻る (IRQ なし)
//   Q = エンベロープ・三角波の線形カウンタ、H = 長さカウンタ・スイープ
//   $4017 への書き込みでのリセットは 3〜4 サイクル遅れる (実機と同じ)。5 ステップならその時に QH
// 【DMC】バッファが空で残りバイトがあれば dmc_req を出す。nes_core がバスを 4 サイクル借りて読み、
//   読めたクロックに dmc_ack と dmc_data を返す。
// 【出力】実機の非線形ミキサ (表引き: apu_pulse.hex / apu_tnd.hex、tools/apu_mix_gen.py が作る) のあと
//   1 次ローパス (約 18kHz) と直流除去 (約 70Hz) を通した符号付き 16bit。ce ごとに更新。
//   実機の溢れ判定などの細かい癖は真似していないものがある (各所のコメント参照)。

// ---------------- エンベロープ (矩形波・ノイズ) ----------------
module apu_env (
    input  wire       clk, rst, ce,
    input  wire       q,          // 1/4 フレームの合図
    input  wire       restart,    // 4 番目のレジスタに書いた
    input  wire       loop,       // 長さカウンタ停止と兼用のビット
    input  wire       cvol,       // 1 = 一定音量
    input  wire [3:0] v,          // 音量 / 減衰の周期
    output wire [3:0] vol
);
    reg       start;
    reg [3:0] div, decay;
    always @(posedge clk) begin
        if (rst) begin
            start <= 1'b0; div <= 4'd0; decay <= 4'd0;
        end else if (ce) begin
            if (q) begin
                if (start) begin
                    start <= 1'b0; decay <= 4'd15; div <= v;
                end else if (div == 4'd0) begin
                    div <= v;
                    if (decay != 4'd0) decay <= decay - 4'd1;
                    else if (loop)     decay <= 4'd15;
                end else
                    div <= div - 4'd1;
            end
            if (restart) start <= 1'b1;
        end
    end
    assign vol = cvol ? v : decay;
endmodule

// ---------------- 長さカウンタ ----------------
module apu_len (
    input  wire       clk, rst, ce,
    input  wire       h,          // 1/2 フレームの合図
    input  wire       halt,
    input  wire       en,         // $4015 の有効ビット
    input  wire       load,       // 4 番目のレジスタに書いた
    input  wire [4:0] idx,        // 書いた値の [7:3]
    output wire       nz          // 0 でない (= 鳴ってよい)
);
    function [7:0] ltab(input [4:0] i);
        case (i)
        5'd0:  ltab = 8'd10;  5'd1:  ltab = 8'd254; 5'd2:  ltab = 8'd20;  5'd3:  ltab = 8'd2;
        5'd4:  ltab = 8'd40;  5'd5:  ltab = 8'd4;   5'd6:  ltab = 8'd80;  5'd7:  ltab = 8'd6;
        5'd8:  ltab = 8'd160; 5'd9:  ltab = 8'd8;   5'd10: ltab = 8'd60;  5'd11: ltab = 8'd10;
        5'd12: ltab = 8'd14;  5'd13: ltab = 8'd12;  5'd14: ltab = 8'd26;  5'd15: ltab = 8'd14;
        5'd16: ltab = 8'd12;  5'd17: ltab = 8'd16;  5'd18: ltab = 8'd24;  5'd19: ltab = 8'd18;
        5'd20: ltab = 8'd48;  5'd21: ltab = 8'd20;  5'd22: ltab = 8'd96;  5'd23: ltab = 8'd22;
        5'd24: ltab = 8'd192; 5'd25: ltab = 8'd24;  5'd26: ltab = 8'd72;  5'd27: ltab = 8'd26;
        5'd28: ltab = 8'd16;  5'd29: ltab = 8'd28;  5'd30: ltab = 8'd32;  default: ltab = 8'd30;
        endcase
    endfunction

    reg [7:0] len;
    always @(posedge clk) begin
        if (rst)
            len <= 8'd0;
        else if (ce) begin
            if (h && !halt && len != 8'd0) len <= len - 8'd1;
            if (load && en) len <= ltab(idx);
            if (!en)        len <= 8'd0;
        end
    end
    assign nz = (len != 8'd0);
endmodule

// ---------------- 矩形波 ----------------
// NEG1 = 1: 矩形波 1 (スイープの引き算が 1 の補数 = さらに 1 引く)
module apu_pulse #(parameter NEG1 = 0) (
    input  wire       clk, rst, ce,
    input  wire       apu_tick,   // 2 サイクルに 1 回
    input  wire       q, h,
    input  wire [3:0] wr,         // どのレジスタに書いたか (1 ホット)
    input  wire [7:0] wdata,
    input  wire       en,
    output wire [3:0] out,
    output wire       len_nz
);
    reg [1:0]  duty;
    reg        halt, cvol;
    reg [3:0]  v;
    reg        sw_en, sw_neg, sw_reload;
    reg [2:0]  sw_p, sw_sh, sw_div;
    reg [10:0] period, t;
    reg [2:0]  seq;

    wire [10:0] change = period >> sw_sh;
    wire [11:0] target = sw_neg ? ({1'b0, period} - {1'b0, change} - (NEG1 ? 12'd1 : 12'd0))
                                : ({1'b0, period} + {1'b0, change});
    // 周期が 8 未満、または足した結果が $7FF を超えると無音 (スイープ無効でも判定する)
    wire mute = (period < 11'd8) || (!sw_neg && target[11]);

    always @(posedge clk) begin
        if (rst) begin
            duty <= 2'd0; halt <= 1'b0; cvol <= 1'b0; v <= 4'd0;
            sw_en <= 1'b0; sw_neg <= 1'b0; sw_reload <= 1'b0; sw_p <= 3'd0; sw_sh <= 3'd0; sw_div <= 3'd0;
            period <= 11'd0; t <= 11'd0; seq <= 3'd0;
        end else if (ce) begin
            if (apu_tick) begin
                if (t == 11'd0) begin t <= period; seq <= seq - 3'd1; end
                else t <= t - 11'd1;
            end
            if (h) begin
                if (sw_div == 3'd0 && sw_en && sw_sh != 3'd0 && !mute) period <= target[10:0];
                if (sw_div == 3'd0 || sw_reload) begin sw_div <= sw_p; sw_reload <= 1'b0; end
                else sw_div <= sw_div - 3'd1;
            end
            // 書き込み (上の更新より後に書いて優先させる)
            if (wr[0]) begin duty <= wdata[7:6]; halt <= wdata[5]; cvol <= wdata[4]; v <= wdata[3:0]; end
            if (wr[1]) begin
                sw_en <= wdata[7]; sw_p <= wdata[6:4]; sw_neg <= wdata[3]; sw_sh <= wdata[2:0];
                sw_reload <= 1'b1;
            end
            if (wr[2]) period[7:0] <= wdata;
            if (wr[3]) begin period[10:8] <= wdata[2:0]; seq <= 3'd0; end
        end
    end

    // デューティ: 12.5% / 25% / 50% / 25% 反転
    reg [7:0] dpat;
    always @(*)
        case (duty)
        2'd0: dpat = 8'b0000_0010;
        2'd1: dpat = 8'b0000_0110;
        2'd2: dpat = 8'b0001_1110;
        default: dpat = 8'b1111_1001;
        endcase

    wire [3:0] vol;
    apu_env env (.clk(clk), .rst(rst), .ce(ce), .q(q), .restart(wr[3]), .loop(halt), .cvol(cvol), .v(v), .vol(vol));
    apu_len lc  (.clk(clk), .rst(rst), .ce(ce), .h(h), .halt(halt), .en(en), .load(wr[3]), .idx(wdata[7:3]), .nz(len_nz));

    assign out = (len_nz && !mute && dpat[seq]) ? vol : 4'd0;
endmodule

// ---------------- APU 本体 ----------------
module apu (
    input  wire        clk,
    input  wire        rst,
    input  wire        ce,
    // CPU のレジスタ ($4000-$4017 の下位 5bit)。reg_wr はサイクルの終わり (ce と同じクロック)
    input  wire [4:0]  reg_addr,
    input  wire        reg_wr,
    input  wire [7:0]  reg_wdata,
    input  wire        rd_4015,      // $4015 を読んだ (フレーム IRQ を消す)
    output wire [7:0]  status,       // $4015 の読み値
    output wire        irq,
    // DMC のメモリ読み
    output wire        dmc_req,
    output wire [15:0] dmc_addr,
    input  wire        dmc_ack,
    input  wire [7:0]  dmc_data,
    // 音
    output reg  signed [15:0] sample,
    // 観測用
    output wire [3:0]  p1_out, p2_out, tri_out, noi_out,
    output wire [6:0]  dmc_out
);
    wire wr = ce && reg_wr;

    // ---------------- $4015 / フレームカウンタ ----------------
    reg [4:0]  en;                   // [0]矩形1 [1]矩形2 [2]三角 [3]ノイズ [4]DMC
    reg        apu_tick;
    reg [15:0] fc_cnt;
    reg        fc_mode, fc_inhibit, frame_irq, fc_irq3;
    reg [2:0]  fc_pend;              // $4017 の書き込みからリセットまでの残り

    wire fc_reset = (fc_pend == 3'd1);
    wire fc_q4 = !fc_mode && (fc_cnt == 16'd7457 || fc_cnt == 16'd14913 || fc_cnt == 16'd22371 || fc_cnt == 16'd29829);
    wire fc_h4 = !fc_mode && (fc_cnt == 16'd14913 || fc_cnt == 16'd29829);
    wire fc_q5 =  fc_mode && (fc_cnt == 16'd7457 || fc_cnt == 16'd14913 || fc_cnt == 16'd22371 || fc_cnt == 16'd37281);
    wire fc_h5 =  fc_mode && (fc_cnt == 16'd14913 || fc_cnt == 16'd37281);
    // リセットの瞬間に 5 ステップなら Q と H を 1 回ずつ
    wire q = ce && (fc_q4 || fc_q5 || (fc_reset && fc_mode));
    wire h = ce && (fc_h4 || fc_h5 || (fc_reset && fc_mode));

    always @(posedge clk) begin
        if (rst) begin
            en <= 5'd0; apu_tick <= 1'b0; fc_cnt <= 16'd0;
            fc_mode <= 1'b0; fc_inhibit <= 1'b0; frame_irq <= 1'b0; fc_irq3 <= 1'b0; fc_pend <= 3'd0;
        end else if (ce) begin
            apu_tick <= ~apu_tick;
            if (fc_reset)
                fc_cnt <= 16'd0;
            else if ((!fc_mode && fc_cnt == 16'd29829) || (fc_mode && fc_cnt == 16'd37281))
                fc_cnt <= 16'd0;
            else
                fc_cnt <= fc_cnt + 16'd1;
            if (fc_pend != 3'd0) fc_pend <= fc_pend - 3'd1;
            // フレーム IRQ は 29828, 29829, 29830 (= 次の 0) の 3 サイクル続けて立てる。
            // $4015 の読みで消えるが、同じサイクルに立てる方が勝つ (実機と同じ。後に書いて優先)
            if (rd_4015) frame_irq <= 1'b0;
            fc_irq3 <= !fc_mode && !fc_reset && fc_cnt == 16'd29829;
            if (!fc_inhibit && ((!fc_mode && (fc_cnt == 16'd29828 || fc_cnt == 16'd29829)) || fc_irq3))
                frame_irq <= 1'b1;

            if (reg_wr && reg_addr == 5'h15) en <= reg_wdata[4:0];
            if (reg_wr && reg_addr == 5'h17) begin
                fc_mode    <= reg_wdata[7];
                fc_inhibit <= reg_wdata[6];
                if (reg_wdata[6]) frame_irq <= 1'b0;
                // 書いたサイクル w の 3 (APU サイクル中) / 4 (APU サイクルの間) サイクル後に効く。
                // ここでは「カウンタ 0 のサイクル」を w+2 / w+3 に置く (残り 1 のクロックでリセット)。
                // そうすると 29828 で立てたフラグが w+29831 の読みで初めて見える
                // (apu_test 6-irq_flag_timing の「$4017 に書いて 29831 クロック後」と一致)
                fc_pend    <= apu_tick ? 3'd1 : 3'd2;
            end
        end
    end

    // ---------------- 矩形波 x2 ----------------
    wire [3:0] wr_p1 = {4{wr && reg_addr[4:2] == 3'd0}} & (4'b0001 << reg_addr[1:0]);
    wire [3:0] wr_p2 = {4{wr && reg_addr[4:2] == 3'd1}} & (4'b0001 << reg_addr[1:0]);
    wire       p1_nz, p2_nz;

    apu_pulse #(.NEG1(1)) pulse1
      (.clk(clk), .rst(rst), .ce(ce), .apu_tick(apu_tick), .q(q), .h(h),
       .wr(wr_p1), .wdata(reg_wdata), .en(en[0]), .out(p1_out), .len_nz(p1_nz));
    apu_pulse #(.NEG1(0)) pulse2
      (.clk(clk), .rst(rst), .ce(ce), .apu_tick(apu_tick), .q(q), .h(h),
       .wr(wr_p2), .wdata(reg_wdata), .en(en[1]), .out(p2_out), .len_nz(p2_nz));

    // ---------------- 三角波 ----------------
    reg        tr_ctrl, tr_lin_rf;
    reg [6:0]  tr_lin_rel, tr_lin;
    reg [10:0] tr_period, tr_t;
    reg [4:0]  tr_step;
    wire       tr_nz;
    always @(posedge clk) begin
        if (rst) begin
            tr_ctrl <= 1'b0; tr_lin_rf <= 1'b0; tr_lin_rel <= 7'd0; tr_lin <= 7'd0;
            tr_period <= 11'd0; tr_t <= 11'd0; tr_step <= 5'd0;
        end else if (ce) begin
            if (tr_t == 11'd0) begin
                tr_t <= tr_period;
                if (tr_lin != 7'd0 && tr_nz) tr_step <= tr_step + 5'd1;
            end else
                tr_t <= tr_t - 11'd1;
            if (q) begin
                if (tr_lin_rf)            tr_lin <= tr_lin_rel;
                else if (tr_lin != 7'd0)  tr_lin <= tr_lin - 7'd1;
                if (!tr_ctrl)             tr_lin_rf <= 1'b0;
            end
            if (wr && reg_addr == 5'h08) begin tr_ctrl <= reg_wdata[7]; tr_lin_rel <= reg_wdata[6:0]; end
            if (wr && reg_addr == 5'h0A) tr_period[7:0] <= reg_wdata;
            if (wr && reg_addr == 5'h0B) begin tr_period[10:8] <= reg_wdata[2:0]; tr_lin_rf <= 1'b1; end
        end
    end
    apu_len tr_lc (.clk(clk), .rst(rst), .ce(ce), .h(h), .halt(tr_ctrl), .en(en[2]),
                   .load(wr && reg_addr == 5'h0B), .idx(reg_wdata[7:3]), .nz(tr_nz));
    // 15,14,…,0,0,1,…,15
    assign tri_out = tr_step[4] ? tr_step[3:0] : ~tr_step[3:0];

    // ---------------- ノイズ ----------------
    function [11:0] ntab(input [3:0] i);
        case (i)
        4'd0: ntab = 12'd4;    4'd1: ntab = 12'd8;    4'd2: ntab = 12'd16;   4'd3: ntab = 12'd32;
        4'd4: ntab = 12'd64;   4'd5: ntab = 12'd96;   4'd6: ntab = 12'd128;  4'd7: ntab = 12'd160;
        4'd8: ntab = 12'd202;  4'd9: ntab = 12'd254;  4'd10: ntab = 12'd380; 4'd11: ntab = 12'd508;
        4'd12: ntab = 12'd762; 4'd13: ntab = 12'd1016; 4'd14: ntab = 12'd2034; default: ntab = 12'd4068;
        endcase
    endfunction

    reg        nz_halt, nz_cvol, nz_mode;
    reg [3:0]  nz_v, nz_pidx;
    reg [11:0] nz_t;
    reg [14:0] lfsr;
    wire [3:0] nz_vol;
    wire       noi_nz;
    always @(posedge clk) begin
        if (rst) begin
            nz_halt <= 1'b0; nz_cvol <= 1'b0; nz_mode <= 1'b0; nz_v <= 4'd0; nz_pidx <= 4'd0;
            nz_t <= 12'd0; lfsr <= 15'd1;
        end else if (ce) begin
            if (nz_t == 12'd0) begin
                nz_t <= ntab(nz_pidx) - 12'd1;
                lfsr <= {lfsr[0] ^ (nz_mode ? lfsr[6] : lfsr[1]), lfsr[14:1]};
            end else
                nz_t <= nz_t - 12'd1;
            if (wr && reg_addr == 5'h0C) begin nz_halt <= reg_wdata[5]; nz_cvol <= reg_wdata[4]; nz_v <= reg_wdata[3:0]; end
            if (wr && reg_addr == 5'h0E) begin nz_mode <= reg_wdata[7]; nz_pidx <= reg_wdata[3:0]; end
        end
    end
    apu_env nz_env (.clk(clk), .rst(rst), .ce(ce), .q(q), .restart(wr && reg_addr == 5'h0F),
                    .loop(nz_halt), .cvol(nz_cvol), .v(nz_v), .vol(nz_vol));
    apu_len nz_lc  (.clk(clk), .rst(rst), .ce(ce), .h(h), .halt(nz_halt), .en(en[3]),
                    .load(wr && reg_addr == 5'h0F), .idx(reg_wdata[7:3]), .nz(noi_nz));
    assign noi_out = (noi_nz && !lfsr[0]) ? nz_vol : 4'd0;

    // ---------------- DMC ----------------
    function [8:0] rtab(input [3:0] i);
        case (i)
        4'd0: rtab = 9'd428;  4'd1: rtab = 9'd380;  4'd2: rtab = 9'd340;  4'd3: rtab = 9'd320;
        4'd4: rtab = 9'd286;  4'd5: rtab = 9'd254;  4'd6: rtab = 9'd226;  4'd7: rtab = 9'd214;
        4'd8: rtab = 9'd190;  4'd9: rtab = 9'd160;  4'd10: rtab = 9'd142; 4'd11: rtab = 9'd128;
        4'd12: rtab = 9'd106; 4'd13: rtab = 9'd84;  4'd14: rtab = 9'd72;  default: rtab = 9'd54;
        endcase
    endfunction

    reg        dm_irq_en, dm_loop, dm_irq;
    reg [3:0]  dm_rate;
    reg [6:0]  dm_level;
    reg [7:0]  dm_sa, dm_sl;
    reg [15:0] dm_addr;
    reg [11:0] dm_rem;               // 残りバイト数
    reg [7:0]  dm_buf, dm_shift;
    reg        dm_full, dm_silence;
    reg [3:0]  dm_bits;
    reg [8:0]  dm_t;

    assign dmc_req  = !dm_full && dm_rem != 12'd0;
    assign dmc_addr = dm_addr;
    assign dmc_out  = dm_level;

    always @(posedge clk) begin
        if (rst) begin
            dm_irq_en <= 1'b0; dm_loop <= 1'b0; dm_irq <= 1'b0; dm_rate <= 4'd0; dm_level <= 7'd0;
            dm_sa <= 8'd0; dm_sl <= 8'd0; dm_addr <= 16'hC000; dm_rem <= 12'd0;
            dm_buf <= 8'd0; dm_shift <= 8'd0; dm_full <= 1'b0; dm_silence <= 1'b1; dm_bits <= 4'd8;
            dm_t <= 9'd0;
        end else if (ce) begin
            // 出力: 1 ビットごとに ±2
            if (dm_t == 9'd0) begin
                dm_t <= rtab(dm_rate) - 9'd1;
                if (!dm_silence) begin
                    if (dm_shift[0]) begin if (dm_level <= 7'd125) dm_level <= dm_level + 7'd2; end
                    else             begin if (dm_level >= 7'd2)   dm_level <= dm_level - 7'd2; end
                end
                dm_shift <= {1'b0, dm_shift[7:1]};
                if (dm_bits == 4'd1) begin                 // 8 ビット終わり → 次のバイト
                    dm_bits <= 4'd8;
                    if (dm_full) begin dm_shift <= dm_buf; dm_silence <= 1'b0; dm_full <= 1'b0; end
                    else dm_silence <= 1'b1;
                end else
                    dm_bits <= dm_bits - 4'd1;
            end else
                dm_t <= dm_t - 9'd1;

            // メモリから 1 バイト届いた
            if (dmc_ack) begin
                dm_buf  <= dmc_data;
                dm_full <= 1'b1;
                dm_addr <= (dm_addr == 16'hFFFF) ? 16'h8000 : dm_addr + 16'd1;
                if (dm_rem == 12'd1) begin
                    if (dm_loop) begin dm_addr <= {2'b11, dm_sa, 6'd0}; dm_rem <= {dm_sl, 4'd0} + 12'd1; end
                    else begin dm_rem <= 12'd0; if (dm_irq_en) dm_irq <= 1'b1; end
                end else
                    dm_rem <= dm_rem - 12'd1;
            end

            if (wr && reg_addr == 5'h10) begin
                dm_irq_en <= reg_wdata[7]; dm_loop <= reg_wdata[6]; dm_rate <= reg_wdata[3:0];
                if (!reg_wdata[7]) dm_irq <= 1'b0;
            end
            if (wr && reg_addr == 5'h11) dm_level <= reg_wdata[6:0];
            if (wr && reg_addr == 5'h12) dm_sa <= reg_wdata;
            if (wr && reg_addr == 5'h13) dm_sl <= reg_wdata;
            if (wr && reg_addr == 5'h15) begin
                dm_irq <= 1'b0;
                if (!reg_wdata[4]) dm_rem <= 12'd0;
                else if (dm_rem == 12'd0) begin dm_addr <= {2'b11, dm_sa, 6'd0}; dm_rem <= {dm_sl, 4'd0} + 12'd1; end
            end
        end
    end

    assign status = {dm_irq, frame_irq, 1'b0, dm_rem != 12'd0, noi_nz, tr_nz, p2_nz, p1_nz};
    assign irq    = frame_irq | dm_irq;

    // ---------------- ミキサとフィルタ ----------------
    reg [15:0] mix_p [0:30];
    reg [15:0] mix_t [0:202];
    initial begin
        $readmemh("apu_pulse.hex", mix_p);
        $readmemh("apu_tnd.hex", mix_t);
    end
    wire [4:0]  pidx = p1_out + p2_out;
    wire [7:0]  tidx = tri_out * 2'd3 + noi_out * 2'd2 + dmc_out;
    wire [15:0] mix  = mix_p[pidx] + mix_t[tidx];

    // 8bit の小数を持たせて、ローパス (1/16) → 直流除去 (1/4096 で追う平均を引く)
    reg  signed [24:0] lp, dc;
    wire signed [24:0] x   = {1'b0, mix, 8'd0};
    wire signed [24:0] hpv = lp - dc;
    always @(posedge clk) begin
        if (rst) begin
            lp <= 25'sd0; dc <= 25'sd0; sample <= 16'sd0;
        end else if (ce) begin
            lp     <= lp + ((x - lp) >>> 4);
            dc     <= dc + ((lp - dc) >>> 12);
            sample <= hpv[23:8];
        end
    end
endmodule
