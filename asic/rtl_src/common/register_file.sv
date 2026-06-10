// File: register_file.sv
// ASIC/Yosys-friendly EVPIX register file.
// Two asynchronous read ports, one synchronous write port.
// v11 change: replaced 1024-bit debug-register dump with a 5-bit indexed
// debug read port. This preserves BIST/table observability while avoiding a
// massive top-level debug bus that makes ABC mapping very slow.

module register_file (
    input  logic        clk,
    input  logic        reset,
    input  logic        reg_write,
    input  logic [4:0]  rs1,
    input  logic [4:0]  rs2,
    input  logic [4:0]  rd,
    input  logic [31:0] write_data,
    input  logic [4:0]  debug_sel,
    output logic [31:0] rd1,
    output logic [31:0] rd2,
    output logic [31:0] debug_reg_value
);

    logic [31:0] registers [0:31];

    initial begin : INIT_REGFILE
        for (int i = 0; i < 32; i = i + 1)
            registers[i] = 32'd0;
    end

    // reset intentionally does not clear the full register array. The BIST and
    // IPU programs overwrite the architectural registers they check/use. This
    // avoids adding reset muxes to 31 x 32 flip-flops in ASIC and FPGA flows.
    always_ff @(posedge clk) begin
        if (reg_write && rd != 5'd0)
            registers[rd] <= write_data;
    end

    assign rd1 = (rs1 == 5'd0) ? 32'b0 : registers[rs1];
    assign rd2 = (rs2 == 5'd0) ? 32'b0 : registers[rs2];
    assign debug_reg_value = (debug_sel == 5'd0) ? 32'b0 : registers[debug_sel];

endmodule
