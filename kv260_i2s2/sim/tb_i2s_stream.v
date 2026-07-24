`timescale 1ns/1ps
// i2s_stream_axi: 右のみ/左のみのデータで、各スロットに正しくビットが出るか確認
module tb_i2s_stream;
    localparam AW = 7;
    reg clk = 0, rst_n = 0;
    reg  [AW-1:0] AWADDR, ARADDR;
    reg  [31:0]   WDATA;
    reg           AWVALID, WVALID, BREADY, ARVALID, RREADY;
    reg  [3:0]    WSTRB;
    wire          AWREADY, WREADY, BVALID, ARREADY, RVALID;
    wire [1:0]    BRESP, RRESP;
    wire [31:0]   RDATA;
    wire          mclk_o, sclk, lrck, sdout;

    i2s_stream_axi dut (
        .S_AXI_ACLK(clk), .S_AXI_ARESETN(rst_n),
        .S_AXI_AWADDR(AWADDR), .S_AXI_AWPROT(3'b0), .S_AXI_AWVALID(AWVALID), .S_AXI_AWREADY(AWREADY),
        .S_AXI_WDATA(WDATA), .S_AXI_WSTRB(WSTRB), .S_AXI_WVALID(WVALID), .S_AXI_WREADY(WREADY),
        .S_AXI_BRESP(BRESP), .S_AXI_BVALID(BVALID), .S_AXI_BREADY(BREADY),
        .S_AXI_ARADDR(ARADDR), .S_AXI_ARPROT(3'b0), .S_AXI_ARVALID(ARVALID), .S_AXI_ARREADY(ARREADY),
        .S_AXI_RDATA(RDATA), .S_AXI_RRESP(RRESP), .S_AXI_RVALID(RVALID), .S_AXI_RREADY(RREADY),
        .mclk_o(mclk_o), .sclk(sclk), .lrck(lrck), .sdout(sdout)
    );

    always #5 clk = ~clk;

    task axi_write(input [AW-1:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            AWADDR <= addr; WDATA <= data; WSTRB <= 4'hF;
            AWVALID <= 1; WVALID <= 1;
            @(posedge clk);
            while (!(AWREADY && WREADY)) @(posedge clk);
            AWVALID <= 0; WVALID <= 0; BREADY <= 1;
            @(posedge clk);
            while (!BVALID) @(posedge clk);
            BREADY <= 0;
        end
    endtask

    // 内部信号を各スロットの代表点で捕まえる
    reg [15:0] cur_left = 0, cur_right = 0;
    always @(posedge clk) begin
        if (dut.c == 8'd12)  cur_left  <= dut.cur;   // c[7]=0 左スロット中
        if (dut.c == 8'd140) cur_right <= dut.cur;   // c[7]=1 右スロット中
    end

    integer i;
    initial begin
        AWVALID=0; WVALID=0; BREADY=0; ARVALID=0; RREADY=0; WSTRB=4'hF;
        rst_n=0; #200; @(posedge clk); rst_n=1; #50;

        axi_write(7'h20, 32'd1);    // CTRL=1 再生有効
        axi_write(7'h30, 32'd64);   // GAIN=64 等倍
        axi_write(7'h40, 32'd0);    // ECHO=0

        #100;
        $display("AXI後の内部: reg_play=%b reg_gain=%0d reg_echo=%0d",
                 dut.reg_play, dut.reg_gain, dut.reg_echo);

        // 右のみ: L=0, R=0x1234
        for (i = 0; i < 40; i = i + 1) axi_write(7'h00, 32'h0000_1234);
        #100;
        $display("DATA書込40回後: fifo_count=%0d fifo_empty=%b",
                 dut.fifo_count, dut.fifo_empty);

        // 数フレーム送出させて内部を見る
        #20000;
        $display("[右のみ L=0 R=0x1234] fx_l=0x%04h fx_r=0x%04h  左cur=0x%04h 右cur=0x%04h",
                 dut.fx_l, dut.fx_r, cur_left, cur_right);

        // 左のみ: L=0x5678, R=0
        for (i = 0; i < 40; i = i + 1) axi_write(7'h00, 32'h5678_0000);
        #20000;
        $display("[左のみ L=0x5678 R=0] fx_l=0x%04h fx_r=0x%04h  左cur=0x%04h 右cur=0x%04h",
                 dut.fx_l, dut.fx_r, cur_left, cur_right);

        $finish;
    end
endmodule
