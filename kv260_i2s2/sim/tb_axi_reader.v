`timescale 1ns/1ps
// axi_reader 検証: 簡易 AXI スレーブ(擬似DDR)を繋ぎ、正しい順序で読めるか確認
module tb_axi_reader;
    localparam DW = 64;
    reg clk = 0, rst_n = 0;
    reg start = 0;
    reg [31:0] base_addr = 32'h1000_0000;
    reg [31:0] total_len = 32'd256;      // 256バイト = 32転送 = 2バースト
    wire busy, done;
    wire [31:0] read_cnt;

    wire out_valid;
    wire [DW-1:0] out_data;
    reg  out_ready = 1;

    wire [31:0] ARADDR;
    wire [7:0]  ARLEN;
    wire [2:0]  ARSIZE, ARPROT;
    wire [1:0]  ARBURST;
    wire [3:0]  ARCACHE;
    wire        ARVALID;
    reg         ARREADY = 0;
    reg  [DW-1:0] RDATA = 0;
    reg         RLAST = 0, RVALID = 0;
    wire        RREADY;

    axi_reader #(.DW(DW), .BURST(16)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .base_addr(base_addr), .total_len(total_len),
        .busy(busy), .done(done), .read_cnt(read_cnt),
        .out_valid(out_valid), .out_data(out_data), .out_ready(out_ready),
        .M_AXI_ARADDR(ARADDR), .M_AXI_ARLEN(ARLEN), .M_AXI_ARSIZE(ARSIZE),
        .M_AXI_ARBURST(ARBURST), .M_AXI_ARCACHE(ARCACHE), .M_AXI_ARPROT(ARPROT),
        .M_AXI_ARVALID(ARVALID), .M_AXI_ARREADY(ARREADY),
        .M_AXI_RDATA(RDATA), .M_AXI_RRESP(2'b00), .M_AXI_RLAST(RLAST),
        .M_AXI_RVALID(RVALID), .M_AXI_RREADY(RREADY)
    );

    always #5 clk = ~clk;

    // ---- 簡易 AXI スレーブ（擬似 DDR: アドレス/8 の値を返す）----
    integer beats_left = 0;
    reg [31:0] slave_addr;
    integer nburst = 0, nbeat = 0;

    always @(posedge clk) begin
        if (!rst_n) begin
            ARREADY <= 0; RVALID <= 0; RLAST <= 0; beats_left <= 0;
        end else begin
            // AR 受理
            if (ARVALID && !ARREADY && beats_left == 0) begin
                ARREADY    <= 1;
                slave_addr <= ARADDR;
                beats_left <= ARLEN + 1;
                nburst     <= nburst + 1;
                $display("  バースト%0d 要求: addr=%h len=%0d(=%0d転送)", nburst+1, ARADDR, ARLEN, ARLEN+1);
            end else begin
                ARREADY <= 0;
            end
            // R 返送
            if (beats_left > 0 && !ARREADY) begin
                if (!RVALID || RREADY) begin
                    RDATA      <= slave_addr / 8;       // 擬似データ = アドレス/8
                    RVALID     <= 1;
                    RLAST      <= (beats_left == 1);
                    slave_addr <= slave_addr + 8;
                    beats_left <= beats_left - 1;
                end
            end else if (RVALID && RREADY) begin
                RVALID <= 0; RLAST <= 0;
            end
        end
    end

    // 受け取ったデータの検証
    reg [31:0] expect = 32'h1000_0000 / 8;
    integer errors = 0;
    always @(posedge clk) begin
        if (rst_n && out_valid && out_ready) begin
            if (out_data !== expect) begin
                $display("  NG: %0d 番目 期待=%h 実際=%h", nbeat, expect, out_data);
                errors = errors + 1;
            end
            nbeat  = nbeat + 1;
            expect = expect + 1;
        end
    end

    initial begin
        rst_n = 0; #100; @(posedge clk); rst_n = 1;
        @(posedge clk); start <= 1; @(posedge clk); start <= 0;

        wait (done);
        @(posedge clk);
        $display("読んだバイト数 = %0d (期待 %0d)", read_cnt, total_len);
        $display("受け取った転送数 = %0d (期待 %0d)", nbeat, total_len/8);
        if (errors == 0 && read_cnt == total_len && nbeat == total_len/8)
            $display("PASS: AXI4 バースト読み出しが正しく動作");
        else
            $display("FAIL: errors=%0d", errors);
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL: タイムアウト (done が来ない)");
        $finish;
    end
endmodule
