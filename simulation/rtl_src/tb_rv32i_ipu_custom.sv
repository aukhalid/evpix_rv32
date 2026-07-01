module tb_rv32i_ipu_custom;

    localparam int IMG_W    = 128;
    localparam int IMG_H    = 128;
    localparam int PIXELS   = IMG_W * IMG_H;
    localparam int SRC_BASE = 32'h0000_0000;
    localparam int DST_BASE = 32'h0000_C000;

    logic clk;
    logic reset;
    integer i;
    integer f;
    integer timeout_cycles;

    rv32i_core dut (
        .clk   (clk),
        .reset (reset)
    );

    always #5 clk = ~clk;

    task automatic dump_output_hex;
        begin
            f = $fopen("ipu_output.hex", "w");
            if (f == 0) begin
                $display("ERROR: could not open ipu_output.hex");
            end else begin
                for (i = 0; i < PIXELS; i = i + 1) begin
                    $fdisplay(f, "%02x", dut.dmem.ram[DST_BASE + i]);
                end
                $fclose(f);
                $display("Output image written to ipu_output.hex");
            end
        end
    endtask

    initial begin
        clk            = 1'b0;
        reset          = 1'b1;
        timeout_cycles = 0;

        $display("==============================================================");
        $display("RV32I + IPU simulation start");
        $display("Instruction file : memfile_pix.hex");
        $display("Image data file  : image_rgb888.hex");
        $display("Instruction memory loads memfile_pix.hex internally.");
        $display("Testbench loads image_rgb888.hex into data memory.");
        $display("Waiting on IPU busy/done, not x10.");
        $display("==============================================================");

        // Load source image into data memory
        $readmemh("image_rgb888.hex", dut.dmem.ram);

        // Apply reset
        repeat (4) @(posedge clk);
        reset = 1'b0;

        // ----------------------------------------------------------
        // Wait until the IPU actually starts
        // ----------------------------------------------------------
        timeout_cycles = 0;
        while (dut.u_ipu.busy !== 1'b1) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
            if (timeout_cycles > 1000) begin
                $display("ERROR: Timeout waiting for IPU to start.");
                $finish;
            end
        end

        $display("IPU started at t=%0t", $time);

        // ----------------------------------------------------------
        // Wait until the IPU actually finishes
        // ----------------------------------------------------------
        timeout_cycles = 0;
        while (dut.u_ipu.busy === 1'b1) begin
            @(posedge clk);
            timeout_cycles = timeout_cycles + 1;
            if (timeout_cycles > 500000) begin
                $display("ERROR: Timeout waiting for IPU to finish.");
                $finish;
            end
        end

        // Give a few extra cycles for final writeback / settling
        repeat (10) @(posedge clk);

        $display("==============================================================");
        $display("Simulation finished");
        $display("x10       = 0x%08h", dut.dp.decode.rf.registers[10]);
        $display("ipu_busy  = %0b", dut.u_ipu.busy);
        $display("ipu_done  = %0b", dut.u_ipu.done);
        $display("ipu_result= 0x%08h", dut.u_ipu.result);
        $display("==============================================================");

        dump_output_hex();

        $display("First 16 output bytes:");
        for (i = 0; i < 16; i = i + 1) begin
            $display("OUT[%0d] = 0x%02h", i, dut.dmem.ram[DST_BASE + i]);
        end

        $finish;
    end

    always @(posedge clk) begin
        if (!reset) begin
            $display("t=%0t | PC=%08h | IF_instr=%08h | x10=%08h | ipu_busy=%0b | ipu_done=%0b",
                     $time,
                     dut.dp.pc_f,
                     dut.instr,
                     dut.dp.decode.rf.registers[10],
                     dut.u_ipu.busy,
                     dut.u_ipu.done);
        end
    end

endmodule