module writeback_stage (
    input  logic [31:0] alu_out_w,
    input  logic [31:0] read_data_w,
    input  logic [31:0] pc_plus4_w,
    input  logic        mem_to_reg_w,
    input  logic        pc_to_reg_w,
    output logic [31:0] result_w
);

    always_comb begin
        if (pc_to_reg_w)
            result_w = pc_plus4_w;
        else if (mem_to_reg_w)
            result_w = read_data_w;
        else
            result_w = alu_out_w;
    end

endmodule
