`timescale 1ns / 1ps

module tb_mips;

    reg clk, reset, halt;
    reg imem_we;
    reg [7:0] imem_waddr;
    reg [31:0] imem_wdata;
    reg [4:0] dbg_reg_addr;
    wire [31:0] pc, dbg_reg_data;

    mips_top uut (
        .clk(clk),
        .reset(reset),
        .halt(halt),
        .imem_we(imem_we),
        .imem_waddr(imem_waddr),
        .imem_wdata(imem_wdata),
        .pc(pc),
        .dbg_reg_addr(dbg_reg_addr),
        .dbg_reg_data(dbg_reg_data)
    );

    always #10 clk = ~clk; // 50MHz

    // プログラムロードタスク
    task load_word;
        input [7:0] addr;
        input [31:0] data;
        begin
            @(posedge clk);
            imem_we = 1;
            imem_waddr = addr;
            imem_wdata = data;
            @(posedge clk);
            imem_we = 0;
        end
    endtask

    // レジスタ読み出しタスク
    task read_reg;
        input [4:0] addr;
        begin
            dbg_reg_addr = addr;
            #1; // 組み合わせ回路の遅延待ち
            $display("  $%0d = 0x%08x (%0d)", addr, dbg_reg_data, dbg_reg_data);
        end
    endtask

    integer i;

    initial begin
        $dumpfile("tb_mips.vcd");
        $dumpvars(0, tb_mips);

        clk = 0; reset = 1; halt = 1;
        imem_we = 0; imem_waddr = 0; imem_wdata = 0;
        dbg_reg_addr = 0;

        // プログラムロード
        #40;
        load_word(0, 32'h20010005); // addi $1, $0, 5
        load_word(1, 32'h20020003); // addi $2, $0, 3
        load_word(2, 32'h00221820); // add  $3, $1, $2
        load_word(3, 32'h00222022); // sub  $4, $1, $2
        load_word(4, 32'h00222824); // and  $5, $1, $2
        load_word(5, 32'h00223025); // or   $6, $1, $2
        load_word(6, 32'h0041382A); // slt  $7, $2, $1

        // 実行開始
        @(posedge clk);
        reset = 0;
        halt = 0;

        // 命令数分のサイクル + 余裕
        repeat (10) @(posedge clk);
        halt = 1;

        // レジスタダンプ
        $display("--- Register Dump ---");
        $display("PC = 0x%08x", pc);
        $display("Expected: $1=5, $2=3, $3=8, $4=2, $5=1, $6=7, $7=1");
        for (i = 1; i <= 7; i = i + 1) begin
            read_reg(i);
        end

        #20;
        $finish;
    end

    // 実行トレース
    always @(posedge clk) begin
        if (!reset && !halt)
            $display("[%0t] PC=0x%08x instr=0x%08x", $time, pc, uut.instr);
    end

endmodule
