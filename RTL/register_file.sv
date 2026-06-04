// File: register_file.sv
// ============================================================
// v11 LUT-safe register file.
// Architecture is unchanged: two asynchronous read ports and one synchronous
// write port. The reset loop was removed because resetting all 32x32 registers
// costs extra reset mux/control logic on Basys 3. FPGA configuration initializes
// them to zero, and both the IPU firmware and BIST program write the registers
// they use before checking results.

module register_file (
    input  logic        clk, reset, reg_write,
    input  logic [4:0]  rs1, rs2, rd,
    input  logic [31:0] write_data,
    output logic [31:0] rd1, rd2,
    output logic [31:0] debug_registers [0:31]
);

    logic [31:0] registers [0:31];

    initial begin : INIT_REGFILE
        for (int i = 0; i < 32; i = i + 1)
            registers[i] = 32'd0;
    end

    // reset is intentionally unused for the register array to reduce LUT/reset
    // mux usage. x0 is still hard-wired to zero on reads/debug output.
    always_ff @(posedge clk) begin
        if (reg_write && rd != 5'd0)
            registers[rd] <= write_data;
    end

    assign rd1 = (rs1 == 5'd0) ? 32'b0 : registers[rs1];
    assign rd2 = (rs2 == 5'd0) ? 32'b0 : registers[rs2];

    genvar dbg_i;
    generate
        for (dbg_i = 0; dbg_i < 32; dbg_i = dbg_i + 1) begin : G_DEBUG_REGS
            assign debug_registers[dbg_i] = (dbg_i == 0) ? 32'd0 : registers[dbg_i];
        end
    endgenerate

endmodule
