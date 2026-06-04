// ============================================================
// File: evpix_top_ov7670_direct.sv
// V4: source display double-buffer + camera/core decoupling + 60Hz display-FPS demo mode.
// ============================================================
// Drop-in replacement top for evpix_top_esp32cam_spi.sv. Adds SW7 TinyML finger-count mode.
// It removes the ESP32/SPI input path and uses OV7670 direct parallel DVP.
// CPU, IPU, BIST, instruction ROM, VGA display, memory map, and algorithms
// are unchanged. Set this module as Vivado top.

module evpix_top_ov7670_direct #(
    parameter int CPU_RESET_CYCLES       = 16,
    parameter int PROCESS_TIMEOUT_CYCLES = 10000000    // 0.1 s @ 100 MHz
) (
    input  logic        clk_100mhz,
    input  logic        reset_btn,

    // Basys 3 switches
    input  logic [15:0] sw,

    // OV7670 direct parallel camera interface
    input  logic        ov7670_pclk,
    input  logic        ov7670_href,
    input  logic        ov7670_vsync,
    input  logic [7:0]  ov7670_d,
    output logic        ov7670_xclk,
    output logic        ov7670_sioc,
    inout  wire         ov7670_siod,
    output logic        ov7670_pwdn,
    output logic        ov7670_reset_n,

    output logic [15:0] led,

    output logic [3:0]  vga_r,
    output logic [3:0]  vga_g,
    output logic [3:0]  vga_b,
    output logic        hsync,
    output logic        vsync
);

    localparam int IMG_W    = 128;
    localparam int IMG_H    = 128;
    localparam int SRC_BASE = 0;
    localparam int DST_BASE = 32'h0000_C000;

    // EVPIX core/SPI loader/write side runs at 100 MHz.
    logic clk_core;
    assign clk_core = clk_100mhz;

    // VGA pixel clock: 100 MHz / 4 = 25 MHz.
    logic [1:0] clk_div;
    logic       clk_25mhz;

    always_ff @(posedge clk_100mhz or posedge reset_btn) begin
        if (reset_btn)
            clk_div <= 2'b00;
        else
            clk_div <= clk_div + 2'b01;
    end

    assign clk_25mhz = clk_div[1];

    // 25 MHz XCLK for OV7670. SCCB sets CLKRC=0x01, giving a stable 30 fps
    // class stream. Do not use the old CLKRC=0x00 setting; it overdrives the
    // cheap OV7670 modules and causes color noise/vibration.
    assign ov7670_xclk    = clk_25mhz;
    assign ov7670_pwdn    = 1'b0; // 0 = normal operation
    assign ov7670_reset_n = 1'b1; // active-low reset released

    logic ov_sccb_done;
    logic ov_sccb_busy;
    logic ov_sccb_error;

    ov7670_sccb_init u_ov7670_sccb (
        .clk        (clk_core),
        .reset      (reset_btn),
        .colorbar_enable(sw[10]),
        .ov_sioc    (ov7670_sioc),
        .ov_siod    (ov7670_siod),
        .init_done  (ov_sccb_done),
        .init_busy  (ov_sccb_busy),
        .init_error (ov_sccb_error)
    );

    // ------------------------------------------------------------------------
    // Switch synchronizer + robust runtime decoder
    // ------------------------------------------------------------------------
    logic [15:0] sw_meta, sw_sync;

    always_ff @(posedge clk_core or posedge reset_btn) begin
        if (reset_btn) begin
            sw_meta <= 16'b0;
            sw_sync <= 16'b0;
        end else begin
            sw_meta <= sw;
            sw_sync <= sw_meta;
        end
    end

    logic       ipu_mode;
    logic       ml_mode;
    logic       cpu_bist_mode;
    logic       cpu_welcome_mode;
    logic [3:0] instr_sw;
    logic       instr_onehot;
    logic       ipu_valid;
    logic       bypass_output;
    logic [2:0] selected_program_id;

    assign ipu_mode         = sw_sync[0];
    assign ml_mode          = sw_sync[7];                 // SW7 = TinyML finger-count mode
    assign cpu_bist_mode    = (~ml_mode) & (~sw_sync[0]) & sw_sync[6];   // SW6 only works in CPU mode
    assign cpu_welcome_mode = (~ml_mode) & (~sw_sync[0]) & ~sw_sync[6];
    assign instr_sw         = sw_sync[4:1];
    assign instr_onehot  = (instr_sw != 4'b0000) && ((instr_sw & (instr_sw - 4'b0001)) == 4'b0000);
    assign ipu_valid     = (~ml_mode) && ipu_mode && instr_onehot;
    assign bypass_output = ml_mode ? 1'b1 : ~ipu_valid; // ML mode shows live source on both panes

    always_comb begin
        unique case (1'b1)
            sw_sync[1]: selected_program_id = 3'd0; // SOBEL
            sw_sync[2]: selected_program_id = 3'd1; // GRAY
            sw_sync[3]: selected_program_id = 3'd2; // THRESH
            sw_sync[4]: selected_program_id = 3'd3; // CONV_IDENTITY
            default:    selected_program_id = 3'd0;
        endcase
    end

    // Detect real-time switch/mode changes. Used to safely stop the current
    // processing transaction and restart cleanly on the next accepted frame.
    logic [7:0] control_word_q;
    logic [7:0] control_word_now;
    logic       control_changed;

    assign control_word_now = {ml_mode, ipu_mode, cpu_bist_mode, ipu_valid, selected_program_id, instr_onehot};
    assign control_changed  = (control_word_now != control_word_q);

    always_ff @(posedge clk_core or posedge reset_btn) begin
        if (reset_btn)
            control_word_q <= 8'b0;
        else
            control_word_q <= control_word_now;
    end

    // VGA timing stays at 25 MHz.
    logic [9:0] vga_x;
    logic [9:0] vga_y;
    logic       vga_active;

    vga_640x480 u_vga_timing (
        .clk_pix (clk_25mhz),
        .reset   (reset_btn),
        .x       (vga_x),
        .y       (vga_y),
        .active  (vga_active),
        .hsync   (hsync),
        .vsync   (vsync)
    );

    // OV7670 camera capture -> source display buffer and EVPIX source memory.
    logic        host_we;       // continuous display-mirror camera writes
    logic [31:0] host_addr;
    logic [7:0]  host_wdata;

    logic        cam_core_we;   // gated EVPIX source-memory camera writes
    logic [31:0] cam_core_addr;
    logic [7:0]  cam_core_wdata;
    logic        core_frame_done;
    logic        core_load_done;

    logic        frame_done;
    logic        frame_loading;
    logic        load_done;
    logic [31:0] load_count;
    logic [31:0] frame_count;
    logic [31:0] dropped_frame_count;
    logic [31:0] spi_error_count;

    logic        processing_active;
    logic        accept_enable;

    // V4: camera display capture always runs inside the capture module. This
    // signal now controls only writes into the EVPIX CPU/IPU source memory.
    // That removes live-view freezes and prevents partial source-memory writes.
    assign accept_enable = ipu_valid ? ~processing_active : 1'b0;

    ov7670_capture_128_rgb565_to_rgb888 #(
        .IMG_W      (IMG_W),
        .IMG_H      (IMG_H),
        .BASE_ADDR  (SRC_BASE),
        .SWAP_RB    (1'b0),
        .SWAP_BYTES (1'b0)
    ) u_ov7670_capture (
        .clk                 (clk_core),
        .reset               (reset_btn | ~ov_sccb_done),
        .ov_pclk             (ov7670_pclk),
        .ov_href             (ov7670_href),
        .ov_vsync            (ov7670_vsync),
        .ov_d                (ov7670_d),
        .accept_enable       (accept_enable),
        .cfg_swap_bytes      (sw_sync[12]),
        .cfg_swap_rb         (sw_sync[13]),
        .cfg_sample_falling  (sw_sync[11]),
        .host_we             (host_we),
        .host_addr           (host_addr),
        .host_wdata          (host_wdata),
        .core_host_we        (cam_core_we),
        .core_host_addr      (cam_core_addr),
        .core_host_wdata     (cam_core_wdata),
        .core_frame_done     (core_frame_done),
        .core_load_done      (core_load_done),
        .frame_done          (frame_done),
        .frame_loading       (frame_loading),
        .load_done           (load_done),
        .byte_count          (load_count),
        .frame_count         (frame_count),
        .dropped_frame_count (dropped_frame_count),
        .error_count         (spi_error_count)
    );

    // CPU/IPU core and processed output mirror.
    logic        proc_we;
    logic [31:0] proc_addr;
    logic [7:0]  proc_wdata;

    logic [31:0] debug_pc;
    logic [31:0] debug_instr;
    logic        debug_ipu_busy;
    logic        debug_ipu_done;
    logic [31:0] debug_ipu_result;
    logic [31:0] debug_cycle_counter;
    logic [31:0] perf_ipu_busy_count;
    logic [31:0] perf_conv_count;
    logic [31:0] perf_pool_count;
    logic [31:0] perf_stall_count;
    logic        bist_done;
    logic        bist_pass;
    logic [5:0]  bist_fail_count;
    logic [31:0] bist_reg_got [0:31];
    logic [7:0]  bist_mem_got [0:10];

    // Gate camera writes into EVPIX data memory unless a valid IPU instruction
    // is selected. The VGA source buffer still receives all host_we writes.
    logic        core_host_we;
    logic [31:0] core_host_addr;
    logic [7:0]  core_host_wdata;

    assign core_host_we    = ipu_valid ? cam_core_we : 1'b0;
    assign core_host_addr  = cam_core_addr;
    assign core_host_wdata = cam_core_wdata;

    // Reset/restart policy:
    //   CPU mode: release CPU once and run CPU-BIST program.
    //   Valid IPU mode: reset/restart CPU after every accepted source-memory frame.
    //   Invalid/bypass IPU mode: hold CPU in reset and mirror input to output.
    logic cpu_reset_hold;
    logic [$clog2(CPU_RESET_CYCLES+1)-1:0] cpu_reset_count;
    logic cpu_reset;
    logic [31:0] process_counter;
    logic process_timeout_seen;

    always_ff @(posedge clk_core or posedge reset_btn) begin
        if (reset_btn) begin
            cpu_reset_hold       <= 1'b1;
            cpu_reset_count      <= CPU_RESET_CYCLES;
            processing_active    <= 1'b0;
            process_counter      <= 32'd0;
            process_timeout_seen <= 1'b0;
        end else begin
            if (control_changed) begin
                // Any mode/instruction change gets a clean CPU restart and
                // releases any in-flight processing lock.
                cpu_reset_hold       <= 1'b1;
                cpu_reset_count      <= CPU_RESET_CYCLES;
                processing_active    <= 1'b0;
                process_counter      <= 32'd0;
                process_timeout_seen <= 1'b0;
            end else if (cpu_bist_mode) begin
                // CPU-BIST mode: SW0=0 and SW6=1. Release CPU once and run the exact
                // baseline regression ROM.
                processing_active <= 1'b0;
                process_counter   <= 32'd0;

                if (cpu_reset_hold) begin
                    if (cpu_reset_count != 0)
                        cpu_reset_count <= cpu_reset_count - 1'b1;
                    else
                        cpu_reset_hold <= 1'b0;
                end
            end else if (ml_mode || cpu_welcome_mode || !ipu_valid) begin
                // ML mode, CPU welcome mode, or invalid/no IPU instruction:
                // safe display-only state; CPU is held reset. ML runs as a
                // passive camera-stream feature/classifier path.
                cpu_reset_hold    <= 1'b1;
                cpu_reset_count   <= CPU_RESET_CYCLES;
                processing_active <= 1'b0;
                process_counter   <= 32'd0;
            end else begin
                // Valid IPU mode: restart CPU after every accepted full source-memory frame.
                if (core_frame_done) begin
                    cpu_reset_hold       <= 1'b1;
                    cpu_reset_count      <= CPU_RESET_CYCLES;
                    processing_active    <= 1'b1;
                    process_counter      <= 32'd0;
                    process_timeout_seen <= 1'b0;
                end else begin
                    if (cpu_reset_hold) begin
                        if (cpu_reset_count != 0)
                            cpu_reset_count <= cpu_reset_count - 1'b1;
                        else if (core_load_done)
                            cpu_reset_hold <= 1'b0;
                    end

                    if (processing_active && !cpu_reset_hold) begin
                        process_counter <= process_counter + 32'd1;

                        if (debug_ipu_done) begin
                            processing_active <= 1'b0;
                        end else if (process_counter >= PROCESS_TIMEOUT_CYCLES) begin
                            processing_active    <= 1'b0;
                            process_timeout_seen <= 1'b1;
                        end
                    end
                end
            end
        end
    end

    assign cpu_reset = reset_btn | cpu_reset_hold;

    // ------------------------------------------------------------------------
    // Real-time research/performance counters for VGA overlay.
    // fps_estimate updates once per second from accepted SPI frames.
    // last_process_cycles captures the most recent IPU processing latency.
    // ------------------------------------------------------------------------
    localparam int CORE_HZ = 100000000;
    logic [31:0] fps_window_counter;
    logic [31:0] cam_frame_accum;
    logic [31:0] disp_frame_accum;
    logic [31:0] fps_estimate;
    logic [31:0] last_process_cycles;
    logic        vga_vsync_q;
    logic        display_60_mode;

    // SW9 selects display-refresh FPS reporting. This does not invent new
    // camera frames; it reports the 640x480 VGA refresh/display cadence, which
    // naturally repeats the latest stable source/processed frame at ~60 Hz.
    assign display_60_mode = sw_sync[9];

    always_ff @(posedge clk_core or posedge reset_btn) begin
        if (reset_btn) begin
            fps_window_counter <= 32'd0;
            cam_frame_accum    <= 32'd0;
            disp_frame_accum   <= 32'd0;
            fps_estimate       <= 32'd0;
            last_process_cycles<= 32'd0;
            vga_vsync_q        <= 1'b0;
        end else begin
            vga_vsync_q <= vsync;

            if (frame_done)
                cam_frame_accum <= cam_frame_accum + 32'd1;

            if (vsync && !vga_vsync_q)
                disp_frame_accum <= disp_frame_accum + 32'd1;

            if (fps_window_counter >= CORE_HZ-1) begin
                fps_window_counter <= 32'd0;
                fps_estimate       <= display_60_mode ? disp_frame_accum : cam_frame_accum;
                cam_frame_accum    <= 32'd0;
                disp_frame_accum   <= 32'd0;
            end else begin
                fps_window_counter <= fps_window_counter + 32'd1;
            end

            if (ipu_valid && processing_active && !cpu_reset_hold && (debug_ipu_done || (process_counter >= PROCESS_TIMEOUT_CYCLES))) begin
                last_process_cycles <= process_counter;
            end
        end
    end



    // ------------------------------------------------------------------------
    // TinyML finger-count demo path. This is a passive side-band accelerator:
    // it taps the same 128x128 RGB888 camera stream used by the display and
    // does not modify the existing EVPIX CPU/IPU architecture or algorithms.
    // SW7 enables the VGA ML overlay and holds the CPU/IPU in a safe reset state.
    // ------------------------------------------------------------------------
    logic        ml_feature_valid;
    logic [15:0] ml_skin_count_raw;
    logic [7:0]  ml_bbox_width_raw;
    logic [7:0]  ml_bbox_height_raw;
    logic [7:0]  ml_peak_count_raw;
    logic [7:0]  ml_edge_count_raw;
    logic [3:0]  ml_finger_hint_raw;
    logic [7:0]  ml_feature_confidence;

    logic        ml_result_valid;
    logic [2:0]  ml_finger_count;
    logic [7:0]  ml_confidence;
    logic [15:0] ml_debug_skin_count;
    logic [7:0]  ml_debug_peak_count;
    logic [7:0]  ml_debug_bbox_width;
    logic [7:0]  ml_debug_bbox_height;

    evpix_ml_feature_extractor #(
        .IMG_W    (IMG_W),
        .IMG_H    (IMG_H),
        .SRC_BASE (SRC_BASE)
    ) u_ml_features (
        .clk           (clk_core),
        .reset         (reset_btn | ~ov_sccb_done),
        .host_we       (host_we),
        .host_addr     (host_addr),
        .host_wdata    (host_wdata),
        .frame_done    (frame_done),
        .feature_valid (ml_feature_valid),
        .skin_count    (ml_skin_count_raw),
        .bbox_width    (ml_bbox_width_raw),
        .bbox_height   (ml_bbox_height_raw),
        .peak_count    (ml_peak_count_raw),
        .edge_count    (ml_edge_count_raw),
        .finger_hint   (ml_finger_hint_raw),
        .confidence    (ml_feature_confidence)
    );

    evpix_tinyml_classifier u_tinyml_classifier (
        .clk                (clk_core),
        .reset              (reset_btn | ~ov_sccb_done),
        .feature_valid      (ml_feature_valid),
        .skin_count         (ml_skin_count_raw),
        .bbox_width         (ml_bbox_width_raw),
        .bbox_height        (ml_bbox_height_raw),
        .peak_count         (ml_peak_count_raw),
        .edge_count         (ml_edge_count_raw),
        .finger_hint        (ml_finger_hint_raw),
        .feature_confidence (ml_feature_confidence),
        .result_valid       (ml_result_valid),
        .finger_count       (ml_finger_count),
        .confidence         (ml_confidence),
        .debug_skin_count   (ml_debug_skin_count),
        .debug_peak_count   (ml_debug_peak_count),
        .debug_bbox_width   (ml_debug_bbox_width),
        .debug_bbox_height  (ml_debug_bbox_height)
    );

    rv32i_core_fpga #(
        .IMG_W (IMG_W),
        .IMG_H (IMG_H)
    ) cpu_core (
        .clk                 (clk_core),
        .reset               (cpu_reset),
        .program_id          (selected_program_id),
        .cpu_regression_mode (cpu_bist_mode),
        .host_we             (core_host_we),
        .host_addr           (core_host_addr),
        .host_wdata          (core_host_wdata),
        .proc_we             (proc_we),
        .proc_addr           (proc_addr),
        .proc_wdata          (proc_wdata),
        .debug_pc            (debug_pc),
        .debug_instr         (debug_instr),
        .debug_ipu_busy      (debug_ipu_busy),
        .debug_ipu_done      (debug_ipu_done),
        .debug_ipu_result    (debug_ipu_result),
        .debug_cycle_counter (debug_cycle_counter),
        .perf_ipu_busy_count (perf_ipu_busy_count),
        .perf_conv_count     (perf_conv_count),
        .perf_pool_count     (perf_pool_count),
        .perf_stall_count    (perf_stall_count),
        .bist_done           (bist_done),
        .bist_pass           (bist_pass),
        .bist_fail_count     (bist_fail_count),
        .bist_reg_got        (bist_reg_got),
        .bist_mem_got        (bist_mem_got)
    );

    logic cpu_pass;
    logic cpu_fail;
    assign cpu_pass = cpu_bist_mode && bist_done && bist_pass;
    assign cpu_fail = cpu_bist_mode && bist_done && !bist_pass;

    logic [1:0] overlay_mode;
    assign overlay_mode = cpu_bist_mode ? 2'd2 : (cpu_welcome_mode ? 2'd1 : 2'd0);

    // Dual-clock display mirror: writes at core clock, reads at VGA pixel clock.
    // If bypass_output=1, right side shows the original RGB source frame.
    evpix_vga_frame_display_db #(
        .IMG_W    (IMG_W),
        .IMG_H    (IMG_H),
        .SRC_BASE (SRC_BASE),
        .DST_BASE (DST_BASE),
        .LEFT_X   (96),
        .TOP_Y    (176),
        .GAP      (64)
    ) u_display (
        .clk_wr           (clk_core),
        .clk_pix          (clk_25mhz),
        .reset            (reset_btn),
        .right_bypass_src (bypass_output),
        .overlay_mode     (overlay_mode),
        .bist_page        (sw_sync[15:14]),
        .bist_done        (bist_done),
        .bist_pass        (bist_pass),
        .bist_fail_count  (bist_fail_count),
        .bist_reg_got     (bist_reg_got),
        .bist_mem_got     (bist_mem_got),
        .ipu_mode         (ipu_mode),
        .ipu_valid        (ipu_valid),
        .ipu_program_id   (selected_program_id),
        .fps_estimate     (fps_estimate),
        .last_process_cycles(last_process_cycles),
        .frame_count      (frame_count),
        .dropped_frame_count(dropped_frame_count),
        .spi_error_count  (spi_error_count),
        .perf_cycle_count (debug_cycle_counter),
        .perf_ipu_busy_count(perf_ipu_busy_count),
        .perf_conv_count  (perf_conv_count),
        .perf_pool_count  (perf_pool_count),
        .perf_stall_count (perf_stall_count),
        .debug_ipu_result (debug_ipu_result),
        .ml_mode          (ml_mode),
        .ml_valid         (ml_result_valid),
        .ml_finger_count  (ml_finger_count),
        .ml_skin_count    (ml_debug_skin_count),
        .ml_bbox_width    (ml_debug_bbox_width),
        .ml_bbox_height   (ml_debug_bbox_height),
        .ml_peak_count    (ml_debug_peak_count),
        .ml_confidence    (ml_confidence),
        .x                (vga_x),
        .y                (vga_y),
        .active           (vga_active),
        .host_we          (host_we),
        .host_addr        (host_addr),
        .host_wdata       (host_wdata),
        .src_frame_done   (frame_done),
        .proc_we          ((ipu_valid && !ml_mode) ? proc_we : 1'b0),
        .proc_addr        (proc_addr),
        .proc_wdata       (proc_wdata),
        .vga_r            (vga_r),
        .vga_g            (vga_g),
        .vga_b            (vga_b)
    );

    // LED map, V6:
    //   LED0    = SW0/IPU mode. 0=CPU mode, 1=IPU mode
    //   LED4:1  = raw instruction switches SW4..SW1 mirrored as LEDs
    //   LED5    = valid one-hot IPU instruction selection
    //   LED6    = SW6 CPU-BIST request, active only when SW0=0
    //   LED7    = CPU regression PASS
    //   LED8    = CPU regression FAIL
    //   LED9    = SPI/frame error occurred
    //   LED10   = processing active
    //   LED11   = processing timeout occurred
    //   LED12   = OV7670 color debug: SW12 byte swap
    //   LED13   = OV7670 color debug: SW13 red/blue swap
    //   LED14   = OV7670 colorbar request SW10
    //   LED15   = SW9 display-60 FPS overlay mode
    assign led[0]    = ml_mode ? ml_finger_count[0] : ipu_mode;
    assign led[1]    = ml_mode ? ml_finger_count[1] : sw_sync[1];
    assign led[2]    = ml_mode ? ml_finger_count[2] : sw_sync[2];
    assign led[3]    = ml_mode ? (ml_finger_count == 3'd3) : sw_sync[3];
    assign led[4]    = ml_mode ? (ml_finger_count == 3'd4) : sw_sync[4];
    assign led[5]    = ml_mode ? (ml_finger_count == 3'd5) : ipu_valid;
    assign led[6]    = ml_mode ? ml_result_valid : cpu_bist_mode;
    assign led[7]    = ml_mode ? (ml_confidence >= 8'd70) : cpu_pass;
    assign led[8]    = ml_mode ? (ml_confidence < 8'd45) : cpu_fail;
    assign led[9]    = |spi_error_count | ov_sccb_error;
    assign led[10]   = ml_mode ? ml_feature_valid : processing_active;
    assign led[11]   = ml_mode ? (ml_skin_count_raw > 16'd180) : process_timeout_seen;
    assign led[12]   = cpu_bist_mode ? bist_fail_count[0] : sw_sync[12];
    assign led[13]   = cpu_bist_mode ? bist_fail_count[1] : sw_sync[13];
    assign led[14]   = cpu_bist_mode ? 1'b0 : sw_sync[10];
    assign led[15]   = cpu_bist_mode ? 1'b0 : sw_sync[9];

endmodule
