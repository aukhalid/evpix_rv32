// EVPIX VGA frame display DB v7: resource-fit clean UI, no stripe text renderer.
// v10 v7-style full-BIST resource-fit
module evpix_vga_frame_display_db #(
    parameter int IMG_W    = 128,
    parameter int IMG_H    = 128,
    parameter int SRC_BASE = 0,
    parameter int DST_BASE = 32'h0000_C000,
    parameter int LEFT_X   = 96,
    parameter int TOP_Y    = 176,
    parameter int GAP      = 64
) (
    input  logic        clk_wr,
    input  logic        clk_pix,
    input  logic        reset,

    input  logic        right_bypass_src,
    input  logic [1:0]  overlay_mode,   // 0=image, 1=CPU welcome, 2=BIST table
    input  logic [1:0]  bist_page,
    input  logic        bist_done,
    input  logic        bist_pass,
    input  logic [5:0]  bist_fail_count,
    input  logic [31:0] bist_reg_got [0:31],
    input  logic [7:0]  bist_mem_got [0:10],

    // Live IPU/research overlay inputs
    input  logic        ipu_mode,
    input  logic        ipu_valid,
    input  logic [2:0]  ipu_program_id,
    input  logic [31:0] fps_estimate,
    input  logic [31:0] last_process_cycles,
    input  logic [31:0] frame_count,
    input  logic [31:0] dropped_frame_count,
    input  logic [31:0] spi_error_count,
    input  logic [31:0] perf_cycle_count,
    input  logic [31:0] perf_ipu_busy_count,
    input  logic [31:0] perf_conv_count,
    input  logic [31:0] perf_pool_count,
    input  logic [31:0] perf_stall_count,
    input  logic [31:0] debug_ipu_result,

    // TinyML overlay inputs, intentionally minimal for Basys 3 LUT budget.
    input  logic        ml_mode,
    input  logic        ml_valid,
    input  logic [2:0]  ml_finger_count,
    input  logic [15:0] ml_skin_count,
    input  logic [7:0]  ml_bbox_width,
    input  logic [7:0]  ml_bbox_height,
    input  logic [7:0]  ml_peak_count,
    input  logic [7:0]  ml_confidence,

    input  logic [9:0]  x,
    input  logic [9:0]  y,
    input  logic        active,

    input  logic        host_we,
    input  logic [31:0] host_addr,
    input  logic [7:0]  host_wdata,
    input  logic        src_frame_done,  // pulse after a complete source frame was written

    input  logic        proc_we,
    input  logic [31:0] proc_addr,
    input  logic [7:0]  proc_wdata,

    output logic [3:0]  vga_r,
    output logic [3:0]  vga_g,
    output logic [3:0]  vga_b
);

    localparam int PIXELS    = IMG_W * IMG_H;
    localparam int RGB_BYTES = PIXELS * 3;
    localparam int RIGHT_X   = LEFT_X + IMG_W + GAP;
    localparam int PIX_AW    = $clog2(PIXELS);

    // ------------------------------------------------------------------------
    // BRAM-safe double-buffered source frame display.
    //
    // IMPORTANT SYNTHESIS FIX:
    //   Do not put these RAM writes in an async-reset always_ff block.
    //   Vivado cannot infer BRAM/DRAM for a memory that is sensitive to an
    //   asynchronous reset.  The RAM contents do not need reset; only the small
    //   control registers below are reset.
    // ------------------------------------------------------------------------
    (* ram_style = "block" *) logic [11:0] src_rgb444_a [0:PIXELS-1];
    (* ram_style = "block" *) logic [11:0] src_rgb444_b [0:PIXELS-1];
    (* ram_style = "block" *) logic [7:0]  dst_gray     [0:PIXELS-1];

    logic src_wr_sel;
    logic src_rd_sel;

    logic [7:0]  cap_r;
    logic [7:0]  cap_g;
    logic [1:0]  host_rgb_phase_wr;
    logic [PIX_AW-1:0] cap_pix_addr;
    logic [31:0] proc_index_wr;
    logic        proc_index_valid;
    logic        host_in_src_range;
    logic        host_new_frame_byte;

    assign host_in_src_range   = host_we && (host_addr >= SRC_BASE) && (host_addr < (SRC_BASE + RGB_BYTES));
    assign host_new_frame_byte = host_in_src_range && (host_addr == SRC_BASE);
    assign proc_index_valid    = proc_we && (proc_addr >= DST_BASE) && ((proc_addr - DST_BASE) < PIXELS);
    assign proc_index_wr       = proc_addr - DST_BASE;

    // Reset only control registers, not RAM arrays.
    always_ff @(posedge clk_wr or posedge reset) begin
        if (reset) begin
            src_wr_sel        <= 1'b0;
            src_rd_sel        <= 1'b1;
            cap_r             <= 8'd0;
            cap_g             <= 8'd0;
            cap_pix_addr      <= '0;
            host_rgb_phase_wr <= 2'd0;
        end else begin
            // The OV7670 capture block writes SRC_BASE..SRC_BASE+49151 in
            // byte order R,G,B.  Track byte phase sequentially instead of using
            // expensive /3 and %3 operators.
            if (host_new_frame_byte) begin
                // First byte of the frame is always R for pixel 0.
                cap_r             <= host_wdata;
                host_rgb_phase_wr <= 2'd1;
                cap_pix_addr      <= '0;
            end else if (host_in_src_range) begin
                unique case (host_rgb_phase_wr)
                    2'd0: begin
                        cap_r             <= host_wdata;
                        host_rgb_phase_wr <= 2'd1;
                    end
                    2'd1: begin
                        cap_g             <= host_wdata;
                        host_rgb_phase_wr <= 2'd2;
                    end
                    default: begin
                        host_rgb_phase_wr <= 2'd0;
                        if (cap_pix_addr != PIXELS-1)
                            cap_pix_addr <= cap_pix_addr + {{(PIX_AW-1){1'b0}}, 1'b1};
                    end
                endcase
            end

            // Swap the completed camera frame into the VGA read side. The final
            // pixel write sees the old src_wr_sel, then the next frame writes the
            // other back buffer.
            if (src_frame_done) begin
                src_rd_sel <= src_wr_sel;
                src_wr_sel <= ~src_wr_sel;
            end
        end
    end

    // BRAM write ports. No reset here: this is required for Vivado BRAM inference.
    always_ff @(posedge clk_wr) begin
        if (host_in_src_range && !host_new_frame_byte && (host_rgb_phase_wr == 2'd2) && (cap_pix_addr < PIXELS)) begin
            if (!src_wr_sel)
                src_rgb444_a[cap_pix_addr] <= {cap_r[7:4], cap_g[7:4], host_wdata[7:4]};
            else
                src_rgb444_b[cap_pix_addr] <= {cap_r[7:4], cap_g[7:4], host_wdata[7:4]};
        end

        if (proc_index_valid)
            dst_gray[proc_index_wr[PIX_AW-1:0]] <= proc_wdata;
    end

    logic in_left, in_right;
    logic pane_active;
    logic [9:0] img_x, img_y;
    logic [31:0] pix_index;
    logic [11:0] src_a_q, src_b_q, src_q;
    logic [7:0]  dst_q;
    logic        in_left_q, in_right_q, active_q, right_bypass_src_q;
    logic        src_rd_sel_pix_q;
    logic [1:0]  overlay_mode_q;
    logic [9:0]  x_q, y_q;

    always_comb begin
        in_left  = active && (x >= LEFT_X) && (x < LEFT_X + IMG_W) && (y >= TOP_Y) && (y < TOP_Y + IMG_H);
        in_right = active && (x >= RIGHT_X) && (x < RIGHT_X + IMG_W) && (y >= TOP_Y) && (y < TOP_Y + IMG_H);
        pane_active = in_left || in_right;
        if (in_left) begin
            img_x = x - LEFT_X; img_y = y - TOP_Y;
        end else if (in_right) begin
            img_x = x - RIGHT_X; img_y = y - TOP_Y;
        end else begin
            img_x = 10'd0; img_y = 10'd0;
        end
        pix_index = (img_y * IMG_W) + img_x;
    end

    always_ff @(posedge clk_pix) begin
        if (pane_active && (pix_index < PIXELS)) begin
            // Read frame BRAMs only while the VGA beam is inside one of the two
            // 128x128 panes.  Outside the panes, force the registered image
            // samples to zero so stale BRAM data cannot leak through as vertical
            // analog stripes on some VGA monitors/cables.
            src_a_q <= src_rgb444_a[pix_index[PIX_AW-1:0]];
            src_b_q <= src_rgb444_b[pix_index[PIX_AW-1:0]];
            dst_q   <= dst_gray[pix_index[PIX_AW-1:0]];
        end else begin
            src_a_q <= 12'b0;
            src_b_q <= 12'b0;
            dst_q   <= 8'b0;
        end
        src_rd_sel_pix_q <= src_rd_sel;
        in_left_q <= in_left; in_right_q <= in_right; active_q <= active;
        right_bypass_src_q <= right_bypass_src; overlay_mode_q <= overlay_mode;
        x_q <= x; y_q <= y;
    end

    assign src_q = (!src_rd_sel_pix_q) ? src_a_q : src_b_q;

    function automatic logic [3:0] hex_nibble(input logic [31:0] value, input int pos);
        begin
            hex_nibble = value[4*(7-pos) +: 4];
        end
    endfunction

    function automatic logic [7:0] hex_char(input logic [3:0] n);
        begin
            hex_char = (n < 10) ? (8'd48 + n) : (8'd55 + n);
        end
    endfunction

    function automatic logic [7:0] dec2_char(input int value, input int pos);
        int tens; int ones;
        begin
            tens = (value / 10) % 10; ones = value % 10;
            if (pos == 0) dec2_char = (value < 10) ? 8'd32 : (8'd48 + tens);
            else dec2_char = 8'd48 + ones;
        end
    endfunction

    function automatic logic [7:0] dec3_char(input int value, input int pos);
        int h; int t; int o;
        begin
            h = (value / 100) % 10; t = (value / 10) % 10; o = value % 10;
            if (pos == 0) dec3_char = (value < 100) ? 8'd32 : (8'd48 + h);
            else if (pos == 1) dec3_char = (value < 10) ? 8'd32 : (8'd48 + t);
            else dec3_char = 8'd48 + o;
        end
    endfunction

    function automatic logic [31:0] expected_reg(input int idx);
        begin
            unique case (idx)
                1: expected_reg=32'h0000000A; 2: expected_reg=32'hFFFFFFFD; 3: expected_reg=32'h00000005; 4: expected_reg=32'h0000000F;
                5: expected_reg=32'h00000007; 6: expected_reg=32'h00000001; 7: expected_reg=32'h00000001; 8: expected_reg=32'h0000000C;
                9: expected_reg=32'h0000001F; 10: expected_reg=32'h00000000; 11: expected_reg=32'h00000014; 12: expected_reg=32'h00000007;
                13: expected_reg=32'hFFFFFFFE; 14: expected_reg=32'h0000000F; 15: expected_reg=32'h00000005; 16: expected_reg=32'h00000007;
                17: expected_reg=32'h0000000F; 18: expected_reg=32'h00000008; 19: expected_reg=32'h00000280; 20: expected_reg=32'h00000000;
                21: expected_reg=32'hFFFFFFFF; 22: expected_reg=32'h00000001; 23: expected_reg=32'h00000000; 24: expected_reg=32'h12345000;
                25: expected_reg=32'h00000060; 26: expected_reg=32'h00000100; 27: expected_reg=32'h0000000A; 28: expected_reg=32'h000000C0;
                29: expected_reg=32'h000000EC; 30: expected_reg=32'h000000D0; 31: expected_reg=32'h0000FFFD;
                default: expected_reg=32'h00000000;
            endcase
        end
    endfunction

    function automatic logic [7:0] expected_mem(input int k);
        begin
            unique case(k)
                0: expected_mem=8'h0A; 1: expected_mem=8'h00; 2: expected_mem=8'h00; 3: expected_mem=8'h00;
                4: expected_mem=8'h05; 5: expected_mem=8'h00; 6: expected_mem=8'h07; 7: expected_mem=8'hFD;
                8: expected_mem=8'hFF; 9: expected_mem=8'hFF; 10: expected_mem=8'hFF;
                default: expected_mem=8'h00;
            endcase
        end
    endfunction

    function automatic int mem_addr_for_test(input int k);
        begin
            unique case(k)
                0: mem_addr_for_test=256; 1: mem_addr_for_test=257; 2: mem_addr_for_test=258; 3: mem_addr_for_test=259;
                4: mem_addr_for_test=260; 5: mem_addr_for_test=261; 6: mem_addr_for_test=262; 7: mem_addr_for_test=264;
                8: mem_addr_for_test=265; 9: mem_addr_for_test=266; 10: mem_addr_for_test=267; default: mem_addr_for_test=0;
            endcase
        end
    endfunction


    function automatic logic [7:0] short_hex_char(input logic [31:0] value, input int nib);
        begin
            short_hex_char = hex_char(value[4*(7-nib) +: 4]);
        end
    endfunction

    function automatic logic [7:0] instr_name_char(input int item, input int pos);
        begin
            instr_name_char = 8'd32;
            unique case (item)
                // Register result rows, item 0..30 = x1..x31
                0,1,2,3,4,25: begin // ADDI group
                    unique case (pos) 0:instr_name_char=8'd65;1:instr_name_char=8'd68;2:instr_name_char=8'd68;3:instr_name_char=8'd73; default: ; endcase
                end
                5: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd76;2:instr_name_char=8'd84;3:instr_name_char=8'd73; default: ; endcase end // SLTI
                6: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd76;2:instr_name_char=8'd84;3:instr_name_char=8'd85;4:instr_name_char=8'd73; default: ; endcase end // SLTUI
                7: begin unique case(pos) 0:instr_name_char=8'd65;1:instr_name_char=8'd78;2:instr_name_char=8'd68;3:instr_name_char=8'd73; default: ; endcase end // ANDI
                8: begin unique case(pos) 0:instr_name_char=8'd79;1:instr_name_char=8'd82;2:instr_name_char=8'd73; default: ; endcase end // ORI
                9: begin unique case(pos) 0:instr_name_char=8'd88;1:instr_name_char=8'd79;2:instr_name_char=8'd82;3:instr_name_char=8'd73; default: ; endcase end // XORI
                10: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd76;2:instr_name_char=8'd76;3:instr_name_char=8'd73; default: ; endcase end // SLLI
                11: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd82;2:instr_name_char=8'd76;3:instr_name_char=8'd73; default: ; endcase end // SRLI
                12: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd82;2:instr_name_char=8'd65;3:instr_name_char=8'd73; default: ; endcase end // SRAI
                13: begin unique case(pos) 0:instr_name_char=8'd65;1:instr_name_char=8'd68;2:instr_name_char=8'd68; default: ; endcase end // ADD
                14: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd85;2:instr_name_char=8'd66; default: ; endcase end // SUB
                15: begin unique case(pos) 0:instr_name_char=8'd65;1:instr_name_char=8'd78;2:instr_name_char=8'd68; default: ; endcase end // AND
                16: begin unique case(pos) 0:instr_name_char=8'd79;1:instr_name_char=8'd82; default: ; endcase end // OR
                17: begin unique case(pos) 0:instr_name_char=8'd88;1:instr_name_char=8'd79;2:instr_name_char=8'd82; default: ; endcase end // XOR
                18: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd76;2:instr_name_char=8'd76; default: ; endcase end // SLL
                19: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd82;2:instr_name_char=8'd76; default: ; endcase end // SRL
                20: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd82;2:instr_name_char=8'd65; default: ; endcase end // SRA
                21: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd76;2:instr_name_char=8'd84; default: ; endcase end // SLT
                22: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd76;2:instr_name_char=8'd84;3:instr_name_char=8'd85; default: ; endcase end // SLTU
                23: begin unique case(pos) 0:instr_name_char=8'd76;1:instr_name_char=8'd85;2:instr_name_char=8'd73; default: ; endcase end // LUI
                24: begin unique case(pos) 0:instr_name_char=8'd65;1:instr_name_char=8'd85;2:instr_name_char=8'd73;3:instr_name_char=8'd80;4:instr_name_char=8'd67; default: ; endcase end // AUIPC
                26: begin unique case(pos) 0:instr_name_char=8'd76;1:instr_name_char=8'd87; default: ; endcase end // LW x27
                27: begin unique case(pos) 0:instr_name_char=8'd74;1:instr_name_char=8'd65;2:instr_name_char=8'd76; default: ; endcase end // JAL result x28
                28: begin unique case(pos) 0:instr_name_char=8'd74;1:instr_name_char=8'd65;2:instr_name_char=8'd76;3:instr_name_char=8'd82; default: ; endcase end // JALR setup/result x29
                29: begin unique case(pos) 0:instr_name_char=8'd74;1:instr_name_char=8'd65;2:instr_name_char=8'd76;3:instr_name_char=8'd82; default: ; endcase end // JALR link x30
                30: begin unique case(pos) 0:instr_name_char=8'd76;1:instr_name_char=8'd72;2:instr_name_char=8'd85; default: ; endcase end // LHU x31
                // Memory rows, item 31..41
                31,32,33,34,38,39,40,41: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd87; default: ; endcase end // SW bytes
                35,36: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd72; default: ; endcase end // SH bytes
                37: begin unique case(pos) 0:instr_name_char=8'd83;1:instr_name_char=8'd66; default: ; endcase end // SB byte
                default: ;
            endcase
        end
    endfunction

    function automatic logic [7:0] program_name_char(input logic [2:0] pid, input int pos);
        begin
            program_name_char = 8'd32;
            unique case (pid)
                3'd0: begin unique case(pos) 0:program_name_char=8'd83;1:program_name_char=8'd79;2:program_name_char=8'd66;3:program_name_char=8'd69;4:program_name_char=8'd76; default: ; endcase end // SOBEL
                3'd1: begin unique case(pos) 0:program_name_char=8'd71;1:program_name_char=8'd82;2:program_name_char=8'd65;3:program_name_char=8'd89; default: ; endcase end // GRAY
                3'd2: begin unique case(pos) 0:program_name_char=8'd84;1:program_name_char=8'd72;2:program_name_char=8'd82;3:program_name_char=8'd69;4:program_name_char=8'd83;5:program_name_char=8'd72; default: ; endcase end // THRESH
                3'd3: begin unique case(pos) 0:program_name_char=8'd67;1:program_name_char=8'd79;2:program_name_char=8'd78;3:program_name_char=8'd86; default: ; endcase end // CONV
                default: ;
            endcase
        end
    endfunction

    function automatic logic [7:0] image_overlay_char(input int tr, input int tc);
        begin
            image_overlay_char = 8'd32;

            // V3 ultra-small TinyML overlay. Shows only the fields needed for
            // the demo and removes CONF/BOX/PEAKS text to recover LUTs.
            if (ml_mode) begin
                if (tr == 0) begin
                    // "TINYML MODE"
                    unique case (tc)
                        0:image_overlay_char=8'd84; 1:image_overlay_char=8'd73; 2:image_overlay_char=8'd78; 3:image_overlay_char=8'd89; 4:image_overlay_char=8'd77; 5:image_overlay_char=8'd76;
                        7:image_overlay_char=8'd77; 8:image_overlay_char=8'd79; 9:image_overlay_char=8'd68; 10:image_overlay_char=8'd69;
                        default: ;
                    endcase
                end else if (tr == 1) begin
                    // "FINGERS:N"
                    unique case (tc)
                        0:image_overlay_char=8'd70; 1:image_overlay_char=8'd73; 2:image_overlay_char=8'd78; 3:image_overlay_char=8'd71; 4:image_overlay_char=8'd69; 5:image_overlay_char=8'd82; 6:image_overlay_char=8'd83; 7:image_overlay_char=8'd58;
                        8:image_overlay_char=8'd48 + {5'd0, ml_finger_count};
                        default: ;
                    endcase
                end
            end
            // Row 0: title
            else if (tr == 0) begin
                unique case (tc)
                    0:image_overlay_char=8'd73;1:image_overlay_char=8'd80;2:image_overlay_char=8'd85;4:image_overlay_char=8'd77;5:image_overlay_char=8'd79;6:image_overlay_char=8'd68;7:image_overlay_char=8'd69;9:image_overlay_char=8'd45;11:image_overlay_char=8'd69;12:image_overlay_char=8'd86;13:image_overlay_char=8'd80;14:image_overlay_char=8'd73;15:image_overlay_char=8'd88;16:image_overlay_char=8'd45;17:image_overlay_char=8'd82;18:image_overlay_char=8'd86;19:image_overlay_char=8'd51;20:image_overlay_char=8'd50;
                    default: ;
                endcase
            end
            // Row 1: selected instruction
            else if (tr == 1) begin
                unique case (tc)
                    0:image_overlay_char=8'd73;1:image_overlay_char=8'd78;2:image_overlay_char=8'd83;3:image_overlay_char=8'd84;4:image_overlay_char=8'd82;5:image_overlay_char=8'd58;
                    7,8,9,10,11,12: image_overlay_char = ipu_valid ? program_name_char(ipu_program_id, tc-7) : ((tc==7)?8'd78:((tc==8)?8'd79:((tc==9)?8'd78:((tc==10)?8'd69:8'd32)))); // NONE
                    20:image_overlay_char=8'd70;21:image_overlay_char=8'd80;22:image_overlay_char=8'd83;23:image_overlay_char=8'd58;
                    25:image_overlay_char=dec3_char(fps_estimate,0);26:image_overlay_char=dec3_char(fps_estimate,1);27:image_overlay_char=dec3_char(fps_estimate,2);
                    default: ;
                endcase
            end
            // Row 2: frame counters
            else if (tr == 2) begin
                unique case (tc)
                    0:image_overlay_char=8'd70;1:image_overlay_char=8'd82;2:image_overlay_char=8'd65;3:image_overlay_char=8'd77;4:image_overlay_char=8'd69;5:image_overlay_char=8'd58;
                    7,8,9,10,11,12,13,14: image_overlay_char=short_hex_char(frame_count,tc-7);
                    17:image_overlay_char=8'd68;18:image_overlay_char=8'd82;19:image_overlay_char=8'd79;20:image_overlay_char=8'd80;21:image_overlay_char=8'd58;
                    23,24,25,26,27,28,29,30: image_overlay_char=short_hex_char(dropped_frame_count,tc-23);
                    33:image_overlay_char=8'd69;34:image_overlay_char=8'd82;35:image_overlay_char=8'd82;36:image_overlay_char=8'd58;
                    38,39,40,41,42,43,44,45: image_overlay_char=short_hex_char(spi_error_count,tc-38);
                    default: ;
                endcase
            end
            // Row 3: processing latency and result
            else if (tr == 3) begin
                unique case (tc)
                    0:image_overlay_char=8'd80;1:image_overlay_char=8'd82;2:image_overlay_char=8'd79;3:image_overlay_char=8'd67;4:image_overlay_char=8'd95;5:image_overlay_char=8'd67;6:image_overlay_char=8'd89;7:image_overlay_char=8'd67;8:image_overlay_char=8'd58;
                    10,11,12,13,14,15,16,17: image_overlay_char=short_hex_char(last_process_cycles,tc-10);
                    20:image_overlay_char=8'd82;21:image_overlay_char=8'd69;22:image_overlay_char=8'd83;23:image_overlay_char=8'd58;
                    25,26,27,28,29,30,31,32: image_overlay_char=short_hex_char(debug_ipu_result,tc-25);
                    default: ;
                endcase
            end
            // Row 4: hardware perf counters
            else if (tr == 4) begin
                unique case (tc)
                    0:image_overlay_char=8'd66;1:image_overlay_char=8'd85;2:image_overlay_char=8'd83;3:image_overlay_char=8'd89;4:image_overlay_char=8'd58;
                    6,7,8,9,10,11,12,13: image_overlay_char=short_hex_char(perf_ipu_busy_count,tc-6);
                    16:image_overlay_char=8'd67;17:image_overlay_char=8'd79;18:image_overlay_char=8'd78;19:image_overlay_char=8'd86;20:image_overlay_char=8'd58;
                    22,23,24,25,26,27,28,29: image_overlay_char=short_hex_char(perf_conv_count,tc-22);
                    32:image_overlay_char=8'd83;33:image_overlay_char=8'd84;34:image_overlay_char=8'd65;35:image_overlay_char=8'd76;36:image_overlay_char=8'd76;37:image_overlay_char=8'd58;
                    39,40,41,42,43,44,45,46: image_overlay_char=short_hex_char(perf_stall_count,tc-39);
                    default: ;
                endcase
            end
        end
    endfunction

    function automatic logic [7:0] cpu_welcome_char(input int tr, input int tc);
        logic [319:0] line;
        begin
            // Big 2x welcome/status page: 40 columns x 30 rows.
            // Keep this compact so Basys 3 LUT usage stays low.
            line = "                                        ";
            unique case (tr)
                2:  line = "EVPIX-RV32 VISION SOC                 ";
                4:  line = "RV32I 5-STAGE CPU + IMAGE IPU + ML    ";
                6:  line = "CORE CLK:100MHZ   VGA:640X480@60HZ    ";
                8:  line = "CAMERA:OV7670  DIRECT FPGA  128X128   ";
                10: line = "INPUT:RGB565   MEMORY:RGB888 SOURCE   ";
                12: line = "SW0 IPU MODE   SW7 TINYML FINGER MODE ";
                14: line = "SW1 SOBEL  SW2 GRAY  SW3 THRESHOLD    ";
                16: line = "SW4 CONV   SW6 RV32I BASELINE BIST     ";
                18: line = "PERF: FPS  FRAME  PROC_CYC  BUSY STALL";
                20: line = "ML: FINGER COUNT 0-5 WITH STABILIZER   ";
                22: line = "DISPLAY: DOUBLE BUFFERED CLEAN VGA     ";
                25: line = "READY. SELECT A SWITCH MODE TO START.  ";
                default: line = "                                        ";
            endcase

            if (tr == 24) begin
                // Live readable status row on the plug-and-play first page.
                unique case (tc)
                    0:  cpu_welcome_char = 8'd70;  // F
                    1:  cpu_welcome_char = 8'd80;  // P
                    2:  cpu_welcome_char = 8'd83;  // S
                    3:  cpu_welcome_char = 8'd58;  // :
                    5:  cpu_welcome_char = dec3_char(fps_estimate,0);
                    6:  cpu_welcome_char = dec3_char(fps_estimate,1);
                    7:  cpu_welcome_char = dec3_char(fps_estimate,2);
                    10: cpu_welcome_char = 8'd70;  // F
                    11: cpu_welcome_char = 8'd82;  // R
                    12: cpu_welcome_char = 8'd65;  // A
                    13: cpu_welcome_char = 8'd77;  // M
                    14: cpu_welcome_char = 8'd69;  // E
                    15: cpu_welcome_char = 8'd58;  // :
                    17,18,19,20,21,22,23,24: cpu_welcome_char = short_hex_char(frame_count, tc-17);
                    27: cpu_welcome_char = 8'd67;  // C
                    28: cpu_welcome_char = 8'd76;  // L
                    29: cpu_welcome_char = 8'd75;  // K
                    30: cpu_welcome_char = 8'd58;  // :
                    31: cpu_welcome_char = 8'd49;  // 1
                    32: cpu_welcome_char = 8'd48;  // 0
                    33: cpu_welcome_char = 8'd48;  // 0
                    34: cpu_welcome_char = 8'd77;  // M
                    35: cpu_welcome_char = 8'd72;  // H
                    36: cpu_welcome_char = 8'd90;  // Z
                    default: cpu_welcome_char = 8'd32;
                endcase
            end else if ((tc >= 0) && (tc < 40)) begin
                cpu_welcome_char = line[8*(39-tc) +: 8];
            end else begin
                cpu_welcome_char = 8'd32;
            end
        end
    endfunction

    // --------------------------------------------------------------------
    // Full paged RV32I BIST table, resource-fit edition.
    // Restores TEST | EXP | GOT | RESULT display with SW15:SW14 page select.
    // This keeps v7 renderer/background style and avoids the v9 stripe artifact.
    // --------------------------------------------------------------------
    function automatic logic [7:0] bist_line_char(input int item, input int tc);
        int r; int m; logic [31:0] exp32; logic [31:0] got32; logic [7:0] exp8; logic [7:0] got8; logic is_pass;
        begin
            bist_line_char = 8'd32;
            if (item < 31) begin
                r = item + 1; exp32 = expected_reg(r); got32 = bist_reg_got[r]; is_pass = (got32 == exp32);
                if (tc>=0 && tc<5) bist_line_char=instr_name_char(item,tc);
                else if (tc==5) bist_line_char=8'd88; else if (tc==6) bist_line_char=dec2_char(r,0); else if (tc==7) bist_line_char=dec2_char(r,1);
                else if (tc==9) bist_line_char=8'd69; else if (tc==10) bist_line_char=8'd88; else if (tc==11) bist_line_char=8'd80;
                else if (tc>=13 && tc<21) bist_line_char=hex_char(hex_nibble(exp32,tc-13));
                else if (tc==23) bist_line_char=8'd71; else if (tc==24) bist_line_char=8'd79; else if (tc==25) bist_line_char=8'd84;
                else if (tc>=27 && tc<35) bist_line_char=hex_char(hex_nibble(got32,tc-27));
                else if (tc==37) bist_line_char=is_pass?8'd80:8'd70;
                else if (tc==38) bist_line_char=is_pass?8'd65:8'd65;
                else if (tc==39) bist_line_char=is_pass?8'd83:8'd73;
                else if (tc==40) bist_line_char=is_pass?8'd83:8'd76;
            end else if (item < 42) begin
                m = item - 31; exp8 = expected_mem(m); got8 = bist_mem_got[m]; is_pass = (got8 == exp8);
                if (tc>=0 && tc<3) bist_line_char=instr_name_char(item,tc);
                else if (tc>=4 && tc<7) bist_line_char=dec3_char(mem_addr_for_test(m), tc-4);
                else if (tc==9) bist_line_char=8'd69; else if (tc==10) bist_line_char=8'd88; else if (tc==11) bist_line_char=8'd80;
                else if (tc==17) bist_line_char=hex_char(exp8[7:4]); else if (tc==18) bist_line_char=hex_char(exp8[3:0]);
                else if (tc==23) bist_line_char=8'd71; else if (tc==24) bist_line_char=8'd79; else if (tc==25) bist_line_char=8'd84;
                else if (tc==31) bist_line_char=hex_char(got8[7:4]); else if (tc==32) bist_line_char=hex_char(got8[3:0]);
                else if (tc==37) bist_line_char=is_pass?8'd80:8'd70;
                else if (tc==38) bist_line_char=is_pass?8'd65:8'd65;
                else if (tc==39) bist_line_char=is_pass?8'd83:8'd73;
                else if (tc==40) bist_line_char=is_pass?8'd83:8'd76;
            end
        end
    endfunction

    function automatic logic [7:0] bist_char(input int tr, input int tc);
        int item; int local_row;
        begin
            bist_char = 8'd32;
            if (tr == 2) begin
                unique case (tc)
                    0:bist_char=8'd67;1:bist_char=8'd80;2:bist_char=8'd85;4:bist_char=8'd66;5:bist_char=8'd73;6:bist_char=8'd83;7:bist_char=8'd84;9:bist_char=8'd77;10:bist_char=8'd79;11:bist_char=8'd68;12:bist_char=8'd69;14:bist_char=8'd45;16:bist_char=8'd82;17:bist_char=8'd86;18:bist_char=8'd51;19:bist_char=8'd50;20:bist_char=8'd73;22:bist_char=8'd66;23:bist_char=8'd65;24:bist_char=8'd83;25:bist_char=8'd69;26:bist_char=8'd76;27:bist_char=8'd73;28:bist_char=8'd78;29:bist_char=8'd69;
                    default: ;
                endcase
            end else if (tr == 4) begin
                if (!bist_done) begin
                    unique case (tc)
                        0:bist_char=8'd82;1:bist_char=8'd85;2:bist_char=8'd78;3:bist_char=8'd78;4:bist_char=8'd73;5:bist_char=8'd78;6:bist_char=8'd71;8:bist_char=8'd46;9:bist_char=8'd46;10:bist_char=8'd46;
                        default: ;
                    endcase
                end else if (bist_pass) begin
                    unique case (tc)
                        0:bist_char=8'd65;1:bist_char=8'd76;2:bist_char=8'd76;4:bist_char=8'd66;5:bist_char=8'd65;6:bist_char=8'd83;7:bist_char=8'd69;8:bist_char=8'd76;9:bist_char=8'd73;10:bist_char=8'd78;11:bist_char=8'd69;13:bist_char=8'd67;14:bist_char=8'd72;15:bist_char=8'd69;16:bist_char=8'd67;17:bist_char=8'd75;18:bist_char=8'd83;20:bist_char=8'd80;21:bist_char=8'd65;22:bist_char=8'd83;23:bist_char=8'd83;24:bist_char=8'd69;25:bist_char=8'd68;
                        default: ;
                    endcase
                end else begin
                    unique case (tc)
                        0:bist_char=8'd70;1:bist_char=8'd65;2:bist_char=8'd73;3:bist_char=8'd76;5:bist_char=8'd67;6:bist_char=8'd79;7:bist_char=8'd85;8:bist_char=8'd78;9:bist_char=8'd84;11:bist_char=8'd61;13:bist_char=dec2_char(bist_fail_count,0);14:bist_char=dec2_char(bist_fail_count,1);
                        default: ;
                    endcase
                end
            end else if (tr == 6) begin
                unique case (tc)
                    0:bist_char=8'd84;1:bist_char=8'd69;2:bist_char=8'd83;3:bist_char=8'd84;9:bist_char=8'd69;10:bist_char=8'd88;11:bist_char=8'd80;21:bist_char=8'd71;22:bist_char=8'd79;23:bist_char=8'd84;34:bist_char=8'd82;35:bist_char=8'd69;36:bist_char=8'd83;37:bist_char=8'd85;38:bist_char=8'd76;39:bist_char=8'd84;
                    default: ;
                endcase
            end else if (tr >= 8 && tr < 22) begin
                local_row = tr - 8; item = (bist_page * 14) + local_row;
                bist_char = bist_line_char(item, tc);
            end else if (tr == 24) begin
                unique case (tc)
                    0:bist_char=8'd80;1:bist_char=8'd65;2:bist_char=8'd71;3:bist_char=8'd69;5:bist_char=8'd83;6:bist_char=8'd87;7:bist_char=8'd49;8:bist_char=8'd53;9:bist_char=8'd58;10:bist_char=8'd49;11:bist_char=8'd52;13:bist_char=8'd84;14:bist_char=8'd79;16:bist_char=8'd83;17:bist_char=8'd87;18:bist_char=8'd49;19:bist_char=8'd53;20:bist_char=8'd58;21:bist_char=8'd49;22:bist_char=8'd52;24:bist_char=8'd80;25:bist_char=8'd65;26:bist_char=8'd71;27:bist_char=8'd69;
                    default: ;
                endcase
            end
        end
    endfunction

    function automatic logic [4:0] font5x7(input logic [7:0] ch, input logic [2:0] row);
        begin
            font5x7 = 5'b00000;
            unique case (ch)
            8'd32: begin
                unique case (row)
                    3'd0: font5x7 = 5'b00000;
                    3'd1: font5x7 = 5'b00000;
                    3'd2: font5x7 = 5'b00000;
                    3'd3: font5x7 = 5'b00000;
                    3'd4: font5x7 = 5'b00000;
                    3'd5: font5x7 = 5'b00000;
                    3'd6: font5x7 = 5'b00000;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd33: begin
                unique case (row)
                    3'd0: font5x7 = 5'b00100;
                    3'd1: font5x7 = 5'b00100;
                    3'd2: font5x7 = 5'b00100;
                    3'd3: font5x7 = 5'b00100;
                    3'd4: font5x7 = 5'b00100;
                    3'd5: font5x7 = 5'b00000;
                    3'd6: font5x7 = 5'b00100;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd58: begin
                unique case (row)
                    3'd0: font5x7 = 5'b00000;
                    3'd1: font5x7 = 5'b00100;
                    3'd2: font5x7 = 5'b00100;
                    3'd3: font5x7 = 5'b00000;
                    3'd4: font5x7 = 5'b00100;
                    3'd5: font5x7 = 5'b00100;
                    3'd6: font5x7 = 5'b00000;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd45: begin
                unique case (row)
                    3'd0: font5x7 = 5'b00000;
                    3'd1: font5x7 = 5'b00000;
                    3'd2: font5x7 = 5'b00000;
                    3'd3: font5x7 = 5'b11111;
                    3'd4: font5x7 = 5'b00000;
                    3'd5: font5x7 = 5'b00000;
                    3'd6: font5x7 = 5'b00000;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd46: begin
                unique case (row)
                    3'd0: font5x7 = 5'b00000;
                    3'd1: font5x7 = 5'b00000;
                    3'd2: font5x7 = 5'b00000;
                    3'd3: font5x7 = 5'b00000;
                    3'd4: font5x7 = 5'b00000;
                    3'd5: font5x7 = 5'b00110;
                    3'd6: font5x7 = 5'b00110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd44: begin
                unique case (row)
                    3'd0: font5x7 = 5'b00000;
                    3'd1: font5x7 = 5'b00000;
                    3'd2: font5x7 = 5'b00000;
                    3'd3: font5x7 = 5'b00000;
                    3'd4: font5x7 = 5'b00110;
                    3'd5: font5x7 = 5'b00100;
                    3'd6: font5x7 = 5'b01000;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd47: begin
                unique case (row)
                    3'd0: font5x7 = 5'b00001;
                    3'd1: font5x7 = 5'b00010;
                    3'd2: font5x7 = 5'b00100;
                    3'd3: font5x7 = 5'b01000;
                    3'd4: font5x7 = 5'b10000;
                    3'd5: font5x7 = 5'b00000;
                    3'd6: font5x7 = 5'b00000;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd61: begin
                unique case (row)
                    3'd0: font5x7 = 5'b00000;
                    3'd1: font5x7 = 5'b11111;
                    3'd2: font5x7 = 5'b00000;
                    3'd3: font5x7 = 5'b11111;
                    3'd4: font5x7 = 5'b00000;
                    3'd5: font5x7 = 5'b00000;
                    3'd6: font5x7 = 5'b00000;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd48: begin
                unique case (row)
                    3'd0: font5x7 = 5'b01110;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10011;
                    3'd3: font5x7 = 5'b10101;
                    3'd4: font5x7 = 5'b11001;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b01110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd49: begin
                unique case (row)
                    3'd0: font5x7 = 5'b00100;
                    3'd1: font5x7 = 5'b01100;
                    3'd2: font5x7 = 5'b00100;
                    3'd3: font5x7 = 5'b00100;
                    3'd4: font5x7 = 5'b00100;
                    3'd5: font5x7 = 5'b00100;
                    3'd6: font5x7 = 5'b01110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd50: begin
                unique case (row)
                    3'd0: font5x7 = 5'b01110;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b00001;
                    3'd3: font5x7 = 5'b00010;
                    3'd4: font5x7 = 5'b00100;
                    3'd5: font5x7 = 5'b01000;
                    3'd6: font5x7 = 5'b11111;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd51: begin
                unique case (row)
                    3'd0: font5x7 = 5'b11110;
                    3'd1: font5x7 = 5'b00001;
                    3'd2: font5x7 = 5'b00001;
                    3'd3: font5x7 = 5'b01110;
                    3'd4: font5x7 = 5'b00001;
                    3'd5: font5x7 = 5'b00001;
                    3'd6: font5x7 = 5'b11110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd52: begin
                unique case (row)
                    3'd0: font5x7 = 5'b00010;
                    3'd1: font5x7 = 5'b00110;
                    3'd2: font5x7 = 5'b01010;
                    3'd3: font5x7 = 5'b10010;
                    3'd4: font5x7 = 5'b11111;
                    3'd5: font5x7 = 5'b00010;
                    3'd6: font5x7 = 5'b00010;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd53: begin
                unique case (row)
                    3'd0: font5x7 = 5'b11111;
                    3'd1: font5x7 = 5'b10000;
                    3'd2: font5x7 = 5'b10000;
                    3'd3: font5x7 = 5'b11110;
                    3'd4: font5x7 = 5'b00001;
                    3'd5: font5x7 = 5'b00001;
                    3'd6: font5x7 = 5'b11110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd54: begin
                unique case (row)
                    3'd0: font5x7 = 5'b00110;
                    3'd1: font5x7 = 5'b01000;
                    3'd2: font5x7 = 5'b10000;
                    3'd3: font5x7 = 5'b11110;
                    3'd4: font5x7 = 5'b10001;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b01110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd55: begin
                unique case (row)
                    3'd0: font5x7 = 5'b11111;
                    3'd1: font5x7 = 5'b00001;
                    3'd2: font5x7 = 5'b00010;
                    3'd3: font5x7 = 5'b00100;
                    3'd4: font5x7 = 5'b01000;
                    3'd5: font5x7 = 5'b01000;
                    3'd6: font5x7 = 5'b01000;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd56: begin
                unique case (row)
                    3'd0: font5x7 = 5'b01110;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10001;
                    3'd3: font5x7 = 5'b01110;
                    3'd4: font5x7 = 5'b10001;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b01110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd57: begin
                unique case (row)
                    3'd0: font5x7 = 5'b01110;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10001;
                    3'd3: font5x7 = 5'b01111;
                    3'd4: font5x7 = 5'b00001;
                    3'd5: font5x7 = 5'b00010;
                    3'd6: font5x7 = 5'b01100;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd65: begin
                unique case (row)
                    3'd0: font5x7 = 5'b01110;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10001;
                    3'd3: font5x7 = 5'b11111;
                    3'd4: font5x7 = 5'b10001;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b10001;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd66: begin
                unique case (row)
                    3'd0: font5x7 = 5'b11110;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10001;
                    3'd3: font5x7 = 5'b11110;
                    3'd4: font5x7 = 5'b10001;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b11110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd67: begin
                unique case (row)
                    3'd0: font5x7 = 5'b01110;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10000;
                    3'd3: font5x7 = 5'b10000;
                    3'd4: font5x7 = 5'b10000;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b01110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd68: begin
                unique case (row)
                    3'd0: font5x7 = 5'b11110;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10001;
                    3'd3: font5x7 = 5'b10001;
                    3'd4: font5x7 = 5'b10001;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b11110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd69: begin
                unique case (row)
                    3'd0: font5x7 = 5'b11111;
                    3'd1: font5x7 = 5'b10000;
                    3'd2: font5x7 = 5'b10000;
                    3'd3: font5x7 = 5'b11110;
                    3'd4: font5x7 = 5'b10000;
                    3'd5: font5x7 = 5'b10000;
                    3'd6: font5x7 = 5'b11111;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd70: begin
                unique case (row)
                    3'd0: font5x7 = 5'b11111;
                    3'd1: font5x7 = 5'b10000;
                    3'd2: font5x7 = 5'b10000;
                    3'd3: font5x7 = 5'b11110;
                    3'd4: font5x7 = 5'b10000;
                    3'd5: font5x7 = 5'b10000;
                    3'd6: font5x7 = 5'b10000;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd71: begin
                unique case (row)
                    3'd0: font5x7 = 5'b01110;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10000;
                    3'd3: font5x7 = 5'b10111;
                    3'd4: font5x7 = 5'b10001;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b01111;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd72: begin
                unique case (row)
                    3'd0: font5x7 = 5'b10001;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10001;
                    3'd3: font5x7 = 5'b11111;
                    3'd4: font5x7 = 5'b10001;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b10001;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd73: begin
                unique case (row)
                    3'd0: font5x7 = 5'b01110;
                    3'd1: font5x7 = 5'b00100;
                    3'd2: font5x7 = 5'b00100;
                    3'd3: font5x7 = 5'b00100;
                    3'd4: font5x7 = 5'b00100;
                    3'd5: font5x7 = 5'b00100;
                    3'd6: font5x7 = 5'b01110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd74: begin
                unique case (row)
                    3'd0: font5x7 = 5'b00111;
                    3'd1: font5x7 = 5'b00010;
                    3'd2: font5x7 = 5'b00010;
                    3'd3: font5x7 = 5'b00010;
                    3'd4: font5x7 = 5'b10010;
                    3'd5: font5x7 = 5'b10010;
                    3'd6: font5x7 = 5'b01100;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd75: begin
                unique case (row)
                    3'd0: font5x7 = 5'b10001;
                    3'd1: font5x7 = 5'b10010;
                    3'd2: font5x7 = 5'b10100;
                    3'd3: font5x7 = 5'b11000;
                    3'd4: font5x7 = 5'b10100;
                    3'd5: font5x7 = 5'b10010;
                    3'd6: font5x7 = 5'b10001;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd76: begin
                unique case (row)
                    3'd0: font5x7 = 5'b10000;
                    3'd1: font5x7 = 5'b10000;
                    3'd2: font5x7 = 5'b10000;
                    3'd3: font5x7 = 5'b10000;
                    3'd4: font5x7 = 5'b10000;
                    3'd5: font5x7 = 5'b10000;
                    3'd6: font5x7 = 5'b11111;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd77: begin
                unique case (row)
                    3'd0: font5x7 = 5'b10001;
                    3'd1: font5x7 = 5'b11011;
                    3'd2: font5x7 = 5'b10101;
                    3'd3: font5x7 = 5'b10101;
                    3'd4: font5x7 = 5'b10001;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b10001;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd78: begin
                unique case (row)
                    3'd0: font5x7 = 5'b10001;
                    3'd1: font5x7 = 5'b11001;
                    3'd2: font5x7 = 5'b10101;
                    3'd3: font5x7 = 5'b10011;
                    3'd4: font5x7 = 5'b10001;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b10001;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd79: begin
                unique case (row)
                    3'd0: font5x7 = 5'b01110;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10001;
                    3'd3: font5x7 = 5'b10001;
                    3'd4: font5x7 = 5'b10001;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b01110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd80: begin
                unique case (row)
                    3'd0: font5x7 = 5'b11110;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10001;
                    3'd3: font5x7 = 5'b11110;
                    3'd4: font5x7 = 5'b10000;
                    3'd5: font5x7 = 5'b10000;
                    3'd6: font5x7 = 5'b10000;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd81: begin
                unique case (row)
                    3'd0: font5x7 = 5'b01110;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10001;
                    3'd3: font5x7 = 5'b10001;
                    3'd4: font5x7 = 5'b10101;
                    3'd5: font5x7 = 5'b10010;
                    3'd6: font5x7 = 5'b01101;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd82: begin
                unique case (row)
                    3'd0: font5x7 = 5'b11110;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10001;
                    3'd3: font5x7 = 5'b11110;
                    3'd4: font5x7 = 5'b10100;
                    3'd5: font5x7 = 5'b10010;
                    3'd6: font5x7 = 5'b10001;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd83: begin
                unique case (row)
                    3'd0: font5x7 = 5'b01111;
                    3'd1: font5x7 = 5'b10000;
                    3'd2: font5x7 = 5'b10000;
                    3'd3: font5x7 = 5'b01110;
                    3'd4: font5x7 = 5'b00001;
                    3'd5: font5x7 = 5'b00001;
                    3'd6: font5x7 = 5'b11110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd84: begin
                unique case (row)
                    3'd0: font5x7 = 5'b11111;
                    3'd1: font5x7 = 5'b00100;
                    3'd2: font5x7 = 5'b00100;
                    3'd3: font5x7 = 5'b00100;
                    3'd4: font5x7 = 5'b00100;
                    3'd5: font5x7 = 5'b00100;
                    3'd6: font5x7 = 5'b00100;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd85: begin
                unique case (row)
                    3'd0: font5x7 = 5'b10001;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10001;
                    3'd3: font5x7 = 5'b10001;
                    3'd4: font5x7 = 5'b10001;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b01110;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd86: begin
                unique case (row)
                    3'd0: font5x7 = 5'b10001;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10001;
                    3'd3: font5x7 = 5'b10001;
                    3'd4: font5x7 = 5'b10001;
                    3'd5: font5x7 = 5'b01010;
                    3'd6: font5x7 = 5'b00100;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd87: begin
                unique case (row)
                    3'd0: font5x7 = 5'b10001;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b10001;
                    3'd3: font5x7 = 5'b10101;
                    3'd4: font5x7 = 5'b10101;
                    3'd5: font5x7 = 5'b10101;
                    3'd6: font5x7 = 5'b01010;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd88: begin
                unique case (row)
                    3'd0: font5x7 = 5'b10001;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b01010;
                    3'd3: font5x7 = 5'b00100;
                    3'd4: font5x7 = 5'b01010;
                    3'd5: font5x7 = 5'b10001;
                    3'd6: font5x7 = 5'b10001;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd89: begin
                unique case (row)
                    3'd0: font5x7 = 5'b10001;
                    3'd1: font5x7 = 5'b10001;
                    3'd2: font5x7 = 5'b01010;
                    3'd3: font5x7 = 5'b00100;
                    3'd4: font5x7 = 5'b00100;
                    3'd5: font5x7 = 5'b00100;
                    3'd6: font5x7 = 5'b00100;
                    default: font5x7 = 5'b00000;
                endcase
            end
            8'd90: begin
                unique case (row)
                    3'd0: font5x7 = 5'b11111;
                    3'd1: font5x7 = 5'b00001;
                    3'd2: font5x7 = 5'b00010;
                    3'd3: font5x7 = 5'b00100;
                    3'd4: font5x7 = 5'b01000;
                    3'd5: font5x7 = 5'b10000;
                    3'd6: font5x7 = 5'b11111;
                    default: font5x7 = 5'b00000;
                endcase
            end
                default: font5x7 = 5'b00000;
            endcase
        end
    endfunction

    logic [6:0] text_col;
    logic [5:0] text_row;
    logic [2:0] font_x;
    logic [2:0] font_y;
    logic [7:0] text_ch;
    logic [4:0] font_bits;
    logic       font_on;
    logic       text_pixel;

    always_comb begin
        // Resource-fit clean text renderer.
        // Keep 1x text cells to stay inside the Basys 3 LUT budget.
        text_col = x_q[9:3];
        text_row = y_q[8:3];
        font_x   = x_q[2:0];
        font_y   = y_q[2:0];
        text_ch  = 8'd32;

        if (overlay_mode_q == 2'd0) text_ch = image_overlay_char(text_row, text_col);
        else if (overlay_mode_q == 2'd1) text_ch = cpu_welcome_char(text_row, text_col);
        else if (overlay_mode_q == 2'd2) text_ch = bist_char(text_row, text_col);

        font_bits = font5x7(text_ch, font_y);

        // Do not use font_bits[4-font_x]. Some Vivado builds synthesize the
        // out-of-range dynamic select into visible vertical stripes. This mux
        // is slightly more explicit but still fits because the welcome text was
        // compressed in v7.
        unique case (font_x)
            3'd0: font_on = font_bits[4];
            3'd1: font_on = font_bits[3];
            3'd2: font_on = font_bits[2];
            3'd3: font_on = font_bits[1];
            3'd4: font_on = font_bits[0];
            default: font_on = 1'b0;
        endcase

        text_pixel = active_q && font_on && ((overlay_mode_q != 2'd0) || (text_row < 6'd5));
    end

    // --------------------------------------------------------------------
    // Registered VGA RGB output.
    //
    // The previous combinational RGB mux was functionally correct, but on the
    // real Basys-3 VGA DAC/monitor path it could expose very short glitches
    // from BRAM/font mux transitions as thin vertical stripes in the black
    // regions beside the image panes.  Registering the final RGB value makes
    // each pixel stable for the full pixel-clock period.  This does not change
    // the CPU, IPU, ML, BIST, camera capture, memory map, or algorithms.
    // --------------------------------------------------------------------
    logic [3:0] vga_r_next, vga_g_next, vga_b_next;

    always_comb begin
        vga_r_next = 4'h0;
        vga_g_next = 4'h0;
        vga_b_next = 4'h0;

        if (overlay_mode_q != 2'd0) begin
            // Clean black/blue background. Gate by active_q so blanking cannot
            // leak a pattern into the monitor scaler.
            if (active_q) begin
                vga_r_next = 4'h0;
                vga_g_next = 4'h0;
                vga_b_next = (overlay_mode_q == 2'd1) ? 4'h0 : 4'h2;
            end

            if (text_pixel) begin
                if (overlay_mode_q == 2'd2 && bist_done && !bist_pass) begin
                    vga_r_next = 4'hF; vga_g_next = 4'h3; vga_b_next = 4'h3;
                end else if (overlay_mode_q == 2'd2 && bist_done && bist_pass) begin
                    vga_r_next = 4'h3; vga_g_next = 4'hF; vga_b_next = 4'h3;
                end else begin
                    vga_r_next = 4'hF; vga_g_next = 4'hF; vga_b_next = 4'hF;
                end
            end
        end else begin
            // Default image-mode background is hard black.
            if (active_q &&
                (x_q >= LEFT_X + IMG_W + (GAP/2) - 1) &&
                (x_q <= LEFT_X + IMG_W + (GAP/2) + 1) &&
                (y_q >= TOP_Y) && (y_q < TOP_Y + IMG_H)) begin
                vga_r_next = 4'hF; vga_g_next = 4'hF; vga_b_next = 4'hF;
            end

            if (in_left_q) begin
                vga_r_next = src_q[11:8];
                vga_g_next = src_q[7:4];
                vga_b_next = src_q[3:0];
            end else if (in_right_q) begin
                if (right_bypass_src_q) begin
                    vga_r_next = src_q[11:8];
                    vga_g_next = src_q[7:4];
                    vga_b_next = src_q[3:0];
                end else begin
                    vga_r_next = dst_q[7:4];
                    vga_g_next = dst_q[7:4];
                    vga_b_next = dst_q[7:4];
                end
            end

            // IPU/research live overlay at the top of the VGA screen.
            if (text_pixel) begin
                vga_r_next = 4'h0;
                vga_g_next = 4'hF;
                vga_b_next = 4'h0;
            end
        end
    end

    always_ff @(posedge clk_pix or posedge reset) begin
        if (reset) begin
            vga_r <= 4'h0;
            vga_g <= 4'h0;
            vga_b <= 4'h0;
        end else begin
            vga_r <= vga_r_next;
            vga_g <= vga_g_next;
            vga_b <= vga_b_next;
        end
    end

endmodule
