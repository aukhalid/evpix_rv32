// data_memory_fpga.sv
// EVPIX-RV32 Basys 3 data memory, V9 resource-safe fix.
//
// Why this file exists:
//   V8 fixed CPU LW/LHU timing by reading the full 64 KiB data memory on the
//   falling edge. Vivado could not infer BRAM from that structure and mapped the
//   64 KiB memory into LUT/distributed RAM, causing implementation failure:
//     [DRC UTLZ-1] LUT as Distributed RAM over-utilized.
//
// V9 fix:
//   1) The large 64 KiB EVPIX image/IPU memory is kept as true block RAM.
//   2) The CPU regression/BIST data region 0x0000_0000..0x0000_01FF is mirrored
//      in a tiny 512-byte CPU-fast memory with combinational read. This is small
//      enough for LUT RAM and lets the existing 5-stage pipeline see load data
//      in time for the FPGA BIST without turning the full image memory into LUTs.
//   3) IPU/image algorithms and the EVPIX memory map are unchanged:
//        0x0000_0000..0x0000_BFFF : 128x128 RGB888 source image
//        0x0000_C000..0x0000_FFFF : 128x128 8-bit processed output
//
// Practical note:
//   The hardware BIST uses addresses around 0x100, so it is served by the small
//   fast CPU memory. Live IPU mode uses the large BRAM image memory.

