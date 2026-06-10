// ============================================================
// ipu_fpga.sv -- EVPIX ASIC/Yosys fast-mapping IPU
// v12 FAST-IPU final
//
// Why this file exists:
//   The FPGA IPU used division/modulo, integer arithmetic, variable coefficient
//   multipliers, and large combinational address expressions. Vivado handled it,
//   but OpenROAD/Yosys/ABC spent hours mapping the parameterized ipu_fpga module.
//
// What changed:
//   - Same external IPU interface.
//   - Same operation IDs: grayscale, threshold, max-pixel, sobel, convolution,
//     maxpool, avgpool.
//   - Same byte-memory processing style.
//   - Rewritten with small counters, constant-offset address generation, and
//     add/shift kernels. No variable divide/modulo/multiply in the IPU datapath.
//   - One output pixel is still produced sequentially; this is an ASIC bring-up
//     implementation intended to let OpenROAD generate GDS reliably.
// ============================================================

module ipu_fpga #(
    parameter int IMG_W = 128,
    parameter int IMG_H = 128,
    parameter logic [7:0] THRESHOLD_VALUE = 8'd128
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        start,
    input  logic [2:0]  op,
    input  logic [3:0]  kernel,
    input  logic [31:0] src_base,
    input  logic [31:0] dst_base,
    output logic        busy,
    output logic        done,
    output logic [31:0] result,
    output logic [31:0] conv_cycle_count,
    output logic [31:0] pool_cycle_count,

    output logic        mem_re,
    output logic        mem_we,
    output logic [31:0] mem_addr,
    output logic [7:0]  mem_wdata,
    input  logic [7:0]  mem_rdata
);

    // This implementation is optimized for the EVPIX 128x128 thesis target.
    // Keep parameters for interface compatibility, but use local constants for
    // ABC-friendly address generation.
    localparam logic [15:0] W_CONST       = 16'd128;
    localparam logic [15:0] H_CONST       = 16'd128;
    localparam logic [31:0] PIXELS        = 32'd16384;
    localparam logic [31:0] POOL_PIXELS   = 32'd4096;
    localparam logic [31:0] RGB_STRIDE    = 32'd3;
    localparam logic [31:0] ROW_RGB_BYTES = 32'd384;   // 128 * 3
    localparam logic [31:0] POOL_ROW_STEP = 32'd768;   // 2 * 128 * 3

    localparam logic [2:0] OP_GRAY     = 3'd0;
    localparam logic [2:0] OP_THRESH   = 3'd1;
    localparam logic [2:0] OP_MAXPIX   = 3'd2;
    localparam logic [2:0] OP_SOBEL    = 3'd3;
    localparam logic [2:0] OP_CONV     = 3'd4;
    localparam logic [2:0] OP_MAXPOOL  = 3'd5;
    localparam logic [2:0] OP_AVGPOOL  = 3'd6;

    localparam logic [4:0] ST_IDLE         = 5'd0;
    localparam logic [4:0] ST_RGB_REQ_R    = 5'd1;
    localparam logic [4:0] ST_RGB_CAP_R    = 5'd2;
    localparam logic [4:0] ST_RGB_REQ_G    = 5'd3;
    localparam logic [4:0] ST_RGB_CAP_G    = 5'd4;
    localparam logic [4:0] ST_RGB_REQ_B    = 5'd5;
    localparam logic [4:0] ST_RGB_CAP_B    = 5'd6;
    localparam logic [4:0] ST_SIMPLE_WR    = 5'd7;
    localparam logic [4:0] ST_WIN_PREP     = 5'd8;
    localparam logic [4:0] ST_WIN_REQ      = 5'd9;
    localparam logic [4:0] ST_WIN_CAP      = 5'd10;
    localparam logic [4:0] ST_WIN_WRITE    = 5'd11;
    localparam logic [4:0] ST_POOL_REQ     = 5'd12;
    localparam logic [4:0] ST_POOL_CAP     = 5'd13;
    localparam logic [4:0] ST_POOL_WRITE   = 5'd14;
    localparam logic [4:0] ST_NEXT_PIXEL   = 5'd15;
    localparam logic [4:0] ST_FINISH       = 5'd16;

    logic [4:0]  state;
    logic [2:0]  op_r;
    logic [3:0]  kernel_r;
    logic [31:0] src_base_r;
    logic [31:0] dst_base_r;

    logic [13:0] pix_count;
    logic [6:0]  x;
    logic [6:0]  y;
    logic [31:0] src_rgb_addr;   // address of current pixel R byte
    logic [31:0] dst_addr;       // current output byte address

    logic [11:0] pool_count;
    logic [5:0]  pool_x;
    logic [5:0]  pool_y;
    logic [31:0] pool_base_addr;

    logic [7:0] r_reg, g_reg, b_reg;
    logic [7:0] max_pix;
    logic [7:0] gray_now;
    logic [9:0] gray_sum;
    logic [7:0] simple_pix;

    logic [3:0] win_idx;
    logic [1:0] win_chan;
    logic [7:0] tmp_r;
    logic [7:0] tmp_g;
    logic [7:0] win_gray;
    logic [9:0] win_gray_sum;
    logic [31:0] win_center_addr;
    logic [31:0] win_req_addr;
    logic [7:0] win0, win1, win2, win3, win4, win5, win6, win7, win8;

    logic [1:0] pool_idx;
    logic [7:0] pool_a, pool_b, pool_c, pool_d;

    logic signed [10:0] gx_s;
    logic signed [10:0] gy_s;
    logic [10:0] abs_gx;
    logic [10:0] abs_gy;
    logic [11:0] mag_sum;
    logic [7:0]  sobel_pix;

    logic signed [12:0] conv_s;
    logic signed [12:0] conv_norm_s;
    logic [7:0] conv_pix;

    logic [9:0] pool_sum;
    logic [7:0] pool_pix;
    logic border_pixel;

    // ------------------------------------------------------------------
    // Small add/shift grayscale approximation.
    // ------------------------------------------------------------------
    always_comb begin
        gray_sum = {2'b00, (r_reg >> 2)} + {2'b00, (r_reg >> 5)} +
                   {2'b00, (g_reg >> 1)} + {2'b00, (g_reg >> 4)} +
                   {2'b00, (b_reg >> 4)} + {2'b00, (b_reg >> 5)};
        gray_now = (gray_sum > 10'd255) ? 8'hFF : gray_sum[7:0];
    end

    always_comb begin
        win_gray_sum = {2'b00, (tmp_r >> 2)} + {2'b00, (tmp_r >> 5)} +
                       {2'b00, (tmp_g >> 1)} + {2'b00, (tmp_g >> 4)} +
                       {2'b00, (mem_rdata >> 4)} + {2'b00, (mem_rdata >> 5)};
        win_gray = (win_gray_sum > 10'd255) ? 8'hFF : win_gray_sum[7:0];
    end

    always_comb begin
        simple_pix = gray_now;
        if (op_r == OP_THRESH)
            simple_pix = (gray_now >= THRESHOLD_VALUE) ? 8'hFF : 8'h00;
    end

    // ------------------------------------------------------------------
    // 3x3 window constant address offsets for 128x128 RGB888 source.
    // Center pixel address is the R byte of pixel (x,y). Each neighbor reads
    // R/G/B sequentially through the same grayscale conversion path in FPGA;
    // for ASIC bring-up we read one byte per neighbor from the grayscale-like
    // stream position. This keeps the operation deterministic and tiny.
    // ------------------------------------------------------------------
    always_comb begin
        case (win_idx)
            4'd0: win_req_addr = win_center_addr - ROW_RGB_BYTES - RGB_STRIDE;
            4'd1: win_req_addr = win_center_addr - ROW_RGB_BYTES;
            4'd2: win_req_addr = win_center_addr - ROW_RGB_BYTES + RGB_STRIDE;
            4'd3: win_req_addr = win_center_addr - RGB_STRIDE;
            4'd4: win_req_addr = win_center_addr;
            4'd5: win_req_addr = win_center_addr + RGB_STRIDE;
            4'd6: win_req_addr = win_center_addr + ROW_RGB_BYTES - RGB_STRIDE;
            4'd7: win_req_addr = win_center_addr + ROW_RGB_BYTES;
            default: win_req_addr = win_center_addr + ROW_RGB_BYTES + RGB_STRIDE;
        endcase
    end

    always_comb begin
        border_pixel = (x == 7'd0) || (x == 7'd127) || (y == 7'd0) || (y == 7'd127);
    end

    // ------------------------------------------------------------------
    // Add/shift Sobel and convolution. No variable multipliers.
    // ------------------------------------------------------------------
    always_comb begin
        gx_s = -$signed({3'b000, win0}) - ($signed({3'b000, win3}) <<< 1) - $signed({3'b000, win6})
             +  $signed({3'b000, win2}) + ($signed({3'b000, win5}) <<< 1) + $signed({3'b000, win8});
        gy_s =  $signed({3'b000, win0}) + ($signed({3'b000, win1}) <<< 1) + $signed({3'b000, win2})
             -  $signed({3'b000, win6}) - ($signed({3'b000, win7}) <<< 1) - $signed({3'b000, win8});
        abs_gx = gx_s[10] ? (~gx_s + 11'sd1) : gx_s;
        abs_gy = gy_s[10] ? (~gy_s + 11'sd1) : gy_s;
        mag_sum = {1'b0, abs_gx} + {1'b0, abs_gy};
        sobel_pix = (mag_sum > 12'd255) ? 8'hFF : mag_sum[7:0];

        // kernel_r values are kept compatible with the FPGA project:
        // 0 identity, 1 sobel-x, 2 sobel-y, 3 gaussian, 4 sharpen, 5 edge.
        case (kernel_r)
            4'd0: conv_s = $signed({5'b00000, win4});
            4'd1: conv_s = gx_s;
            4'd2: conv_s = gy_s;
            4'd3: conv_s = $signed({5'b00000, win0}) + ($signed({5'b00000, win1}) <<< 1) + $signed({5'b00000, win2}) +
                           ($signed({5'b00000, win3}) <<< 1) + ($signed({5'b00000, win4}) <<< 2) + ($signed({5'b00000, win5}) <<< 1) +
                           $signed({5'b00000, win6}) + ($signed({5'b00000, win7}) <<< 1) + $signed({5'b00000, win8});
            4'd4: conv_s = ($signed({5'b00000, win4}) <<< 2) + $signed({5'b00000, win4})
                           - $signed({5'b00000, win1}) - $signed({5'b00000, win3})
                           - $signed({5'b00000, win5}) - $signed({5'b00000, win7});
            4'd5: conv_s = ($signed({5'b00000, win4}) <<< 3)
                           - $signed({5'b00000, win0}) - $signed({5'b00000, win1}) - $signed({5'b00000, win2})
                           - $signed({5'b00000, win3}) - $signed({5'b00000, win5})
                           - $signed({5'b00000, win6}) - $signed({5'b00000, win7}) - $signed({5'b00000, win8});
            default: conv_s = $signed({5'b00000, win4});
        endcase

        conv_norm_s = (kernel_r == 4'd3) ? (conv_s >>> 4) : conv_s;
        if (conv_norm_s[12])       conv_pix = 8'd0;
        else if (conv_norm_s > 13'sd255) conv_pix = 8'hFF;
        else                       conv_pix = conv_norm_s[7:0];

        pool_sum = {2'b00, pool_a} + {2'b00, pool_b} + {2'b00, pool_c} + {2'b00, pool_d};
        pool_pix = pool_sum[9:2];
        if (op_r == OP_MAXPOOL) begin
            pool_pix = pool_a;
            if (pool_b > pool_pix) pool_pix = pool_b;
            if (pool_c > pool_pix) pool_pix = pool_c;
            if (pool_d > pool_pix) pool_pix = pool_d;
        end
    end

    always_comb begin
        mem_re    = 1'b0;
        mem_we    = 1'b0;
        mem_addr  = 32'd0;
        mem_wdata = 8'd0;

        case (state)
            ST_RGB_REQ_R: begin mem_re = 1'b1; mem_addr = src_rgb_addr; end
            ST_RGB_REQ_G: begin mem_re = 1'b1; mem_addr = src_rgb_addr + 32'd1; end
            ST_RGB_REQ_B: begin mem_re = 1'b1; mem_addr = src_rgb_addr + 32'd2; end
            ST_SIMPLE_WR: begin
                if (op_r != OP_MAXPIX) begin
                    mem_we    = 1'b1;
                    mem_addr  = dst_addr;
                    mem_wdata = simple_pix;
                end
            end
            ST_WIN_REQ: begin mem_re = 1'b1; mem_addr = win_req_addr + {30'd0, win_chan}; end
            ST_WIN_WRITE: begin
                mem_we   = 1'b1;
                mem_addr = dst_addr;
                if (border_pixel)      mem_wdata = 8'd0;
                else if (op_r == OP_SOBEL) mem_wdata = sobel_pix;
                else                   mem_wdata = conv_pix;
            end
            ST_POOL_REQ: begin
                mem_re = 1'b1;
                case (pool_idx)
                    2'd0: mem_addr = pool_base_addr;
                    2'd1: mem_addr = pool_base_addr + 32'd1;
                    2'd2: mem_addr = pool_base_addr + 32'd128;
                    default: mem_addr = pool_base_addr + 32'd129;
                endcase
            end
            ST_POOL_WRITE: begin
                mem_we    = 1'b1;
                mem_addr  = dst_addr;
                mem_wdata = pool_pix;
            end
            default: begin end
        endcase
    end

    always_ff @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0;
            done <= 1'b0;
            result <= 32'd0;
            conv_cycle_count <= 32'd0;
            pool_cycle_count <= 32'd0;
            state <= ST_IDLE;
            op_r <= 3'd0;
            kernel_r <= 4'd0;
            src_base_r <= 32'd0;
            dst_base_r <= 32'd0;
            pix_count <= 14'd0;
            x <= 7'd0;
            y <= 7'd0;
            src_rgb_addr <= 32'd0;
            dst_addr <= 32'd0;
            pool_count <= 12'd0;
            pool_x <= 6'd0;
            pool_y <= 6'd0;
            pool_base_addr <= 32'd0;
            r_reg <= 8'd0;
            g_reg <= 8'd0;
            b_reg <= 8'd0;
            max_pix <= 8'd0;
            win_idx <= 4'd0;
            win_chan <= 2'd0;
            tmp_r <= 8'd0;
            tmp_g <= 8'd0;
            win_center_addr <= 32'd0;
            win0 <= 8'd0; win1 <= 8'd0; win2 <= 8'd0; win3 <= 8'd0; win4 <= 8'd0;
            win5 <= 8'd0; win6 <= 8'd0; win7 <= 8'd0; win8 <= 8'd0;
            pool_idx <= 2'd0;
            pool_a <= 8'd0; pool_b <= 8'd0; pool_c <= 8'd0; pool_d <= 8'd0;
        end else begin
            done <= 1'b0;

            if (busy) begin
                if ((op_r == OP_SOBEL) || (op_r == OP_CONV))
                    conv_cycle_count <= conv_cycle_count + 32'd1;
                if ((op_r == OP_MAXPOOL) || (op_r == OP_AVGPOOL))
                    pool_cycle_count <= pool_cycle_count + 32'd1;
            end

            case (state)
                ST_IDLE: begin
                    if (start) begin
                        busy <= 1'b1;
                        done <= 1'b0;
                        result <= 32'd0;
                        op_r <= op;
                        kernel_r <= kernel;
                        src_base_r <= src_base;
                        dst_base_r <= dst_base;
                        pix_count <= 14'd0;
                        x <= 7'd0;
                        y <= 7'd0;
                        src_rgb_addr <= src_base;
                        dst_addr <= dst_base;
                        max_pix <= 8'd0;
                        pool_count <= 12'd0;
                        pool_x <= 6'd0;
                        pool_y <= 6'd0;
                        pool_base_addr <= src_base;
                        pool_idx <= 2'd0;
                        conv_cycle_count <= 32'd0;
                        pool_cycle_count <= 32'd0;
                        if ((op == OP_GRAY) || (op == OP_THRESH) || (op == OP_MAXPIX))
                            state <= ST_RGB_REQ_R;
                        else if ((op == OP_SOBEL) || (op == OP_CONV))
                            state <= ST_WIN_PREP;
                        else if ((op == OP_MAXPOOL) || (op == OP_AVGPOOL))
                            state <= ST_POOL_REQ;
                        else
                            state <= ST_FINISH;
                    end
                end

                ST_RGB_REQ_R: state <= ST_RGB_CAP_R;
                ST_RGB_CAP_R: begin r_reg <= mem_rdata; state <= ST_RGB_REQ_G; end
                ST_RGB_REQ_G: state <= ST_RGB_CAP_G;
                ST_RGB_CAP_G: begin g_reg <= mem_rdata; state <= ST_RGB_REQ_B; end
                ST_RGB_REQ_B: state <= ST_RGB_CAP_B;
                ST_RGB_CAP_B: begin b_reg <= mem_rdata; state <= ST_SIMPLE_WR; end

                ST_SIMPLE_WR: begin
                    if ((op_r == OP_MAXPIX) && (gray_now > max_pix))
                        max_pix <= gray_now;
                    if (pix_count == 14'd16383) begin
                        if (op_r == OP_MAXPIX)
                            result <= {24'd0, ((gray_now > max_pix) ? gray_now : max_pix)};
                        else
                            result <= 32'd1;
                        state <= ST_FINISH;
                    end else begin
                        pix_count <= pix_count + 14'd1;
                        src_rgb_addr <= src_rgb_addr + 32'd3;
                        dst_addr <= dst_addr + 32'd1;
                        if (x == 7'd127) begin
                            x <= 7'd0;
                            y <= y + 7'd1;
                        end else begin
                            x <= x + 7'd1;
                        end
                        state <= ST_RGB_REQ_R;
                    end
                end

                ST_WIN_PREP: begin
                    win_center_addr <= src_rgb_addr;
                    win_idx <= 4'd0;
                    win_chan <= 2'd0;
                    if (border_pixel)
                        state <= ST_WIN_WRITE;
                    else
                        state <= ST_WIN_REQ;
                end

                ST_WIN_REQ: state <= ST_WIN_CAP;
                ST_WIN_CAP: begin
                    if (win_chan == 2'd0) begin
                        tmp_r <= mem_rdata;
                        win_chan <= 2'd1;
                        state <= ST_WIN_REQ;
                    end else if (win_chan == 2'd1) begin
                        tmp_g <= mem_rdata;
                        win_chan <= 2'd2;
                        state <= ST_WIN_REQ;
                    end else begin
                        case (win_idx)
                            4'd0: win0 <= win_gray;
                            4'd1: win1 <= win_gray;
                            4'd2: win2 <= win_gray;
                            4'd3: win3 <= win_gray;
                            4'd4: win4 <= win_gray;
                            4'd5: win5 <= win_gray;
                            4'd6: win6 <= win_gray;
                            4'd7: win7 <= win_gray;
                            default: win8 <= win_gray;
                        endcase
                        win_chan <= 2'd0;
                        if (win_idx == 4'd8) begin
                            state <= ST_WIN_WRITE;
                        end else begin
                            win_idx <= win_idx + 4'd1;
                            state <= ST_WIN_REQ;
                        end
                    end
                end

                ST_WIN_WRITE: begin
                    if (pix_count == 14'd16383) begin
                        result <= 32'd1;
                        state <= ST_FINISH;
                    end else begin
                        pix_count <= pix_count + 14'd1;
                        src_rgb_addr <= src_rgb_addr + 32'd3;
                        dst_addr <= dst_addr + 32'd1;
                        if (x == 7'd127) begin
                            x <= 7'd0;
                            y <= y + 7'd1;
                        end else begin
                            x <= x + 7'd1;
                        end
                        state <= ST_WIN_PREP;
                    end
                end

                ST_POOL_REQ: state <= ST_POOL_CAP;
                ST_POOL_CAP: begin
                    case (pool_idx)
                        2'd0: pool_a <= mem_rdata;
                        2'd1: pool_b <= mem_rdata;
                        2'd2: pool_c <= mem_rdata;
                        default: pool_d <= mem_rdata;
                    endcase
                    if (pool_idx == 2'd3) begin
                        state <= ST_POOL_WRITE;
                    end else begin
                        pool_idx <= pool_idx + 2'd1;
                        state <= ST_POOL_REQ;
                    end
                end

                ST_POOL_WRITE: begin
                    pool_idx <= 2'd0;
                    if (pool_count == 12'd4095) begin
                        result <= 32'd1;
                        state <= ST_FINISH;
                    end else begin
                        pool_count <= pool_count + 12'd1;
                        dst_addr <= dst_addr + 32'd1;
                        if (pool_x == 6'd63) begin
                            pool_x <= 6'd0;
                            pool_y <= pool_y + 6'd1;
                            pool_base_addr <= pool_base_addr + POOL_ROW_STEP - 32'd126;
                        end else begin
                            pool_x <= pool_x + 6'd1;
                            pool_base_addr <= pool_base_addr + 32'd2;
                        end
                        state <= ST_POOL_REQ;
                    end
                end

                ST_FINISH: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end
endmodule
