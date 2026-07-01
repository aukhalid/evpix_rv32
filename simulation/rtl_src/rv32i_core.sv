module rv32i_core #(
    parameter int IMG_W = 128,
    parameter int IMG_H = 128,
    parameter string MEMFILE = "memfile_pix.hex"
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
    logic [2:0]  ipu_op;
    logic [3:0]  ipu_kernel;
    logic [31:0] ipu_src_base;
    logic [31:0] ipu_dst_base;
    logic        ipu_busy;
    logic        ipu_done;
    logic [31:0] ipu_result;
    logic [31:0] ipu_conv_cycles;
    logic [31:0] ipu_pool_cycles;
    logic        ipu_mem_re;
    logic        ipu_mem_we;
    logic [31:0] ipu_mem_addr;
    logic [7:0]  ipu_mem_wdata;
    logic [7:0]  ipu_mem_rdata;

    logic [31:0] cycle_counter;
    logic [31:0] ipu_busy_counter;
    logic [31:0] stall_counter;
    logic        stall_pulse;

    instruction_memory #(
        .MEMFILE(MEMFILE)
    ) imem (
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
        .kernel   (ipu_kernel),
        .src_base (ipu_src_base),
        .dst_base (ipu_dst_base),
        .busy     (ipu_busy),
        .done     (ipu_done),
        .result   (ipu_result),
        .conv_cycle_count (ipu_conv_cycles),
        .pool_cycle_count (ipu_pool_cycles),
        .mem_re   (ipu_mem_re),
        .mem_we   (ipu_mem_we),
        .mem_addr (ipu_mem_addr),
        .mem_wdata(ipu_mem_wdata),
        .mem_rdata(ipu_mem_rdata)
    );

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            cycle_counter    <= 32'b0;
            ipu_busy_counter <= 32'b0;
            stall_counter    <= 32'b0;
        end else begin
            cycle_counter <= cycle_counter + 32'd1;
            if (ipu_busy)
                ipu_busy_counter <= ipu_busy_counter + 32'd1;
            if (stall_pulse)
                stall_counter <= stall_counter + 32'd1;
        end
    end

    datapath dp (
        .clk          (clk),
        .reset        (reset),
        .instr_f      (instr),
        .read_data_m  (read_data),
        .ipu_busy     (ipu_busy),
        .ipu_done     (ipu_done),
        .ipu_result   (ipu_result),
        .perf_cycle_count    (cycle_counter),
        .perf_ipu_busy_count (ipu_busy_counter),
        .perf_conv_count     (ipu_conv_cycles),
        .perf_pool_count     (ipu_pool_cycles),
        .perf_stall_count    (stall_counter),
        .pc_f         (pc_out),
        .alu_out_m    (alu_result),
        .write_data_m (write_data),
        .mem_read_m   (mem_read),
        .mem_write_m  (mem_write),
        .funct3_m     (mem_funct3),
        .ipu_start    (ipu_start),
        .ipu_op       (ipu_op),
        .ipu_kernel   (ipu_kernel),
        .ipu_src_base (ipu_src_base),
        .ipu_dst_base (ipu_dst_base),
        .stall_pulse  (stall_pulse)
    );

endmodule
