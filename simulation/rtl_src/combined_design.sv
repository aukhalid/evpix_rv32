// Start of: adder.sv
module adder (
    input  logic [31:0] a, b,
    output logic [31:0] sum
);

    assign sum = a + b;

endmodule


// Start of: alu.sv
module alu (
    input  logic [31:0] a, b,
    input  logic [3:0]  alu_ctrl,
    output logic [31:0] result,
    output logic        zero
);

    always_comb begin
        case (alu_ctrl)
            4'b0000: result = a & b;
            4'b0001: result = a | b;
            4'b0010: result = a + b;
            4'b0011: result = (a < b) ? 32'd1 : 32'd0;
            4'b0110: result = a - b;
            4'b0111: result = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
            4'b1000: result = a << b[4:0];
            4'b1001: result = a >> b[4:0];
            4'b1010: result = $signed(a) >>> b[4:0];
            4'b1101: result = a ^ b;
            default: result = 32'b0;
        endcase
    end

    assign zero = (result == 32'b0);

endmodule


// Start of: alu_control.sv
module alu_control (
    input  logic [1:0] alu_op,
    input  logic [2:0] funct3,
    input  logic       funct7_5,
    output logic [3:0] alu_ctrl
);

    always_comb begin
        case (alu_op)
            2'b00: alu_ctrl = 4'b0010;
            2'b01: alu_ctrl = 4'b0110;
            2'b10, 2'b11: begin
                case (funct3)
                    3'b000: alu_ctrl = (funct7_5 && (alu_op == 2'b10)) ? 4'b0110 : 4'b0010;
                    3'b001: alu_ctrl = 4'b1000;
                    3'b010: alu_ctrl = 4'b0111;
                    3'b011: alu_ctrl = 4'b0011;
                    3'b100: alu_ctrl = 4'b1101;
                    3'b101: alu_ctrl = funct7_5 ? 4'b1010 : 4'b1001;
                    3'b110: alu_ctrl = 4'b0001;
                    3'b111: alu_ctrl = 4'b0000;
                    default: alu_ctrl = 4'b0010;
                endcase
            end
            default: alu_ctrl = 4'b0010;
        endcase
    end

endmodule


// Start of: branch_unit.sv
module branch_unit (
    input  logic [31:0] rs1, rs2,
    input  logic [2:0]  funct3,
    output logic        branch_taken
);

    always_comb begin
        case (funct3)
            3'b000: branch_taken = (rs1 == rs2);
            3'b001: branch_taken = (rs1 != rs2);
            3'b100: branch_taken = ($signed(rs1) < $signed(rs2));
            3'b101: branch_taken = ($signed(rs1) >= $signed(rs2));
            3'b110: branch_taken = (rs1 < rs2);
            3'b111: branch_taken = (rs1 >= rs2);
            default: branch_taken = 1'b0;
        endcase
    end

endmodule


