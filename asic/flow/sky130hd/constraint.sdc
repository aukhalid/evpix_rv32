# EVPIX SKY130HD first-pass ASIC layout constraints.
# OpenROAD-compatible SDC: avoids PrimeTime-only remove_from_collection.
# 100 ns = 10 MHz for a reliable first GDS. Tighten later for timing studies.

create_clock -name core_clk -period 100.000 [get_ports clk]

# All synchronous inputs except clk. rst_n is modeled as an input for first-pass STA.
set_input_delay 5.000 -clock core_clk [get_ports {rst_n program_id cpu_regression_mode ml_mode host_we host_addr host_wdata host_frame_done cpu_mem_rdata ipu_mem_rdata bist_debug_index}]

# All top-level output ports.
set_output_delay 5.000 -clock core_clk [get_ports {host_mem_we host_mem_addr host_mem_wdata cpu_mem_read cpu_mem_write cpu_mem_funct3 cpu_mem_addr cpu_mem_wdata ipu_mem_re ipu_mem_we ipu_mem_addr ipu_mem_wdata proc_we proc_addr proc_wdata debug_pc debug_instr debug_ipu_busy debug_ipu_done debug_ipu_result debug_cycle_counter perf_ipu_busy_count perf_conv_count perf_pool_count perf_stall_count bist_done bist_pass bist_fail_count bist_debug_value bist_mem_got_flat ml_result_valid ml_finger_count ml_confidence ml_debug_skin_count ml_debug_peak_count}]

# Conservative first-pass IO assumptions.
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 [get_ports {rst_n program_id cpu_regression_mode ml_mode host_we host_addr host_wdata host_frame_done cpu_mem_rdata ipu_mem_rdata bist_debug_index}]
set_load 0.020 [get_ports {host_mem_we host_mem_addr host_mem_wdata cpu_mem_read cpu_mem_write cpu_mem_funct3 cpu_mem_addr cpu_mem_wdata ipu_mem_re ipu_mem_we ipu_mem_addr ipu_mem_wdata proc_we proc_addr proc_wdata debug_pc debug_instr debug_ipu_busy debug_ipu_done debug_ipu_result debug_cycle_counter perf_ipu_busy_count perf_conv_count perf_pool_count perf_stall_count bist_done bist_pass bist_fail_count bist_debug_value bist_mem_got_flat ml_result_valid ml_finger_count ml_confidence ml_debug_skin_count ml_debug_peak_count}]
