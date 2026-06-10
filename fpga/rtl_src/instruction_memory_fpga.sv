// instruction_memory_fpga.sv
// EVPIX-RV32 V6 runtime ROM.
// cpu_regression_mode=1 runs the exact RV32I baseline memfile used in simulation.
// cpu_regression_mode=0 runs the live EVPIX image program selected by switches.

module instruction_memory_fpga (
    input  logic [31:0] addr,
    input  logic [2:0]  program_id,
    input  logic        cpu_regression_mode,
    output logic [31:0] instr
);

    localparam logic [31:0] NOP = 32'h0000_0013;

    always_comb begin
        instr = NOP;

        if (cpu_regression_mode) begin
            case (addr[11:2])
                10'd0: instr = 32'h00a0_0093;
                10'd1: instr = 32'hffd0_0113;
                10'd2: instr = 32'h0050_0193;
                10'd3: instr = 32'h00f0_0213;
                10'd4: instr = 32'h0070_0293;
                10'd5: instr = 32'h0141_2313;
                10'd6: instr = 32'h0140_b393;
                10'd7: instr = 32'h00c2_7413;
                10'd8: instr = 32'h0102_6493;
                10'd9: instr = 32'h00f2_4513;
                10'd10: instr = 32'h0021_9593;
                10'd11: instr = 32'h0012_5613;
                10'd12: instr = 32'h4011_5693;
                10'd13: instr = 32'h0030_8733;
                10'd14: instr = 32'h4030_87b3;
                10'd15: instr = 32'h0052_7833;
                10'd16: instr = 32'h0052_68b3;
                10'd17: instr = 32'h0052_4933;
                10'd18: instr = 32'h0051_99b3;
                10'd19: instr = 32'h0032_5a33;
                10'd20: instr = 32'h4031_5ab3;
                10'd21: instr = 32'h0011_2b33;
                10'd22: instr = 32'h0011_3bb3;
                10'd23: instr = 32'h1234_5c37;
                10'd24: instr = 32'h0000_0c97;
                10'd25: instr = 32'h1000_0d13;
                10'd26: instr = 32'h001d_2023;
                10'd27: instr = 32'h003d_1223;
                10'd28: instr = 32'h005d_0323;
                10'd29: instr = 32'h000d_2d83;
                10'd30: instr = 32'h004d_1e03;
                10'd31: instr = 32'h006d_0e83;
                10'd32: instr = 32'h002d_2423;
                10'd33: instr = 32'h008d_4f03;
                10'd34: instr = 32'h008d_5f83;
                10'd35: instr = 32'h0031_8463;
                10'd36: instr = 32'h063d_8d93;
                10'd37: instr = 32'h0020_9463;
                10'd38: instr = 32'h063d_8d93;
                10'd39: instr = 32'h0011_4463;
                10'd40: instr = 32'h063d_8d93;
                10'd41: instr = 32'h0020_d463;
                10'd42: instr = 32'h063d_8d93;
                10'd43: instr = 32'h0020_e463;
                10'd44: instr = 32'h063d_8d93;
                10'd45: instr = 32'h0011_7463;
                10'd46: instr = 32'h063d_8d93;
                10'd47: instr = 32'h0080_0e6f;
                10'd48: instr = 32'h07b0_0d93;
                10'd49: instr = 32'h0000_0013;
                10'd50: instr = 32'h0ec0_0e93;
                10'd51: instr = 32'h000e_8f67;
                10'd52: instr = 32'h0370_0d93;
                10'd53: instr = 32'h0000_0013;
                10'd54: instr = 32'h0000_0013;
                10'd55: instr = 32'h0000_0013;
                10'd56: instr = 32'h0000_0013;
                10'd57: instr = 32'h0000_0013;
                10'd58: instr = 32'h0000_0013;
                10'd59: instr = 32'h0000_0013;
                10'd60: instr = 32'h0000_006f;
                default: instr = NOP;
            endcase
        end else begin
            case (addr[11:2])
                10'd0: instr = 32'h0000_0093; // addi x1,x0,0 : source RGB888 base
                10'd1: instr = 32'h0000_c137; // lui  x2,0x0000c : destination processed base

                10'd2: begin
                    unique case (program_id)
                        3'd0: instr = 32'h0620_850b; // SOBEL: op=3
                        3'd1: instr = 32'h0020_850b; // GRAY: op=0
                        3'd2: instr = 32'h0220_850b; // THRESH: op=1
                        3'd3: instr = 32'h0820_850b; // CONV_IDENTITY: op=4,kernel=0
                        default: instr = NOP;
                    endcase
                end

                10'd3: instr = 32'h0000_158b; // custom STATUS -> x11
                10'd4: instr = 32'h0025_f613; // andi x12,x11,2
                10'd5: instr = 32'hfe06_0ce3; // beq x12,x0,poll
                10'd6: instr = 32'h0000_268b; // custom RESULT -> x13
                10'd7: instr = 32'h0000_370b; // custom PERF cycles -> x14
                10'd8: instr = 32'h0200_378b; // custom PERF busy -> x15
                10'd9: instr = 32'h0000_006f; // jal x0,0
                default: instr = NOP;
            endcase
        end
    end

endmodule