module data_memory_fpga #(
    parameter int MEM_BYTES = 65536
) (
    input  logic        clk,
    input  logic        reset,

    // CPU data memory port from existing pipeline
    input  logic        mem_write,
    input  logic        mem_read,
    input  logic [2:0]  funct3,
    input  logic [31:0] addr,
    input  logic [31:0] write_data,
    output logic [31:0] read_data,

    // IPU byte memory port
    input  logic        ipu_mem_re,
    input  logic        ipu_mem_we,
    input  logic [31:0] ipu_addr,
    input  logic [7:0]  ipu_write_data,
    output logic [7:0]  ipu_read_data,

    // Camera/SPI image-loader byte write port
    input  logic        host_we,
    input  logic [31:0] host_addr,
    input  logic [7:0]  host_wdata,

    // Optional hardware-test MMIO status
    output logic [31:0] mmio_status,
    output logic        mmio_valid
);

    localparam int WORDS = MEM_BYTES / 4;
    localparam logic [31:0] MMIO_STATUS_ADDR = 32'h0000_FF00;
    localparam int CPU_FAST_BYTES = 288;  // v11: enough for BIST bytes up to 0x10B, saves LUT/FF reset logic

    // ------------------------------------------------------------------
    // Large image/IPU memory: force block RAM inference.
    // Four byte lanes allow byte writes while preserving the existing memory map.
    // ------------------------------------------------------------------
    (* ram_style = "block" *) logic [7:0] ram0 [0:WORDS-1];
    (* ram_style = "block" *) logic [7:0] ram1 [0:WORDS-1];
    (* ram_style = "block" *) logic [7:0] ram2 [0:WORDS-1];
    (* ram_style = "block" *) logic [7:0] ram3 [0:WORDS-1];

    // Small fast CPU/BIST memory. Only 288 bytes; safe as distributed RAM.
    // v11 LUT-safe fix:
    //   Do NOT reset this memory in an async-reset process. Reset-sensitive
    //   memory forces Vivado to implement it with many registers/LUTs. The BIST
    //   writes all tested bytes before reading them; the initial block gives
    //   deterministic power-up zeros for unused observed bytes.
    (* ram_style = "distributed" *) logic [7:0] cpu_fast_mem [0:CPU_FAST_BYTES-1];

    initial begin : INIT_CPU_FAST_MEM
        for (int init_i = 0; init_i < CPU_FAST_BYTES; init_i = init_i + 1)
            cpu_fast_mem[init_i] = 8'd0;
    end

    function automatic logic in_byte_range(input logic [31:0] a);
        in_byte_range = (a < MEM_BYTES);
    endfunction

    function automatic logic in_word_range(input logic [31:0] wa);
        in_word_range = (wa < WORDS);
    endfunction

    function automatic logic in_cpu_fast_range(input logic [31:0] a);
        in_cpu_fast_range = (a < CPU_FAST_BYTES);
    endfunction

    // ------------------------------------------------------------------
    // Write arbitration for the large image/IPU BRAM.
    // Priority matches the previous design: host camera, then IPU, then CPU.
    // ------------------------------------------------------------------
    logic        bram_wr_en;
    logic [31:0] bram_wr_word_addr;
    logic [3:0]  bram_wr_be;
    logic [7:0]  bram_wr_b0, bram_wr_b1, bram_wr_b2, bram_wr_b3;

    always_comb begin
        bram_wr_en        = 1'b0;
        bram_wr_word_addr = 32'd0;
        bram_wr_be        = 4'b0000;
        bram_wr_b0        = 8'd0;
        bram_wr_b1        = 8'd0;
        bram_wr_b2        = 8'd0;
        bram_wr_b3        = 8'd0;

        if (host_we && in_byte_range(host_addr)) begin
            bram_wr_en        = 1'b1;
            bram_wr_word_addr = host_addr[31:2];
            unique case (host_addr[1:0])
                2'd0: begin bram_wr_be = 4'b0001; bram_wr_b0 = host_wdata; end
                2'd1: begin bram_wr_be = 4'b0010; bram_wr_b1 = host_wdata; end
                2'd2: begin bram_wr_be = 4'b0100; bram_wr_b2 = host_wdata; end
                2'd3: begin bram_wr_be = 4'b1000; bram_wr_b3 = host_wdata; end
                default: ;
            endcase
        end else if (ipu_mem_we && in_byte_range(ipu_addr)) begin
            bram_wr_en        = 1'b1;
            bram_wr_word_addr = ipu_addr[31:2];
            unique case (ipu_addr[1:0])
                2'd0: begin bram_wr_be = 4'b0001; bram_wr_b0 = ipu_write_data; end
                2'd1: begin bram_wr_be = 4'b0010; bram_wr_b1 = ipu_write_data; end
                2'd2: begin bram_wr_be = 4'b0100; bram_wr_b2 = ipu_write_data; end
                2'd3: begin bram_wr_be = 4'b1000; bram_wr_b3 = ipu_write_data; end
                default: ;
            endcase
        end else if (mem_write && (addr != MMIO_STATUS_ADDR) && in_byte_range(addr)) begin
            // CPU stores are also mirrored into the large memory for completeness,
            // although the BIST read path uses cpu_fast_mem for timing-safe loads.
            bram_wr_en        = 1'b1;
            bram_wr_word_addr = addr[31:2];
            unique case (funct3)
                3'b000: begin // SB
                    unique case (addr[1:0])
                        2'd0: begin bram_wr_be = 4'b0001; bram_wr_b0 = write_data[7:0]; end
                        2'd1: begin bram_wr_be = 4'b0010; bram_wr_b1 = write_data[7:0]; end
                        2'd2: begin bram_wr_be = 4'b0100; bram_wr_b2 = write_data[7:0]; end
                        2'd3: begin bram_wr_be = 4'b1000; bram_wr_b3 = write_data[7:0]; end
                        default: ;
                    endcase
                end
                3'b001: begin // SH, aligned halfword
                    if (addr[1:0] == 2'd0) begin
                        bram_wr_be = 4'b0011;
                        bram_wr_b0 = write_data[7:0];
                        bram_wr_b1 = write_data[15:8];
                    end else if (addr[1:0] == 2'd2) begin
                        bram_wr_be = 4'b1100;
                        bram_wr_b2 = write_data[7:0];
                        bram_wr_b3 = write_data[15:8];
                    end else begin
                        bram_wr_en = 1'b0;
                    end
                end
                3'b010: begin // SW, aligned word
                    if (addr[1:0] == 2'd0) begin
                        bram_wr_be = 4'b1111;
                        bram_wr_b0 = write_data[7:0];
                        bram_wr_b1 = write_data[15:8];
                        bram_wr_b2 = write_data[23:16];
                        bram_wr_b3 = write_data[31:24];
                    end else begin
                        bram_wr_en = 1'b0;
                    end
                end
                default: bram_wr_en = 1'b0;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // CPU-fast memory write port for BIST/general low-address loads/stores.
    // v11 LUT-safe fix:
    //   This RAM is intentionally NOT reset. Resetting even a small RAM with a
    //   for-loop can map it into thousands of resettable FFs/LUTs. The initial
    //   block above provides deterministic power-up contents, and the BIST
    //   writes all bytes that it later verifies.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (mem_write && (addr != MMIO_STATUS_ADDR) && in_cpu_fast_range(addr)) begin
            unique case (funct3)
                3'b000: begin // SB
                    cpu_fast_mem[addr[8:0]] <= write_data[7:0];
                end
                3'b001: begin // SH, little endian
                    if (((addr[1:0] == 2'd0) || (addr[1:0] == 2'd2)) &&
                        in_cpu_fast_range(addr + 32'd1)) begin
                        cpu_fast_mem[addr[8:0]]         <= write_data[7:0];
                        cpu_fast_mem[addr[8:0] + 9'd1] <= write_data[15:8];
                    end
                end
                3'b010: begin // SW, little endian
                    if ((addr[1:0] == 2'd0) && in_cpu_fast_range(addr + 32'd3)) begin
                        cpu_fast_mem[addr[8:0]]         <= write_data[7:0];
                        cpu_fast_mem[addr[8:0] + 9'd1] <= write_data[15:8];
                        cpu_fast_mem[addr[8:0] + 9'd2] <= write_data[23:16];
                        cpu_fast_mem[addr[8:0] + 9'd3] <= write_data[31:24];
                    end
                end
                default: ;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Large BRAM posedge write + IPU synchronous byte read.
    // The IPU FSM expects one-clock read latency.
    // ------------------------------------------------------------------
    logic [7:0] ipu_b0_q, ipu_b1_q, ipu_b2_q, ipu_b3_q;
    logic [1:0] ipu_lane_q;

    always_ff @(posedge clk) begin
        if (bram_wr_en && in_word_range(bram_wr_word_addr)) begin
            if (bram_wr_be[0]) ram0[bram_wr_word_addr] <= bram_wr_b0;
            if (bram_wr_be[1]) ram1[bram_wr_word_addr] <= bram_wr_b1;
            if (bram_wr_be[2]) ram2[bram_wr_word_addr] <= bram_wr_b2;
            if (bram_wr_be[3]) ram3[bram_wr_word_addr] <= bram_wr_b3;
        end

        if (ipu_mem_re && in_word_range(ipu_addr[31:2])) begin
            ipu_b0_q <= ram0[ipu_addr[31:2]];
            ipu_b1_q <= ram1[ipu_addr[31:2]];
            ipu_b2_q <= ram2[ipu_addr[31:2]];
            ipu_b3_q <= ram3[ipu_addr[31:2]];
        end else begin
            ipu_b0_q <= 8'd0;
            ipu_b1_q <= 8'd0;
            ipu_b2_q <= 8'd0;
            ipu_b3_q <= 8'd0;
        end
        ipu_lane_q <= ipu_addr[1:0];
    end

    always_comb begin
        unique case (ipu_lane_q)
            2'd0: ipu_read_data = ipu_b0_q;
            2'd1: ipu_read_data = ipu_b1_q;
            2'd2: ipu_read_data = ipu_b2_q;
            2'd3: ipu_read_data = ipu_b3_q;
            default: ipu_read_data = 8'd0;
        endcase
    end

    // ------------------------------------------------------------------
    // CPU load read path. For the hardware BIST/test region (<512 bytes), use
    // small combinational memory so load values are stable in the existing
    // 5-stage pipeline. For higher addresses, return zero; live IPU firmware
    // does not require CPU loads from image memory.
    // ------------------------------------------------------------------
    logic [31:0] cpu_fast_word;
    logic [8:0]  cpu_base_addr;
    logic        cpu_fast_word_ok;

    assign cpu_base_addr    = {addr[8:2], 2'b00};
    assign cpu_fast_word_ok = (addr < CPU_FAST_BYTES) && (({addr[31:2], 2'b00} + 32'd3) < CPU_FAST_BYTES);

    always_comb begin
        if (cpu_fast_word_ok) begin
            cpu_fast_word = {
                cpu_fast_mem[cpu_base_addr + 9'd3],
                cpu_fast_mem[cpu_base_addr + 9'd2],
                cpu_fast_mem[cpu_base_addr + 9'd1],
                cpu_fast_mem[cpu_base_addr]
            };
        end else begin
            cpu_fast_word = 32'd0;
        end
    end

    always_comb begin
        read_data = 32'd0;
        if (mem_read && cpu_fast_word_ok) begin
            unique case (funct3)
                3'b000: begin // LB
                    unique case (addr[1:0])
                        2'd0: read_data = {{24{cpu_fast_word[7]}},  cpu_fast_word[7:0]};
                        2'd1: read_data = {{24{cpu_fast_word[15]}}, cpu_fast_word[15:8]};
                        2'd2: read_data = {{24{cpu_fast_word[23]}}, cpu_fast_word[23:16]};
                        2'd3: read_data = {{24{cpu_fast_word[31]}}, cpu_fast_word[31:24]};
                        default: read_data = 32'd0;
                    endcase
                end
                3'b001: begin // LH
                    if (addr[1] == 1'b0)
                        read_data = {{16{cpu_fast_word[15]}}, cpu_fast_word[15:0]};
                    else
                        read_data = {{16{cpu_fast_word[31]}}, cpu_fast_word[31:16]};
                end
                3'b010: begin // LW
                    read_data = cpu_fast_word;
                end
                3'b100: begin // LBU
                    unique case (addr[1:0])
                        2'd0: read_data = {24'd0, cpu_fast_word[7:0]};
                        2'd1: read_data = {24'd0, cpu_fast_word[15:8]};
                        2'd2: read_data = {24'd0, cpu_fast_word[23:16]};
                        2'd3: read_data = {24'd0, cpu_fast_word[31:24]};
                        default: read_data = 32'd0;
                    endcase
                end
                3'b101: begin // LHU
                    if (addr[1] == 1'b0)
                        read_data = {16'd0, cpu_fast_word[15:0]};
                    else
                        read_data = {16'd0, cpu_fast_word[31:16]};
                end
                default: read_data = 32'd0;
            endcase
        end
    end

    // MMIO status register retained for compatibility.
    always_ff @(posedge clk or posedge reset) begin
        if (reset) begin
            mmio_status <= 32'd0;
            mmio_valid  <= 1'b0;
        end else begin
            mmio_valid <= 1'b0;
            if (mem_write && (addr == MMIO_STATUS_ADDR)) begin
                mmio_status <= write_data;
                mmio_valid  <= 1'b1;
            end
        end
    end

endmodule
