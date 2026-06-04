// ipu_fpga.sv
// FPGA-synthesis-safe IPU for EVPIX-RV32.
//
// v3 fix:
//   - Removed the small unpacked array win[0:8]. Vivado was treating it as a RAM
//     inside an async-reset process and refused BRAM/DRAM inference.
//   - Replaced it with nine scalar window registers win0..win8.
//   - No image-processing algorithm was changed.
//
// Memory timing expected:
//   mem_addr/mem_re asserted in a *_REQ state
//   mem_rdata captured in the following *_CAP state

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

    localparam int PIXELS      = IMG_W * IMG_H;
    localparam int POOL_W      = IMG_W / 2;
    localparam int POOL_H      = IMG_H / 2;
    localparam int POOL_PIXELS = POOL_W * POOL_H;

    localparam logic [2:0] OP_GRAY     = 3'd0;
    localparam logic [2:0] OP_THRESH   = 3'd1;
    localparam logic [2:0] OP_MAXPIX   = 3'd2;
    localparam logic [2:0] OP_SOBEL    = 3'd3;
    localparam logic [2:0] OP_CONV     = 3'd4;
    localparam logic [2:0] OP_MAXPOOL  = 3'd5;
    localparam logic [2:0] OP_AVGPOOL  = 3'd6;

    typedef enum logic [4:0] {
        ST_IDLE          = 5'd0,
        ST_RGB_REQ_R     = 5'd1,
        ST_RGB_CAP_R     = 5'd2,
        ST_RGB_REQ_G     = 5'd3,
        ST_RGB_CAP_G     = 5'd4,
        ST_RGB_REQ_B     = 5'd5,
        ST_RGB_CAP_B     = 5'd6,
        ST_SIMPLE_WRITE  = 5'd7,
        ST_WIN_START     = 5'd8,
        ST_WIN_REQ       = 5'd9,
        ST_WIN_CAP       = 5'd10,
        ST_CONV_WRITE    = 5'd11,
        ST_POOL_REQ      = 5'd12,
        ST_POOL_CAP      = 5'd13,
        ST_POOL_WRITE    = 5'd14,
        ST_FINISH        = 5'd15
    } state_t;

    state_t state;
    logic [2:0]  op_r;
    logic [3:0]  kernel_r;
    logic [31:0] src_base_r, dst_base_r;
    logic [31:0] pix_idx;

    logic [7:0] r_reg, g_reg, b_reg;
    logic [7:0] max_pix;
    logic [7:0] gray_now;

    logic [3:0] win_idx;
    logic [1:0] chan_idx;
    logic [7:0] tmp_r, tmp_g;

    // Nine scalar 3x3-window registers. Do not use an unpacked array here:
    // Vivado may infer it as a reset-sensitive RAM and fail elaboration.
    logic [7:0] win0, win1, win2, win3, win4, win5, win6, win7, win8;

    logic [1:0] pool_idx;
    logic [7:0] pool_a, pool_b, pool_c, pool_d;

    integer cx, cy;
    integer nx, ny;
    integer n_pix;
    integer gx_calc, gy_calc, mag_calc;
    integer conv_sum, norm_val;
    logic [7:0] sobel_pix, conv_pix, pool_pix;
    logic [9:0] pool_sum;

    function automatic [7:0] rgb_to_gray(
        input logic [7:0] r,
        input logic [7:0] g,
        input logic [7:0] b
    );
        logic [15:0] sum;
        begin
            sum = (r * 8'd77) + (g * 8'd150) + (b * 8'd29);
            rgb_to_gray = sum[15:8];
        end
    endfunction

    function automatic signed [7:0] kernel_coeff(
        input logic [3:0] kid,
        input integer idx
    );
        begin
            case (kid)
                4'd0: begin // identity
                    case (idx)
                        4: kernel_coeff = 8'sd1;
                        default: kernel_coeff = 8'sd0;
                    endcase
                end
                4'd1: begin // sobel x
                    case (idx)
                        0: kernel_coeff = -8'sd1;
                        1: kernel_coeff =  8'sd0;
                        2: kernel_coeff =  8'sd1;
                        3: kernel_coeff = -8'sd2;
                        4: kernel_coeff =  8'sd0;
                        5: kernel_coeff =  8'sd2;
                        6: kernel_coeff = -8'sd1;
                        7: kernel_coeff =  8'sd0;
                        8: kernel_coeff =  8'sd1;
                        default: kernel_coeff = 8'sd0;
                    endcase
                end
                4'd2: begin // sobel y
                    case (idx)
                        0: kernel_coeff =  8'sd1;
                        1: kernel_coeff =  8'sd2;
                        2: kernel_coeff =  8'sd1;
                        3: kernel_coeff =  8'sd0;
                        4: kernel_coeff =  8'sd0;
                        5: kernel_coeff =  8'sd0;
                        6: kernel_coeff = -8'sd1;
                        7: kernel_coeff = -8'sd2;
                        8: kernel_coeff = -8'sd1;
                        default: kernel_coeff = 8'sd0;
                    endcase
                end
                4'd3: begin // gaussian blur
                    case (idx)
                        0,2,6,8: kernel_coeff = 8'sd1;
                        1,3,5,7: kernel_coeff = 8'sd2;
                        4: kernel_coeff = 8'sd4;
                        default: kernel_coeff = 8'sd0;
                    endcase
                end
                4'd4: begin // sharpen
                    case (idx)
                        0,2,6,8: kernel_coeff = 8'sd0;
                        1,3,5,7: kernel_coeff = -8'sd1;
                        4: kernel_coeff = 8'sd5;
                        default: kernel_coeff = 8'sd0;
                    endcase
                end
                4'd5: begin // edge detect
                    case (idx)
                        4: kernel_coeff = 8'sd8;
                        default: kernel_coeff = -8'sd1;
                    endcase
                end
                default: kernel_coeff = 8'sd0;
            endcase
        end
    endfunction

    always_comb begin
        gray_now = rgb_to_gray(r_reg, g_reg, b_reg);
    end

    always_comb begin
        // Center coordinate of current output pixel
        cx = pix_idx % IMG_W;
        cy = pix_idx / IMG_W;

        // Neighbor coordinate for current 3x3 window element
        nx = cx + (win_idx % 3) - 1;
        ny = cy + (win_idx / 3) - 1;
        n_pix = (ny * IMG_W) + nx;

        sobel_pix = 8'd0;
        gx_calc = -$signed({1'b0, win0})
                  -($signed({1'b0, win3}) <<< 1)
                  -$signed({1'b0, win6})
                  +$signed({1'b0, win2})
                  +($signed({1'b0, win5}) <<< 1)
                  +$signed({1'b0, win8});

        gy_calc =  $signed({1'b0, win0})
                  +($signed({1'b0, win1}) <<< 1)
                  +$signed({1'b0, win2})
                  -$signed({1'b0, win6})
                  -($signed({1'b0, win7}) <<< 1)
                  -$signed({1'b0, win8});

        if (gx_calc < 0) gx_calc = -gx_calc;
        if (gy_calc < 0) gy_calc = -gy_calc;
        mag_calc = gx_calc + gy_calc;
        if (mag_calc > 255) sobel_pix = 8'hFF;
        else                sobel_pix = mag_calc[7:0];

        conv_sum = 0;
        conv_sum += $signed(kernel_coeff(kernel_r,0)) * $signed({1'b0, win0});
        conv_sum += $signed(kernel_coeff(kernel_r,1)) * $signed({1'b0, win1});
        conv_sum += $signed(kernel_coeff(kernel_r,2)) * $signed({1'b0, win2});
        conv_sum += $signed(kernel_coeff(kernel_r,3)) * $signed({1'b0, win3});
        conv_sum += $signed(kernel_coeff(kernel_r,4)) * $signed({1'b0, win4});
        conv_sum += $signed(kernel_coeff(kernel_r,5)) * $signed({1'b0, win5});
        conv_sum += $signed(kernel_coeff(kernel_r,6)) * $signed({1'b0, win6});
        conv_sum += $signed(kernel_coeff(kernel_r,7)) * $signed({1'b0, win7});
        conv_sum += $signed(kernel_coeff(kernel_r,8)) * $signed({1'b0, win8});

        if (kernel_r == 4'd3) norm_val = conv_sum >>> 4;
        else                 norm_val = conv_sum;

        if (norm_val < 0)        conv_pix = 8'd0;
        else if (norm_val > 255) conv_pix = 8'hFF;
        else                     conv_pix = norm_val[7:0];

        pool_sum = {2'b00, pool_a} + {2'b00, pool_b} + {2'b00, pool_c} + {2'b00, pool_d};
        if (op_r == OP_MAXPOOL) begin
            pool_pix = pool_a;
            if (pool_b > pool_pix) pool_pix = pool_b;
            if (pool_c > pool_pix) pool_pix = pool_c;
            if (pool_d > pool_pix) pool_pix = pool_d;
        end else begin
            pool_pix = pool_sum[9:2];
        end
    end

    always_comb begin
        mem_re    = 1'b0;
        mem_we    = 1'b0;
        mem_addr  = 32'b0;
        mem_wdata = 8'b0;

        case (state)
            ST_RGB_REQ_R: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + (pix_idx * 32'd3);
            end
            ST_RGB_REQ_G: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + (pix_idx * 32'd3) + 32'd1;
            end
            ST_RGB_REQ_B: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + (pix_idx * 32'd3) + 32'd2;
            end
            ST_SIMPLE_WRITE: begin
                if (op_r != OP_MAXPIX) begin
                    mem_we    = 1'b1;
                    mem_addr  = dst_base_r + pix_idx;
                    mem_wdata = (op_r == OP_THRESH) ?
                                ((gray_now >= THRESHOLD_VALUE) ? 8'hFF : 8'h00) :
                                gray_now;
                end
            end
            ST_WIN_REQ: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + (n_pix * 32'd3) + chan_idx;
            end
            ST_CONV_WRITE: begin
                mem_we    = 1'b1;
                mem_addr  = dst_base_r + pix_idx;
                if ((cx == 0) || (cx == IMG_W-1) || (cy == 0) || (cy == IMG_H-1))
                    mem_wdata = 8'd0;
                else if (op_r == OP_SOBEL)
                    mem_wdata = sobel_pix;
                else
                    mem_wdata = conv_pix;
            end
            ST_POOL_REQ: begin
                mem_re = 1'b1;
                case (pool_idx)
                    2'd0: mem_addr = src_base_r + ((pix_idx / POOL_W) * 2 * IMG_W) + ((pix_idx % POOL_W) * 2);
                    2'd1: mem_addr = src_base_r + ((pix_idx / POOL_W) * 2 * IMG_W) + ((pix_idx % POOL_W) * 2) + 32'd1;
                    2'd2: mem_addr = src_base_r + ((pix_idx / POOL_W) * 2 * IMG_W) + IMG_W + ((pix_idx % POOL_W) * 2);
                    2'd3: mem_addr = src_base_r + ((pix_idx / POOL_W) * 2 * IMG_W) + IMG_W + ((pix_idx % POOL_W) * 2) + 32'd1;
                    default: mem_addr = 32'b0;
                endcase
            end
            ST_POOL_WRITE: begin
                mem_we    = 1'b1;
                mem_addr  = dst_base_r + pix_idx;
                mem_wdata = pool_pix;
            end
            default: begin
            end
        endcase
    end

    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            busy             <= 1'b0;
            done             <= 1'b0;
            result           <= 32'b0;
            conv_cycle_count <= 32'b0;
            pool_cycle_count <= 32'b0;
            state            <= ST_IDLE;
            op_r             <= 3'b0;
            kernel_r         <= 4'b0;
            src_base_r       <= 32'b0;
            dst_base_r       <= 32'b0;
            pix_idx          <= 32'b0;
            r_reg            <= 8'b0;
            g_reg            <= 8'b0;
            b_reg            <= 8'b0;
            max_pix          <= 8'b0;
            win_idx          <= 4'b0;
            chan_idx         <= 2'b0;
            tmp_r            <= 8'b0;
            tmp_g            <= 8'b0;
            win0             <= 8'b0;
            win1             <= 8'b0;
            win2             <= 8'b0;
            win3             <= 8'b0;
            win4             <= 8'b0;
            win5             <= 8'b0;
            win6             <= 8'b0;
            win7             <= 8'b0;
            win8             <= 8'b0;
            pool_idx         <= 2'b0;
            pool_a           <= 8'b0;
            pool_b           <= 8'b0;
            pool_c           <= 8'b0;
            pool_d           <= 8'b0;
        end else begin
            if (busy) begin
                if ((op_r == OP_SOBEL) || (op_r == OP_CONV))
                    conv_cycle_count <= conv_cycle_count + 32'd1;
                else if ((op_r == OP_MAXPOOL) || (op_r == OP_AVGPOOL))
                    pool_cycle_count <= pool_cycle_count + 32'd1;
            end

            if (start && !busy) begin
                busy       <= 1'b1;
                done       <= 1'b0;
                result     <= 32'b0;
                op_r       <= op;
                kernel_r   <= kernel;
                src_base_r <= src_base;
                dst_base_r <= dst_base;
                pix_idx    <= 32'b0;
                max_pix    <= 8'b0;
                win_idx    <= 4'd0;
                chan_idx   <= 2'd0;
                pool_idx   <= 2'd0;

                case (op)
                    OP_GRAY, OP_THRESH, OP_MAXPIX: state <= ST_RGB_REQ_R;
                    OP_SOBEL, OP_CONV:             state <= ST_WIN_START;
                    OP_MAXPOOL, OP_AVGPOOL:        state <= ST_POOL_REQ;
                    default: begin
                        busy   <= 1'b0;
                        done   <= 1'b1;
                        result <= 32'b0;
                        state  <= ST_IDLE;
                    end
                endcase
            end else begin
                case (state)
                    ST_IDLE: begin
                    end

                    ST_RGB_REQ_R: state <= ST_RGB_CAP_R;
                    ST_RGB_CAP_R: begin
                        r_reg <= mem_rdata;
                        state <= ST_RGB_REQ_G;
                    end
                    ST_RGB_REQ_G: state <= ST_RGB_CAP_G;
                    ST_RGB_CAP_G: begin
                        g_reg <= mem_rdata;
                        state <= ST_RGB_REQ_B;
                    end
                    ST_RGB_REQ_B: state <= ST_RGB_CAP_B;
                    ST_RGB_CAP_B: begin
                        b_reg <= mem_rdata;
                        state <= ST_SIMPLE_WRITE;
                    end

                    ST_SIMPLE_WRITE: begin
                        if ((op_r == OP_MAXPIX) && (gray_now > max_pix))
                            max_pix <= gray_now;

                        if (pix_idx == PIXELS-1) begin
                            result <= (op_r == OP_MAXPIX) ? {24'b0, (gray_now > max_pix ? gray_now : max_pix)} : 32'd1;
                            state  <= ST_FINISH;
                        end else begin
                            pix_idx <= pix_idx + 32'd1;
                            state   <= ST_RGB_REQ_R;
                        end
                    end

                    ST_WIN_START: begin
                        if ((cx == 0) || (cx == IMG_W-1) || (cy == 0) || (cy == IMG_H-1)) begin
                            state <= ST_CONV_WRITE;
                        end else begin
                            win_idx  <= 4'd0;
                            chan_idx <= 2'd0;
                            state    <= ST_WIN_REQ;
                        end
                    end

                    ST_WIN_REQ: state <= ST_WIN_CAP;
                    ST_WIN_CAP: begin
                        if (chan_idx == 2'd0) begin
                            tmp_r    <= mem_rdata;
                            chan_idx <= 2'd1;
                            state    <= ST_WIN_REQ;
                        end else if (chan_idx == 2'd1) begin
                            tmp_g    <= mem_rdata;
                            chan_idx <= 2'd2;
                            state    <= ST_WIN_REQ;
                        end else begin
                            case (win_idx)
                                4'd0: win0 <= rgb_to_gray(tmp_r, tmp_g, mem_rdata);
                                4'd1: win1 <= rgb_to_gray(tmp_r, tmp_g, mem_rdata);
                                4'd2: win2 <= rgb_to_gray(tmp_r, tmp_g, mem_rdata);
                                4'd3: win3 <= rgb_to_gray(tmp_r, tmp_g, mem_rdata);
                                4'd4: win4 <= rgb_to_gray(tmp_r, tmp_g, mem_rdata);
                                4'd5: win5 <= rgb_to_gray(tmp_r, tmp_g, mem_rdata);
                                4'd6: win6 <= rgb_to_gray(tmp_r, tmp_g, mem_rdata);
                                4'd7: win7 <= rgb_to_gray(tmp_r, tmp_g, mem_rdata);
                                4'd8: win8 <= rgb_to_gray(tmp_r, tmp_g, mem_rdata);
                                default: ;
                            endcase
                            chan_idx <= 2'd0;
                            if (win_idx == 4'd8) begin
                                state <= ST_CONV_WRITE;
                            end else begin
                                win_idx <= win_idx + 4'd1;
                                state   <= ST_WIN_REQ;
                            end
                        end
                    end

                    ST_CONV_WRITE: begin
                        if (pix_idx == PIXELS-1) begin
                            result <= 32'd1;
                            state  <= ST_FINISH;
                        end else begin
                            pix_idx <= pix_idx + 32'd1;
                            state   <= ST_WIN_START;
                        end
                    end

                    ST_POOL_REQ: state <= ST_POOL_CAP;
                    ST_POOL_CAP: begin
                        case (pool_idx)
                            2'd0: pool_a <= mem_rdata;
                            2'd1: pool_b <= mem_rdata;
                            2'd2: pool_c <= mem_rdata;
                            2'd3: pool_d <= mem_rdata;
                            default: ;
                        endcase

                        if (pool_idx == 2'd3) begin
                            pool_idx <= 2'd0;
                            state    <= ST_POOL_WRITE;
                        end else begin
                            pool_idx <= pool_idx + 2'd1;
                            state    <= ST_POOL_REQ;
                        end
                    end

                    ST_POOL_WRITE: begin
                        if (pix_idx == POOL_PIXELS-1) begin
                            result <= 32'd1;
                            state  <= ST_FINISH;
                        end else begin
                            pix_idx <= pix_idx + 32'd1;
                            state   <= ST_POOL_REQ;
                        end
                    end

                    ST_FINISH: begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= ST_IDLE;
                    end

                    default: begin
                        state <= ST_IDLE;
                    end
                endcase
            end
        end
    end

endmodule
