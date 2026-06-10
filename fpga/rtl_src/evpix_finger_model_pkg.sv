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

    // Q8.8 reference centers for peak count classes 0..5. These are included
    // so the demo has an explicit model artifact and so the Python exporter has
    // a compatible target format.
    parameter logic signed [15:0] PEAK_CENTER_Q8_8 [0:5] = '{
        16'sd0,    // 0 fingers/no hand
        16'sd256,  // 1 finger
        16'sd512,  // 2 fingers
        16'sd768,  // 3 fingers
        16'sd1024, // 4 fingers
        16'sd1280  // 5 fingers
    };
endpackage