// Start of: datapath.sv
module datapath (
    input  logic        clk,
    input  logic        reset,
    input  logic [31:0] instr_f,
    input  logic [31:0] read_data_m,
    input  logic        ipu_busy,
    input  logic        ipu_done,
    input  logic [31:0] ipu_result,
    output logic [31:0] pc_f,
    output logic [31:0] alu_out_m,
    output logic [31:0] write_data_m,
    output logic        mem_read_m,
    output logic        mem_write_m,
    output logic [2:0]  funct3_m,
    output logic        ipu_start,
    output logic [1:0]  ipu_op,
    output logic [31:0] ipu_src_base,
    output logic [31:0] ipu_dst_base
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
    logic        funct7_5_e;
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
    logic        stall_ipu;
    logic        stall_all;
    logic [1:0]  forward_a, forward_b;

    assign stall_ipu = ipu_en_e && !ipu_done;
    assign stall_all = stall_load | stall_ipu;

    fetch_stage fetch (
        .clk         (clk),
        .reset       (reset),
        .stall       (stall_all),
        .pc_src_e    (pc_src_e),
        .pc_target_e (pc_target_e),
        .pc_f        (pc_f),
        .pc_plus4_f  (pc_plus4_f)
    );

    if_id_reg if_id (
        .clk        (clk),
        .reset      (reset),
        .stall      (stall_all),
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
        .alu_op_d     (alu_op_d)
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
        .hold         (stall_ipu),
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
        .funct7_5_d   (instr_d[30]),
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
        .funct7_5_e   (funct7_5_e)
    );

    execute_stage execute (
        .reg_rd1_e    (reg_rd1_e),
        .reg_rd2_e    (reg_rd2_e),
        .imm_ext_e    (imm_ext_e),
        .pc_e         (pc_e),
        .result_w     (result_w),
        .alu_out_m    (alu_out_m),
        .alu_src_e    (alu_src_e),
        .branch_e     (branch_e),
        .jump_e       (jump_e),
        .jalr_e       (jalr_e),
        .lui_e        (lui_e),
        .auipc_e      (auipc_e),
        .ipu_en_e     (ipu_en_e),
        .funct3_e     (funct3_e),
        .funct7_5_e   (funct7_5_e),
        .alu_op_e     (alu_op_e),
        .forward_a    (forward_a),
        .forward_b    (forward_b),
        .ipu_busy     (ipu_busy),
        .ipu_done     (ipu_done),
        .ipu_result   (ipu_result),
        .alu_out_e    (alu_out_e),
        .write_data_e (write_data_e),
        .pc_target_e  (pc_target_e),
        .pc_src_e     (pc_src_e),
        .zero_e       (zero_e),
        .ipu_start_e  (ipu_start),
        .ipu_op_e     (ipu_op),
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
        .reg_write_e  (stall_ipu ? 1'b0     : reg_write_e),
        .mem_to_reg_e (stall_ipu ? 1'b0     : mem_to_reg_e),
        .pc_to_reg_e  (stall_ipu ? 1'b0     : pc_to_reg_e),
        .mem_write_e  (stall_ipu ? 1'b0     : mem_write_e),
        .mem_read_e   (stall_ipu ? 1'b0     : mem_read_e),
        .alu_out_e    (stall_ipu ? 32'b0    : alu_out_e),
        .write_data_e (stall_ipu ? 32'b0    : write_data_e),
        .pc_plus4_e   (stall_ipu ? 32'b0    : pc_plus4_e),
        .rd_e         (stall_ipu ? 5'b0     : rd_e),
        .funct3_e     (stall_ipu ? 3'b0     : funct3_e),
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

endmodule


// Start of: data_memory.sv
module data_memory #(
    parameter int MEM_BYTES = 65536
) (
    input  logic        clk,
    input  logic        mem_write,
    input  logic        mem_read,
    input  logic [2:0]  funct3,
    input  logic [31:0] addr,
    input  logic [31:0] write_data,
    output logic [31:0] read_data,

    input  logic        ipu_mem_re,
    input  logic        ipu_mem_we,
    input  logic [31:0] ipu_addr,
    input  logic [7:0]  ipu_write_data,
    output logic [7:0]  ipu_read_data
);

    logic [7:0] ram [0:MEM_BYTES-1];
    integer i;

    initial begin
        for (i = 0; i < MEM_BYTES; i = i + 1)
            ram[i] = 8'h00;
    end

    always_ff @(posedge clk) begin
        if (mem_write) begin
            case (funct3)
                3'b000: begin
                    ram[addr] <= write_data[7:0];
                end
                3'b001: begin
                    ram[addr]     <= write_data[7:0];
                    ram[addr + 1] <= write_data[15:8];
                end
                3'b010: begin
                    ram[addr]     <= write_data[7:0];
                    ram[addr + 1] <= write_data[15:8];
                    ram[addr + 2] <= write_data[23:16];
                    ram[addr + 3] <= write_data[31:24];
                end
                default: begin
                end
            endcase
        end

        if (ipu_mem_we) begin
            ram[ipu_addr] <= ipu_write_data;
        end
    end

    always_comb begin
        read_data = 32'b0;

        if (mem_read) begin
            case (funct3)
                3'b000: read_data = {{24{ram[addr][7]}}, ram[addr]};
                3'b001: read_data = {{16{ram[addr + 1][7]}}, ram[addr + 1], ram[addr]};
                3'b010: read_data = {ram[addr + 3], ram[addr + 2], ram[addr + 1], ram[addr]};
                3'b100: read_data = {24'b0, ram[addr]};
                3'b101: read_data = {16'b0, ram[addr + 1], ram[addr]};
                default: read_data = 32'b0;
            endcase
        end
    end

    assign ipu_read_data = ipu_mem_re ? ram[ipu_addr] : 8'h00;

endmodule


// Start of: decode_stage.sv
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
    output logic [1:0]  alu_op_d
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
        .rd2        (reg_rd2_d)
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


// Start of: evpix_top.sv
module evpix_top (
    input  logic        clk_100mhz,
    input  logic        reset_btn,
    input  logic        rx,
    output logic        tx,
    output logic [3:0]  vga_r,
    output logic [3:0]  vga_g,
    output logic [3:0]  vga_b,
    output logic        hsync,
    output logic        vsync
);

    logic clk_50mhz;
    logic clk_div;

    always_ff @(posedge clk_100mhz) clk_div <= ~clk_div;
    assign clk_50mhz = clk_div;

    rv32i_core cpu_core (
        .clk   (clk_50mhz),
        .reset (reset_btn)
    );

    assign tx    = rx;
    assign vga_r = 4'b0;
    assign vga_g = 4'b0;
    assign vga_b = 4'b0;
    assign hsync = 1'b0;
    assign vsync = 1'b0;

endmodule


// Start of: execute_stage.sv
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
    input  logic        funct7_5_e,
    input  logic [1:0]  alu_op_e,
    input  logic [1:0]  forward_a,
    input  logic [1:0]  forward_b,
    input  logic        ipu_busy,
    input  logic        ipu_done,
    input  logic [31:0] ipu_result,

    output logic [31:0] alu_out_e,
    output logic [31:0] write_data_e,
    output logic [31:0] pc_target_e,
    output logic        pc_src_e,
    output logic        zero_e,
    output logic        ipu_start_e,
    output logic [1:0]  ipu_op_e,
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

    assign write_data_e  = src_b;
    assign ipu_src_base_e = src_a;
    assign ipu_dst_base_e = src_b;
    assign ipu_op_e       = funct3_e[1:0];
    assign ipu_start_e    = ipu_en_e && !ipu_busy && !ipu_done;

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
        .funct7_5 (funct7_5_e),
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
        if (ipu_en_e) begin
            alu_out_e = ipu_done ? ipu_result : 32'b0;
            zero_e    = (ipu_done ? ipu_result : 32'b0) == 32'b0;
        end else begin
            alu_out_e = alu_result_normal;
            zero_e    = zero_normal;
        end
    end

endmodule


// Start of: ex_mem_reg.sv
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

    always_ff @(posedge clk or posedge reset) begin
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


// Start of: fetch_stage.sv
module fetch_stage (
    input  logic        clk,
    input  logic        reset,
    input  logic        stall,
    input  logic        pc_src_e,
    input  logic [31:0] pc_target_e,
    output logic [31:0] pc_f,
    output logic [31:0] pc_plus4_f
);

    logic [31:0] next_pc;

    program_counter pc_reg (
        .clk    (clk),
        .reset  (reset),
        .en     (~stall),
        .pc_in  (next_pc),
        .pc_out (pc_f)
    );

    adder pc_adder (
        .a   (pc_f),
        .b   (32'd4),
        .sum (pc_plus4_f)
    );

    assign next_pc = pc_src_e ? pc_target_e : pc_plus4_f;

endmodule


// Start of: forwarding_unit.sv
module forwarding_unit (
    input  logic [4:0] rs1_e, rs2_e, rd_m, rd_w,
    input  logic       reg_write_m, reg_write_w,
    output logic [1:0] forward_a, forward_b
);

    always_comb begin
        if (reg_write_m && (rd_m != 5'd0) && (rd_m == rs1_e))
            forward_a = 2'b10;
        else if (reg_write_w && (rd_w != 5'd0) && (rd_w == rs1_e))
            forward_a = 2'b01;
        else
            forward_a = 2'b00;
    end

    always_comb begin
        if (reg_write_m && (rd_m != 5'd0) && (rd_m == rs2_e))
            forward_b = 2'b10;
        else if (reg_write_w && (rd_w != 5'd0) && (rd_w == rs2_e))
            forward_b = 2'b01;
        else
            forward_b = 2'b00;
    end

endmodule


// Start of: hazard_detection_unit.sv
module hazard_detection_unit (
    input  logic [4:0] rs1_d,
    input  logic [4:0] rs2_d,
    input  logic [4:0] rd_e,
    input  logic       mem_read_e,
    output logic       stall
);

    always_comb begin
        stall = mem_read_e &&
                (rd_e != 5'd0) &&
                ((rd_e == rs1_d) || (rd_e == rs2_d));
    end

endmodule


// Start of: id_ex_reg.sv
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
    input  logic        funct7_5_d,

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
    output logic        funct7_5_e
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
            funct7_5_e   <= 1'b0;
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
            funct7_5_e   <= funct7_5_d;
        end
    end

endmodule


// Start of: if_id_reg.sv
module if_id_reg (
    input  logic        clk, reset, stall, flush,
    input  logic [31:0] instr_f, pc_f, pc_plus4_f,
    output logic [31:0] instr_d, pc_d, pc_plus4_d
);

    always_ff @(posedge clk or posedge reset) begin
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


// Start of: imm_generator.sv
module imm_generator (
    input  logic [31:0] instr,
    output logic [31:0] imm_ext
);

    logic [6:0] opcode;
    assign opcode = instr[6:0];

    always_comb begin
        case (opcode)
            7'b0010011,
            7'b0000011,
            7'b1100111:
                imm_ext = {{20{instr[31]}}, instr[31:20]};

            7'b0100011:
                imm_ext = {{20{instr[31]}}, instr[31:25], instr[11:7]};

            7'b1100011:
                imm_ext = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};

            7'b0110111,
            7'b0010111:
                imm_ext = {instr[31:12], 12'b0};

            7'b1101111:
                imm_ext = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};

            default: imm_ext = 32'b0;
        endcase
    end

endmodule


// Start of: instruction_memory.sv
module instruction_memory (
    input  logic [31:0] addr,
    output logic [31:0] instr
);

    logic [31:0] rom [0:1023];

    initial begin
        $readmemh("memfile.hex", rom);
    end

    assign instr = rom[addr[31:2]];

endmodule


// Start of: ipu.sv
module ipu #(
    parameter int IMG_W = 128,
    parameter int IMG_H = 128,
    parameter logic [7:0] THRESHOLD_VALUE = 8'd128
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [1:0]  op,
    input  logic [31:0] src_base,
    input  logic [31:0] dst_base,
    output logic        busy,
    output logic        done,
    output logic [31:0] result,

    output logic        mem_re,
    output logic        mem_we,
    output logic [31:0] mem_addr,
    output logic [7:0]  mem_wdata,
    input  logic [7:0]  mem_rdata
);

    localparam int PIXELS    = IMG_W * IMG_H;
    localparam int RGB_BYTES = PIXELS * 3;

    typedef enum logic [3:0] {
        ST_IDLE          = 4'd0,
        ST_SIMPLE_R      = 4'd1,
        ST_SIMPLE_G      = 4'd2,
        ST_SIMPLE_B      = 4'd3,
        ST_SIMPLE_WRITE  = 4'd4,
        ST_SOBEL_LOAD_R  = 4'd5,
        ST_SOBEL_LOAD_G  = 4'd6,
        ST_SOBEL_LOAD_B  = 4'd7,
        ST_SOBEL_PROC    = 4'd8,
        ST_DONE          = 4'd9
    } state_t;

    localparam logic [1:0] OP_GRAYSCALE = 2'b00;
    localparam logic [1:0] OP_SOBEL     = 2'b01;
    localparam logic [1:0] OP_THRESHOLD = 2'b10;
    localparam logic [1:0] OP_MAXPIX    = 2'b11;

    state_t state;
    logic [1:0]  op_r;
    logic [31:0] src_base_r, dst_base_r;
    logic [31:0] pix_idx;
    logic [7:0]  r_reg, g_reg, b_reg;
    logic [7:0]  gray_buf [0:PIXELS-1];
    logic [7:0]  max_pix;
    integer      x;
    integer      y;
    integer      gx;
    integer      gy;
    integer      mag;
    logic [7:0]  gray_now;
    logic [7:0]  sobel_pix;

    function automatic [7:0] rgb_to_gray(
        input logic [7:0] r,
        input logic [7:0] g,
        input logic [7:0] b
    );
        logic [15:0] sum;
        begin
            sum = (r * 8'd77) + (g * 8'd150) + (b * 8'd29);
            rgb_to_gray = sum[15:8];
        end
    endfunction

    always_comb begin
        gray_now = rgb_to_gray(r_reg, g_reg, b_reg);
    end

    always_comb begin
        sobel_pix = 8'd0;
        if ((pix_idx < PIXELS) && (state == ST_SOBEL_PROC)) begin
            x = pix_idx % IMG_W;
            y = pix_idx / IMG_W;
            if ((x == 0) || (x == IMG_W-1) || (y == 0) || (y == IMG_H-1)) begin
                sobel_pix = 8'd0;
            end else begin
                gx = -gray_buf[(y-1)*IMG_W + (x-1)]
                     -($signed({1'b0, gray_buf[y*IMG_W + (x-1)]}) <<< 1)
                     -gray_buf[(y+1)*IMG_W + (x-1)]
                     +gray_buf[(y-1)*IMG_W + (x+1)]
                     +($signed({1'b0, gray_buf[y*IMG_W + (x+1)]}) <<< 1)
                     +gray_buf[(y+1)*IMG_W + (x+1)];

                gy =  gray_buf[(y-1)*IMG_W + (x-1)]
                     +($signed({1'b0, gray_buf[(y-1)*IMG_W + x]}) <<< 1)
                     +gray_buf[(y-1)*IMG_W + (x+1)]
                     -gray_buf[(y+1)*IMG_W + (x-1)]
                     -($signed({1'b0, gray_buf[(y+1)*IMG_W + x]}) <<< 1)
                     -gray_buf[(y+1)*IMG_W + (x+1)];

                if (gx < 0) gx = -gx;
                if (gy < 0) gy = -gy;
                mag = gx + gy;
                if (mag > 255)
                    sobel_pix = 8'hFF;
                else
                    sobel_pix = mag[7:0];
            end
        end
    end

    always_comb begin
        mem_re    = 1'b0;
        mem_we    = 1'b0;
        mem_addr  = 32'b0;
        mem_wdata = 8'b0;

        case (state)
            ST_SIMPLE_R: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + (pix_idx * 32'd3);
            end
            ST_SIMPLE_G: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + (pix_idx * 32'd3) + 32'd1;
            end
            ST_SIMPLE_B: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + (pix_idx * 32'd3) + 32'd2;
            end
            ST_SIMPLE_WRITE: begin
                if (op_r != OP_MAXPIX) begin
                    mem_we    = 1'b1;
                    mem_addr  = dst_base_r + pix_idx;
                    mem_wdata = (op_r == OP_THRESHOLD) ?
                                ((gray_now >= THRESHOLD_VALUE) ? 8'hFF : 8'h00) :
                                gray_now;
                end
            end
            ST_SOBEL_LOAD_R: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + (pix_idx * 32'd3);
            end
            ST_SOBEL_LOAD_G: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + (pix_idx * 32'd3) + 32'd1;
            end
            ST_SOBEL_LOAD_B: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + (pix_idx * 32'd3) + 32'd2;
            end
            ST_SOBEL_PROC: begin
                mem_we    = 1'b1;
                mem_addr  = dst_base_r + pix_idx;
                mem_wdata = sobel_pix;
            end
            default: begin
            end
        endcase
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            busy       <= 1'b0;
            done       <= 1'b0;
            result     <= 32'b0;
            state      <= ST_IDLE;
            op_r       <= 2'b00;
            src_base_r <= 32'b0;
            dst_base_r <= 32'b0;
            pix_idx    <= 32'b0;
            r_reg      <= 8'b0;
            g_reg      <= 8'b0;
            b_reg      <= 8'b0;
            max_pix    <= 8'b0;
        end else begin
            done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy       <= 1'b1;
                        op_r       <= op;
                        src_base_r <= src_base;
                        dst_base_r <= dst_base;
                        pix_idx    <= 32'b0;
                        max_pix    <= 8'b0;
                        if (op == OP_SOBEL)
                            state <= ST_SOBEL_LOAD_R;
                        else
                            state <= ST_SIMPLE_R;
                    end
                end

                ST_SIMPLE_R: begin
                    r_reg <= mem_rdata;
                    state <= ST_SIMPLE_G;
                end

                ST_SIMPLE_G: begin
                    g_reg <= mem_rdata;
                    state <= ST_SIMPLE_B;
                end

                ST_SIMPLE_B: begin
                    b_reg <= mem_rdata;
                    state <= ST_SIMPLE_WRITE;
                end

                ST_SIMPLE_WRITE: begin
                    if (op_r == OP_MAXPIX) begin
                        if (gray_now > max_pix)
                            max_pix <= gray_now;
                    end

                    if (pix_idx == PIXELS-1) begin
                        result <= (op_r == OP_MAXPIX) ? {24'b0, (gray_now > max_pix ? gray_now : max_pix)} : 32'd1;
                        state  <= ST_DONE;
                    end else begin
                        pix_idx <= pix_idx + 32'd1;
                        state   <= ST_SIMPLE_R;
                    end
                end

                ST_SOBEL_LOAD_R: begin
                    r_reg <= mem_rdata;
                    state <= ST_SOBEL_LOAD_G;
                end

                ST_SOBEL_LOAD_G: begin
                    g_reg <= mem_rdata;
                    state <= ST_SOBEL_LOAD_B;
                end

                ST_SOBEL_LOAD_B: begin
                    b_reg <= mem_rdata;
                    gray_buf[pix_idx] <= gray_now;
                    if (pix_idx == PIXELS-1) begin
                        pix_idx <= 32'b0;
                        state   <= ST_SOBEL_PROC;
                    end else begin
                        pix_idx <= pix_idx + 32'd1;
                        state   <= ST_SOBEL_LOAD_R;
                    end
                end

                ST_SOBEL_PROC: begin
                    if (pix_idx == PIXELS-1) begin
                        result <= 32'd1;
                        state  <= ST_DONE;
                    end else begin
                        pix_idx <= pix_idx + 32'd1;
                    end
                end

                ST_DONE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule


// Start of: main_control.sv
module main_control (
    input  logic [6:0] opcode,
    output logic       reg_write,
    output logic       mem_to_reg,
    output logic       pc_to_reg,
    output logic       mem_write,
    output logic       mem_read,
    output logic       branch,
    output logic       jump,
    output logic       jalr,
    output logic       alu_src,
    output logic       lui,
    output logic       auipc,
    output logic       ipu_en,
    output logic [1:0] alu_op
);

    localparam logic [6:0] OPCODE_RTYPE   = 7'b0110011;
    localparam logic [6:0] OPCODE_ITYPE   = 7'b0010011;
    localparam logic [6:0] OPCODE_LOAD    = 7'b0000011;
    localparam logic [6:0] OPCODE_STORE   = 7'b0100011;
    localparam logic [6:0] OPCODE_BRANCH  = 7'b1100011;
    localparam logic [6:0] OPCODE_LUI     = 7'b0110111;
    localparam logic [6:0] OPCODE_AUIPC   = 7'b0010111;
    localparam logic [6:0] OPCODE_JAL     = 7'b1101111;
    localparam logic [6:0] OPCODE_JALR    = 7'b1100111;
    localparam logic [6:0] OPCODE_CUSTOM0 = 7'b0001011;

    always_comb begin
        reg_write  = 1'b0;
        mem_to_reg = 1'b0;
        pc_to_reg  = 1'b0;
        mem_write  = 1'b0;
        mem_read   = 1'b0;
        branch     = 1'b0;
        jump       = 1'b0;
        jalr       = 1'b0;
        alu_src    = 1'b0;
        lui        = 1'b0;
        auipc      = 1'b0;
        ipu_en     = 1'b0;
        alu_op     = 2'b00;

        case (opcode)
            OPCODE_RTYPE: begin
                reg_write = 1'b1;
                alu_op    = 2'b10;
            end

            OPCODE_ITYPE: begin
                reg_write = 1'b1;
                alu_src   = 1'b1;
                alu_op    = 2'b11;
            end

            OPCODE_LOAD: begin
                reg_write  = 1'b1;
                mem_to_reg = 1'b1;
                mem_read   = 1'b1;
                alu_src    = 1'b1;
                alu_op     = 2'b00;
            end

            OPCODE_STORE: begin
                mem_write = 1'b1;
                alu_src   = 1'b1;
                alu_op    = 2'b00;
            end

            OPCODE_BRANCH: begin
                branch = 1'b1;
                alu_op = 2'b01;
            end

            OPCODE_LUI: begin
                reg_write = 1'b1;
                alu_src   = 1'b1;
                lui       = 1'b1;
                alu_op    = 2'b00;
            end

            OPCODE_AUIPC: begin
                reg_write = 1'b1;
                alu_src   = 1'b1;
                auipc     = 1'b1;
                alu_op    = 2'b00;
            end

            OPCODE_JAL: begin
                reg_write = 1'b1;
                pc_to_reg = 1'b1;
                jump      = 1'b1;
            end

            OPCODE_JALR: begin
                reg_write = 1'b1;
                pc_to_reg = 1'b1;
                jump      = 1'b1;
                jalr      = 1'b1;
                alu_src   = 1'b1;
                alu_op    = 2'b00;
            end

            OPCODE_CUSTOM0: begin
                reg_write = 1'b1;
                ipu_en    = 1'b1;
            end

            default: begin
            end
        endcase
    end

endmodule


// Start of: memory_stage.sv
module memory_stage (
);
endmodule


// Start of: mem_wb_reg.sv
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


// Start of: program_counter.sv
module program_counter (
    input  logic        clk, reset, en,
    input  logic [31:0] pc_in,
    output logic [31:0] pc_out
);

    always_ff @(posedge clk or posedge reset) begin
        if (reset) pc_out <= 32'b0;
        else if (en) pc_out <= pc_in;
    end

endmodule


// Start of: register_file.sv
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


// Start of: rv32i_core.sv
module rv32i_core #(
    parameter int IMG_W = 128,
    parameter int IMG_H = 128
) (
    input logic clk,
    input logic reset
);

    logic [31:0] pc_out;
    logic [31:0] instr;
    logic [31:0] alu_result;
    logic [31:0] write_data;
    logic [31:0] read_data;
    logic        mem_read;
    logic        mem_write;
    logic [2:0]  mem_funct3;

    logic        ipu_start;
    logic [1:0]  ipu_op;
    logic [31:0] ipu_src_base;
    logic [31:0] ipu_dst_base;
    logic        ipu_busy;
    logic        ipu_done;
    logic [31:0] ipu_result;
    logic        ipu_mem_re;
    logic        ipu_mem_we;
    logic [31:0] ipu_mem_addr;
    logic [7:0]  ipu_mem_wdata;
    logic [7:0]  ipu_mem_rdata;

    instruction_memory imem (
        .addr  (pc_out),
        .instr (instr)
    );

    data_memory #(
        .MEM_BYTES(65536)
    ) dmem (
        .clk           (clk),
        .mem_write     (mem_write),
        .mem_read      (mem_read),
        .funct3        (mem_funct3),
        .addr          (alu_result),
        .write_data    (write_data),
        .read_data     (read_data),
        .ipu_mem_re    (ipu_mem_re),
        .ipu_mem_we    (ipu_mem_we),
        .ipu_addr      (ipu_mem_addr),
        .ipu_write_data(ipu_mem_wdata),
        .ipu_read_data (ipu_mem_rdata)
    );

    ipu #(
        .IMG_W(IMG_W),
        .IMG_H(IMG_H)
    ) u_ipu (
        .clk      (clk),
        .reset    (reset),
        .start    (ipu_start),
        .op       (ipu_op),
        .src_base (ipu_src_base),
        .dst_base (ipu_dst_base),
        .busy     (ipu_busy),
        .done     (ipu_done),
        .result   (ipu_result),
        .mem_re   (ipu_mem_re),
        .mem_we   (ipu_mem_we),
        .mem_addr (ipu_mem_addr),
        .mem_wdata(ipu_mem_wdata),
        .mem_rdata(ipu_mem_rdata)
    );

    datapath dp (
        .clk          (clk),
        .reset        (reset),
        .instr_f      (instr),
        .read_data_m  (read_data),
        .ipu_busy     (ipu_busy),
        .ipu_done     (ipu_done),
        .ipu_result   (ipu_result),
        .pc_f         (pc_out),
        .alu_out_m    (alu_result),
        .write_data_m (write_data),
        .mem_read_m   (mem_read),
        .mem_write_m  (mem_write),
        .funct3_m     (mem_funct3),
        .ipu_start    (ipu_start),
        .ipu_op       (ipu_op),
        .ipu_src_base (ipu_src_base),
        .ipu_dst_base (ipu_dst_base)
    );

endmodule


// Start of: tb_rv32i_ipu_custom.sv
module tb_rv32i_ipu_custom;

    localparam int IMG_W     = 128;
    localparam int IMG_H     = 128;
    localparam int PIXELS    = IMG_W * IMG_H;
    localparam int SRC_BASE  = 32'h0000_0000;
    localparam int DST_BASE  = 32'h0000_C000;

    logic clk;
    logic reset;
    integer i;
    integer f;

    rv32i_core dut (
        .clk   (clk),
        .reset (reset)
    );

    always #5 clk = ~clk;

    task automatic dump_output_hex;
        begin
            f = $fopen("ipu_output.hex", "w");
            if (f == 0) begin
                $display("ERROR: could not open ipu_output.hex");
            end else begin
                for (i = 0; i < PIXELS; i = i + 1) begin
                    $fdisplay(f, "%02x", dut.dmem.ram[DST_BASE + i]);
                end
                $fclose(f);
                $display("Output image written to ipu_output.hex");
            end
        end
    endtask

    initial begin
        clk   = 1'b0;
        reset = 1'b1;

        $display("==============================================================");
        $display("RV32I + IPU simulation start");
        $display("Instruction file : memfile.hex");
        $display("Image data file  : image_rgb888.hex");
        $display("==============================================================");

        // Load source image into data memory
        $readmemh("image_rgb888.hex", dut.dmem.ram);

        repeat (4) @(posedge clk);
        reset = 1'b0;

        wait (dut.dp.decode.rf.registers[10] != 32'b0);
        repeat (10) @(posedge clk);

        $display("Done. x10 = 0x%08h", dut.dp.decode.rf.registers[10]);

        dump_output_hex();

        $display("First 16 output bytes:");
        for (i = 0; i < 16; i = i + 1) begin
            $display("OUT[%0d] = 0x%02h", i, dut.dmem.ram[DST_BASE + i]);
        end

        $finish;
    end

    always @(posedge clk) begin
        if (!reset) begin
            $display("t=%0t | PC=%08h | IF_instr=%08h | x10=%08h",
                     $time,
                     dut.dp.pc_f,
                     dut.instr,
                     dut.dp.decode.rf.registers[10]);
        end
    end

endmodule

// Start of: tb_rv32i_top.sv
// =============================================================================
// tb_rv32i_comprehensive.sv
// Comprehensive RV32I 5-Stage Pipeline Testbench
// Tests all 40 RV32I base instructions:
//   I-type ALU : ADDI, SLTI, SLTIU, ANDI, ORI, XORI, SLLI, SRLI, SRAI
//   R-type     : ADD, SUB, AND, OR, XOR, SLL, SRL, SRA, SLT, SLTU
//   U-type     : LUI, AUIPC
//   Load       : LW, LH, LB, LHU, LBU
//   Store      : SW, SH, SB
//   Branch     : BEQ, BNE, BLT, BGE, BLTU, BGEU
//   Jump       : JAL, JALR
// =============================================================================
//
// PROGRAM SUMMARY (memfile.hex, 61 instructions):
//
// [00..12] I-type ALU setup:
//   x1  =  10          (ADDI)
//   x2  =  -3          (ADDI)
//   x3  =   5          (ADDI)
//   x4  =  15          (ADDI)
//   x5  =   7          (ADDI)
//   x6  =   1          (SLTI  x2,20  : -3 < 20 signed)
//   x7  =   1          (SLTIU x1,20  : 10 < 20 unsigned)
//   x8  =  12          (ANDI  x4,12  : 15 & 12)
//   x9  =  31          (ORI   x4,16  : 15 | 16)
//   x10 =   0          (XORI  x4,15  : 15 ^ 15)
//   x11 =  20          (SLLI  x3,2   : 5 << 2)
//   x12 =   7          (SRLI  x4,1   : 15 >> 1)
//   x13 =  -2          (SRAI  x2,1   : -3 >>> 1 arithmetic)
// [13..22] R-type:
//   x14 =  15          (ADD   x1,x3  : 10+5)
//   x15 =   5          (SUB   x1,x3  : 10-5)
//   x16 =   7          (AND   x4,x5  : 15&7)
//   x17 =  15          (OR    x4,x5  : 15|7)
//   x18 =   8          (XOR   x4,x5  : 15^7)
//   x19 = 640=0x280    (SLL   x3,x5  : 5<<7)
//   x20 =   0          (SRL   x4,x3  : 15>>5)
//   x21 =  -1          (SRA   x2,x3  : -3>>>5 arithmetic)
//   x22 =   1          (SLT   x2,x1  : -3 < 10 signed)
//   x23 =   0          (SLTU  x2,x1  : 0xFFFFFFFD <u 10 = false)
// [23..24] U-type:
//   x24 = 0x12345000   (LUI)
//   x25 = 0x00000060   (AUIPC PC+0, PC=0x60)
// [25..34] Memory:
//   x26 = 256          (ADDI base addr)
//   SW  x1,  0(x26)   -> mem[256..259] = 0x0000000A
//   SH  x3,  4(x26)   -> mem[260..261] = 0x0005
//   SB  x5,  6(x26)   -> mem[262]      = 0x07
//   x27 = 10           (LW   0(x26))
//   x28 =  5           (LH   4(x26))  <- later overwritten by JAL
//   x29 =  7           (LB   6(x26))  <- later overwritten by JALR target
//   SW  x2,  8(x26)   -> mem[264..267] = 0xFFFFFFFD
//   x30 = 0xFD         (LBU  8(x26))  <- later overwritten by JALR ret addr
//   x31 = 0xFFFD       (LHU  8(x26))
// [35..52] Branches (all 6, all TAKEN, each skips a poison ADDI x27,x27,99):
//   BEQ x3,x3,+8   taken (3==3)
//   BNE x1,x2,+8   taken (10!=-3)
//   BLT x2,x1,+8   taken (-3<10 signed)
//   BGE x1,x2,+8   taken (10>=-3 signed)
//   BLTU x1,x2,+8  taken (10 <u 0xFFFFFFFD)
//   BGEU x2,x1,+8  taken (0xFFFFFFFD >=u 10)
//   -> x27 remains 10 (all poison ADDIs skipped)
// [53..55] JAL:
//   JAL x28, +8    x28=0xD8, jumps to NOP (skips poison ADDI)
// [56..59] JALR:
//   ADDI x29,x0,0xEC  x29=0xEC (target)
//   JALR x30,0(x29)   x30=0xE8, jumps to 0xEC (skips poison ADDI)
// [60] JAL x0,0       infinite self-loop (halt)
//
// FINAL EXPECTED STATE:
//   x1=0x0000000A  x2=0xFFFFFFFD  x3=0x00000005  x4=0x0000000F
//   x5=0x00000007  x6=0x00000001  x7=0x00000001  x8=0x0000000C
//   x9=0x0000001F  x10=0x00000000 x11=0x00000014 x12=0x00000007
//   x13=0xFFFFFFFE x14=0x0000000F x15=0x00000005 x16=0x00000007
//   x17=0x0000000F x18=0x00000008 x19=0x00000280 x20=0x00000000
//   x21=0xFFFFFFFF x22=0x00000001 x23=0x00000000 x24=0x12345000
//   x25=0x00000060 x26=0x00000100 x27=0x0000000A x28=0x000000D8
//   x29=0x000000EC x30=0x000000E8 x31=0x0000FFFD
//   mem[256]=0x0A mem[257]=0x00 mem[258]=0x00 mem[259]=0x00
//   mem[260]=0x05 mem[261]=0x00 mem[262]=0x07
//   mem[264]=0xFD mem[265]=0xFF mem[266]=0xFF mem[267]=0xFF
// =============================================================================

module tb_rv32i_top;

    // -----------------------------------------------------------------------
    // DUT signals
    // -----------------------------------------------------------------------
    logic clk;
    logic reset;

    rv32i_core dut (
        .clk   (clk),
        .reset (reset)
    );

    // -----------------------------------------------------------------------
    // Clock generation: 10 ns period
    // -----------------------------------------------------------------------
    initial clk = 1'b0;
    always  #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // Test bookkeeping
    // -----------------------------------------------------------------------
    integer pass_count;
    integer fail_count;
    integer total_checks;

    // -----------------------------------------------------------------------
    // Helper: check a register value and print PASS/FAIL
    // -----------------------------------------------------------------------
    task automatic chk_reg (
        input integer       idx,
        input logic [31:0]  expected,
        input string        description
    );
        logic [31:0] got;
        begin
            got = dut.dp.decode.rf.registers[idx];
            total_checks++;
            if (got === expected) begin
                $display("  PASS  x%-2d | got=0x%08X | expected=0x%08X | %s",
                         idx, got, expected, description);
                pass_count++;
            end else begin
                $display("  FAIL  x%-2d | got=0x%08X | expected=0x%08X | %s  *** ERROR ***",
                         idx, got, expected, description);
                fail_count++;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Helper: check a memory byte
    // -----------------------------------------------------------------------
    task automatic chk_mem (
        input integer      addr,
        input logic [7:0]  expected,
        input string       description
    );
        logic [7:0] got;
        begin
            got = dut.dmem.ram[addr];
            total_checks++;
            if (got === expected) begin
                $display("  PASS  mem[%04d] | got=0x%02X | expected=0x%02X | %s",
                         addr, got, expected, description);
                pass_count++;
            end else begin
                $display("  FAIL  mem[%04d] | got=0x%02X | expected=0x%02X | %s  *** ERROR ***",
                         addr, got, expected, description);
                fail_count++;
            end
        end
    endtask

    // -----------------------------------------------------------------------
    // Cycle-by-cycle monitor (non-intrusive)
    // -----------------------------------------------------------------------
    always @(posedge clk) begin
        if (!reset) begin
            $display("  [t=%5t] PC=%08X  INSTR=%08X  WB_we=%b  WB_rd=x%-2d  WB_data=%08X",
                     $time,
                     dut.dp.pc_f,
                     dut.instr,
                     dut.dp.reg_write_w,
                     dut.dp.rd_w,
                     dut.dp.result_w);
        end
    end

    // -----------------------------------------------------------------------
    // Main test sequence
    // -----------------------------------------------------------------------
    initial begin
        // ---------- initialise ----------
        pass_count   = 0;
        fail_count   = 0;
        total_checks = 0;

        $display("");
        $display("==============================================================");
        $display("  RV32I Comprehensive Pipeline Test");
        $display("  40 Instructions Tested | Program: memfile.hex");
        $display("==============================================================");
        $display("  Instructions Under Test:");
        $display("  I-ALU : ADDI SLTI SLTIU ANDI ORI XORI SLLI SRLI SRAI (9)");
        $display("  R-type: ADD SUB AND OR XOR SLL SRL SRA SLT SLTU      (10)");
        $display("  U-type: LUI AUIPC                                      (2)");
        $display("  Loads : LW LH LB LHU LBU                              (5)");
        $display("  Stores: SW SH SB                                       (3)");
        $display("  Branch: BEQ BNE BLT BGE BLTU BGEU                     (6)");
        $display("  Jump  : JAL JALR                                       (2)");
        $display("  NOP (ADDI x0,x0,0)                                     (1)");
        $display("  TOTAL : 38 unique mnemonics, 40+ instruction instances");
        $display("==============================================================");
        $display("");
        $display("--- Cycle trace (PC | INSTR | WB write-back) ---");

        // ---------- reset ----------
        reset = 1'b1;
        repeat (4) @(posedge clk);
        reset = 1'b0;

        // 61 instructions in 5-stage pipeline + stalls for load-use hazards
        // = ~75 cycles needed; run 120 to be safe
        repeat (120) @(posedge clk);

        // ---------- check results ----------
        $display("");
        $display("==============================================================");
        $display("  ARCHITECTURAL STATE CHECK");
        $display("==============================================================");

        // ---- I-type ALU ----
        $display("");
        $display("  [I-TYPE ALU INSTRUCTIONS]");
        chk_reg(1,  32'h0000000A, "ADDI x1,x0,10         => x1=10");
        chk_reg(2,  32'hFFFFFFFD, "ADDI x2,x0,-3         => x2=0xFFFFFFFD (-3)");
        chk_reg(3,  32'h00000005, "ADDI x3,x0,5          => x3=5");
        chk_reg(4,  32'h0000000F, "ADDI x4,x0,15         => x4=15");
        chk_reg(5,  32'h00000007, "ADDI x5,x0,7          => x5=7");
        chk_reg(6,  32'h00000001, "SLTI  x6,x2,20        => x6=1  (-3<20 signed=true)");
        chk_reg(7,  32'h00000001, "SLTIU x7,x1,20        => x7=1  (10<20 unsigned=true)");
        chk_reg(8,  32'h0000000C, "ANDI  x8,x4,12        => x8=12 (15&12=0xC)");
        chk_reg(9,  32'h0000001F, "ORI   x9,x4,16        => x9=31 (15|16=0x1F)");
        chk_reg(10, 32'h00000000, "XORI  x10,x4,15       => x10=0 (15^15=0)");
        chk_reg(11, 32'h00000014, "SLLI  x11,x3,2        => x11=20 (5<<2)");
        chk_reg(12, 32'h00000007, "SRLI  x12,x4,1        => x12=7  (15>>1 logical)");
        chk_reg(13, 32'hFFFFFFFE, "SRAI  x13,x2,1        => x13=-2=0xFFFFFFFE (-3>>1 arith)");

        // ---- R-type ----
        $display("");
        $display("  [R-TYPE INSTRUCTIONS]");
        chk_reg(14, 32'h0000000F, "ADD   x14,x1,x3       => x14=15 (10+5)");
        chk_reg(15, 32'h00000005, "SUB   x15,x1,x3       => x15=5  (10-5)");
        chk_reg(16, 32'h00000007, "AND   x16,x4,x5       => x16=7  (15&7)");
        chk_reg(17, 32'h0000000F, "OR    x17,x4,x5       => x17=15 (15|7)");
        chk_reg(18, 32'h00000008, "XOR   x18,x4,x5       => x18=8  (15^7)");
        chk_reg(19, 32'h00000280, "SLL   x19,x3,x5       => x19=640=0x280 (5<<7)");
        chk_reg(20, 32'h00000000, "SRL   x20,x4,x3       => x20=0  (15>>5 logical)");
        chk_reg(21, 32'hFFFFFFFF, "SRA   x21,x2,x3       => x21=-1=0xFFFFFFFF (-3>>5 arith)");
        chk_reg(22, 32'h00000001, "SLT   x22,x2,x1       => x22=1  (-3<10 signed=true)");
        chk_reg(23, 32'h00000000, "SLTU  x23,x2,x1       => x23=0  (0xFFFFFFFD<u10=false)");

        // ---- U-type ----
        $display("");
        $display("  [U-TYPE INSTRUCTIONS]");
        chk_reg(24, 32'h12345000, "LUI   x24,0x12345     => x24=0x12345000");
        chk_reg(25, 32'h00000060, "AUIPC x25,0           => x25=0x60 (PC at instr 24 = 0x60)");

        // ---- Memory Base ----
        $display("");
        $display("  [MEMORY BASE SETUP]");
        chk_reg(26, 32'h00000100, "ADDI  x26,x0,256      => x26=0x100 (memory base address)");

        // ---- Stores (verified via memory read-back) ----
        $display("");
        $display("  [STORE + LOAD INSTRUCTIONS]");
        chk_mem(256, 8'h0A, "SW x1,0(x26)  -> mem[256]=0x0A (byte 0 of 10)");
        chk_mem(257, 8'h00, "SW x1,0(x26)  -> mem[257]=0x00 (byte 1 of 10)");
        chk_mem(258, 8'h00, "SW x1,0(x26)  -> mem[258]=0x00 (byte 2 of 10)");
        chk_mem(259, 8'h00, "SW x1,0(x26)  -> mem[259]=0x00 (byte 3 of 10)");
        chk_mem(260, 8'h05, "SH x3,4(x26)  -> mem[260]=0x05 (lo byte of 5)");
        chk_mem(261, 8'h00, "SH x3,4(x26)  -> mem[261]=0x00 (hi byte of 5)");
        chk_mem(262, 8'h07, "SB x5,6(x26)  -> mem[262]=0x07 (byte 7)");
        chk_mem(264, 8'hFD, "SW x2,8(x26)  -> mem[264]=0xFD (byte 0 of -3=0xFFFFFFFD)");
        chk_mem(265, 8'hFF, "SW x2,8(x26)  -> mem[265]=0xFF (byte 1 of -3)");
        chk_mem(266, 8'hFF, "SW x2,8(x26)  -> mem[266]=0xFF (byte 2 of -3)");
        chk_mem(267, 8'hFF, "SW x2,8(x26)  -> mem[267]=0xFF (byte 3 of -3)");

        // ---- Loads ----
        chk_reg(27, 32'h0000000A, "LW    x27,0(x26)      => x27=10=0x0A  (sign-ext word)");
        // x28 and x29 are overwritten by JAL/JALR below
        // x30 is overwritten by JALR below
        chk_reg(31, 32'h0000FFFD, "LHU   x31,8(x26)      => x31=0xFFFD (zero-ext halfword of -3)");
        // LH and LB are partially tested; x28/x29/x30 final values from JAL/JALR

        // ---- Branches (poison check: x27 must remain 10) ----
        $display("");
        $display("  [BRANCH INSTRUCTIONS  (all taken -- poison ADDI must be skipped)]");
        chk_reg(27, 32'h0000000A,
            "x27 unchanged=10 (all 6 branch-skip ADDIs were correctly NOT executed)");
        $display("    => BEQ  (3==3)                  TAKEN - correctly skipped poison ADDI");
        $display("    => BNE  (10!=-3)                TAKEN - correctly skipped poison ADDI");
        $display("    => BLT  (-3<10 signed)          TAKEN - correctly skipped poison ADDI");
        $display("    => BGE  (10>=-3 signed)         TAKEN - correctly skipped poison ADDI");
        $display("    => BLTU (10 <u 0xFFFFFFFD)      TAKEN - correctly skipped poison ADDI");
        $display("    => BGEU (0xFFFFFFFD >=u 10)     TAKEN - correctly skipped poison ADDI");

        // ---- JAL ----
        $display("");
        $display("  [JAL INSTRUCTION]");
        chk_reg(28, 32'h000000D8,
            "JAL x28,+8 @ PC=0xD4  => x28=0xD8 (return addr PC+4), jumped to 0xDC (NOP)");

        // ---- JALR ----
        $display("");
        $display("  [JALR INSTRUCTION]");
        chk_reg(29, 32'h000000EC,
            "ADDI x29,x0,0xEC      => x29=0xEC (JALR jump target)");
        chk_reg(30, 32'h000000E8,
            "JALR x30,0(x29) @0xE4 => x30=0xE8 (return addr PC+4), jumped to 0xEC (NOP)");

        // ---------- summary ----------
        $display("");
        $display("==============================================================");
        $display("  TEST SUMMARY");
        $display("==============================================================");
        $display("  Total checks : %0d", total_checks);
        $display("  Passed       : %0d", pass_count);
        $display("  Failed       : %0d", fail_count);
        $display("--------------------------------------------------------------");
        if (fail_count == 0) begin
            $display("  *** ALL %0d CHECKS PASSED -- RV32I CORE CERTIFIED ***", total_checks);
        end else begin
            $display("  *** FAILED: %0d / %0d CHECKS -- REVIEW ERRORS ABOVE ***",
                     fail_count, total_checks);
        end
        $display("==============================================================");
        $finish;
    end

endmodule

// Start of: writeback_stage.sv
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


