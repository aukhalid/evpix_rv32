// rv32i_core_fpga.sv
// EVPIX-RV32 FPGA wrapper, V6.
// Adds passive hardware-regression visibility without changing the RV32I/IPU datapath algorithm.

module rv32i_core_fpga #(
    parameter int IMG_W = 128,
    parameter int IMG_H = 128
) (
    input  logic clk,
    input  logic reset,

    input  logic [2:0]  program_id,          // 0=SOBEL,1=GRAY,2=THRESH,3=CONV_IDENTITY
    input  logic        cpu_regression_mode, // 1=run exact RV32I baseline memfile ROM

    input  logic        host_we,
    input  logic [31:0] host_addr,
    input  logic [7:0]  host_wdata,

    output logic        proc_we,
    output logic [31:0] proc_addr,
    output logic [7:0]  proc_wdata,

    output logic [31:0] debug_pc,
    output logic [31:0] debug_instr,
    output logic        debug_ipu_busy,
    output logic        debug_ipu_done,
    output logic [31:0] debug_ipu_result,
    output logic [31:0] debug_cycle_counter,
    output logic [31:0] perf_ipu_busy_count,
    output logic [31:0] perf_conv_count,
    output logic [31:0] perf_pool_count,
    output logic [31:0] perf_stall_count,

    // Hardware regression result/output table
    output logic        bist_done,
    output logic        bist_pass,
    output logic [5:0]  bist_fail_count,
    output logic [31:0] bist_reg_got [0:31],
    output logic [7:0]  bist_mem_got [0:10]
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

    logic        debug_wb_we;
    logic [4:0]  debug_wb_rd;
    logic [31:0] debug_wb_data;
    logic [31:0] debug_reg_snapshot [0:31];

    instruction_memory_fpga imem (
        .addr                (pc_out),
        .program_id          (program_id),
        .cpu_regression_mode (cpu_regression_mode),
        .instr               (instr)
    );

    data_memory_fpga #(
        .MEM_BYTES(65536)
    ) dmem (
        .clk            (clk),
        .reset          (reset),
        .mem_write      (mem_write),
        .mem_read       (mem_read),
        .funct3         (mem_funct3),
        .addr           (alu_result),
        .write_data     (write_data),
        .read_data      (read_data),
        .ipu_mem_re     (ipu_mem_re),
        .ipu_mem_we     (ipu_mem_we),
        .ipu_addr       (ipu_mem_addr),
        .ipu_write_data (ipu_mem_wdata),
        .ipu_read_data  (ipu_mem_rdata),
        .host_we        (host_we),
        .host_addr      (host_addr),
        .host_wdata     (host_wdata),
        .mmio_status    (),
        .mmio_valid     ()
    );

    ipu_fpga #(
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
        .stall_pulse  (stall_pulse),
        .debug_wb_we  (debug_wb_we),
        .debug_wb_rd  (debug_wb_rd),
        .debug_wb_data(debug_wb_data),
        .debug_reg_snapshot(debug_reg_snapshot)
    );

    assign proc_we    = ipu_mem_we;
    assign proc_addr  = ipu_mem_addr;
    assign proc_wdata = ipu_mem_wdata;

    assign debug_pc            = pc_out;
    assign debug_instr         = instr;
    assign debug_ipu_busy      = ipu_busy;
    assign debug_ipu_done      = ipu_done;
    assign debug_ipu_result    = ipu_result;
    assign debug_cycle_counter = cycle_counter;
    assign perf_ipu_busy_count = ipu_busy_counter;
    assign perf_conv_count     = ipu_conv_cycles;
    assign perf_pool_count     = ipu_pool_cycles;
    assign perf_stall_count    = stall_counter;

    // ------------------------------------------------------------------
    // Passive hardware-regression scoreboard, v11 LUT-safe edition.
    //
    // Previous versions kept a 32-register shadow and a 512-byte memory shadow.
    // The full shadows were display/debug convenience only and consumed a large
    // amount of LUT/FF/reset logic. The BIST table only needs:
    //   - actual architectural registers from debug_reg_snapshot
    //   - 11 observed memory bytes at addresses 0x100..0x10B subset
    //
    // This keeps the same BIST behavior and table contents while removing the
    // unused 512-byte shadow RAM and 32x32 register shadow.
    // ------------------------------------------------------------------

    function automatic logic [3:0] bist_mem_index(input logic [31:0] a);
        begin
            unique case (a)
                32'd256: bist_mem_index = 4'd0;
                32'd257: bist_mem_index = 4'd1;
                32'd258: bist_mem_index = 4'd2;
                32'd259: bist_mem_index = 4'd3;
                32'd260: bist_mem_index = 4'd4;
                32'd261: bist_mem_index = 4'd5;
                32'd262: bist_mem_index = 4'd6;
                32'd264: bist_mem_index = 4'd7;
                32'd265: bist_mem_index = 4'd8;
                32'd266: bist_mem_index = 4'd9;
                32'd267: bist_mem_index = 4'd10;
                default: bist_mem_index = 4'd15;
            endcase
        end
    endfunction

    task automatic update_bist_byte(input logic [31:0] a, input logic [7:0] d);
        logic [3:0] idx;
        begin
            idx = bist_mem_index(a);
            if (idx != 4'd15)
                bist_mem_got[idx] <= d;
        end
    endtask

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            for (int i = 0; i < 11; i = i + 1)
                bist_mem_got[i] <= 8'd0;
        end else if (cpu_regression_mode && mem_write) begin
            unique case (mem_funct3)
                3'b000: begin // SB
                    update_bist_byte(alu_result, write_data[7:0]);
                end
                3'b001: begin // SH
                    update_bist_byte(alu_result,          write_data[7:0]);
                    update_bist_byte(alu_result + 32'd1, write_data[15:8]);
                end
                3'b010: begin // SW
                    update_bist_byte(alu_result,          write_data[7:0]);
                    update_bist_byte(alu_result + 32'd1, write_data[15:8]);
                    update_bist_byte(alu_result + 32'd2, write_data[23:16]);
                    update_bist_byte(alu_result + 32'd3, write_data[31:24]);
                end
                default: ;
            endcase
        end
    end

    genvar gi;
    generate
        for (gi = 0; gi < 32; gi = gi + 1) begin : G_BIST_REG_OUT
            // Use actual architectural register-file contents for the BIST table.
            assign bist_reg_got[gi] = debug_reg_snapshot[gi];
        end
    endgenerate

    function automatic logic [31:0] expected_reg(input int idx);
        begin
            unique case (idx)
                1:  expected_reg = 32'h0000000A;  2:  expected_reg = 32'hFFFFFFFD;
                3:  expected_reg = 32'h00000005;  4:  expected_reg = 32'h0000000F;
                5:  expected_reg = 32'h00000007;  6:  expected_reg = 32'h00000001;
                7:  expected_reg = 32'h00000001;  8:  expected_reg = 32'h0000000C;
                9:  expected_reg = 32'h0000001F; 10:  expected_reg = 32'h00000000;
                11: expected_reg = 32'h00000014; 12:  expected_reg = 32'h00000007;
                13: expected_reg = 32'hFFFFFFFE; 14:  expected_reg = 32'h0000000F;
                15: expected_reg = 32'h00000005; 16:  expected_reg = 32'h00000007;
                17: expected_reg = 32'h0000000F; 18:  expected_reg = 32'h00000008;
                19: expected_reg = 32'h00000280; 20:  expected_reg = 32'h00000000;
                21: expected_reg = 32'hFFFFFFFF; 22:  expected_reg = 32'h00000001;
                23: expected_reg = 32'h00000000; 24:  expected_reg = 32'h12345000;
                25: expected_reg = 32'h00000060; 26:  expected_reg = 32'h00000100;
                27: expected_reg = 32'h0000000A; 28:  expected_reg = 32'h000000C0;
                29: expected_reg = 32'h000000EC; 30:  expected_reg = 32'h000000D0;
                31: expected_reg = 32'h0000FFFD;
                default: expected_reg = 32'h00000000;
            endcase
        end
    endfunction

    function automatic logic [7:0] expected_mem(input int k);
        begin
            unique case (k)
                0: expected_mem = 8'h0A; 1: expected_mem = 8'h00; 2: expected_mem = 8'h00;
                3: expected_mem = 8'h00; 4: expected_mem = 8'h05; 5: expected_mem = 8'h00;
                6: expected_mem = 8'h07; 7: expected_mem = 8'hFD; 8: expected_mem = 8'hFF;
                9: expected_mem = 8'hFF; 10: expected_mem = 8'hFF;
                default: expected_mem = 8'h00;
            endcase
        end
    endfunction

    // v11 LUT-safe BIST checker:
    // Compare one register/memory item per clock instead of building a large
    // parallel 31x32-bit comparator tree. The visible result is the same; BIST
    // simply becomes valid a few dozen cycles after the 1000-cycle settle point.
    logic        bist_checking;
    logic [5:0]  bist_check_idx;
    logic [5:0]  bist_fail_accum;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            bist_done       <= 1'b0;
            bist_pass       <= 1'b0;
            bist_fail_count <= 6'd0;
            bist_checking   <= 1'b0;
            bist_check_idx  <= 6'd0;
            bist_fail_accum <= 6'd0;
        end else if (!cpu_regression_mode) begin
            bist_done       <= 1'b0;
            bist_pass       <= 1'b0;
            bist_fail_count <= 6'd0;
            bist_checking   <= 1'b0;
            bist_check_idx  <= 6'd0;
            bist_fail_accum <= 6'd0;
        end else begin
            if (!bist_done && !bist_checking && (cycle_counter >= 32'd1000)) begin
                bist_checking   <= 1'b1;
                bist_check_idx  <= 6'd1;   // x1 first; x0 is hardwired zero
                bist_fail_accum <= 6'd0;
            end else if (bist_checking) begin
                if (bist_check_idx <= 6'd31) begin
                    if (bist_reg_got[bist_check_idx[4:0]] !== expected_reg(bist_check_idx))
                        bist_fail_accum <= bist_fail_accum + 6'd1;
                    bist_check_idx <= bist_check_idx + 6'd1;
                end else if (bist_check_idx <= 6'd42) begin
                    if (bist_mem_got[bist_check_idx - 6'd32] !== expected_mem(bist_check_idx - 6'd32))
                        bist_fail_accum <= bist_fail_accum + 6'd1;
                    bist_check_idx <= bist_check_idx + 6'd1;
                end else begin
                    bist_checking   <= 1'b0;
                    bist_done       <= 1'b1;
                    bist_fail_count <= bist_fail_accum;
                    bist_pass       <= (bist_fail_accum == 6'd0);
                end
            end
        end
    end

endmodule
