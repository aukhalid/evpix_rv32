// ============================================================
// File: evpix_tinyml_classifier.sv
// EVPIX TinyML classifier, V5 stability/hysteresis tuned.
// ============================================================
// Why V5 exists:
//   V4 could still shuffle between neighboring counts, for example 5 -> 4 -> 5,
//   because the displayed result changed after only a small number of matching
//   raw frames.
//
// V5 fix:
//   - Adds candidate-count hysteresis.
//   - A new non-zero count must persist for several frames before it replaces
//     the currently displayed count.
//   - Switching downward from 5 needs extra confirmation, so a single merged
//     fingertip row does not make 5 fingers flicker to 4.
//   - Zero/hand-removed clears faster than non-zero changes.
//
// This block is intentionally small. It does not change CPU, IPU, camera,
// memory map, BIST, display RAMs, or EVPIX image-processing algorithms.

module evpix_tinyml_classifier #(
    // Minimum object quality checks.
    parameter logic [15:0] SKIN_MIN_PIXELS = 16'd220,
    parameter logic [7:0]  CONF_MIN_SHOW   = 8'd38,

    // Temporal filter. At 30 camera FPS:
    //   4 frames ~= 133 ms, 6 frames ~= 200 ms.
    parameter int NONZERO_CONFIRM_FRAMES = 4,
    parameter int ZERO_CONFIRM_FRAMES    = 2,
    parameter int FIVE_DOWN_CONFIRM      = 6
) (
    input  logic        clk,
    input  logic        reset,

    input  logic        feature_valid,
    input  logic [15:0] skin_count,
    input  logic [7:0]  bbox_width,
    input  logic [7:0]  bbox_height,
    input  logic [7:0]  peak_count,
    input  logic [7:0]  edge_count,
    input  logic [3:0]  finger_hint,
    input  logic [7:0]  feature_confidence,

    output logic        result_valid,
    output logic [2:0]  finger_count,
    output logic [7:0]  confidence,
    output logic [15:0] debug_skin_count,
    output logic [7:0]  debug_peak_count,
    output logic [7:0]  debug_bbox_width,
    output logic [7:0]  debug_bbox_height
);

    localparam logic [2:0] NONZERO_CONFIRM_L   = NONZERO_CONFIRM_FRAMES;
    localparam logic [2:0] ZERO_CONFIRM_L      = ZERO_CONFIRM_FRAMES;
    localparam logic [2:0] FIVE_DOWN_CONFIRM_L = FIVE_DOWN_CONFIRM;

    logic [2:0] raw_count;
    logic [2:0] candidate_count;
    logic [2:0] candidate_score;
    logic [2:0] confirm_needed;
    logic [7:0] stable_confidence;

    assign debug_skin_count  = skin_count;
    assign debug_peak_count  = peak_count;
    assign debug_bbox_width  = bbox_width;
    assign debug_bbox_height = bbox_height;

    always_comb begin
        if ((skin_count < SKIN_MIN_PIXELS) || (feature_confidence < CONF_MIN_SHOW))
            raw_count = 3'd0;
        else if (finger_hint > 4'd5)
            raw_count = 3'd5;
        else
            raw_count = finger_hint[2:0];
    end

    always_comb begin
        confirm_needed = NONZERO_CONFIRM_L;

        if (raw_count == 3'd0) begin
            confirm_needed = ZERO_CONFIRM_L;
        end else if ((finger_count == 3'd5) && (raw_count < 3'd5)) begin
            // Strongly suppress the common 5->4->5 flicker.
            confirm_needed = FIVE_DOWN_CONFIRM_L;
        end else if ((finger_count != 3'd0) && (raw_count != finger_count)) begin
            confirm_needed = NONZERO_CONFIRM_L;
        end
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            result_valid      <= 1'b0;
            finger_count      <= 3'd0;
            confidence        <= 8'd0;
            candidate_count   <= 3'd0;
            candidate_score   <= 3'd0;
            stable_confidence <= 8'd0;
        end else begin
            result_valid <= 1'b0;

            if (feature_valid) begin
                result_valid <= 1'b1;

                if (raw_count == finger_count) begin
                    // Current result is confirmed again. Clear pending switch.
                    candidate_count   <= raw_count;
                    candidate_score   <= 3'd0;
                    stable_confidence <= feature_confidence;
                    confidence        <= feature_confidence;
                end else begin
                    // New candidate must persist for confirm_needed frames.
                    if (raw_count == candidate_count) begin
                        if (candidate_score != 3'd7)
                            candidate_score <= candidate_score + 3'd1;
                    end else begin
                        candidate_count <= raw_count;
                        candidate_score <= 3'd1;
                    end

                    if ((raw_count == candidate_count) && (candidate_score >= confirm_needed)) begin
                        finger_count      <= raw_count;
                        stable_confidence <= feature_confidence;
                        confidence        <= feature_confidence;
                        candidate_score   <= 3'd0;
                    end else begin
                        // Hold last stable value and show reduced confidence while
                        // the candidate is still being verified.
                        confidence <= (stable_confidence > 8'd20) ? (stable_confidence - 8'd20) : stable_confidence;
                    end
                end
            end
        end
    end

endmodule
