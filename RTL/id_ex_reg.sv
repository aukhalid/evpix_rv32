module id_ex_reg (
    input  logic        clk,
    input  logic        reset,
    input  logic        flush,
    input  logic        hold,

    input  logic        reg_write_d,
    input  logic        mem_to_reg_d,
    input  logic        pc_to_reg_d,
    input  logic        mem_write_d,
    input  logic        mem_read_d,
    input  logic        branch_d,
    input  logic        jump_d,
    input  logic        jalr_d,
    input  logic        alu_src_d,
    input  logic        lui_d,
    input  logic        auipc_d,
    input  logic        ipu_en_d,
    input  logic [1:0]  alu_op_d,

    input  logic [31:0] pc_d,
    input  logic [31:0] reg_rd1_d,
    input  logic [31:0] reg_rd2_d,
    input  logic [31:0] imm_ext_d,
    input  logic [31:0] pc_plus4_d,
    input  logic [4:0]  rs1_d,
    input  logic [4:0]  rs2_d,
    input  logic [4:0]  rd_d,
    input  logic [2:0]  funct3_d,
    input  logic [6:0]  funct7_d,

    output logic        reg_write_e,
    output logic        mem_to_reg_e,
    output logic        pc_to_reg_e,
    output logic        mem_write_e,
    output logic        mem_read_e,
    output logic        branch_e,
    output logic        jump_e,
    output logic        jalr_e,
    output logic        alu_src_e,
    output logic        lui_e,
    output logic        auipc_e,
    output logic        ipu_en_e,
    output logic [1:0]  alu_op_e,

    output logic [31:0] pc_e,
    output logic [31:0] reg_rd1_e,
    output logic [31:0] reg_rd2_e,
    output logic [31:0] imm_ext_e,
    output logic [31:0] pc_plus4_e,
    output logic [4:0]  rs1_e,
    output logic [4:0]  rs2_e,
    output logic [4:0]  rd_e,
    output logic [2:0]  funct3_e,
    output logic [6:0]  funct7_e
);

    always_ff @(posedge clk or posedge reset) begin
        if (reset || flush) begin
            reg_write_e  <= 1'b0;
            mem_to_reg_e <= 1'b0;
            pc_to_reg_e  <= 1'b0;
            mem_write_e  <= 1'b0;
            mem_read_e   <= 1'b0;
            branch_e     <= 1'b0;
            jump_e       <= 1'b0;
            jalr_e       <= 1'b0;
            alu_src_e    <= 1'b0;
            lui_e        <= 1'b0;
            auipc_e      <= 1'b0;
            ipu_en_e     <= 1'b0;
            alu_op_e     <= 2'b00;
            pc_e         <= 32'b0;
            reg_rd1_e    <= 32'b0;
            reg_rd2_e    <= 32'b0;
            imm_ext_e    <= 32'b0;
            pc_plus4_e   <= 32'b0;
            rs1_e        <= 5'b0;
            rs2_e        <= 5'b0;
            rd_e         <= 5'b0;
            funct3_e     <= 3'b0;
            funct7_e     <= 7'b0;
        end else if (!hold) begin
            reg_write_e  <= reg_write_d;
            mem_to_reg_e <= mem_to_reg_d;
            pc_to_reg_e  <= pc_to_reg_d;
            mem_write_e  <= mem_write_d;
            mem_read_e   <= mem_read_d;
            branch_e     <= branch_d;
            jump_e       <= jump_d;
            jalr_e       <= jalr_d;
            alu_src_e    <= alu_src_d;
            lui_e        <= lui_d;
            auipc_e      <= auipc_d;
            ipu_en_e     <= ipu_en_d;
            alu_op_e     <= alu_op_d;
            pc_e         <= pc_d;
            reg_rd1_e    <= reg_rd1_d;
            reg_rd2_e    <= reg_rd2_d;
            imm_ext_e    <= imm_ext_d;
            pc_plus4_e   <= pc_plus4_d;
            rs1_e        <= rs1_d;
            rs2_e        <= rs2_d;
            rd_e         <= rd_d;
            funct3_e     <= funct3_d;
            funct7_e     <= funct7_d;
        end
    end

endmodule
