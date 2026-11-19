// sequential_gemm.v
// Phase II Baseline - Conventional Sequential Matrix Multiplication Engine
//
// Architecture:
//   - A genuinely sequential matrix multiplication baseline using a single MAC datapath.
//   - Computes: C[i][j] = \sum_{k=0}^{M-1} A[i][k] * B[k][j]
//   - Performs exactly 1 multiply-accumulate operation per clock cycle during compute.
//   - Zero parallel PEs, zero systolic interconnects, single MAC execution.
//   - FSM States:
//       * ST_IDLE (2'b00): Accepts matrix writes for A and B, validates cfg_matrix_dim.
//       * ST_COMP (2'b01): Iterates over (i, j, k) performing 1 MAC per cycle; asserts
//                          host_done pulse and transitions to ST_DONE on final compute edge.
//       * ST_DONE (2'b10): Single-cycle completion state; holds host_done, rejects writes,
//                          and returns to ST_IDLE on the subsequent clock edge.
//   - Supports 3x3 (M=3, 27 compute cycles) and 6x6 (M=6, 216 compute cycles).
//   - Arithmetic specification:
//       * 8-bit signed two's-complement matrix operands (DATA_WIDTH = 8).
//       * 16-bit signed multiplication product.
//       * 32-bit signed accumulation (ACC_WIDTH = 32).
//   - Active-low asynchronous reset (rst_n).
//   - Fully synthesizable, zero latches, clean handshakes matching Phase I/II top_module.

`timescale 1ns / 1ps
`default_nettype none

