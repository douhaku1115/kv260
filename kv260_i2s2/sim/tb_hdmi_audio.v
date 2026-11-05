`timescale 1ns/1ps
// i2s_stream_axi の HDMI 音声 (OUT_SEL=1) の確認 (2026-11-05)
//   FIFO に決まった 300 組 (L=0x1000+i, R=0x2000+i) を書き、HDMI 側 (aud_*) に書いた順どおり左右が出るか、
//   FIFO が 48kHz で減るか、空の回数 (0x150) が数えられるかを見る。
//   HDMI 側 (PS の DP) は 24.576MHz の 256 クロックごとに 1 副フレームを引き取るとまねる (= 48kHz × 左右)。
module tb_hdmi_audio;
    localparam AW = 9;
    reg clk = 0, aud_clk = 0, rst_n = 0;
    reg  [AW-1:0] AWADDR = 0, ARADDR = 0;
    reg  [31:0]   WDATA = 0;
    reg           AWVALID = 0, WVALID = 0, BREADY = 0, ARVALID = 0, RREADY = 0;
    wire          AWREADY, WREADY, BVALID, ARREADY, RVALID;
    wire [1:0]    BRESP, RRESP;
    wire [31:0]   RDATA;
    wire          mclk_o, sclk, lrck, sdout;
    wire [31:0]   aud_data;
    wire          aud_id, aud_valid;
    reg           aud_ready = 0;

    i2s_stream_axi dut (
        .S_AXI_ACLK(clk), .S_AXI_ARESETN(rst_n),
        .S_AXI_AWADDR(AWADDR), .S_AXI_AWPROT(3'b0), .S_AXI_AWVALID(AWVALID), .S_AXI_AWREADY(AWREADY),
        .S_AXI_WDATA(WDATA), .S_AXI_WSTRB(4'hF), .S_AXI_WVALID(WVALID), .S_AXI_WREADY(WREADY),
        .S_AXI_BRESP(BRESP), .S_AXI_BVALID(BVALID), .S_AXI_BREADY(BREADY),
        .S_AXI_ARADDR(ARADDR), .S_AXI_ARPROT(3'b0), .S_AXI_ARVALID(ARVALID), .S_AXI_ARREADY(ARREADY),
        .S_AXI_RDATA(RDATA), .S_AXI_RRESP(RRESP), .S_AXI_RVALID(RVALID), .S_AXI_RREADY(RREADY),
        .M_AXI_AWREADY(1'b0), .M_AXI_WREADY(1'b0), .M_AXI_BRESP(2'b0), .M_AXI_BVALID(1'b0),
        .M_AXI_ARREADY(1'b0), .M_AXI_RDATA(64'd0), .M_AXI_RRESP(2'b0), .M_AXI_RLAST(1'b0), .M_AXI_RVALID(1'b0),
        .mclk_o(mclk_o), .sclk(sclk), .lrck(lrck), .sdout(sdout),
        .aud_clk(aud_clk), .aud_data(aud_data), .aud_id(aud_id), .aud_valid(aud_valid),
        .aud_ready(aud_ready)
    );

    always #40 clk = ~clk;              // 12.5MHz
    always #20.345 aud_clk = ~aud_clk;  // 24.576MHz

    // HDMI 側: 256 クロックに 1 回 tready (1 クロック)
    reg [7:0] rc = 0;
    always @(posedge aud_clk) begin
        rc <= rc + 1;
        aud_ready <= (rc == 8'd0);
    end

    task axi_write(input [AW-1:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            AWADDR <= addr; WDATA <= data; AWVALID <= 1; WVALID <= 1;
            @(posedge clk);
            while (!(AWREADY && WREADY)) @(posedge clk);
            AWVALID <= 0; WVALID <= 0; BREADY <= 1;
            @(posedge clk);
            while (!BVALID) @(posedge clk);
            BREADY <= 0;
        end
    endtask

    task axi_read(input [AW-1:0] addr, output [31:0] data);
        begin
            @(posedge clk);
            ARADDR <= addr; ARVALID <= 1; RREADY <= 1;
            @(posedge clk);
            while (!RVALID) @(posedge clk);
            data = RDATA;
            ARVALID <= 0; RREADY <= 0;
            @(posedge clk);
        end
    endtask

    // HDMI 側で受け取った副フレームを記録 (標本は [27:12]。xlive_audio の data_tx の並び)
    integer nl = 0, nr = 0, n_err = 0, n_nz = 0;
    reg [15:0] lbuf [0:4095];
    reg [15:0] rbuf [0:4095];
    reg [15:0] smp;
    always @(posedge aud_clk) begin
        if (aud_valid && aud_ready) begin
            smp = aud_data[27:12];
            if (aud_id == 1'b0) begin lbuf[nl] = smp; nl = nl + 1; end
            else                 begin rbuf[nr] = smp; nr = nr + 1; end
        end
    end

    integer i, k, first;
    reg [31:0] r;
    real t0, t1;
    integer c0, c1;
    initial begin
        #400; @(posedge clk); rst_n = 1; #400;
        axi_write(9'h140, 32'd1);           // OUT_SEL = HDMI
        axi_read(9'h140, r);  $display("OUT_SEL = %0d", r);
        for (i = 0; i < 300; i = i + 1)      // 再生前に 300 組ためる
            axi_write(9'h000, {16'h1000 + i[15:0], 16'h2000 + i[15:0]});
        axi_read(9'h010, r);  $display("書いた後の FIFO 段数 = %0d", r[29:16]);
        // FIFO が 48kHz で減るかを測る: 10 組目から 290 組目までの時間 (短いと読み出しの固まりでぶれる)
        axi_write(9'h020, 32'd1);           // CTRL = 再生
        c0 = dut.fifo_count;
        wait (dut.fifo_count <= c0 - 10);   // 始めの 10 組 (小さな FIFO に一気に入る分) は除く
        c0 = dut.fifo_count; t0 = $realtime;
        wait (dut.fifo_count <= c0 - 280);
        c1 = dut.fifo_count; t1 = $realtime;
        $display("FIFO が %0d 組減るのに %0.1f us → %0.0f 組/秒", c0 - c1, (t1 - t0) / 1000.0,
                 (c0 - c1) * 1.0e9 / (t1 - t0));
        wait (dut.fifo_empty);
        #300000;                            // 空になってから約 14 組ぶん (無音のはず)
        axi_read(9'h150, r);  $display("HDMI_EMPTY (空の回数) = %0d", r);

        // HDMI に出た左右: 最初の 0 でない左の位置から 40 組が 0x1000+k / 0x2000+k か
        first = -1;
        for (k = 0; k < nl; k = k + 1) if (first < 0 && lbuf[k] != 0) first = k;
        $display("HDMI で受けた副フレーム 左 %0d 右 %0d、最初の音は左の %0d 番目", nl, nr, first);
        for (k = 0; k < 300; k = k + 1) begin
            if (lbuf[first + k] !== 16'h1000 + k || rbuf[first + k] !== 16'h2000 + k) begin
                n_err = n_err + 1;
                if (n_err <= 5) $display("  不一致 %0d: 左 %h 右 %h", k, lbuf[first + k], rbuf[first + k]);
            end
        end
        for (k = first + 300; k < nl; k = k + 1) if (lbuf[k] != 0 || rbuf[k] != 0) n_nz = n_nz + 1;
        $display("300 組の不一致 %0d、その後 (空) で 0 でない組 %0d (全 %0d 組)", n_err, n_nz, nl - first - 300);

        axi_write(9'h140, 32'd0);           // I2S に戻すと 0x150 も 0 に
        axi_read(9'h150, r);  $display("OUT_SEL=0 にした後の HDMI_EMPTY = %0d", r);
        if (n_err == 0 && n_nz == 0) $display("結果: OK"); else $display("結果: NG");
        $finish;
    end
endmodule
