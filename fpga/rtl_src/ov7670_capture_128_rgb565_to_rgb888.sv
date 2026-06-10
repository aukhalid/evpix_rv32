// EVPIX-RV32 OV7670 DVP capture, V4 stable-display/core-decoupled.
//
// Fixes over V3:
//   1) Display capture is always accepted, so the live left VGA pane no longer
//      freezes while the IPU is processing Sobel/Conv.
//   2) EVPIX source-memory writes are separately gated by accept_enable. This
//      preserves the original single source buffer architecture and prevents
//      the IPU from reading a source frame while it is being overwritten.
//   3) Adds separate core_* write outputs and core_frame_done/core_load_done for
//      the top-level scheduler.
//   4) Keeps the resource-safe crop/decimate datapath: no div/mod/mul/FIFO.
//
// Output formats:
//   host_*      : continuous RGB888 camera frame writes for VGA display mirror.
//   core_host_* : RGB888 writes into existing EVPIX source memory only for
//                 accepted full frames.
//
// Camera format expected from SCCB setup:
//   VGA RGB565. Standard byte0={R[4:0],G[5:3]}, byte1={G[2:0],B[4:0]}.
//   If your module uses opposite byte order, set SW12=1.

module ov7670_capture_128_rgb565_to_rgb888 #(
    parameter int IMG_W      = 128,
    parameter int IMG_H      = 128,
    parameter int VGA_W      = 640,
    parameter int VGA_H      = 480,
    parameter int CROP_X0    = 192,
    parameter int CROP_Y0    = 112,
    parameter int DECIMATE   = 2,
    parameter int BASE_ADDR  = 0,
    parameter int FIFO_DEPTH = 128,   // Kept for drop-in compatibility. Not used.
    parameter bit SWAP_RB    = 1'b0,
    parameter bit SWAP_BYTES = 1'b0
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        ov_pclk,
    input  logic        ov_href,
    input  logic        ov_vsync,
    input  logic [7:0]  ov_d,

    // Core/source-memory frame acceptance. Display capture is always accepted.
    input  logic        accept_enable,

    // Runtime debug/correction controls.
    input  logic        cfg_swap_bytes,      // SW12: swap RGB565 byte order
    input  logic        cfg_swap_rb,         // SW13: swap red and blue channels
    input  logic        cfg_sample_falling,  // SW11: sample camera bus on falling PCLK

    // Continuous camera writes for VGA display mirror.
    output logic        host_we,
    output logic [31:0] host_addr,
    output logic [7:0]  host_wdata,

    // Gated writes for EVPIX CPU/IPU source memory.
    output logic        core_host_we,
    output logic [31:0] core_host_addr,
    output logic [7:0]  core_host_wdata,
    output logic        core_frame_done,
    output logic        core_load_done,

    // Display-frame status/counters.
    output logic        frame_done,
    output logic        frame_loading,
    output logic        load_done,
    output logic [31:0] byte_count,
    output logic [31:0] frame_count,
    output logic [31:0] dropped_frame_count,
    output logic [31:0] error_count
);

    localparam int PIXELS          = IMG_W * IMG_H;
    localparam int FRAME_OUT_BYTES = PIXELS * 3;
    localparam int CROP_X1         = CROP_X0 + (IMG_W * DECIMATE);
    localparam int CROP_Y1         = CROP_Y0 + (IMG_H * DECIMATE);
    localparam int LINE_BYTES      = IMG_W * 3;

    initial begin
        if (IMG_W != 128 || IMG_H != 128 || DECIMATE != 2) begin
            $error("ov7670_capture_128_rgb565_to_rgb888 V4 expects IMG_W=128, IMG_H=128, DECIMATE=2");
        end
    end

    // ------------------------------------------------------------------
    // Synchronize camera pins into 100 MHz clock domain.
    // ------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) logic [2:0] pclk_sync;
    (* ASYNC_REG = "TRUE" *) logic [2:0] href_sync;
    (* ASYNC_REG = "TRUE" *) logic [2:0] vsync_sync;
    logic [7:0] d_meta, d_sync;

    logic pclk_q, href_q, vsync_q;
    logic pclk_rise, pclk_fall, href_fall, vsync_rise, vsync_fall;
    logic pclk_sample_edge;

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            pclk_sync  <= 3'b000;
            href_sync  <= 3'b000;
            vsync_sync <= 3'b000;
            d_meta     <= 8'd0;
            d_sync     <= 8'd0;
            pclk_q     <= 1'b0;
            href_q     <= 1'b0;
            vsync_q    <= 1'b0;
        end else begin
            pclk_sync  <= {pclk_sync[1:0], ov_pclk};
            href_sync  <= {href_sync[1:0], ov_href};
            vsync_sync <= {vsync_sync[1:0], ov_vsync};
            d_meta     <= ov_d;
            d_sync     <= d_meta;
            pclk_q     <= pclk_sync[2];
            href_q     <= href_sync[2];
            vsync_q    <= vsync_sync[2];
        end
    end

    assign pclk_rise        =  pclk_sync[2]  & ~pclk_q;
    assign pclk_fall        = ~pclk_sync[2]  &  pclk_q;
    assign pclk_sample_edge = cfg_sample_falling ? pclk_fall : pclk_rise;
    assign href_fall        = ~href_sync[2]  &  href_q;
    assign vsync_rise       =  vsync_sync[2] & ~vsync_q;
    assign vsync_fall       = ~vsync_sync[2] &  vsync_q;

    // ------------------------------------------------------------------
    // Camera parser state.
    // ------------------------------------------------------------------
    logic        accepting_frame;       // display path, always true during active frames
    logic        core_accepting_frame;  // EVPIX source-memory path, gated per frame
    logic        byte_phase;
    logic [7:0]  rgb_hi;
    logic [10:0] src_x;
    logic [10:0] src_y;
    logic [31:0] captured_pixels_this_frame;

    logic in_crop_x;
    logic in_crop_y;
    logic keep_x;
    logic keep_y;
    logic keep_pixel_now;

    always_comb begin
        in_crop_x      = (src_x >= CROP_X0[10:0]) && (src_x < CROP_X1[10:0]);
        in_crop_y      = (src_y >= CROP_Y0[10:0]) && (src_y < CROP_Y1[10:0]);
        keep_x         = in_crop_x && (src_x[0] == CROP_X0[0]);
        keep_y         = in_crop_y && (src_y[0] == CROP_Y0[0]);
        keep_pixel_now = accepting_frame && href_sync[2] && !vsync_sync[2] && keep_x && keep_y;
    end

    // ------------------------------------------------------------------
    // One-pixel write buffer. Host/display and core-memory writes are emitted
    // in parallel using identical RGB888 byte values.
    // ------------------------------------------------------------------
    logic        wr_active;
    logic        wr_core_valid;
    logic [1:0]  wr_phase;
    logic [31:0] wr_base_addr;
    logic [15:0] wr_rgb565;
    logic        frame_done_pending;
    logic        core_done_pending;

    logic [31:0] dst_line_base;
    logic [31:0] dst_addr_next;

    logic [4:0] r5, b5;
    logic [5:0] g6;
    logic [7:0] wr_r, wr_g, wr_b;
    logic [7:0] wr_byte_now;
    logic [31:0] wr_addr_now;

    always_comb begin
        if (!(SWAP_RB ^ cfg_swap_rb)) begin
            r5 = wr_rgb565[15:11];
            g6 = wr_rgb565[10:5];
            b5 = wr_rgb565[4:0];
        end else begin
            b5 = wr_rgb565[15:11];
            g6 = wr_rgb565[10:5];
            r5 = wr_rgb565[4:0];
        end
        wr_r = {r5, r5[4:2]};
        wr_g = {g6, g6[5:4]};
        wr_b = {b5, b5[4:2]};

        unique case (wr_phase)
            2'd0: begin wr_byte_now = wr_r; wr_addr_now = wr_base_addr; end
            2'd1: begin wr_byte_now = wr_g; wr_addr_now = wr_base_addr + 32'd1; end
            default: begin wr_byte_now = wr_b; wr_addr_now = wr_base_addr + 32'd2; end
        endcase
    end

    // ------------------------------------------------------------------
    // Main logic.
    // ------------------------------------------------------------------
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            accepting_frame            <= 1'b0;
            core_accepting_frame       <= 1'b0;
            byte_phase                 <= 1'b0;
            rgb_hi                     <= 8'd0;
            src_x                      <= 11'd0;
            src_y                      <= 11'd0;
            captured_pixels_this_frame <= 32'd0;

            wr_active                  <= 1'b0;
            wr_core_valid              <= 1'b0;
            wr_phase                   <= 2'd0;
            wr_base_addr               <= 32'd0;
            wr_rgb565                  <= 16'd0;
            frame_done_pending         <= 1'b0;
            core_done_pending          <= 1'b0;
            dst_line_base              <= BASE_ADDR[31:0];
            dst_addr_next              <= BASE_ADDR[31:0];

            host_we                    <= 1'b0;
            host_addr                  <= 32'd0;
            host_wdata                 <= 8'd0;
            core_host_we               <= 1'b0;
            core_host_addr             <= 32'd0;
            core_host_wdata            <= 8'd0;

            frame_done                 <= 1'b0;
            core_frame_done            <= 1'b0;
            frame_loading              <= 1'b0;
            load_done                  <= 1'b1;
            core_load_done             <= 1'b1;
            byte_count                 <= 32'd0;
            frame_count                <= 32'd0;
            dropped_frame_count        <= 32'd0;
            error_count                <= 32'd0;
        end else begin
            host_we         <= 1'b0;
            core_host_we    <= 1'b0;
            frame_done      <= 1'b0;
            core_frame_done <= 1'b0;

            // Emit pending RGB888 bytes to both consumers. Display always gets
            // complete accepted camera frames; EVPIX memory gets only frames that
            // were accepted at the start of the camera frame.
            if (wr_active) begin
                host_we    <= 1'b1;
                host_addr  <= wr_addr_now;
                host_wdata <= wr_byte_now;

                if (wr_core_valid) begin
                    core_host_we    <= 1'b1;
                    core_host_addr  <= wr_addr_now;
                    core_host_wdata <= wr_byte_now;
                end

                if (wr_phase == 2'd2) begin
                    wr_active <= 1'b0;

                    if (frame_done_pending) begin
                        frame_done_pending <= 1'b0;
                        frame_done         <= 1'b1;
                        frame_loading      <= 1'b0;
                        frame_count        <= frame_count + 32'd1;
                    end

                    if (core_done_pending) begin
                        core_done_pending <= 1'b0;
                        core_frame_done   <= 1'b1;
                        load_done         <= 1'b1;
                        core_load_done    <= 1'b1;
                    end
                end else begin
                    wr_phase <= wr_phase + 2'd1;
                end

                if (byte_count < FRAME_OUT_BYTES[31:0])
                    byte_count <= byte_count + 32'd1;
            end

            // VSYNC high = frame blanking for common OV7670 timing.
            if (vsync_rise) begin
                accepting_frame      <= 1'b0;
                core_accepting_frame <= 1'b0;
                frame_loading        <= 1'b0;
                byte_phase           <= 1'b0;
                src_x                <= 11'd0;
                src_y                <= 11'd0;

                if ((captured_pixels_this_frame != 32'd0) &&
                    (captured_pixels_this_frame != PIXELS[31:0]) &&
                    !frame_done_pending)
                    error_count <= error_count + 32'd1;
            end

            // New active frame begins on VSYNC falling edge. Display path always
            // accepts it. Core path accepts only when the top-level says the IPU
            // is not processing the previous source frame.
            if (vsync_fall) begin
                accepting_frame            <= 1'b1;
                core_accepting_frame       <= accept_enable;
                frame_loading              <= 1'b1;
                byte_phase                 <= 1'b0;
                src_x                      <= 11'd0;
                src_y                      <= 11'd0;
                captured_pixels_this_frame <= 32'd0;
                byte_count                 <= 32'd0;
                frame_done_pending         <= 1'b0;
                core_done_pending          <= 1'b0;
                dst_line_base              <= BASE_ADDR[31:0];
                dst_addr_next              <= BASE_ADDR[31:0];

                if (accept_enable) begin
                    load_done      <= 1'b0;
                    core_load_done <= 1'b0;
                end else begin
                    dropped_frame_count <= dropped_frame_count + 32'd1;
                end
            end

            // End of line: reset x, advance y, and advance destination line only
            // for rows kept by vertical decimation.
            if (href_fall) begin
                src_x      <= 11'd0;
                byte_phase <= 1'b0;

                if (!vsync_sync[2]) begin
                    if (accepting_frame && keep_y && in_crop_y) begin
                        dst_line_base <= dst_line_base + LINE_BYTES[31:0];
                        dst_addr_next <= dst_line_base + LINE_BYTES[31:0];
                    end

                    if (src_y < (VGA_H[10:0] - 11'd1))
                        src_y <= src_y + 11'd1;
                end
            end

            // Capture RGB565 bytes on selected PCLK edge.
            if (pclk_sample_edge && accepting_frame && href_sync[2] && !vsync_sync[2]) begin
                if (!byte_phase) begin
                    rgb_hi     <= d_sync;
                    byte_phase <= 1'b1;
                end else begin
                    byte_phase <= 1'b0;

                    // Complete RGB565 pixel at current src_x/src_y.
                    if (keep_pixel_now) begin
                        if (wr_active) begin
                            error_count <= error_count + 32'd1;
                        end else if (captured_pixels_this_frame < PIXELS[31:0]) begin
                            wr_active     <= 1'b1;
                            wr_core_valid <= core_accepting_frame;
                            wr_phase      <= 2'd0;
                            wr_base_addr  <= dst_addr_next;
                            wr_rgb565     <= (SWAP_BYTES ^ cfg_swap_bytes) ? {d_sync, rgb_hi} : {rgb_hi, d_sync};
                            dst_addr_next <= dst_addr_next + 32'd3;

                            captured_pixels_this_frame <= captured_pixels_this_frame + 32'd1;

                            if (captured_pixels_this_frame == (PIXELS[31:0] - 32'd1)) begin
                                frame_done_pending <= 1'b1;
                                if (core_accepting_frame)
                                    core_done_pending <= 1'b1;
                            end
                        end
                    end

                    if (src_x < (VGA_W[10:0] - 11'd1))
                        src_x <= src_x + 11'd1;
                end
            end
        end
    end

endmodule
