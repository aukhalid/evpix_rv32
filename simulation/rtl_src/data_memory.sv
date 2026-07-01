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
