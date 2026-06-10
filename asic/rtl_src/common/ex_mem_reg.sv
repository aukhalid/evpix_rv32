module ex_mem_reg (
    input  logic        clk,
    input  logic        reset,
    input  logic        reg_write_e,
    input  logic        mem_to_reg_e,
    input  logic        pc_to_reg_e,
    input  logic        mem_write_e,
    input  logic        mem_read_e,
    input  logic [31:0] alu_out_e,
    input  logic [31:0] write_data_e,
    input  logic [31:0] pc_plus4_e,
    input  logic [4:0]  rd_e,
    input  logic [2:0]  funct3_e,

    output logic        reg_write_m,
    output logic        mem_to_reg_m,
    output logic        pc_to_reg_m,
    output logic        mem_write_m,
    output logic        mem_read_m,
    output logic [31:0] alu_out_m,
    output logic [31:0] write_data_m,
    output logic [31:0] pc_plus4_m,
    output logic [4:0]  rd_m,
    output logic [2:0]  funct3_m
);

    always_ff @(posedge clk) begin
        if (reset) begin
            reg_write_m  <= 1'b0;
            mem_to_reg_m <= 1'b0;
            pc_to_reg_m  <= 1'b0;
            mem_write_m  <= 1'b0;
            mem_read_m   <= 1'b0;
            alu_out_m    <= 32'b0;
            write_data_m <= 32'b0;
            pc_plus4_m   <= 32'b0;
            rd_m         <= 5'b0;
            funct3_m     <= 3'b0;
        end else begin
            reg_write_m  <= reg_write_e;
            mem_to_reg_m <= mem_to_reg_e;
            pc_to_reg_m  <= pc_to_reg_e;
            mem_write_m  <= mem_write_e;
            mem_read_m   <= mem_read_e;
            alu_out_m    <= alu_out_e;
            write_data_m <= write_data_e;
            pc_plus4_m   <= pc_plus4_e;
            rd_m         <= rd_e;
            funct3_m     <= funct3_e;
        end
    end

endmodule
