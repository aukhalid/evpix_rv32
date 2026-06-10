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
