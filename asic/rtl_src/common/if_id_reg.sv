module if_id_reg (
    input  logic        clk, reset, stall, flush,
    input  logic [31:0] instr_f, pc_f, pc_plus4_f,
    output logic [31:0] instr_d, pc_d, pc_plus4_d
);

    always_ff @(posedge clk) begin
        if (reset || flush) begin
            instr_d    <= 32'h00000013;
            pc_d       <= 32'b0;
            pc_plus4_d <= 32'b0;
        end else if (!stall) begin
            instr_d    <= instr_f;
            pc_d       <= pc_f;
            pc_plus4_d <= pc_plus4_f;
        end
    end

endmodule
