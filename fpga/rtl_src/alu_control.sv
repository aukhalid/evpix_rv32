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
