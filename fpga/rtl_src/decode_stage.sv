// File: decode_stage.sv
// ============================================================

module decode_stage (
    input  logic        clk,
    input  logic        reset,
    input  logic [31:0] instr_d,
    input  logic [31:0] result_w,
    input  logic        reg_write_w,
    input  logic [4:0]  rd_w,
    output logic [31:0] reg_rd1_d,
    output logic [31:0] reg_rd2_d,
    output logic [31:0] imm_ext_d,
    output logic        reg_write_d,
    output logic        mem_to_reg_d,
    output logic        pc_to_reg_d,
    output logic        mem_write_d,
    output logic        mem_read_d,
    output logic        branch_d,
    output logic        jump_d,
    output logic        jalr_d,
    output logic        alu_src_d,
    output logic        lui_d,
    output logic        auipc_d,
    output logic        ipu_en_d,
    output logic [1:0]  alu_op_d,
    output logic [31:0] debug_registers [0:31]
);

    register_file rf (
        .clk        (~clk),
        .reset      (reset),
        .reg_write  (reg_write_w),
        .rs1        (instr_d[19:15]),
        .rs2        (instr_d[24:20]),
        .rd         (rd_w),
        .write_data (result_w),
        .rd1        (reg_rd1_d),
        .rd2        (reg_rd2_d),
        .debug_registers(debug_registers)
    );

    imm_generator imm_gen (
        .instr   (instr_d),
        .imm_ext (imm_ext_d)
    );

    main_control ctrl (
        .opcode     (instr_d[6:0]),
        .reg_write  (reg_write_d),
        .mem_to_reg (mem_to_reg_d),
        .pc_to_reg  (pc_to_reg_d),
        .mem_write  (mem_write_d),
        .mem_read   (mem_read_d),
        .branch     (branch_d),
        .jump       (jump_d),
        .jalr       (jalr_d),
        .alu_src    (alu_src_d),
        .lui        (lui_d),
        .auipc      (auipc_d),
        .ipu_en     (ipu_en_d),
        .alu_op     (alu_op_d)
    );

endmodule
