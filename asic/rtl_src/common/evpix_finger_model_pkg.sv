// Default fixed-point model/threshold constants for the EVPIX TinyML finger
// counter demo.  The shipped RTL classifier uses these as a lightweight
// pretrained feature model.  Replace with values exported by the training script
// after collecting your own samples for best accuracy.

package evpix_finger_model_pkg;
    parameter int Q_FRAC = 8;

    // Feature-quality thresholds for 128x128 camera frames.
    parameter logic [15:0] SKIN_MIN_PIXELS      = 16'd180;
    parameter logic [15:0] SKIN_GOOD_PIXELS     = 16'd700;
    parameter logic [7:0]  BBOX_MIN_WIDTH       = 8'd12;
    parameter logic [7:0]  BBOX_MIN_HEIGHT      = 8'd16;
    parameter logic [7:0]  STABLE_FRAMES        = 8'd2;

    // Q8.8 reference centers for peak count classes 0..5.
    // Kept scalar instead of an unpacked parameter array so older Yosys builds
    // and OpenROAD canonicalization do not fail on package syntax.
    parameter logic signed [15:0] PEAK_CENTER_Q8_8_0 = 16'sd0;
    parameter logic signed [15:0] PEAK_CENTER_Q8_8_1 = 16'sd256;
    parameter logic signed [15:0] PEAK_CENTER_Q8_8_2 = 16'sd512;
    parameter logic signed [15:0] PEAK_CENTER_Q8_8_3 = 16'sd768;
    parameter logic signed [15:0] PEAK_CENTER_Q8_8_4 = 16'sd1024;
    parameter logic signed [15:0] PEAK_CENTER_Q8_8_5 = 16'sd1280;
endpackage
