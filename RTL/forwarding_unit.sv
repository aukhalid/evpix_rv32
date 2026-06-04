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
