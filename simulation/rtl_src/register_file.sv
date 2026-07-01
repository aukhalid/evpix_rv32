module register_file (
    input  logic        clk, reset, reg_write,
    input  logic [4:0]  rs1, rs2, rd,
    input  logic [31:0] write_data,
    output logic [31:0] rd1, rd2
);

    logic [31:0] registers [0:31];
    integer i;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            for (i = 0; i < 32; i = i + 1)
                registers[i] <= 32'b0;
        end else if (reg_write && rd != 5'd0) begin
            registers[rd] <= write_data;
        end
    end

    assign rd1 = (rs1 == 5'd0) ? 32'b0 : registers[rs1];
    assign rd2 = (rs2 == 5'd0) ? 32'b0 : registers[rs2];

endmodule
