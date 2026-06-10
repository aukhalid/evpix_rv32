// ============================================================
// File: rv32i_core_asic_extmem.sv
// EVPIX-RV32 ASIC wrapper with external frame/data memory ports.
// ============================================================
// Purpose:
//   ASIC flows should not infer the 64 KiB FPGA BRAM frame memory as standard
//   cells. This wrapper preserves the RV32I datapath, IPU, instruction ROM,
//   custom-instruction interface, performance counters, and BIST checker, but
//   exposes CPU/IPU/host memory transactions as ports so they can connect to
//   SRAM macros or a bus wrapper in physical design.
//
//   Algorithms and CPU/IPU architecture are unchanged. Only FPGA BRAM has been
//   replaced by ASIC memory interfaces.

module rv32i_core_asic_extmem #(
    parameter int IMG_W = 128,
    parameter int IMG_H = 128
) (
    input  logic clk,
    input  logic reset,

    input  logic [2:0]  program_id,
    input  logic        cpu_regression_mode,

    // Host/camera RGB888 source-frame write stream. In ASIC this should connect
    // to the external/source-frame SRAM write port or a memory arbiter.
    input  logic        host_we,
    input  logic [31:0] host_addr,
    input  logic [7:0]  host_wdata,
    output logic        host_mem_we,
    output logic [31:0] host_mem_addr,
    output logic [7:0]  host_mem_wdata,

    // CPU data-memory interface. Existing pipeline expects read_data to be valid
    // when the MEM/WB register samples it. For ASIC macro integration, either
    // use a small single-cycle BIST SRAM/bypass for low addresses or insert the
    // same timing assumption in the memory wrapper.
    output logic        cpu_mem_read,
    output logic        cpu_mem_write,
    output logic [2:0]  cpu_mem_funct3,
    output logic [31:0] cpu_mem_addr,
    output logic [31:0] cpu_mem_wdata,
    input  logic [31:0] cpu_mem_rdata,

    // IPU byte memory interface. IPU expects one-cycle read latency.
    output logic        ipu_mem_re,
    output logic        ipu_mem_we,
    output logic [31:0] ipu_mem_addr,
    output logic [7:0]  ipu_mem_wdata,
    input  logic [7:0]  ipu_mem_rdata,

    // Processed output mirror, identical to the FPGA proc_* tap.
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

    output logic        bist_done,
    output logic        bist_pass,
    output logic [5:0]  bist_fail_count,

    // v11 ASIC debug/table interface. Read x0..x31 or memory test bytes one
    // entry at a time instead of exporting a 1024-bit bus.
    input  logic [5:0]  bist_debug_index,
    output logic [31:0] bist_debug_value,
    output logic [87:0] bist_mem_got_flat
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

    logic [31:0] cycle_counter;
    logic [31:0] ipu_busy_counter;
    logic [31:0] stall_counter;
    logic        stall_pulse;

    logic        debug_wb_we;
    logic [4:0]  debug_wb_rd;
    logic [31:0] debug_wb_data;
    logic [4:0]  debug_reg_sel;
    logic [31:0] debug_reg_value;
    logic [87:0]   bist_mem_got_r;


    instruction_memory_fpga imem (
        .addr                (pc_out),
        .program_id          (program_id),
        .cpu_regression_mode (cpu_regression_mode),
        .instr               (instr)
    );

    assign host_mem_we    = host_we;
    assign host_mem_addr  = host_addr;
    assign host_mem_wdata = host_wdata;

    assign cpu_mem_read   = mem_read;
    assign cpu_mem_write  = mem_write;
    assign cpu_mem_funct3 = mem_funct3;
    assign cpu_mem_addr   = alu_result;
    assign cpu_mem_wdata  = write_data;
    assign read_data      = cpu_mem_rdata;

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

    always_ff @(posedge clk) begin
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
        .debug_reg_sel(debug_reg_sel),
        .debug_wb_we  (debug_wb_we),
        .debug_wb_rd  (debug_wb_rd),
        .debug_wb_data(debug_wb_data),
        .debug_reg_value(debug_reg_value)
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
    // ASIC/Yosys-safe BIST memory scoreboard.
    //
    // Earlier versions used an unpacked byte array plus a task that wrote
    // bist_mem_got[idx]. Some Yosys/OpenROAD versions fail width inference for
    // that style during canonicalization. This version keeps the same BIST
    // behavior but stores the eleven observed BIST bytes in one packed 88-bit
    // vector and writes only constant slices.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (reset) begin
            bist_mem_got_r <= 88'd0;
        end else if (cpu_regression_mode && mem_write) begin
            unique case (mem_funct3)
                3'b000: begin // SB
                    unique case (alu_result)
                        32'd256: bist_mem_got_r[7:0]    <= write_data[7:0];
                        32'd257: bist_mem_got_r[15:8]   <= write_data[7:0];
                        32'd258: bist_mem_got_r[23:16]  <= write_data[7:0];
                        32'd259: bist_mem_got_r[31:24]  <= write_data[7:0];
                        32'd260: bist_mem_got_r[39:32]  <= write_data[7:0];
                        32'd261: bist_mem_got_r[47:40]  <= write_data[7:0];
                        32'd262: bist_mem_got_r[55:48]  <= write_data[7:0];
                        32'd264: bist_mem_got_r[63:56]  <= write_data[7:0];
                        32'd265: bist_mem_got_r[71:64]  <= write_data[7:0];
                        32'd266: bist_mem_got_r[79:72]  <= write_data[7:0];
                        32'd267: bist_mem_got_r[87:80]  <= write_data[7:0];
                        default: ;
                    endcase
                end

                3'b001: begin // SH, little-endian, BIST-visible addresses only
                    unique case (alu_result)
                        32'd256: begin
                            bist_mem_got_r[7:0]   <= write_data[7:0];
                            bist_mem_got_r[15:8]  <= write_data[15:8];
                        end
                        32'd258: begin
                            bist_mem_got_r[23:16] <= write_data[7:0];
                            bist_mem_got_r[31:24] <= write_data[15:8];
                        end
                        32'd260: begin
                            bist_mem_got_r[39:32] <= write_data[7:0];
                            bist_mem_got_r[47:40] <= write_data[15:8];
                        end
                        32'd264: begin
                            bist_mem_got_r[63:56] <= write_data[7:0];
                            bist_mem_got_r[71:64] <= write_data[15:8];
                        end
                        32'd266: begin
                            bist_mem_got_r[79:72] <= write_data[7:0];
                            bist_mem_got_r[87:80] <= write_data[15:8];
                        end
                        default: ;
                    endcase
                end

                3'b010: begin // SW, little-endian, BIST-visible addresses only
                    unique case (alu_result)
                        32'd256: begin
                            bist_mem_got_r[7:0]   <= write_data[7:0];
                            bist_mem_got_r[15:8]  <= write_data[15:8];
                            bist_mem_got_r[23:16] <= write_data[23:16];
                            bist_mem_got_r[31:24] <= write_data[31:24];
                        end
                        32'd260: begin
                            bist_mem_got_r[39:32] <= write_data[7:0];
                            bist_mem_got_r[47:40] <= write_data[15:8];
                            bist_mem_got_r[55:48] <= write_data[23:16];
                            // Address 263 is not displayed in the 11-byte BIST table.
                        end
                        32'd264: begin
                            bist_mem_got_r[63:56] <= write_data[7:0];
                            bist_mem_got_r[71:64] <= write_data[15:8];
                            bist_mem_got_r[79:72] <= write_data[23:16];
                            bist_mem_got_r[87:80] <= write_data[31:24];
                        end
                        default: ;
                    endcase
                end

                default: ;
            endcase
        end
    end

    assign bist_mem_got_flat = bist_mem_got_r;

    logic        bist_checking;
    logic [5:0]  bist_check_idx;
    logic [5:0]  bist_fail_accum;

    // Select register debug source. During the sequential BIST checker the
    // index comes from bist_check_idx; otherwise external debug can read a table
    // entry by driving bist_debug_index.
    assign debug_reg_sel = (bist_checking && (bist_check_idx <= 6'd31))
                         ? bist_check_idx[4:0]
                         : bist_debug_index[4:0];

    function automatic logic [31:0] get_bist_reg(input logic [4:0] idx);
        begin
            // debug_reg_sel is already driven by idx while the checker is active.
            // idx is kept in the signature to preserve the original checker code
            // structure and readability.
            get_bist_reg = debug_reg_value;
        end
    endfunction

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
                17: expected_reg = 32'h0000000F; 18: expected_reg = 32'h00000008;
                19: expected_reg = 32'h00000280; 20: expected_reg = 32'h00000000;
                21: expected_reg = 32'hFFFFFFFF; 22: expected_reg = 32'h00000001;
                23: expected_reg = 32'h00000000; 24: expected_reg = 32'h12345000;
                25: expected_reg = 32'h00000060; 26: expected_reg = 32'h00000100;
                27: expected_reg = 32'h0000000A; 28: expected_reg = 32'h000000C0;
                29: expected_reg = 32'h000000EC; 30: expected_reg = 32'h000000D0;
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

    function automatic logic [7:0] get_bist_mem(input logic [3:0] idx);
        begin
            unique case (idx)
                4'd0:  get_bist_mem = bist_mem_got_r[7:0];
                4'd1:  get_bist_mem = bist_mem_got_r[15:8];
                4'd2:  get_bist_mem = bist_mem_got_r[23:16];
                4'd3:  get_bist_mem = bist_mem_got_r[31:24];
                4'd4:  get_bist_mem = bist_mem_got_r[39:32];
                4'd5:  get_bist_mem = bist_mem_got_r[47:40];
                4'd6:  get_bist_mem = bist_mem_got_r[55:48];
                4'd7:  get_bist_mem = bist_mem_got_r[63:56];
                4'd8:  get_bist_mem = bist_mem_got_r[71:64];
                4'd9:  get_bist_mem = bist_mem_got_r[79:72];
                4'd10: get_bist_mem = bist_mem_got_r[87:80];
                default: get_bist_mem = 8'd0;
            endcase
        end
    endfunction


    always_comb begin
        if (bist_debug_index < 6'd32) begin
            bist_debug_value = debug_reg_value;
        end else begin
            unique case (bist_debug_index - 6'd32)
                6'd0:  bist_debug_value = {24'd0, bist_mem_got_r[7:0]};
                6'd1:  bist_debug_value = {24'd0, bist_mem_got_r[15:8]};
                6'd2:  bist_debug_value = {24'd0, bist_mem_got_r[23:16]};
                6'd3:  bist_debug_value = {24'd0, bist_mem_got_r[31:24]};
                6'd4:  bist_debug_value = {24'd0, bist_mem_got_r[39:32]};
                6'd5:  bist_debug_value = {24'd0, bist_mem_got_r[47:40]};
                6'd6:  bist_debug_value = {24'd0, bist_mem_got_r[55:48]};
                6'd7:  bist_debug_value = {24'd0, bist_mem_got_r[63:56]};
                6'd8:  bist_debug_value = {24'd0, bist_mem_got_r[71:64]};
                6'd9:  bist_debug_value = {24'd0, bist_mem_got_r[79:72]};
                6'd10: bist_debug_value = {24'd0, bist_mem_got_r[87:80]};
                default: bist_debug_value = 32'd0;
            endcase
        end
    end

    always_ff @(posedge clk) begin
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
                bist_check_idx  <= 6'd1;
                bist_fail_accum <= 6'd0;
            end else if (bist_checking) begin
                if (bist_check_idx <= 6'd31) begin
                    if (get_bist_reg(bist_check_idx[4:0]) !== expected_reg(bist_check_idx))
                        bist_fail_accum <= bist_fail_accum + 6'd1;
                    bist_check_idx <= bist_check_idx + 6'd1;
                end else if (bist_check_idx <= 6'd42) begin
                    if (get_bist_mem(bist_check_idx - 6'd32) !== expected_mem(bist_check_idx - 6'd32))
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
