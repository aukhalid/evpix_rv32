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
