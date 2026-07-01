module tb_rv32i_top;


    logic   clk   ;
    logic   reset ;
    integer errors;

    rv32i_core #(
        .MEMFILE("memfile_rv32i.hex")
    ) dut (
        .clk   (clk),
        .reset (reset)
    );

    always #5 clk = ~clk;

    task automatic check_reg(input integer idx, input logic [31:0] expected);
        logic [31:0] got;
        begin
            got = dut.dp.decode.rf.registers[idx];
            if (got !== expected) begin
                $display("FAIL REG x%0d : expected = 0x%08h, got = 0x%08h", idx, expected, got);
                errors = errors + 1;
            end else begin
                $display("PASS REG x%0d : 0x%08h", idx, got);
            end
        end
    endtask

    task automatic check_mem_byte(input integer addr, input logic [7:0] expected);
        logic [7:0] got;
        begin
            got = dut.dmem.ram[addr];
            if (got !== expected) begin
                $display("FAIL MEM[%0d] : expected = 0x%02h, got = 0x%02h", addr, expected, got);
                errors = errors + 1;
            end else begin
                $display("PASS MEM[%0d] : 0x%02h", addr, got);
            end
        end
    endtask

    always @(posedge clk) begin
        if (!reset) begin
            $display("t = %0t | PC = %08h | IF_instr = %08h | WB_we = %0b | WB_rd = x%0d | WB_data = %08h",
            $time,
            dut.dp.pc_f,
            dut.instr,
            dut.dp.reg_write_w,
            dut.dp.rd_w,
            dut.dp.result_w);
        end
    end

    initial begin
        clk    = 1'b0;
        reset  = 1'b1;
        errors = 0   ;

        $display("==============================================================");
        $display("RV32I baseline regression test");
        $display("Program file: memfile_rv32i.hex");
        $display("==============================================================");

        repeat (4) @(posedge clk);
        reset = 1'b0;

        repeat (220) @(posedge clk);

        check_reg(1,  32'h0000000A);
        check_reg(2,  32'hFFFFFFFD);
        check_reg(3,  32'h00000005);
        check_reg(4,  32'h0000000F);
        check_reg(5,  32'h00000007);
        check_reg(6,  32'h00000001);
        check_reg(7,  32'h00000001);
        check_reg(8,  32'h0000000C);
        check_reg(9,  32'h0000001F);
        check_reg(10, 32'h00000000);
        check_reg(11, 32'h00000014);
        check_reg(12, 32'h00000007);
        check_reg(13, 32'hFFFFFFFE);
        check_reg(14, 32'h0000000F);
        check_reg(15, 32'h00000005);
        check_reg(16, 32'h00000007);
        check_reg(17, 32'h0000000F);
        check_reg(18, 32'h00000008);
        check_reg(19, 32'h00000280);
        check_reg(20, 32'h00000000);
        check_reg(21, 32'hFFFFFFFF);
        check_reg(22, 32'h00000001);
        check_reg(23, 32'h00000000);
        check_reg(24, 32'h12345000);
        check_reg(25, 32'h00000060);
        check_reg(26, 32'h00000100);
        check_reg(27, 32'h0000000A);
        check_reg(28, 32'h000000C0);
        check_reg(29, 32'h000000EC);
        check_reg(30, 32'h000000D0);
        check_reg(31, 32'h0000FFFD);

        check_mem_byte(256, 8'h0A);
        check_mem_byte(257, 8'h00);
        check_mem_byte(258, 8'h00);
        check_mem_byte(259, 8'h00);
        check_mem_byte(260, 8'h05);
        check_mem_byte(261, 8'h00);
        check_mem_byte(262, 8'h07);
        check_mem_byte(264, 8'hFD);
        check_mem_byte(265, 8'hFF);
        check_mem_byte(266, 8'hFF);
        check_mem_byte(267, 8'hFF);

        $display("==============================================================");
        if (errors == 0) begin
            $display("ALL BASELINE CHECKS PASSED");
        end else begin
            $display("BASELINE TEST FAILED WITH %0d ERROR(S)", errors);
        end
        $display("==============================================================");
        $finish;
    end
endmodule
