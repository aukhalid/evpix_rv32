// ============================================================
// File: evpix_ml_feature_extractor.sv
// EVPIX TinyML finger-count feature extractor, V5 stable/accuracy tuned.
// ============================================================
// Why V5 exists:
//   V4 worked, but counts could shuffle between neighboring values such as
//   5 -> 4 -> 5 when one fingertip merged/split across frames.
//
// V5 fix:
//   - Uses the user-tested defaults RUN_MIN_WIDTH=3, ROW_MIN_SKIN=8, ROW_SUPPORT=3.
//   - Gives 5-finger detection a slightly lower row-support threshold, because
//     the thumb/little finger often appears on fewer clean rows.
//   - Keeps the same resource-light histogram logic.
//   - Temporal stability is handled in evpix_tinyml_classifier V5.
//
// This remains a passive camera-stream side path. CPU, IPU, memory map, OV7670
// capture, display buffering, and image-processing algorithms are unchanged.
//
// Demo requirement:
//   Put the hand/fingers against a plain non-skin background. Face/background
//   skin in the image can still be detected as a hand-like object; this is a
//   tiny feature model, not a CNN.

module evpix_ml_feature_extractor #(
    parameter int IMG_W    = 128,
    parameter int IMG_H    = 128,
    parameter int SRC_BASE = 0,

    // ROI used for finger separation. These defaults focus on the upper/middle
    // part of the 128x128 crop where raised fingers appear.
    parameter int ROI_X0   = 8,
    parameter int ROI_X1   = 120,
    parameter int ROI_Y0   = 8,
    parameter int ROI_Y1   = 78,

    // Ignore tiny noisy skin blobs. Tune RUN_MIN_WIDTH to 5 or 6 if the output
    // still over-counts. Tune it to 3 if it under-counts thin fingers.
    parameter int RUN_MIN_WIDTH = 3,
    parameter int ROW_MIN_SKIN  = 8,
    parameter int ROW_SUPPORT   = 3,
    // 5 fingers often has fewer fully-separated rows than 2/3/4 because the
    // thumb and little finger are shorter/angled. Keeping this at 2 improves
    // 5-finger recognition without making all outputs stick at 5.
    parameter int ROW_SUPPORT_5 = 2
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        host_we,
    input  logic [31:0] host_addr,
    input  logic [7:0]  host_wdata,
    input  logic        frame_done,

    output logic        feature_valid,
    output logic [15:0] skin_count,
    output logic [7:0]  bbox_width,
    output logic [7:0]  bbox_height,
    output logic [7:0]  peak_count,
    output logic [7:0]  edge_count,
    output logic [3:0]  finger_hint,
    output logic [7:0]  confidence
);

    localparam int PIXELS    = IMG_W * IMG_H;
    localparam int RGB_BYTES = PIXELS * 3;
    localparam logic [6:0] ROI_X0_L = ROI_X0[6:0];
    localparam logic [6:0] ROI_X1_L = ROI_X1[6:0];
    localparam logic [6:0] ROI_Y0_L = ROI_Y0[6:0];
    localparam logic [6:0] ROI_Y1_L = ROI_Y1[6:0];
    localparam logic [5:0] RUN_MIN_WIDTH_L = RUN_MIN_WIDTH[5:0];
    localparam logic [7:0] ROW_MIN_SKIN_L = ROW_MIN_SKIN[7:0];
    localparam logic [6:0] ROW_SUPPORT_L   = ROW_SUPPORT[6:0];
    localparam logic [6:0] ROW_SUPPORT_5_L = ROW_SUPPORT_5[6:0];

    initial begin
        if (IMG_W != 128 || IMG_H != 128)
            $error("evpix_ml_feature_extractor V5 expects 128x128 RGB stream");
    end

    logic host_in_range;
    logic host_first_byte;
    assign host_in_range   = host_we && (host_addr >= SRC_BASE) && (host_addr < (SRC_BASE + RGB_BYTES));
    assign host_first_byte = host_we && (host_addr == SRC_BASE);

    logic [1:0] rgb_phase;
    logic [7:0] r_q, g_q;
    logic [6:0] x, y;

    logic [15:0] skin_acc;
    logic [7:0]  edge_acc;
    logic        prev_skin;

    // Per-row run extraction.
    logic [7:0] row_skin;
    logic [4:0] run_width;
    logic [3:0] row_runs;

    // Histogram: how many scan rows had N separated finger runs.
    logic [6:0] hist1, hist2, hist3, hist4, hist5;

    function automatic logic skin_mask(input logic [7:0] r, input logic [7:0] g, input logic [7:0] b);
        logic [8:0] r9, g9, b9;
        logic [8:0] maxc, minc;
        begin
            r9 = {1'b0, r};
            g9 = {1'b0, g};
            b9 = {1'b0, b};
            maxc = (r9 > g9) ? ((r9 > b9) ? r9 : b9) : ((g9 > b9) ? g9 : b9);
            minc = (r9 < g9) ? ((r9 < b9) ? r9 : b9) : ((g9 < b9) ? g9 : b9);

            // Stricter than V3. This rejects white background and much of the
            // yellow/green OV7670 noise while keeping normal skin under room light.
            skin_mask = (r > 8'd62) &&
                        (g > 8'd32) &&
                        (b > 8'd18) &&
                        ((maxc - minc) > 9'd18) &&
                        (r9 + 9'd10 >= g9) &&
                        (r9 > b9 + 9'd12) &&
                        (g9 > b9 + 9'd2) &&
                        !((r > 8'd224) && (g > 8'd224) && (b > 8'd224));
        end
    endfunction

    logic [7:0] b_now;
    logic       in_roi;
    logic       skin_now;
    logic       row_end;
    logic       run_end;
    logic [5:0] run_width_with_cur;
    logic       valid_run_end;
    logic [3:0] row_runs_after;
    logic [7:0] row_skin_after;

    assign b_now              = host_wdata;
    assign in_roi             = (x >= ROI_X0_L) && (x < ROI_X1_L) && (y >= ROI_Y0_L) && (y < ROI_Y1_L);
    assign skin_now           = in_roi && skin_mask(r_q, g_q, b_now);
    assign row_end            = (x == 7'd127);
    assign run_width_with_cur = {1'b0, run_width} + (skin_now ? 6'd1 : 6'd0);
    assign run_end            = prev_skin && ((!skin_now) || row_end);
    assign valid_run_end      = run_end && (run_width_with_cur >= RUN_MIN_WIDTH_L);
    assign row_runs_after     = row_runs + ((valid_run_end && (row_runs < 4'd5)) ? 4'd1 : 4'd0);
    assign row_skin_after     = row_skin + ((skin_now && (row_skin != 8'hFF)) ? 8'd1 : 8'd0);

    // Frame-end classification from the row-run histogram.
    logic [3:0] hint_next;
    logic [7:0] conf_next;
    logic [7:0] peak_next;
    logic       enough_skin;
    assign enough_skin = (skin_acc >= 16'd220);

    always_comb begin
        hint_next = 4'd0;
        peak_next = 8'd0;
        conf_next = 8'd20;

        if (enough_skin) begin
            // Prefer the highest count that persists for multiple rows. This is
            // what prevents one noisy 5-run row from forcing "5 fingers".
            if (hist5 >= ROW_SUPPORT_5_L) begin
                hint_next = 4'd5;
                peak_next = {1'b0, hist5};
                conf_next = (hist5 >= ROW_SUPPORT_L) ? 8'd92 : 8'd82;
            end else if (hist4 >= ROW_SUPPORT_L) begin
                hint_next = 4'd4;
                peak_next = {1'b0, hist4};
                conf_next = 8'd88;
            end else if (hist3 >= ROW_SUPPORT_L) begin
                hint_next = 4'd3;
                peak_next = {1'b0, hist3};
                conf_next = 8'd84;
            end else if (hist2 >= ROW_SUPPORT_L) begin
                hint_next = 4'd2;
                peak_next = {1'b0, hist2};
                conf_next = 8'd80;
            end else if (hist1 >= ROW_SUPPORT_L) begin
                hint_next = 4'd1;
                peak_next = {1'b0, hist1};
                conf_next = 8'd72;
            end else begin
                // Skin exists but no clean separated runs. Treat as one large
                // object only when there is significant area; otherwise zero.
                if (skin_acc > 16'd900) begin
                    hint_next = 4'd1;
                    peak_next = 8'd1;
                    conf_next = 8'd55;
                end else begin
                    hint_next = 4'd0;
                    peak_next = 8'd0;
                    conf_next = 8'd30;
                end
            end
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            rgb_phase     <= 2'd0;
            r_q           <= 8'd0;
            g_q           <= 8'd0;
            x             <= 7'd0;
            y             <= 7'd0;
            skin_acc      <= 16'd0;
            edge_acc      <= 8'd0;
            prev_skin     <= 1'b0;
            row_skin      <= 8'd0;
            run_width     <= 5'd0;
            row_runs      <= 4'd0;
            hist1         <= 7'd0;
            hist2         <= 7'd0;
            hist3         <= 7'd0;
            hist4         <= 7'd0;
            hist5         <= 7'd0;
            feature_valid <= 1'b0;
            skin_count    <= 16'd0;
            bbox_width    <= 8'd0;
            bbox_height   <= 8'd0;
            peak_count    <= 8'd0;
            edge_count    <= 8'd0;
            finger_hint   <= 4'd0;
            confidence    <= 8'd0;
        end else begin
            feature_valid <= 1'b0;

            if (frame_done) begin
                feature_valid <= 1'b1;
                skin_count    <= skin_acc;
                // These are coarse compatibility/debug values. V4 intentionally
                // removes expensive bbox min/max logic to stay inside Basys 3.
                bbox_width    <= enough_skin ? 8'd64 : 8'd0;
                bbox_height   <= enough_skin ? 8'd64 : 8'd0;
                peak_count    <= peak_next;
                edge_count    <= edge_acc;
                finger_hint   <= hint_next;
                confidence    <= conf_next;
            end

            if (host_first_byte) begin
                rgb_phase <= 2'd1;
                r_q       <= host_wdata;
                g_q       <= 8'd0;
                x         <= 7'd0;
                y         <= 7'd0;
                skin_acc  <= 16'd0;
                edge_acc  <= 8'd0;
                prev_skin <= 1'b0;
                row_skin  <= 8'd0;
                run_width <= 5'd0;
                row_runs  <= 4'd0;
                hist1     <= 7'd0;
                hist2     <= 7'd0;
                hist3     <= 7'd0;
                hist4     <= 7'd0;
                hist5     <= 7'd0;
            end else if (host_in_range) begin
                unique case (rgb_phase)
                    2'd0: begin
                        r_q       <= host_wdata;
                        rgb_phase <= 2'd1;
                    end
                    2'd1: begin
                        g_q       <= host_wdata;
                        rgb_phase <= 2'd2;
                    end
                    default: begin
                        rgb_phase <= 2'd0;

                        if (skin_now && (skin_acc != 16'hFFFF))
                            skin_acc <= skin_acc + 16'd1;

                        if ((x != 7'd0) && (skin_now != prev_skin) && (edge_acc != 8'hFF))
                            edge_acc <= edge_acc + 8'd1;

                        if (row_end) begin
                            if (row_skin_after >= ROW_MIN_SKIN_L) begin
                                unique case (row_runs_after)
                                    4'd1: if (hist1 != 7'h7F) hist1 <= hist1 + 7'd1;
                                    4'd2: if (hist2 != 7'h7F) hist2 <= hist2 + 7'd1;
                                    4'd3: if (hist3 != 7'h7F) hist3 <= hist3 + 7'd1;
                                    4'd4: if (hist4 != 7'h7F) hist4 <= hist4 + 7'd1;
                                    default: if ((row_runs_after >= 4'd5) && (hist5 != 7'h7F)) hist5 <= hist5 + 7'd1;
                                endcase
                            end
                            x         <= 7'd0;
                            if (y != 7'd127)
                                y <= y + 7'd1;
                            row_skin  <= 8'd0;
                            row_runs  <= 4'd0;
                            run_width <= 5'd0;
                            prev_skin <= 1'b0;
                        end else begin
                            x <= x + 7'd1;

                            row_skin <= row_skin_after;

                            if (valid_run_end) begin
                                if (row_runs < 4'd5)
                                    row_runs <= row_runs + 4'd1;
                            end

                            if (skin_now)
                                run_width <= (run_width == 5'h1F) ? 5'h1F : (run_width + 5'd1);
                            else
                                run_width <= 5'd0;

                            prev_skin <= skin_now;
                        end
                    end
                endcase
            end
        end
    end

endmodule
