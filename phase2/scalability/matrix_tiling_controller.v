// matrix_tiling_controller.v
// Phase II Scalability - Tiling Controller for Systolic Array GEMM
//
// Responsibilities:
//   - Sequence operand tiles (A_ik, B_kj) across (M/N)^3 tile operations.
//   - Synchronize with host start requests (validating matrices_ready, rejecting if busy/incomplete).
//   - Trigger sub-controller (Phase I systolic_controller) per tile via a 1-cycle start pulse.
//   - Control partial-result capture and inter-tile accumulation:
//       * accumulate_en = 0 on k = 0 (first reduction step: overwrite/initialize tile).
//       * accumulate_en = 1 on k > 0 (subsequent reduction steps: accumulate partial result).
//   - Ensure previous tile results are captured in partial_result_buffer before initiating next tile.
//   - Signal overall matrix multiplication completion (host_done, all_tiles_done).
//   - Active-low asynchronous reset rst_n cleanly returns FSM to IDLE.

`timescale 1ns / 1ps
`default_nettype none

module matrix_tiling_controller #(
    parameter integer ARRAY_SIZE     = 3,
    parameter integer MAX_MATRIX_DIM = 6
) (
    input  wire       clk,
    input  wire       rst_n,

    // Host operation request and status
    input  wire       host_start,
    input  wire       matrices_ready,
    input  wire [3:0] matrix_dim,       // Configured dimension (3 for 3x3, 6 for 6x6)

    output wire       host_ready,
    output wire       host_busy,
    output reg        host_done,
    output reg        start_ack,
    output reg        start_err,

    // Output buffer clear / initialization
    output reg        out_buf_clear,

    // Sub-controller (systolic_controller) interface
    output reg        sub_start,
    input  wire       sub_idle,
    input  wire       sub_done,
    input  wire       sub_result_valid,

    // Tile coordinate and accumulation controls
    output reg  [1:0] tile_i,           // Row tile index of C and A (0 .. K-1)
    output reg  [1:0] tile_j,           // Col tile index of C and B (0 .. K-1)
    output reg  [1:0] tile_k,           // Reduction tile index (0 .. K-1)
    output wire       accumulate_en,    // 0 when tile_k == 0, 1 when tile_k > 0
    output reg        capture_en,       // Strobe to capture/accumulate into buffer
    output reg        all_tiles_done,
    output reg  [3:0] tile_count,       // Count of completed tile operations
    output wire [2:0] state_out
);

    // State encoding
    localparam [2:0]
        ST_IDLE         = 3'b000,
        ST_TILE_START   = 3'b001,
        ST_TILE_EXEC    = 3'b010,
        ST_TILE_CAPTURE = 3'b011,
        ST_TILE_NEXT    = 3'b100,
        ST_DONE         = 3'b101;

    reg [2:0] state;
    assign state_out = state;

    // Host start edge detection and reset lockout (preserves Phase I semantics)
    reg host_start_q;
    reg reset_lock;
    wire host_start_pulse = host_start & ~host_start_q & ~reset_lock;

    // Number of tiles per dimension K = matrix_dim / ARRAY_SIZE
    // If matrix_dim <= 3, K = 1. If matrix_dim == 6, K = 2.
    wire [1:0] k_dim_max = (matrix_dim <= ARRAY_SIZE) ? 2'd1 : 2'd2;

    // accumulate_en is asserted for k > 0
    assign accumulate_en = (tile_k != 2'b00);

    // Status signals
    assign host_ready = (state == ST_IDLE) && matrices_ready;
    assign host_busy  = (state != ST_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= ST_IDLE;
            host_start_q   <= 1'b0;
            reset_lock     <= 1'b1;
            host_done      <= 1'b0;
            start_ack      <= 1'b0;
            start_err      <= 1'b0;
            out_buf_clear  <= 1'b0;
            sub_start      <= 1'b0;
            capture_en     <= 1'b0;
            all_tiles_done <= 1'b0;
            tile_i         <= 2'b00;
            tile_j         <= 2'b00;
            tile_k         <= 2'b00;
            tile_count     <= 4'd0;
        end else begin
            host_start_q   <= host_start;
            reset_lock     <= 1'b0;
            host_done      <= 1'b0;
            start_ack      <= 1'b0;
            start_err      <= 1'b0;
            out_buf_clear  <= 1'b0;
            sub_start      <= 1'b0;
            capture_en     <= 1'b0;
            all_tiles_done <= 1'b0;

            case (state)
                ST_IDLE: begin
                    if (host_start_pulse) begin
                        tile_i     <= 2'b00;
                        tile_j     <= 2'b00;
                        tile_k     <= 2'b00;
                        tile_count <= 4'd0;
                        if (matrices_ready) begin
                            start_ack     <= 1'b1;
                            out_buf_clear <= 1'b1;
                            state         <= ST_TILE_START;
                        end else begin
                            start_err     <= 1'b1;
                        end
                    end
                end

                ST_TILE_START: begin
                    // Trigger sub-controller for tile (tile_i, tile_k) x (tile_k, tile_j)
                    sub_start <= 1'b1;
                    state     <= ST_TILE_EXEC;
                end

                ST_TILE_EXEC: begin
                    sub_start <= 1'b0;
                    // Wait for sub-controller completion pulse
                    if (sub_done || sub_result_valid) begin
                        capture_en <= 1'b1; // Strobe partial result buffer
                        state      <= ST_TILE_CAPTURE;
                    end
                end

                ST_TILE_CAPTURE: begin
                    // One cycle to ensure capture into partial_result_buffer has completed
                    capture_en <= 1'b0;
                    tile_count <= tile_count + 1'b1;
                    state      <= ST_TILE_NEXT;
                end

                ST_TILE_NEXT: begin
                    // Advance tile coordinates in row-major order: k inner, j middle, i outer
                    if (tile_k + 1'b1 < k_dim_max) begin
                        tile_k <= tile_k + 1'b1;
                        state  <= ST_TILE_START;
                    end else begin
                        tile_k <= 2'b00;
                        if (tile_j + 1'b1 < k_dim_max) begin
                            tile_j <= tile_j + 1'b1;
                            state  <= ST_TILE_START;
                        end else begin
                            tile_j <= 2'b00;
                            if (tile_i + 1'b1 < k_dim_max) begin
                                tile_i <= tile_i + 1'b1;
                                state  <= ST_TILE_START;
                            end else begin
                                // All tiles complete
                                state <= ST_DONE;
                            end
                        end
                    end
                end

                ST_DONE: begin
                    host_done      <= 1'b1;
                    all_tiles_done <= 1'b1;
                    state          <= ST_IDLE;
                end

                default: begin
                    state <= ST_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
