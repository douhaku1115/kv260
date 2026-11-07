// -----------------------------------------------------------------------------
// axis_route.v -- 段15: AXI DMA の読み出し流(MM2S)の行き先を切り替える
//
//   mode = 0 : 写す      MM2S → S2MM にそのままつなぐ（DDR→DDR の複写）
//   mode = 1 : 読み捨て  MM2S を常に受け取って捨てる（DDR を読む速さだけを測る）
//                        S2MM には何も流さない
//
//   mode は AXI GPIO から。切り替えは DMA が止まっている間だけ行うこと。
//   組み合わせ回路だけ（レジスタなし）なので、流れの速さには影響しない。
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps

module axis_route #(
    parameter integer W = 128
)(
    input  wire           aclk,
    input  wire           aresetn,
    input  wire           mode,

    // DMA の MM2S（読んだデータ）を受ける側
    input  wire [W-1:0]   s_axis_tdata,
    input  wire [W/8-1:0] s_axis_tkeep,
    input  wire           s_axis_tlast,
    input  wire           s_axis_tvalid,
    output wire           s_axis_tready,

    // DMA の S2MM（書くデータ）へ渡す側
    output wire [W-1:0]   m_axis_tdata,
    output wire [W/8-1:0] m_axis_tkeep,
    output wire           m_axis_tlast,
    output wire           m_axis_tvalid,
    input  wire           m_axis_tready
);
    assign m_axis_tdata  = s_axis_tdata;
    assign m_axis_tkeep  = s_axis_tkeep;
    assign m_axis_tlast  = s_axis_tlast;
    assign m_axis_tvalid = mode ? 1'b0 : s_axis_tvalid;
    assign s_axis_tready = mode ? 1'b1 : m_axis_tready;
endmodule
