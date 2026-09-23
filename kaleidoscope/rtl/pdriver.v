// ============================================================
//  pdriver — 焼き込んだピースの表を順に並び替え器へ流す（最小版）
//
//  段5c を実機で見るためだけの仕掛け。pparts.hex に入れておいた
//  ピースを頭から 1 個ずつ pshade_seq へ渡し、最後まで行ったら止まる。
//
//  本番ではここが AXI のピース表になり、物理演算の結果を毎フレーム受けて
//  描き直す。いまは「PL がピースを描いて HDMI に出る」ことだけを確かめる。
//
//  1 個あたり 24 語 x 24bit。並びは tools/gen_pparts.py と揃えてある。
// ============================================================

module pdriver
  #(
    parameter W      = 24,
    parameter WORDS  = 24,          // 1 個あたりの語数
    parameter NPIECE = 64,          // 表に入っている個数
    parameter CB     = 9,
    parameter CELLB  = 8
    )
  (
   input  wire                  clk,
   input  wire                  resetn,
   input  wire                  seq_busy,

   output reg                   start,
   output wire [3:0]            p_type,
   output wire [CB-1:0]         p_bw,
   output wire [2*CB-1:0]       p_npix,
   output wire [CELLB-1:0]      p_x0,
   output wire [CELLB-1:0]      p_y0,
   output wire signed [W-1:0]   p_vqx0, p_vqy0, p_qx0, p_qy0,
   output wire signed [W-1:0]   p_sx_vqx, p_sy_vqy,
   output wire signed [W-1:0]   p_sx_qx, p_sy_qx, p_sx_qy, p_sy_qy,
   output wire signed [W-1:0]   p_seed, p_e, p_rot, p_time,
   output wire [7:0]            p_cr, p_cg, p_cb,
   output wire signed [W-1:0]   p_depth,
   output wire                  p_premul,
   output wire                  all_done
   );

  (* rom_style = "block" *)
  reg [W-1:0] tab [0:NPIECE*WORDS-1];
  initial $readmemh("pparts.hex", tab);

  reg [15:0] idx;              // いま何個目か
  reg [2:0]  st;
  reg        done;

  localparam D_WAIT = 3'd0, D_GO = 3'd1, D_BUSY = 3'd2,
             D_END = 3'd3, D_WAIT2 = 3'd4;

  wire [15:0] base = idx * WORDS;

  // 表の 24 語をそのまま並び替え器の入り口へつなぐ
  assign p_type   = tab[base +  0][3:0];
  assign p_bw     = tab[base +  1][CB-1:0];
  assign p_npix   = tab[base +  2][2*CB-1:0];
  assign p_x0     = tab[base +  3][CELLB-1:0];
  assign p_y0     = tab[base +  4][CELLB-1:0];
  assign p_vqx0   = tab[base +  5];
  assign p_vqy0   = tab[base +  6];
  assign p_qx0    = tab[base +  7];
  assign p_qy0    = tab[base +  8];
  assign p_sx_vqx = tab[base +  9];
  assign p_sy_vqy = tab[base + 10];
  assign p_sx_qx  = tab[base + 11];
  assign p_sy_qx  = tab[base + 12];
  assign p_sx_qy  = tab[base + 13];
  assign p_sy_qy  = tab[base + 14];
  assign p_seed   = tab[base + 15];
  assign p_e      = tab[base + 16];
  assign p_rot    = tab[base + 17];
  assign p_time   = tab[base + 18];
  assign p_cr     = tab[base + 19][7:0];
  assign p_cg     = tab[base + 20][7:0];
  assign p_cb     = tab[base + 21][7:0];
  assign p_depth  = tab[base + 22];
  assign p_premul = tab[base + 23][0];

  assign all_done = done;

  // 起動後しばらく待ってから流す (映像側が落ち着いてから)
  reg [11:0] warm;

  always @(posedge clk) begin
    start <= 1'b0;
    if (!resetn) begin
      idx <= 16'd0; st <= D_WAIT; done <= 1'b0; warm <= 12'd0;
    end else case (st)
      D_WAIT: begin
        if (warm == 12'hFFF) st <= D_GO;
        else warm <= warm + 12'd1;
      end
      D_GO: if (!seq_busy) begin
        start <= 1'b1;
        st    <= D_BUSY;
      end
      D_BUSY: if (seq_busy) begin
        st <= D_WAIT2;
      end
      D_WAIT2: if (!seq_busy) begin
        if (idx + 1 == NPIECE) begin
          done <= 1'b1;
          st   <= D_END;
        end else begin
          idx <= idx + 16'd1;
          st  <= D_GO;
        end
      end
      default: ;                 // D_END: もう何もしない
    endcase
  end

endmodule
