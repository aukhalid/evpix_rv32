// ============================================================
// File: evpix_asic_core_top.sv
// Top for OpenROAD ASIC implementation of the EVPIX digital core.
// ============================================================
// This is the recommended ASIC physical-design top. It preserves the EVPIX CPU,
// IPU, custom instructions, BIST checker/table values, performance counters, and
// TinyML finger counter. FPGA-only OV7670 SCCB/VGA renderer/pad behavior is not
// synthesized here; camera frames enter as a host RGB888 byte stream and display
// output should be handled by a system wrapper or FPGA demo board.

module evpix_asic_core_top #(
    parameter int IMG_W = 128,
    parameter int IMG_H = 128
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic [2:0]  program_id,
    input  logic        cpu_regression_mode,
    input  logic        ml_mode,

    // RGB888 frame stream from camera front-end/system wrapper.
    input  logic        host_we,
    input  logic [31:0] host_addr,
    input  logic [7:0]  host_wdata,
    input  logic        host_frame_done,

    // External memory interfaces for ASIC SRAM macro/bus wrapper.
    output logic        host_mem_we,
    output logic [31:0] host_mem_addr,
    output logic [7:0]  host_mem_wdata,

    output logic        cpu_mem_read,
    output logic        cpu_mem_write,
    output logic [2:0]  cpu_mem_funct3,
    output logic [31:0] cpu_mem_addr,
    output logic [31:0] cpu_mem_wdata,
    input  logic [31:0] cpu_mem_rdata,

    output logic        ipu_mem_re,
    output logic        ipu_mem_we,
    output logic [31:0] ipu_mem_addr,
    output logic [7:0]  ipu_mem_wdata,
    input  logic [7:0]  ipu_mem_rdata,

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
    input  logic [5:0]  bist_debug_index,
    output logic [31:0] bist_debug_value,
    output logic [87:0] bist_mem_got_flat,

    output logic        ml_result_valid,
    output logic [2:0]  ml_finger_count,
    output logic [7:0]  ml_confidence,
    output logic [15:0] ml_debug_skin_count,
    output logic [7:0]  ml_debug_peak_count
);

    logic reset;
    assign reset = ~rst_n;

    rv32i_core_asic_extmem #(
        .IMG_W(IMG_W),
        .IMG_H(IMG_H)
    ) u_core (
        .clk(clk),
        .reset(reset),
        .program_id(program_id),
        .cpu_regression_mode(cpu_regression_mode),
        .host_we(host_we),
        .host_addr(host_addr),
        .host_wdata(host_wdata),
        .host_mem_we(host_mem_we),
        .host_mem_addr(host_mem_addr),
        .host_mem_wdata(host_mem_wdata),
        .cpu_mem_read(cpu_mem_read),
        .cpu_mem_write(cpu_mem_write),
        .cpu_mem_funct3(cpu_mem_funct3),
        .cpu_mem_addr(cpu_mem_addr),
        .cpu_mem_wdata(cpu_mem_wdata),
        .cpu_mem_rdata(cpu_mem_rdata),
        .ipu_mem_re(ipu_mem_re),
        .ipu_mem_we(ipu_mem_we),
        .ipu_mem_addr(ipu_mem_addr),
        .ipu_mem_wdata(ipu_mem_wdata),
        .ipu_mem_rdata(ipu_mem_rdata),
        .proc_we(proc_we),
        .proc_addr(proc_addr),
        .proc_wdata(proc_wdata),
        .debug_pc(debug_pc),
        .debug_instr(debug_instr),
        .debug_ipu_busy(debug_ipu_busy),
        .debug_ipu_done(debug_ipu_done),
        .debug_ipu_result(debug_ipu_result),
        .debug_cycle_counter(debug_cycle_counter),
        .perf_ipu_busy_count(perf_ipu_busy_count),
        .perf_conv_count(perf_conv_count),
        .perf_pool_count(perf_pool_count),
        .perf_stall_count(perf_stall_count),
        .bist_done(bist_done),
        .bist_pass(bist_pass),
        .bist_fail_count(bist_fail_count),
        .bist_debug_index(bist_debug_index),
        .bist_debug_value(bist_debug_value),
        .bist_mem_got_flat(bist_mem_got_flat)
    );

    logic        ml_feature_valid;
    logic [15:0] ml_skin_count_raw;
    logic [7:0]  ml_bbox_width_raw;
    logic [7:0]  ml_bbox_height_raw;
    logic [7:0]  ml_peak_count_raw;
    logic [7:0]  ml_edge_count_raw;
    logic [3:0]  ml_finger_hint_raw;
    logic [7:0]  ml_feature_confidence;

    evpix_ml_feature_extractor #(
        .IMG_W(IMG_W),
        .IMG_H(IMG_H),
        .SRC_BASE(0)
    ) u_ml_features (
        .clk(clk),
        .reset(reset),
        .host_we(host_we & ml_mode),
        .host_addr(host_addr),
        .host_wdata(host_wdata),
        .frame_done(host_frame_done & ml_mode),
        .feature_valid(ml_feature_valid),
        .skin_count(ml_skin_count_raw),
        .bbox_width(ml_bbox_width_raw),
        .bbox_height(ml_bbox_height_raw),
        .peak_count(ml_peak_count_raw),
        .edge_count(ml_edge_count_raw),
        .finger_hint(ml_finger_hint_raw),
        .confidence(ml_feature_confidence)
    );

    evpix_tinyml_classifier u_tinyml_classifier (
        .clk(clk),
        .reset(reset),
        .feature_valid(ml_feature_valid),
        .skin_count(ml_skin_count_raw),
        .bbox_width(ml_bbox_width_raw),
        .bbox_height(ml_bbox_height_raw),
        .peak_count(ml_peak_count_raw),
        .edge_count(ml_edge_count_raw),
        .finger_hint(ml_finger_hint_raw),
        .feature_confidence(ml_feature_confidence),
        .result_valid(ml_result_valid),
        .finger_count(ml_finger_count),
        .confidence(ml_confidence),
        .debug_skin_count(ml_debug_skin_count),
        .debug_peak_count(ml_debug_peak_count),
        .debug_bbox_width(),
        .debug_bbox_height()
    );

endmodule
