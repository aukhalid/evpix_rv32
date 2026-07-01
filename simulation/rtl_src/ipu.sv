module ipu #(
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
    localparam int RGB_BYTES   = PIXELS * 3;
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

    typedef enum logic [3:0] {
        ST_IDLE         = 4'd0,
        ST_RGB_R        = 4'd1,
        ST_RGB_G        = 4'd2,
        ST_RGB_B        = 4'd3,
        ST_SIMPLE_W     = 4'd4,
        ST_PREP_W       = 4'd5,
        ST_CONV_W       = 4'd6,
        ST_POOL_A       = 4'd7,
        ST_POOL_B       = 4'd8,
        ST_POOL_C       = 4'd9,
        ST_POOL_D       = 4'd10,
        ST_POOL_WRITE   = 4'd11,
        ST_FINISH       = 4'd12
    } state_t;

    state_t state;
    logic [2:0]  op_r;
    logic [3:0]  kernel_r;
    logic [31:0] src_base_r, dst_base_r;
    logic [31:0] pix_idx;
    logic [7:0]  r_reg, g_reg, b_reg;
    logic [7:0]  gray_buf [0:PIXELS-1];
    logic [7:0]  max_pix;
    logic [7:0]  pool_a, pool_b, pool_c, pool_d;
    integer x;
    integer y;
    integer gx;
    integer gy;
    integer mag;
    integer conv_sum;
    integer norm_val;
    logic [7:0] gray_now;
    logic [7:0] conv_pix;
    logic [7:0] sobel_pix;
    logic [7:0] pool_pix;
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
                        0,1,2,3,5,6,7,8: kernel_coeff = 8'sd0;
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
        sobel_pix = 8'd0;
        if (pix_idx < PIXELS) begin
            x = pix_idx % IMG_W;
            y = pix_idx / IMG_W;
            if ((x == 0) || (x == IMG_W-1) || (y == 0) || (y == IMG_H-1)) begin
                sobel_pix = 8'd0;
            end else begin
                gx = -gray_buf[(y-1)*IMG_W + (x-1)]
                     -($signed({1'b0, gray_buf[y*IMG_W + (x-1)]}) <<< 1)
                     -gray_buf[(y+1)*IMG_W + (x-1)]
                     +gray_buf[(y-1)*IMG_W + (x+1)]
                     +($signed({1'b0, gray_buf[y*IMG_W + (x+1)]}) <<< 1)
                     +gray_buf[(y+1)*IMG_W + (x+1)];

                gy =  gray_buf[(y-1)*IMG_W + (x-1)]
                     +($signed({1'b0, gray_buf[(y-1)*IMG_W + x]}) <<< 1)
                     +gray_buf[(y-1)*IMG_W + (x+1)]
                     -gray_buf[(y+1)*IMG_W + (x-1)]
                     -($signed({1'b0, gray_buf[(y+1)*IMG_W + x]}) <<< 1)
                     -gray_buf[(y+1)*IMG_W + (x+1)];

                if (gx < 0) gx = -gx;
                if (gy < 0) gy = -gy;
                mag = gx + gy;
                if (mag > 255)
                    sobel_pix = 8'hFF;
                else
                    sobel_pix = mag[7:0];
            end
        end
    end

    always_comb begin
        conv_pix = 8'd0;
        if (pix_idx < PIXELS) begin
            x = pix_idx % IMG_W;
            y = pix_idx / IMG_W;
            if ((x == 0) || (x == IMG_W-1) || (y == 0) || (y == IMG_H-1)) begin
                conv_pix = 8'd0;
            end else begin
                conv_sum = 0;
                conv_sum += $signed(kernel_coeff(kernel_r,0)) * $signed({1'b0, gray_buf[(y-1)*IMG_W + (x-1)]});
                conv_sum += $signed(kernel_coeff(kernel_r,1)) * $signed({1'b0, gray_buf[(y-1)*IMG_W + x]});
                conv_sum += $signed(kernel_coeff(kernel_r,2)) * $signed({1'b0, gray_buf[(y-1)*IMG_W + (x+1)]});
                conv_sum += $signed(kernel_coeff(kernel_r,3)) * $signed({1'b0, gray_buf[y*IMG_W + (x-1)]});
                conv_sum += $signed(kernel_coeff(kernel_r,4)) * $signed({1'b0, gray_buf[y*IMG_W + x]});
                conv_sum += $signed(kernel_coeff(kernel_r,5)) * $signed({1'b0, gray_buf[y*IMG_W + (x+1)]});
                conv_sum += $signed(kernel_coeff(kernel_r,6)) * $signed({1'b0, gray_buf[(y+1)*IMG_W + (x-1)]});
                conv_sum += $signed(kernel_coeff(kernel_r,7)) * $signed({1'b0, gray_buf[(y+1)*IMG_W + x]});
                conv_sum += $signed(kernel_coeff(kernel_r,8)) * $signed({1'b0, gray_buf[(y+1)*IMG_W + (x+1)]});

                if (kernel_r == 4'd3)
                    norm_val = conv_sum >>> 4;
                else
                    norm_val = conv_sum;

                if (norm_val < 0)
                    conv_pix = 8'd0;
                else if (norm_val > 255)
                    conv_pix = 8'hFF;
                else
                    conv_pix = norm_val[7:0];
            end
        end
    end

    always_comb begin
        pool_pix = 8'd0;
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
            ST_RGB_R: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + (pix_idx * 32'd3);
            end
            ST_RGB_G: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + (pix_idx * 32'd3) + 32'd1;
            end
            ST_RGB_B: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + (pix_idx * 32'd3) + 32'd2;
            end
            ST_SIMPLE_W: begin
                if (op_r != OP_MAXPIX) begin
                    mem_we    = 1'b1;
                    mem_addr  = dst_base_r + pix_idx;
                    mem_wdata = (op_r == OP_THRESH) ?
                                ((gray_now >= THRESHOLD_VALUE) ? 8'hFF : 8'h00) :
                                gray_now;
                end
            end
            ST_CONV_W: begin
                mem_we    = 1'b1;
                mem_addr  = dst_base_r + pix_idx;
                mem_wdata = (op_r == OP_SOBEL) ? sobel_pix : conv_pix;
            end
            ST_POOL_A: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + ((pix_idx / POOL_W) * 2 * IMG_W) + ((pix_idx % POOL_W) * 2);
            end
            ST_POOL_B: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + ((pix_idx / POOL_W) * 2 * IMG_W) + ((pix_idx % POOL_W) * 2) + 32'd1;
            end
            ST_POOL_C: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + ((pix_idx / POOL_W) * 2 * IMG_W) + IMG_W + ((pix_idx % POOL_W) * 2);
            end
            ST_POOL_D: begin
                mem_re   = 1'b1;
                mem_addr = src_base_r + ((pix_idx / POOL_W) * 2 * IMG_W) + IMG_W + ((pix_idx % POOL_W) * 2) + 32'd1;
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
            pool_a           <= 8'b0;
            pool_b           <= 8'b0;
            pool_c           <= 8'b0;
            pool_d           <= 8'b0;
        end else begin
            if (busy)
                if ((op_r == OP_SOBEL) || (op_r == OP_CONV))
                    conv_cycle_count <= conv_cycle_count + 32'd1;
                else if ((op_r == OP_MAXPOOL) || (op_r == OP_AVGPOOL))
                    pool_cycle_count <= pool_cycle_count + 32'd1;

            if (start && !busy) begin
                busy       <= 1'b1;
                done       <= 1'b0;
                op_r       <= op;
                kernel_r   <= kernel;
                src_base_r <= src_base;
                dst_base_r <= dst_base;
                pix_idx    <= 32'b0;
                max_pix    <= 8'b0;
                case (op)
                    OP_GRAY, OP_THRESH, OP_MAXPIX, OP_SOBEL, OP_CONV: state <= ST_RGB_R;
                    OP_MAXPOOL, OP_AVGPOOL: state <= ST_POOL_A;
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

                    ST_RGB_R: begin
                        r_reg <= mem_rdata;
                        state <= ST_RGB_G;
                    end

                    ST_RGB_G: begin
                        g_reg <= mem_rdata;
                        state <= ST_RGB_B;
                    end

                    ST_RGB_B: begin
                        b_reg <= mem_rdata;
                        if ((op_r == OP_SOBEL) || (op_r == OP_CONV))
                            state <= ST_PREP_W;
                        else
                            state <= ST_SIMPLE_W;
                    end

                    ST_PREP_W: begin
                        gray_buf[pix_idx] <= gray_now;
                        if (pix_idx == PIXELS-1) begin
                            pix_idx <= 32'b0;
                            state   <= ST_CONV_W;
                        end else begin
                            pix_idx <= pix_idx + 32'd1;
                            state   <= ST_RGB_R;
                        end
                    end

                    ST_SIMPLE_W: begin
                        if ((op_r == OP_MAXPIX) && (gray_now > max_pix))
                            max_pix <= gray_now;

                        if (pix_idx == PIXELS-1) begin
                            result <= (op_r == OP_MAXPIX) ? {24'b0, (gray_now > max_pix ? gray_now : max_pix)} : 32'd1;
                            state  <= ST_FINISH;
                        end else begin
                            pix_idx <= pix_idx + 32'd1;
                            state   <= ST_RGB_R;
                        end
                    end

                    ST_CONV_W: begin
                        if (pix_idx == PIXELS-1) begin
                            result <= 32'd1;
                            state  <= ST_FINISH;
                        end else begin
                            pix_idx <= pix_idx + 32'd1;
                        end
                    end

                    ST_POOL_A: begin
                        pool_a <= mem_rdata;
                        state  <= ST_POOL_B;
                    end

                    ST_POOL_B: begin
                        pool_b <= mem_rdata;
                        state  <= ST_POOL_C;
                    end

                    ST_POOL_C: begin
                        pool_c <= mem_rdata;
                        state  <= ST_POOL_D;
                    end

                    ST_POOL_D: begin
                        pool_d <= mem_rdata;
                        state  <= ST_POOL_WRITE;
                    end

                    ST_POOL_WRITE: begin
                        if (pix_idx == POOL_PIXELS-1) begin
                            result <= 32'd1;
                            state  <= ST_FINISH;
                        end else begin
                            pix_idx <= pix_idx + 32'd1;
                            state   <= ST_POOL_A;
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
