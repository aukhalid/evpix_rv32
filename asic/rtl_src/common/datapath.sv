module datapath (
    input  logic        clk,
    input  logic        reset,
    input  logic [31:0] instr_f,
    input  logic [31:0] read_data_m,
    input  logic        ipu_busy,
    input  logic        ipu_done,
    input  logic [31:0] ipu_result,
    input  logic [31:0] perf_cycle_count,
    input  logic [31:0] perf_ipu_busy_count,
    input  logic [31:0] perf_conv_count,
    input  logic [31:0] perf_pool_count,
    input  logic [31:0] perf_stall_count,
    output logic [31:0] pc_f,
    output logic [31:0] alu_out_m,
    output logic [31:0] write_data_m,
    output logic        mem_read_m,
    output logic        mem_write_m,
    output logic [2:0]  funct3_m,
    output logic        ipu_start,
    output logic [2:0]  ipu_op,
    output logic [3:0]  ipu_kernel,
    output logic [31:0] ipu_src_base,
    output logic [31:0] ipu_dst_base,
    output logic        stall_pulse,

    // Hardware-BIST/debug visibility. These are passive taps from WB stage.
    input  logic [4:0]  debug_reg_sel,
    output logic        debug_wb_we,
    output logic [4:0]  debug_wb_rd,
    output logic [31:0] debug_wb_data,
    output logic [31:0] debug_reg_value
);

    logic [31:0] pc_plus4_f;

    logic [31:0] instr_d, pc_d, pc_plus4_d;
    logic [31:0] reg_rd1_d, reg_rd2_d, imm_ext_d;
    logic        reg_write_d, mem_to_reg_d, pc_to_reg_d;
    logic        mem_write_d, mem_read_d, branch_d, jump_d, jalr_d, alu_src_d;
    logic        lui_d, auipc_d, ipu_en_d;
    logic [1:0]  alu_op_d;

    logic [31:0] reg_rd1_e, reg_rd2_e, imm_ext_e, pc_e, pc_plus4_e;
    logic [4:0]  rs1_e, rs2_e, rd_e;
    logic        reg_write_e, mem_to_reg_e, pc_to_reg_e;
    logic        mem_write_e, mem_read_e, branch_e, jump_e, jalr_e, alu_src_e;
    logic        lui_e, auipc_e, ipu_en_e;
    logic [1:0]  alu_op_e;
    logic [2:0]  funct3_e;
    logic [6:0]  funct7_e;
    logic [31:0] alu_out_e, pc_target_e, write_data_e;
    logic        zero_e, pc_src_e;

    logic [31:0] pc_plus4_m;
    logic [4:0]  rd_m;
    logic        reg_write_m, mem_to_reg_m, pc_to_reg_m;

    logic [31:0] alu_out_w, read_data_w, pc_plus4_w;
    logic [4:0]  rd_w;
    logic        reg_write_w, mem_to_reg_w, pc_to_reg_w;
    logic [31:0] result_w;

    logic        stall_load;
    logic [1:0]  forward_a, forward_b;

    assign stall_pulse = stall_load;

    fetch_stage fetch (
        .clk         (clk),
        .reset       (reset),
        .stall       (stall_load),
        .pc_src_e    (pc_src_e),
        .pc_target_e (pc_target_e),
        .pc_f        (pc_f),
        .pc_plus4_f  (pc_plus4_f)
    );

    if_id_reg if_id (
        .clk        (clk),
        .reset      (reset),
        .stall      (stall_load),
        .flush      (pc_src_e),
        .instr_f    (instr_f),
        .pc_f       (pc_f),
        .pc_plus4_f (pc_plus4_f),
        .instr_d    (instr_d),
        .pc_d       (pc_d),
        .pc_plus4_d (pc_plus4_d)
    );

    decode_stage decode (
        .clk          (clk),
        .reset        (reset),
        .instr_d      (instr_d),
        .reg_write_w  (reg_write_w),
        .rd_w         (rd_w),
        .debug_reg_sel(debug_reg_sel),
        .result_w     (result_w),
        .reg_rd1_d    (reg_rd1_d),
        .reg_rd2_d    (reg_rd2_d),
        .imm_ext_d    (imm_ext_d),
        .reg_write_d  (reg_write_d),
        .mem_to_reg_d (mem_to_reg_d),
        .pc_to_reg_d  (pc_to_reg_d),
        .mem_write_d  (mem_write_d),
        .mem_read_d   (mem_read_d),
        .branch_d     (branch_d),
        .jump_d       (jump_d),
        .jalr_d       (jalr_d),
        .alu_src_d    (alu_src_d),
        .lui_d        (lui_d),
        .auipc_d      (auipc_d),
        .ipu_en_d     (ipu_en_d),
        .alu_op_d     (alu_op_d),
        .debug_reg_value(debug_reg_value)
    );

    hazard_detection_unit hazard_unit (
        .rs1_d      (instr_d[19:15]),
        .rs2_d      (instr_d[24:20]),
        .rd_e       (rd_e),
        .mem_read_e (mem_read_e),
        .stall      (stall_load)
    );

    id_ex_reg id_ex (
        .clk          (clk),
        .reset        (reset),
        .flush        (stall_load | pc_src_e),
        .hold         (1'b0),
        .reg_write_d  (reg_write_d),
        .mem_to_reg_d (mem_to_reg_d),
        .pc_to_reg_d  (pc_to_reg_d),
        .mem_write_d  (mem_write_d),
        .mem_read_d   (mem_read_d),
        .branch_d     (branch_d),
        .jump_d       (jump_d),
        .jalr_d       (jalr_d),
        .alu_src_d    (alu_src_d),
        .lui_d        (lui_d),
        .auipc_d      (auipc_d),
        .ipu_en_d     (ipu_en_d),
        .alu_op_d     (alu_op_d),
        .pc_d         (pc_d),
        .reg_rd1_d    (reg_rd1_d),
        .reg_rd2_d    (reg_rd2_d),
        .imm_ext_d    (imm_ext_d),
        .rs1_d        (instr_d[19:15]),
        .rs2_d        (instr_d[24:20]),
        .rd_d         (instr_d[11:7]),
        .pc_plus4_d   (pc_plus4_d),
        .funct3_d     (instr_d[14:12]),
        .funct7_d     (instr_d[31:25]),
        .reg_write_e  (reg_write_e),
        .mem_to_reg_e (mem_to_reg_e),
        .pc_to_reg_e  (pc_to_reg_e),
        .mem_write_e  (mem_write_e),
        .mem_read_e   (mem_read_e),
        .branch_e     (branch_e),
        .jump_e       (jump_e),
        .jalr_e       (jalr_e),
        .alu_src_e    (alu_src_e),
        .lui_e        (lui_e),
        .auipc_e      (auipc_e),
        .ipu_en_e     (ipu_en_e),
        .alu_op_e     (alu_op_e),
        .pc_e         (pc_e),
        .reg_rd1_e    (reg_rd1_e),
        .reg_rd2_e    (reg_rd2_e),
        .imm_ext_e    (imm_ext_e),
        .rs1_e        (rs1_e),
        .rs2_e        (rs2_e),
        .rd_e         (rd_e),
        .pc_plus4_e   (pc_plus4_e),
        .funct3_e     (funct3_e),
        .funct7_e     (funct7_e)
    );

    execute_stage execute (
        .reg_rd1_e     (reg_rd1_e),
        .reg_rd2_e     (reg_rd2_e),
        .imm_ext_e     (imm_ext_e),
        .pc_e          (pc_e),
        .result_w      (result_w),
        .alu_out_m     (alu_out_m),
        .alu_src_e     (alu_src_e),
        .branch_e      (branch_e),
        .jump_e        (jump_e),
        .jalr_e        (jalr_e),
        .lui_e         (lui_e),
        .auipc_e       (auipc_e),
        .ipu_en_e      (ipu_en_e),
        .funct3_e      (funct3_e),
        .funct7_e      (funct7_e),
        .alu_op_e      (alu_op_e),
        .forward_a     (forward_a),
        .forward_b     (forward_b),
        .ipu_busy      (ipu_busy),
        .ipu_done      (ipu_done),
        .ipu_result    (ipu_result),
        .perf_cycle_count    (perf_cycle_count),
        .perf_ipu_busy_count (perf_ipu_busy_count),
        .perf_conv_count     (perf_conv_count),
        .perf_pool_count     (perf_pool_count),
        .perf_stall_count    (perf_stall_count),
        .alu_out_e     (alu_out_e),
        .write_data_e  (write_data_e),
        .pc_target_e   (pc_target_e),
        .pc_src_e      (pc_src_e),
        .zero_e        (zero_e),
        .ipu_start_e   (ipu_start),
        .ipu_op_e      (ipu_op),
        .ipu_kernel_e  (ipu_kernel),
        .ipu_src_base_e(ipu_src_base),
        .ipu_dst_base_e(ipu_dst_base)
    );

    forwarding_unit forward_unit (
        .rs1_e       (rs1_e),
        .rs2_e       (rs2_e),
        .rd_m        (rd_m),
        .rd_w        (rd_w),
        .reg_write_m (reg_write_m),
        .reg_write_w (reg_write_w),
        .forward_a   (forward_a),
        .forward_b   (forward_b)
    );

    ex_mem_reg ex_mem (
        .clk          (clk),
        .reset        (reset),
        .reg_write_e  (reg_write_e),
        .mem_to_reg_e (mem_to_reg_e),
        .pc_to_reg_e  (pc_to_reg_e),
        .mem_write_e  (mem_write_e),
        .mem_read_e   (mem_read_e),
        .alu_out_e    (alu_out_e),
        .write_data_e (write_data_e),
        .pc_plus4_e   (pc_plus4_e),
        .rd_e         (rd_e),
        .funct3_e     (funct3_e),
        .reg_write_m  (reg_write_m),
        .mem_to_reg_m (mem_to_reg_m),
        .pc_to_reg_m  (pc_to_reg_m),
        .mem_write_m  (mem_write_m),
        .mem_read_m   (mem_read_m),
        .alu_out_m    (alu_out_m),
        .write_data_m (write_data_m),
        .pc_plus4_m   (pc_plus4_m),
        .rd_m         (rd_m),
        .funct3_m     (funct3_m)
    );

    mem_wb_reg mem_wb (
        .clk          (clk),
        .reset        (reset),
        .reg_write_m  (reg_write_m),
        .mem_to_reg_m (mem_to_reg_m),
        .pc_to_reg_m  (pc_to_reg_m),
        .read_data_m  (read_data_m),
        .alu_out_m    (alu_out_m),
        .pc_plus4_m   (pc_plus4_m),
        .rd_m         (rd_m),
        .reg_write_w  (reg_write_w),
        .mem_to_reg_w (mem_to_reg_w),
        .pc_to_reg_w  (pc_to_reg_w),
        .read_data_w  (read_data_w),
        .alu_out_w    (alu_out_w),
        .pc_plus4_w   (pc_plus4_w),
        .rd_w         (rd_w)
    );

    writeback_stage writeback (
        .alu_out_w    (alu_out_w),
        .read_data_w  (read_data_w),
        .pc_plus4_w   (pc_plus4_w),
        .mem_to_reg_w (mem_to_reg_w),
        .pc_to_reg_w  (pc_to_reg_w),
        .result_w     (result_w)
    );

    // ------------------------------------------------------------------
    // Hardware-BIST / debug writeback taps.
    // These are passive visibility signals only. They do not alter the
    // RV32I datapath, forwarding, hazard, memory, or IPU behavior.
    //
    // The FPGA BIST scoreboard mirrors the same architectural writeback
    // stream that the register file receives, so the on-board test can
    // compare the exact final RV32I regression values.
    // ------------------------------------------------------------------
    assign debug_wb_we   = reg_write_w;
    assign debug_wb_rd   = rd_w;
    assign debug_wb_data = result_w;


endmodule
