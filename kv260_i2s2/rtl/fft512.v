// -----------------------------------------------------------------------------
// fft512.v -- 自作512点FFT（DIT radix-2, 逐次メモリベース, Q15固定小数点）
//
//   段8ではPS(play.c)でFFTしていた。これをPL(FPGA)に載せる第一歩。
//
//   方式: メモリ上でその場(in-place)計算。バタフライ演算器1つを使い回す。
//     1バタフライ1クロック。総クロック ≒ 512(ロード) + 256*9(計算) ≒ 3000。
//     12.5MHzで約0.24ms。512点=10.5msごとなので十分間に合う。
//
//   入力: 実数サンプル(16bit)を start 後に in_valid で512個順に流し込む。
//         内部でビットリバース順に格納する（DITの入力並べ替え）。
//   計算: 各段で W_N^k を掛けるバタフライ。各段 >>1 でスケールしオーバーフロー抑制。
//   出力: done=1 の後、rd_addr で各ビンの実部/虚部を読める。振幅はPS側で求める。
//
//   ツイドル: rtl/twiddle_{cos,sin}.hex（gen_twiddle.pyで生成, Q15, 256点）
//     W_N^k = cos(2πk/N) - i sin(2πk/N)
// -----------------------------------------------------------------------------
module fft512 #(
    parameter integer N    = 512,
    parameter integer LOGN = 9,
    parameter integer DW   = 16
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 start,      // 1クロックのパルスで開始
    input  wire                 in_valid,   // サンプル投入
    input  wire signed [DW-1:0] in_data,    // 実数サンプル
    output reg                  done,       // 計算完了
    output wire                 ready,      // 開始可能（IDLE か DONE のとき1）
    input  wire [LOGN-1:0]      rd_addr,    // 結果読み出しアドレス（ビン番号）
    output wire signed [DW-1:0] rd_re,
    output wire signed [DW-1:0] rd_im
);
    // ---- データメモリ（実部・虚部）----
    reg signed [DW-1:0] mre [0:N-1];
    reg signed [DW-1:0] mim [0:N-1];
    reg signed [DW-1:0] out_re [0:255];   // 結果ダブルバッファ（片側256ビン）
    reg signed [DW-1:0] out_im [0:255];

    // ---- ツイドル係数（Q15）----
    reg [DW-1:0] tw_cos [0:N/2-1];
    reg [DW-1:0] tw_sin [0:N/2-1];
    initial begin
        $readmemh("twiddle_cos.hex", tw_cos);
        $readmemh("twiddle_sin.hex", tw_sin);
    end

    assign rd_re = out_re[rd_addr[7:0]];   // 安定した結果(コピー済み)を読む
    assign rd_im = out_im[rd_addr[7:0]];

    // ---- ビットリバース（LOGNビット）----
    function [LOGN-1:0] bitrev(input [LOGN-1:0] x);
        integer b;
        begin
            for (b = 0; b < LOGN; b = b + 1) bitrev[b] = x[LOGN-1-b];
        end
    endfunction

    // ---- 状態機械 ----
    localparam IDLE = 3'd0, LOAD = 3'd1, COMPUTE = 3'd2, COPY = 3'd3, DONE = 3'd4;
    reg [2:0]      state;
    reg [7:0]      copy_cnt;
    reg [LOGN-1:0] load_cnt;
    reg [3:0]      s;                    // 段 1..LOGN
    reg [LOGN-1:0] kg;                   // グループ先頭
    reg [LOGN-1:0] jj;                   // グループ内位置

    assign ready = (state == IDLE) || (state == DONE);

    wire [LOGN:0]   m    = (1 << s);            // 2..512
    wire [LOGN-1:0] half = (1 << (s - 1));      // 1..256

    // 現在のバタフライ対象
    wire [LOGN-1:0] idx1  = kg + jj;
    wire [LOGN-1:0] idx2  = kg + jj + half;
    wire [LOGN-1:0] twidx = jj << (LOGN - s);   // 0..255

    // 複素バタフライ（組合せ）: t = W * v,  W = cos - i sin
    wire signed [DW-1:0] cw = $signed(tw_cos[twidx]);
    wire signed [DW-1:0] sw = $signed(tw_sin[twidx]);
    wire signed [DW-1:0] ur = mre[idx1];
    wire signed [DW-1:0] ui = mim[idx1];
    wire signed [DW-1:0] vr = mre[idx2];
    wire signed [DW-1:0] vi = mim[idx2];

    wire signed [32:0] mr = cw * vr + sw * vi;  // tr*2^15
    wire signed [32:0] mi = cw * vi - sw * vr;  // ti*2^15
    wire signed [DW-1:0] tr = mr >>> 15;
    wire signed [DW-1:0] ti = mi >>> 15;

    wire signed [DW-1:0] sum_r = (ur + tr) >>> 1;   // 各段 >>1 でスケール
    wire signed [DW-1:0] sum_i = (ui + ti) >>> 1;
    wire signed [DW-1:0] dif_r = (ur - tr) >>> 1;
    wire signed [DW-1:0] dif_i = (ui - ti) >>> 1;

    always @(posedge clk) begin
        if (!rst_n) begin
            state    <= IDLE;
            done     <= 1'b0;
            load_cnt <= {LOGN{1'b0}};
        end else begin
            case (state)
                IDLE: if (start) begin
                    done     <= 1'b0;
                    load_cnt <= {LOGN{1'b0}};
                    state    <= LOAD;
                end

                LOAD: if (in_valid) begin
                    mre[bitrev(load_cnt)] <= in_data;   // 実部はビットリバース順に
                    mim[bitrev(load_cnt)] <= {DW{1'b0}};// 虚部は0
                    if (load_cnt == N - 1) begin
                        s     <= 4'd1;
                        kg    <= {LOGN{1'b0}};
                        jj    <= {LOGN{1'b0}};
                        state <= COMPUTE;
                    end else begin
                        load_cnt <= load_cnt + 1'b1;
                    end
                end

                COMPUTE: begin
                    // バタフライ実行（その場書き換え）
                    mre[idx1] <= sum_r;  mim[idx1] <= sum_i;
                    mre[idx2] <= dif_r;  mim[idx2] <= dif_i;
                    // カウンタ更新: jj → kg → s
                    if (jj == half - 1) begin
                        jj <= {LOGN{1'b0}};
                        if (kg + m >= N) begin
                            kg <= {LOGN{1'b0}};
                            if (s == LOGN) begin
                                state    <= COPY;   // 全段終了→結果をバッファへ
                                copy_cnt <= 8'd0;
                            end else begin
                                s <= s + 1'b1;
                            end
                        end else begin
                            kg <= kg + m;
                        end
                    end else begin
                        jj <= jj + 1'b1;
                    end
                end

                COPY: begin
                    out_re[copy_cnt] <= mre[copy_cnt];   // 片側256ビンをバッファへ
                    out_im[copy_cnt] <= mim[copy_cnt];
                    if (copy_cnt == 8'd255) state <= DONE;
                    else copy_cnt <= copy_cnt + 1'b1;
                end

                DONE: begin
                    done <= 1'b1;
                    if (start) state <= IDLE;
                end
            endcase
        end
    end
endmodule