module sequential_gemm #(
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH  = 32,
    parameter integer MAX_DIM    = 6,
    parameter integer ADDR_WIDTH = (MAX_DIM * MAX_DIM <= 1) ? 1 : $clog2(MAX_DIM * MAX_DIM)
) (
    input  wire                         clk,
    input  wire                         rst_n,

    // Runtime matrix dimension configuration (3 for 3x3, 6 for 6x6)
    input  wire [3:0]                   cfg_matrix_dim,

    // Host control and status
    input  wire                         host_start,
    output wire                         host_ready,
    output reg                          host_busy,
    output reg                          host_done,
    output reg                          start_ack,
    output reg                          start_err,

    // Host matrix write interface
    input  wire                         host_write_en,
    input  wire                         host_write_is_b,
    input  wire [ADDR_WIDTH-1:0]        host_write_addr,
    input  wire signed [DATA_WIDTH-1:0] host_write_data,
    output wire                         host_write_ack,
    output wire                         matrices_ready,

    // Host result read interface
    input  wire                         host_read_en,
    input  wire [ADDR_WIDTH-1:0]        host_read_addr,
    output reg  signed [ACC_WIDTH-1:0]  host_read_data,
    output reg                          host_read_valid,
    output reg                          host_result_available
);

    localparam integer MAX_ELEMENTS = MAX_DIM * MAX_DIM; // 36

    // FSM State Encoding
    localparam [1:0] ST_IDLE = 2'b00;
    localparam [1:0] ST_COMP = 2'b01;
    localparam [1:0] ST_DONE = 2'b10;

    reg [1:0] state;

    // Dimension decoding and validation
    wire dim_supported = (cfg_matrix_dim == 4'd3) || (cfg_matrix_dim == 4'd6);
    wire [3:0] active_dim = (cfg_matrix_dim == 4'd3) ? 4'd3 :
                            (cfg_matrix_dim == 4'd6) ? 4'd6 : 4'd0;
    wire [ADDR_WIDTH:0] total_elements = active_dim * active_dim;

    // Storage memories
    reg signed [DATA_WIDTH-1:0] mem_a [0:MAX_ELEMENTS-1];
    reg signed [DATA_WIDTH-1:0] mem_b [0:MAX_ELEMENTS-1];
    reg signed [ACC_WIDTH-1:0]  mem_c [0:MAX_ELEMENTS-1];

    // Tracking flags for written elements
    reg [MAX_ELEMENTS-1:0] written_a;
    reg [MAX_ELEMENTS-1:0] written_b;

    reg [MAX_ELEMENTS-1:0] expected_mask;
    always @(*) begin
        if (cfg_matrix_dim == 4'd3)
            expected_mask = 36'h0000001ff; // 9 elements
        else if (cfg_matrix_dim == 4'd6)
            expected_mask = 36'hfffffffff; // 36 elements
        else
            expected_mask = 36'h000000000;
    end

    assign matrices_ready = dim_supported &&
                            ((written_a & expected_mask) == expected_mask) &&
                            ((written_b & expected_mask) == expected_mask);

    // Host write gating: reject writes if not in ST_IDLE, unsupported dim, or address out of range
    wire write_accepted = host_write_en && (state == ST_IDLE) && dim_supported && (host_write_addr < total_elements);
    assign host_write_ack = write_accepted;

    // Host status indications
    assign host_ready = (state == ST_IDLE) && matrices_ready;

    // Sequential loop counters
    reg [2:0] i_cnt;
    reg [2:0] j_cnt;
    reg [2:0] k_cnt;

    // Single MAC Datapath
    reg signed [ACC_WIDTH-1:0] acc_reg;

    wire [5:0] addr_a = (active_dim == 4'd3) ? (i_cnt * 3 + k_cnt) : (i_cnt * 6 + k_cnt);
    wire [5:0] addr_b = (active_dim == 4'd3) ? (k_cnt * 3 + j_cnt) : (k_cnt * 6 + j_cnt);
    wire [5:0] addr_c = (active_dim == 4'd3) ? (i_cnt * 3 + j_cnt) : (i_cnt * 6 + j_cnt);

    wire signed [DATA_WIDTH-1:0] a_op = mem_a[addr_a];
    wire signed [DATA_WIDTH-1:0] b_op = mem_b[addr_b];

    // 16-bit signed multiplication
    wire signed [(2*DATA_WIDTH)-1:0] mult_product = a_op * b_op;

    // Sign extension to ACC_WIDTH (32-bit)
    wire signed [ACC_WIDTH-1:0] ext_product = { {(ACC_WIDTH - (2*DATA_WIDTH)){mult_product[(2*DATA_WIDTH)-1]}}, mult_product };

    // Accumulation logic: on k=0, initialize with the first product; on k>0, accumulate
    wire signed [ACC_WIDTH-1:0] mac_result = (k_cnt == 3'd0) ? ext_product : (acc_reg + ext_product);

    integer idx_init;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                 <= ST_IDLE;
            host_busy             <= 1'b0;
            host_done             <= 1'b0;
            start_ack             <= 1'b0;
            start_err             <= 1'b0;
            host_result_available <= 1'b0;
            written_a             <= {MAX_ELEMENTS{1'b0}};
            written_b             <= {MAX_ELEMENTS{1'b0}};
            i_cnt                 <= 3'd0;
            j_cnt                 <= 3'd0;
            k_cnt                 <= 3'd0;
            acc_reg               <= {ACC_WIDTH{1'b0}};
            for (idx_init = 0; idx_init < MAX_ELEMENTS; idx_init = idx_init + 1) begin
                mem_a[idx_init] <= {DATA_WIDTH{1'b0}};
                mem_b[idx_init] <= {DATA_WIDTH{1'b0}};
                mem_c[idx_init] <= {ACC_WIDTH{1'b0}};
            end
        end else begin
            // Default pulse deassertions
            start_ack <= 1'b0;
            start_err <= 1'b0;
            host_done <= 1'b0;

            // Host memory writes (accepted only when write_accepted is high)
            if (write_accepted) begin
                if (!host_write_is_b) begin
                    mem_a[host_write_addr]     <= host_write_data;
                    written_a[host_write_addr] <= 1'b1;
                end else begin
                    mem_b[host_write_addr]     <= host_write_data;
                    written_b[host_write_addr] <= 1'b1;
                end
            end

            // Main FSM
            case (state)
                ST_IDLE: begin
                    host_busy <= 1'b0;
                    if (host_start) begin
                        if (!dim_supported || !matrices_ready) begin
                            start_err <= 1'b1;
                        end else begin
                            start_ack             <= 1'b1;
                            host_busy             <= 1'b1;
                            host_result_available <= 1'b0; // Invalidate previous result
                            i_cnt                 <= 3'd0;
                            j_cnt                 <= 3'd0;
                            k_cnt                 <= 3'd0;
                            acc_reg               <= {ACC_WIDTH{1'b0}};
                            state                 <= ST_COMP;
                        end
                    end
                end

                ST_COMP: begin
                    if (host_start) begin
                        // Reject new start while already busy
                        start_err <= 1'b1;
                    end

                    // Update accumulator register
                    acc_reg <= mac_result;

                    // If at the end of the k-reduction loop, write element to mem_c
                    if (k_cnt == active_dim - 1'b1) begin
                        mem_c[addr_c] <= mac_result;
                    end

                    // Advance nested loop indices (i, j, k)
                    if (k_cnt < active_dim - 1'b1) begin
                        k_cnt <= k_cnt + 1'b1;
                    end else begin
                        k_cnt <= 3'd0;
                        if (j_cnt < active_dim - 1'b1) begin
                            j_cnt <= j_cnt + 1'b1;
                        end else begin
                            j_cnt <= 3'd0;
                            if (i_cnt < active_dim - 1'b1) begin
                                i_cnt <= i_cnt + 1'b1;
                            end else begin
                                // All M^3 MAC operations complete!
                                state                 <= ST_DONE;
                                host_done             <= 1'b1;
                                host_busy             <= 1'b0;
                                host_result_available <= 1'b1;
                            end
                        end
                    end
                end

                ST_DONE: begin
                    if (host_start) begin
                        start_err <= 1'b1;
                    end
                    state <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

    // Synchronous result readback
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            host_read_data  <= {ACC_WIDTH{1'b0}};
            host_read_valid <= 1'b0;
        end else begin
            if (host_read_en && host_result_available && (host_read_addr < total_elements)) begin
                host_read_data  <= mem_c[host_read_addr];
                host_read_valid <= 1'b1;
            end else begin
                host_read_data  <= {ACC_WIDTH{1'b0}};
                host_read_valid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
