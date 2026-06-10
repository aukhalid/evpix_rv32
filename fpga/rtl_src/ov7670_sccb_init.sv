// EVPIX-RV32 OV7670 SCCB/I2C-style register initializer, V3.
//
// Fixes over the previous version:
//   1) Uses a known Linux-driver-style RGB565 color matrix instead of the
//      YUV-style matrix that caused strong pink/magenta color cast.
//   2) Sets CLKRC=0x01. With the 25 MHz XCLK used by the top level this gives
//      a stable 30 fps class camera stream instead of the unstable over-clocked
//      stream that looked like 60+ fps but vibrated/teared.
//   3) Adds optional color-bar mode for wiring/color debugging. Hold SW10 high
//      and press reset to enable the OV7670 test pattern.
//
// Notes:
//   - OV7670 write address is 8'h42.
//   - SIOD/SDA is open-drain. FPGA only drives it low. You MUST have a pull-up
//     to the camera I/O voltage rail, typically 2.8 V or 3.3 V depending on the
//     exact module. 4.7 kOhm is a good starting value.
//   - Some cheap modules label SCCB as I2C. Use SIOC=SCL and SIOD=SDA.

module ov7670_sccb_init #(
    parameter int CLK_HZ  = 100_000_000,
    parameter int SCCB_HZ = 100_000
) (
    input  logic clk,
    input  logic reset,
    input  logic colorbar_enable,

    output logic ov_sioc,
    inout  wire  ov_siod,

    output logic init_done,
    output logic init_busy,
    output logic init_error
);

    localparam int QTR_CYCLES = (CLK_HZ / (SCCB_HZ * 4));
    localparam int QTR_W      = (QTR_CYCLES <= 2) ? 2 : $clog2(QTR_CYCLES + 1);
    localparam int PWR_DELAY_CYCLES = CLK_HZ / 20; // 50 ms
    localparam int PWR_W = $clog2(PWR_DELAY_CYCLES + 1);

    // Register sequence: stable VGA RGB565 setup.
    // The RGB565-specific registers/matrix match the public Linux OV7670 driver:
    // COM7 RGB, COM15 RGB565, COM9 gain ceiling, RGB matrix B3/B3/00/3D/A7/E4.
    function automatic logic [15:0] cfg_word(input int idx);
        begin
            unique case (idx)
                // Reset and stable 30 fps class timing.
                0:  cfg_word = 16'h1280; // COM7 reset
                1:  cfg_word = 16'h1101; // CLKRC: divide input clock, stable 30 fps class
                2:  cfg_word = 16'h3A04; // TSLB baseline ordering
                3:  cfg_word = 16'h1200; // COM7 VGA/YUV baseline before full setup

                // Window/timing values from common OV7670 VGA setup.
                4:  cfg_word = 16'h1713; // HSTART
                5:  cfg_word = 16'h1801; // HSTOP
                6:  cfg_word = 16'h32B6; // HREF
                7:  cfg_word = 16'h1902; // VSTART
                8:  cfg_word = 16'h1A7A; // VSTOP
                9:  cfg_word = 16'h030A; // VREF
                10: cfg_word = 16'h0C00; // COM3 no scaling/DCW
                11: cfg_word = 16'h3E00; // COM14 no manual scaling/PCLK divide
                12: cfg_word = 16'h1500; // COM10 baseline; do not invert syncs

                // Gamma curve and AEC/AGC/AWB defaults. These are the standard
                // OV7670 bring-up values used by mature drivers/examples.
                13: cfg_word = 16'h7A20;
                14: cfg_word = 16'h7B10;
                15: cfg_word = 16'h7C1E;
                16: cfg_word = 16'h7D35;
                17: cfg_word = 16'h7E5A;
                18: cfg_word = 16'h7F69;
                19: cfg_word = 16'h8076;
                20: cfg_word = 16'h8180;
                21: cfg_word = 16'h8288;
                22: cfg_word = 16'h838F;
                23: cfg_word = 16'h8496;
                24: cfg_word = 16'h85A3;
                25: cfg_word = 16'h86AF;
                26: cfg_word = 16'h87C4;
                27: cfg_word = 16'h88D7;
                28: cfg_word = 16'h89E8;

                29: cfg_word = 16'h13E0; // COM8: fast AEC, AEC step, band filter; AGC/AEC later
                30: cfg_word = 16'h0000; // GAIN
                31: cfg_word = 16'h1000; // AECH
                32: cfg_word = 16'h0D40; // COM4 reserved magic
                33: cfg_word = 16'h1418; // COM9 baseline gain ceiling
                34: cfg_word = 16'hA505;
                35: cfg_word = 16'hAB07;
                36: cfg_word = 16'h2495;
                37: cfg_word = 16'h2533;
                38: cfg_word = 16'h26E3;
                39: cfg_word = 16'h9F78;
                40: cfg_word = 16'hA068;
                41: cfg_word = 16'hA103;
                42: cfg_word = 16'hA6D8;
                43: cfg_word = 16'hA7D8;
                44: cfg_word = 16'hA8F0;
                45: cfg_word = 16'hA990;
                46: cfg_word = 16'hAA94;
                47: cfg_word = 16'h13E5; // enable AGC/AEC, AWB enabled later

                // Misc/reserved values from stable OV7670 setup.
                48: cfg_word = 16'h0E61;
                49: cfg_word = 16'h0F4B;
                50: cfg_word = 16'h1602;
                51: cfg_word = 16'h1E07; // MVFP baseline orientation
                52: cfg_word = 16'h2102;
                53: cfg_word = 16'h2291;
                54: cfg_word = 16'h2907;
                55: cfg_word = 16'h330B;
                56: cfg_word = 16'h350B;
                57: cfg_word = 16'h371D;
                58: cfg_word = 16'h3871;
                59: cfg_word = 16'h392A;
                60: cfg_word = 16'h3C78;
                61: cfg_word = 16'h4D40;
                62: cfg_word = 16'h4E20;
                63: cfg_word = 16'h6900;
                64: cfg_word = 16'h6B4A;
                65: cfg_word = 16'h7410;
                66: cfg_word = 16'h8D4F;
                67: cfg_word = 16'h8E00;
                68: cfg_word = 16'h8F00;
                69: cfg_word = 16'h9000;
                70: cfg_word = 16'h9100;
                71: cfg_word = 16'h9600;
                72: cfg_word = 16'h9A00;
                73: cfg_word = 16'hB084;
                74: cfg_word = 16'hB10C;
                75: cfg_word = 16'hB20E;
                76: cfg_word = 16'hB382;
                77: cfg_word = 16'hB80A;

                // White balance / color controls.
                78: cfg_word = 16'h430A;
                79: cfg_word = 16'h44F0;
                80: cfg_word = 16'h4534;
                81: cfg_word = 16'h4658;
                82: cfg_word = 16'h4728;
                83: cfg_word = 16'h483A;
                84: cfg_word = 16'h5988;
                85: cfg_word = 16'h5A88;
                86: cfg_word = 16'h5B44;
                87: cfg_word = 16'h5C67;
                88: cfg_word = 16'h5D49;
                89: cfg_word = 16'h5E0E;
                90: cfg_word = 16'h6C0A;
                91: cfg_word = 16'h6D55;
                92: cfg_word = 16'h6E11;
                93: cfg_word = 16'h6F9F;
                94: cfg_word = 16'h6A40;
                95: cfg_word = 16'h0140; // BLUE gain
                96: cfg_word = 16'h0260; // RED gain
                97: cfg_word = 16'h13E7; // COM8: AGC/AEC/AWB enabled

                // RGB565 format selection and RGB color matrix.
                98:  cfg_word = 16'h1204; // COM7 RGB, VGA
                99:  cfg_word = 16'h8C00; // RGB444 disabled
                100: cfg_word = 16'h0400; // COM1 CCIR601/default
                101: cfg_word = 16'h4010; // COM15 RGB565, normal 10..F0 range
                102: cfg_word = 16'h1438; // COM9 16x gain ceiling for RGB
                103: cfg_word = 16'h4FB3; // RGB matrix coefficient 1
                104: cfg_word = 16'h50B3; // RGB matrix coefficient 2
                105: cfg_word = 16'h5100;
                106: cfg_word = 16'h523D;
                107: cfg_word = 16'h53A7;
                108: cfg_word = 16'h54E4;
                109: cfg_word = 16'h589E; // RGB matrix signs
                110: cfg_word = 16'h3DC0; // COM13 gamma + UV saturation
                111: cfg_word = 16'h4108; // COM16 AWB gain enabled
                112: cfg_word = 16'h3F00; // EDGE off
                113: cfg_word = 16'h5640; // contrast

                // Optional color bar. Hold SW10=1 and press reset to enable.
                114: cfg_word = {8'h42, colorbar_enable ? 8'h08 : 8'h00};

                115: cfg_word = 16'hFFFF;
                default: cfg_word = 16'hFFFF;
            endcase
        end
    endfunction

    typedef enum logic [3:0] {
        ST_POWERUP,
        ST_LOAD,
        ST_START_1,
        ST_START_2,
        ST_BIT_LOW,
        ST_BIT_HIGH,
        ST_ACK_LOW,
        ST_ACK_HIGH,
        ST_STOP_1,
        ST_STOP_2,
        ST_STOP_3,
        ST_NEXT,
        ST_DONE
    } state_t;

    state_t state;
    logic [PWR_W-1:0] pwr_cnt;
    logic [QTR_W-1:0] qtr_cnt;
    logic             tick;

    logic [7:0] dev_addr, reg_addr, reg_data, tx_byte;
    logic [7:0] bit_idx;
    logic [1:0] byte_idx;
    int         cfg_idx;
    logic [15:0] word_now;
    logic        siod_drive_low;

    assign ov_siod = siod_drive_low ? 1'b0 : 1'bz;

    always_comb begin
        tick = (qtr_cnt == QTR_CYCLES[QTR_W-1:0] - 1'b1);
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            qtr_cnt <= '0;
        end else if (state == ST_POWERUP || state == ST_DONE) begin
            qtr_cnt <= '0;
        end else begin
            if (tick)
                qtr_cnt <= '0;
            else
                qtr_cnt <= qtr_cnt + {{(QTR_W-1){1'b0}}, 1'b1};
        end
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            state          <= ST_POWERUP;
            pwr_cnt        <= '0;
            cfg_idx        <= 0;
            byte_idx       <= 2'd0;
            bit_idx        <= 8'd7;
            dev_addr       <= 8'h42;
            reg_addr       <= 8'd0;
            reg_data       <= 8'd0;
            tx_byte        <= 8'h42;
            ov_sioc        <= 1'b1;
            siod_drive_low <= 1'b0;
            init_done      <= 1'b0;
            init_busy      <= 1'b1;
            init_error     <= 1'b0;
        end else begin
            init_busy <= !init_done;

            unique case (state)
                ST_POWERUP: begin
                    ov_sioc        <= 1'b1;
                    siod_drive_low <= 1'b0;
                    if (pwr_cnt == PWR_DELAY_CYCLES[PWR_W-1:0] - 1'b1) begin
                        pwr_cnt <= '0;
                        state   <= ST_LOAD;
                    end else begin
                        pwr_cnt <= pwr_cnt + {{(PWR_W-1){1'b0}}, 1'b1};
                    end
                end

                ST_LOAD: begin
                    word_now = cfg_word(cfg_idx);
                    if (word_now == 16'hFFFF) begin
                        state <= ST_DONE;
                    end else begin
                        dev_addr <= 8'h42;
                        reg_addr <= word_now[15:8];
                        reg_data <= word_now[7:0];
                        tx_byte  <= 8'h42;
                        byte_idx <= 2'd0;
                        bit_idx  <= 8'd7;
                        state    <= ST_START_1;
                    end
                end

                ST_START_1: if (tick) begin
                    ov_sioc        <= 1'b1;
                    siod_drive_low <= 1'b0;
                    state          <= ST_START_2;
                end

                ST_START_2: if (tick) begin
                    ov_sioc        <= 1'b1;
                    siod_drive_low <= 1'b1; // START: SDA falls while SCL high
                    state          <= ST_BIT_LOW;
                end

                ST_BIT_LOW: if (tick) begin
                    ov_sioc        <= 1'b0;
                    siod_drive_low <= ~tx_byte[bit_idx[2:0]];
                    state          <= ST_BIT_HIGH;
                end

                ST_BIT_HIGH: if (tick) begin
                    ov_sioc <= 1'b1;
                    if (bit_idx == 0) begin
                        state <= ST_ACK_LOW;
                    end else begin
                        bit_idx <= bit_idx - 8'd1;
                        state   <= ST_BIT_LOW;
                    end
                end

                ST_ACK_LOW: if (tick) begin
                    ov_sioc        <= 1'b0;
                    siod_drive_low <= 1'b0; // release for ACK
                    state          <= ST_ACK_HIGH;
                end

                ST_ACK_HIGH: if (tick) begin
                    ov_sioc <= 1'b1;
                    // Keep running even if ACK is not seen, but flag LED9 through init_error.
                    // A persistent init_error usually means missing/wrong SIOD/SIOC wiring or
                    // missing SDA pull-up.
                    if (ov_siod)
                        init_error <= 1'b1;

                    if (byte_idx == 2'd0) begin
                        byte_idx <= 2'd1;
                        tx_byte  <= reg_addr;
                        bit_idx  <= 8'd7;
                        state    <= ST_BIT_LOW;
                    end else if (byte_idx == 2'd1) begin
                        byte_idx <= 2'd2;
                        tx_byte  <= reg_data;
                        bit_idx  <= 8'd7;
                        state    <= ST_BIT_LOW;
                    end else begin
                        state <= ST_STOP_1;
                    end
                end

                ST_STOP_1: if (tick) begin
                    ov_sioc        <= 1'b0;
                    siod_drive_low <= 1'b1;
                    state          <= ST_STOP_2;
                end

                ST_STOP_2: if (tick) begin
                    ov_sioc        <= 1'b1;
                    siod_drive_low <= 1'b1;
                    state          <= ST_STOP_3;
                end

                ST_STOP_3: if (tick) begin
                    ov_sioc        <= 1'b1;
                    siod_drive_low <= 1'b0; // STOP: SDA rises while SCL high
                    state          <= ST_NEXT;
                end

                ST_NEXT: if (tick) begin
                    cfg_idx <= cfg_idx + 1;
                    // Extra settle after soft reset.
                    if (cfg_idx == 0)
                        state <= ST_POWERUP;
                    else
                        state <= ST_LOAD;
                end

                ST_DONE: begin
                    ov_sioc        <= 1'b1;
                    siod_drive_low <= 1'b0;
                    init_done      <= 1'b1;
                    init_busy      <= 1'b0;
                end

                default: state <= ST_POWERUP;
            endcase
        end
    end

endmodule
