module instruction_memory #(
    parameter string MEMFILE = "memfile_pix.hex"
) (
    input  logic [31:0] addr,
    output logic [31:0] instr
);

    logic [31:0] rom [0:1023];

    initial begin
        $readmemh(MEMFILE, rom);
    end

    assign instr = rom[addr[31:2]];

endmodule
