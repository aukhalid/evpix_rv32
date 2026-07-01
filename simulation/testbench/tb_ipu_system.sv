module tb_ipu_system;


    localparam int IMG_W     = 8            ;
    localparam int IMG_H     = 8            ;
    localparam int PIXELS    = IMG_W * IMG_H;
    localparam int SRC_BYTES = PIXELS * 3   ;
    localparam int DST_GRAY  = 32'd192      ;
    localparam int DST_THR   = 32'd256      ;
    localparam int DST_SOBEL = 32'd320      ;
    localparam int DST_CONV  = 32'd384      ;
    localparam int DST_MAXP  = 32'd448      ;
    localparam int DST_AVGP  = 32'd512      ;

    logic         clk   ;
    logic         reset ;
    integer       errors;
    integer       i     ;
    integer       x     ;
    integer       y     ;
    logic   [7:0] got   ;
    logic   [7:0] exp   ;

    rv32i_core #(
        .IMG_W(IMG_W),
        .IMG_H(IMG_H),
        .MEMFILE("memfile_ipu_system.hex")
    ) dut (
        .clk   (clk),
        .reset (reset)
    );

    always #5 clk = ~clk;

    task automatic check_reg_eq(input integer idx, input logic [31:0] expected, input string tag);
        logic [31:0] got32;
        begin
            got32 = dut.dp.decode.rf.registers[idx];
            if (got32 !== expected) begin
                $display("FAIL REG x%0d expected=0x%08h got=0x%08h : %s", idx, expected, got32, tag);
                errors = errors + 1;
            end else begin
                $display("PASS REG x%0d = 0x%08h : %s", idx, got32, tag);
            end
        end
    endtask

    task automatic check_reg_nz(input integer idx, input string tag);
        logic [31:0] got32;
        begin
            got32 = dut.dp.decode.rf.registers[idx];
            if (got32 === 32'b0) begin
                $display("FAIL REG x%0d expected non-zero got=0x%08h : %s", idx, got32, tag);
                errors = errors + 1;
            end else begin
                $display("PASS REG x%0d = 0x%08h : %s", idx, got32, tag);
            end
        end
    endtask

    function automatic [7:0] exp_gray(input integer xx);
        begin
            exp_gray = (xx < 4) ? 8'h00 : 8'hFF;
        end
    endfunction

    initial begin
        clk    = 1'b0;
        reset  = 1'b1;
        errors = 0   ;

        $display("==============================================================");
        $display("EVPIX IPU system test");
        $display("Program: memfile_ipu_system.hex");
        $display("Image  : image_rgb888_small.hex (8x8 vertical edge)");
        $display("==============================================================");

        $readmemh("image_rgb888_small.hex", dut.dmem.ram);

        repeat (4) @(posedge clk);
        reset = 1'b0;

        repeat (3000) @(posedge clk);

        $display("--- Register checks ---");
        check_reg_eq(11, 32'd1,   "grayscale result");
        check_reg_eq(12, 32'd1,   "threshold result");
        check_reg_eq(13, 32'd255, "maxpixel result");
        check_reg_eq(14, 32'd1,   "sobel result");
        check_reg_eq(15, 32'd1,   "conv identity result");
        check_reg_eq(16, 32'd1,   "maxpool result");
        check_reg_eq(17, 32'd1,   "avgpool result");
        check_reg_nz(18, "total cycle counter read");
        check_reg_nz(19, "ipu busy counter read");
        check_reg_nz(20, "convolution counter read");
        check_reg_nz(21, "pooling counter read");
        check_reg_eq(22, 32'd0, "stall counter (expected zero in this program)");

        // $display("--- Grayscale output checks ---");
        // for (y = 0; y < IMG_H; y = y + 1) begin
        //     for (x = 0; x < IMG_W; x = x + 1) begin
        //         got = dut.dmem.ram[DST_GRAY + y*IMG_W + x];
        //         exp = exp_gray(x);
        //         if (got !== exp) begin
        //             $display("FAIL GRAY[%0d,%0d] exp=%02h got=%02h", x, y, exp, got);
        //             errors = errors + 1;
        //         end
        //     end
        // end

        // $display("--- Threshold output checks ---");
        // for (y = 0; y < IMG_H; y = y + 1) begin
        //     for (x = 0; x < IMG_W; x = x + 1) begin
        //         got = dut.dmem.ram[DST_THR + y*IMG_W + x];
        //         exp = exp_gray(x);
        //         if (got !== exp) begin
        //             $display("FAIL THR[%0d,%0d] exp=%02h got=%02h", x, y, exp, got);
        //             errors = errors + 1;
        //         end
        //     end
        // end

        // $display("--- Sobel output checks ---");
        // for (y = 0; y < IMG_H; y = y + 1) begin
        //     for (x = 0; x < IMG_W; x = x + 1) begin
        //         got = dut.dmem.ram[DST_SOBEL + y*IMG_W + x];
        //         if ((y == 0) || (y == IMG_H-1) || (x == 0) || (x == IMG_W-1))
        //             exp = 8'h00;
        //         else if ((x == 3) || (x == 4))
        //             exp = 8'hFF;
        //         else
        //             exp = 8'h00;
        //         if (got !== exp) begin
        //             $display("FAIL SOBEL[%0d,%0d] exp=%02h got=%02h", x, y, exp, got);
        //             errors = errors + 1;
        //         end
        //     end
        // end

        // $display("--- Convolution identity output checks ---");
        // for (y = 0; y < IMG_H; y = y + 1) begin
        //     for (x = 0; x < IMG_W; x = x + 1) begin
        //         got = dut.dmem.ram[DST_CONV + y*IMG_W + x];
        //         if ((y == 0) || (y == IMG_H-1) || (x == 0) || (x == IMG_W-1))
        //             exp = 8'h00;
        //         else
        //             exp = exp_gray(x);
        //         if (got !== exp) begin
        //             $display("FAIL CONV[%0d,%0d] exp=%02h got=%02h", x, y, exp, got);
        //             errors = errors + 1;
        //         end
        //     end
        // end

        // $display("--- Maxpool output checks ---");
        // for (y = 0; y < 4; y = y + 1) begin
        //     for (x = 0; x < 4; x = x + 1) begin
        //         got = dut.dmem.ram[DST_MAXP + y*4 + x];
        //         exp = (x < 2) ? 8'h00 : 8'hFF;
        //         if (got !== exp) begin
        //             $display("FAIL MAXPOOL[%0d,%0d] exp=%02h got=%02h", x, y, exp, got);
        //             errors = errors + 1;
        //         end
        //     end
        // end

        // $display("--- Avgpool output checks ---");
        // for (y = 0; y < 4; y = y + 1) begin
        //     for (x = 0; x < 4; x = x + 1) begin
        //         got = dut.dmem.ram[DST_AVGP + y*4 + x];
        //         exp = (x < 2) ? 8'h00 : 8'hFF;
        //         if (got !== exp) begin
        //             $display("FAIL AVGPOOL[%0d,%0d] exp=%02h got=%02h", x, y, exp, got);
        //             errors = errors + 1;
        //         end
        //     end
        // end

        $display("==============================================================");
        if (errors == 0)
            $display("ALL IPU TESTS PASSED");
        else
            $display("IPU TEST FAILED WITH %0d ERROR(S)", errors);
        $display("==============================================================");
        $finish;
    end

    always @(posedge clk) begin
        if (!reset) begin
            $display("t = %0t | PC = %08h | INSTR = %08h | busy = %0b done = %0b | x11 = %08h x13 = %08h",
            $time,
            dut.dp.pc_f,
            dut.instr,
            dut.ipu_busy,
            dut.ipu_done,
            dut.dp.decode.rf.registers[11],
            dut.dp.decode.rf.registers[13]);
        end
    end

endmodule
