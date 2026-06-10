module mem_wb_reg (
    input  logic        clk,
    input  logic        reset,
    input  logic        reg_write_m,
    input  logic        mem_to_reg_m,
    input  logic        pc_to_reg_m,
    input  logic [31:0] read_data_m,
    input  logic [31:0] alu_out_m,
    input  logic [31:0] pc_plus4_m,
    input  logic [4:0]  rd_m,

    output logic        reg_write_w,
    output logic        mem_to_reg_w,
    output logic        pc_to_reg_w,
    output logic [31:0] read_data_w,
    output logic [31:0] alu_out_w,
    output logic [31:0] pc_plus4_w,
    output logic [4:0]  rd_w
);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            reg_write_w  <= 1'b0;
            mem_to_reg_w <= 1'b0;
            pc_to_reg_w  <= 1'b0;
            read_data_w  <= 32'b0;
            alu_out_w    <= 32'b0;
            pc_plus4_w   <= 32'b0;
            rd_w         <= 5'b0;
        end else begin
            reg_write_w  <= reg_write_m;
            mem_to_reg_w <= mem_to_reg_m;
            pc_to_reg_w  <= pc_to_reg_m;
            read_data_w  <= read_data_m;
            alu_out_w    <= alu_out_m;
            pc_plus4_w   <= pc_plus4_m;
            rd_w         <= rd_m;
        end
    end

endmodule
