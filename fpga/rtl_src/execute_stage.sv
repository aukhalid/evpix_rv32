module execute_stage (
    input  logic [31:0] reg_rd1_e,
    input  logic [31:0] reg_rd2_e,
    input  logic [31:0] imm_ext_e,
    input  logic [31:0] pc_e,
    input  logic [31:0] result_w,
    input  logic [31:0] alu_out_m,
    input  logic        alu_src_e,
    input  logic        branch_e,
    input  logic        jump_e,
    input  logic        jalr_e,
    input  logic        lui_e,
    input  logic        auipc_e,
    input  logic        ipu_en_e,
    input  logic [2:0]  funct3_e,
    input  logic [6:0]  funct7_e,
    input  logic [1:0]  alu_op_e,
    input  logic [1:0]  forward_a,
    input  logic [1:0]  forward_b,
    input  logic        ipu_busy,
    input  logic        ipu_done,
    input  logic [31:0] ipu_result,
    input  logic [31:0] perf_cycle_count,
    input  logic [31:0] perf_ipu_busy_count,
    input  logic [31:0] perf_conv_count,
    input  logic [31:0] perf_pool_count,
    input  logic [31:0] perf_stall_count,

    output logic [31:0] alu_out_e,
    output logic [31:0] write_data_e,
    output logic [31:0] pc_target_e,
    output logic        pc_src_e,
    output logic        zero_e,
    output logic        ipu_start_e,
    output logic [2:0]  ipu_op_e,
    output logic [3:0]  ipu_kernel_e,
    output logic [31:0] ipu_src_base_e,
    output logic [31:0] ipu_dst_base_e
);

    logic [31:0] src_a;
    logic [31:0] src_b;
    logic [31:0] alu_operand_a;
    logic [31:0] alu_operand_b;
    logic [31:0] alu_result_normal;
    logic [3:0]  alu_ctrl;
    logic        branch_taken_e;
    logic        zero_normal;
    logic [31:0] custom_result;

    localparam logic [2:0] CUST_START  = 3'b000;
    localparam logic [2:0] CUST_STATUS = 3'b001;
    localparam logic [2:0] CUST_RESULT = 3'b010;
    localparam logic [2:0] CUST_PERF   = 3'b011;

    always_comb begin
        case (forward_a)
            2'b00:   src_a = reg_rd1_e;
            2'b01:   src_a = result_w;
            2'b10:   src_a = alu_out_m;
            default: src_a = reg_rd1_e;
        endcase
    end

    always_comb begin
        case (forward_b)
            2'b00:   src_b = reg_rd2_e;
            2'b01:   src_b = result_w;
            2'b10:   src_b = alu_out_m;
            default: src_b = reg_rd2_e;
        endcase
    end

    assign write_data_e   = src_b;
    assign ipu_src_base_e = src_a;
    assign ipu_dst_base_e = src_b;
    assign ipu_op_e       = funct7_e[2:0];
    assign ipu_kernel_e   = funct7_e[6:3];
    assign ipu_start_e    = ipu_en_e && (funct3_e == CUST_START) && !ipu_busy;

    always_comb begin
        if (auipc_e)
            alu_operand_a = pc_e;
        else if (lui_e)
            alu_operand_a = 32'b0;
        else
            alu_operand_a = src_a;
    end

    assign alu_operand_b = alu_src_e ? imm_ext_e : src_b;

    alu_control alu_c (
        .alu_op   (alu_op_e),
        .funct3   (funct3_e),
        .funct7_5 (funct7_e[5]),
        .alu_ctrl (alu_ctrl)
    );

    alu alu_inst (
        .a        (alu_operand_a),
        .b        (alu_operand_b),
        .alu_ctrl (alu_ctrl),
        .result   (alu_result_normal),
        .zero     (zero_normal)
    );

    branch_unit branch_cmp (
        .rs1          (src_a),
        .rs2          (src_b),
        .funct3       (funct3_e),
        .branch_taken (branch_taken_e)
    );

    always_comb begin
        if (jalr_e)
            pc_target_e = (src_a + imm_ext_e) & 32'hFFFF_FFFE;
        else
            pc_target_e = pc_e + imm_ext_e;
    end

    assign pc_src_e = jump_e | (branch_e & branch_taken_e);

    always_comb begin
        case (funct7_e[2:0])
            3'd0: custom_result = perf_cycle_count;
            3'd1: custom_result = perf_ipu_busy_count;
            3'd2: custom_result = perf_conv_count;
            3'd3: custom_result = perf_pool_count;
            3'd4: custom_result = perf_stall_count;
            default: custom_result = 32'b0;
        endcase
    end

    always_comb begin
        if (ipu_en_e) begin
            case (funct3_e)
                CUST_START:  alu_out_e = (!ipu_busy) ? 32'd1 : 32'd0;
                CUST_STATUS: alu_out_e = {30'b0, ipu_done, ipu_busy};
                CUST_RESULT: alu_out_e = ipu_result;
                CUST_PERF:   alu_out_e = custom_result;
                default:     alu_out_e = 32'b0;
            endcase
            zero_e = (alu_out_e == 32'b0);
        end else begin
            alu_out_e = alu_result_normal;
            zero_e    = zero_normal;
        end
    end

endmodule
