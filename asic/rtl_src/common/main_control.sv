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
