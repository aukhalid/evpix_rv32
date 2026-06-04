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
