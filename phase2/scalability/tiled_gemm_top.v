// tiled_gemm_top.v
// Phase II Scalability - Top-Level Tiled Matrix Multiplication Accelerator
//
// Responsibilities:
//   - Integrates the Phase I 3x3 physical systolic array (systolic_array) and single-tile
//     controller (systolic_controller) with Phase II scalability modules:
//       * matrix_tiling_controller: coordinates tile scheduling across (M/N)^3 operations
//       * tiled_input_buffer: stores matrices A & B and drives skewed tile operands
//       * partial_result_buffer: accumulates and stores partial/final result matrix C
//   - Supports 6x6 tiled matrix multiplication (8 tile operations on 3x3 array)
//     and 3x3 single-tile multiplication (1 tile operation) via cfg_matrix_dim.
//   - Exposes standard host interface identical to Phase I top_module.

`timescale 1ns / 1ps
`default_nettype none

module tiled_gemm_top #(
    parameter integer ARRAY_SIZE      = 3,
    parameter integer MAX_MATRIX_SIZE = 6,
    parameter integer DATA_WIDTH      = 8,
    parameter integer ACC_WIDTH       = 32,
    parameter integer ADDR_WIDTH      = (MAX_MATRIX_SIZE * MAX_MATRIX_SIZE <= 1) ? 1 : $clog2(MAX_MATRIX_SIZE * MAX_MATRIX_SIZE)
) (
    input  wire                         clk,
    input  wire                         rst_n,

    // Runtime matrix dimension configuration (3 for 3x3, 6 for 6x6)
    input  wire [3:0]                   cfg_matrix_dim,

    // Host control and status
    input  wire                         host_start,
    output wire                         host_ready,
    output wire                         host_busy,
    output wire                         host_done,
    output wire                         start_ack,
    output wire                         start_err,

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
    output wire signed [ACC_WIDTH-1:0]  host_read_data,
    output wire                         host_read_valid,
    output wire                         host_result_available
);

    localparam integer LOAD_IDX_W     = (ARRAY_SIZE <= 1) ? 1 : $clog2(ARRAY_SIZE);
    localparam integer COMPUTE_CYCLES = (3 * ARRAY_SIZE) - 2;
    localparam integer CYCLE_W        = (COMPUTE_CYCLES <= 1) ? 1 : $clog2(COMPUTE_CYCLES);

    // Active matrix dimension selection.
    // Only 3 (3x3 single-tile) and 6 (6x6 four-tile) are supported.
    // Any other value is treated as an unsupported configuration:
    //   - active_matrix_dim is forced to 4'd0 to prevent spurious writes.
    //   - dim_unsupported is used to block start_ack and assert start_err.
    wire       dim_unsupported   = (cfg_matrix_dim != 4'd3) && (cfg_matrix_dim != 4'd6);
    wire [3:0] active_matrix_dim = (cfg_matrix_dim == 4'd3) ? 4'd3 :
                                   (cfg_matrix_dim == 4'd6) ? 4'd6 : 4'd0;
    wire [ADDR_WIDTH:0] total_elements = active_matrix_dim * active_matrix_dim;

    // Sub-controller signals
    wire                      sub_start;
    wire                      sub_idle;
    wire                      sub_busy;
    wire                      sub_done;
    wire                      sub_load_en;
    wire [LOAD_IDX_W-1:0]     sub_load_idx;
    wire                      sub_array_clear;
    wire                      sub_compute_en;
    wire [CYCLE_W-1:0]        sub_cycle_count;
    wire                      sub_result_valid;

    // Tiling controller coordinates and strobes
    wire [1:0]                tile_i;
    wire [1:0]                tile_j;
    wire [1:0]                tile_k;
    wire                      accumulate_en;
    wire                      capture_en;
    wire                      all_tiles_done;
    wire                      out_buf_clear;
    wire [3:0]                tile_count;

    // Systolic array boundary inputs and outputs
    wire [(ARRAY_SIZE * DATA_WIDTH)-1:0]           a_west;
    wire [(ARRAY_SIZE * DATA_WIDTH)-1:0]           b_north;
    wire [(ARRAY_SIZE * ARRAY_SIZE * ACC_WIDTH)-1:0] acc_out;

    // Host write gating: accept only when tiling controller is not busy,
    // the dimension is supported, and the address is in range.
    wire write_accepted = host_write_en && (!host_busy) && (!dim_unsupported) &&
                          (host_write_addr < total_elements);
    assign host_write_ack = write_accepted;

    // Unsupported-dimension interlock: mask matrices_ready so the sub-module
    // start-rejection path naturally emits start_err for unsupported dimensions.

    // 1. Matrix Tiling Controller
    // matrices_ready is AND-gated with !dim_unsupported so the controller's
    // start-rejection path naturally emits start_err for unsupported dimensions.
    matrix_tiling_controller #(
        .ARRAY_SIZE    (ARRAY_SIZE),
        .MAX_MATRIX_DIM(MAX_MATRIX_SIZE)
    ) u_tiling_ctrl (
        .clk             (clk),
        .rst_n           (rst_n),
        .host_start      (host_start),
        .matrices_ready  (matrices_ready && !dim_unsupported),
        .matrix_dim      (active_matrix_dim),
        .host_ready      (host_ready),
        .host_busy       (host_busy),
        .host_done       (host_done),
        .start_ack       (start_ack),
        .start_err       (start_err),
        .out_buf_clear   (out_buf_clear),
        .sub_start       (sub_start),
        .sub_idle        (sub_idle),
        .sub_done        (sub_done),
        .sub_result_valid(sub_result_valid),
        .tile_i          (tile_i),
        .tile_j          (tile_j),
        .tile_k          (tile_k),
        .accumulate_en   (accumulate_en),
        .capture_en      (capture_en),
        .all_tiles_done  (all_tiles_done),
        .tile_count      (tile_count),
        .state_out       ()
    );

    // 2. Tiled Matrix Input Buffer
    tiled_input_buffer #(
        .ARRAY_SIZE    (ARRAY_SIZE),
        .MAX_MATRIX_DIM(MAX_MATRIX_SIZE),
        .DATA_WIDTH    (DATA_WIDTH),
        .LOAD_IDX_W    (LOAD_IDX_W),
        .COMPUTE_CYCLES(COMPUTE_CYCLES),
        .CYCLE_W       (CYCLE_W),
        .ADDR_WIDTH    (ADDR_WIDTH)
    ) u_input_buffer (
        .clk           (clk),
        .rst_n         (rst_n),
        .matrix_dim    (active_matrix_dim),
        .write_en      (write_accepted),
        .write_is_b    (host_write_is_b),
        .write_addr    (host_write_addr),
        .write_data    (host_write_data),
        .matrices_ready(matrices_ready),
        .tile_i        (tile_i),
        .tile_j        (tile_j),
        .tile_k        (tile_k),
        .load_en       (sub_load_en),
        .load_idx      (sub_load_idx),
        .compute_en    (sub_compute_en),
        .cycle_count   (sub_cycle_count),
        .a_west        (a_west),
        .b_north       (b_north)
    );

    // 3. Phase I Single-Tile Systolic Controller (reused unmodified from rtl/)
    systolic_controller #(
        .ARRAY_SIZE    (ARRAY_SIZE),
        .LOAD_CYCLES   (ARRAY_SIZE),
        .COMPUTE_CYCLES(COMPUTE_CYCLES),
        .LOAD_IDX_W    (LOAD_IDX_W),
        .CYCLE_W       (CYCLE_W)
    ) u_tile_controller (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (sub_start),
        .idle        (sub_idle),
        .busy        (sub_busy),
        .done        (sub_done),
        .load_en     (sub_load_en),
        .load_idx    (sub_load_idx),
        .array_clear (sub_array_clear),
        .compute_en  (sub_compute_en),
        .cycle_count (sub_cycle_count),
        .result_valid(sub_result_valid),
        .state       ()
    );

    // 4. Phase I Physical 3x3 Systolic Array (reused unmodified from rtl/)
    systolic_array #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)
    ) u_array (
        .clk        (clk),
        .rst_n      (rst_n),
        .compute_en (sub_compute_en),
        .array_clear(sub_array_clear),
        .a_west     (a_west),
        .b_north    (b_north),
        .a_east     (),
        .b_south    (),
        .acc_out    (acc_out)
    );

    // 5. Partial Result Buffer & Inter-Tile Accumulator
    partial_result_buffer #(
        .ARRAY_SIZE    (ARRAY_SIZE),
        .MAX_MATRIX_DIM(MAX_MATRIX_SIZE),
        .ACC_WIDTH     (ACC_WIDTH),
        .ADDR_WIDTH    (ADDR_WIDTH)
    ) u_partial_buffer (
        .clk             (clk),
        .rst_n           (rst_n),
        .clear           (out_buf_clear),
        .matrix_dim      (active_matrix_dim),
        .tile_i          (tile_i),
        .tile_j          (tile_j),
        .accumulate_en   (accumulate_en),
        .capture_en      (capture_en),
        .all_tiles_done  (all_tiles_done),
        .acc_in          (acc_out),
        .read_en         (host_read_en),
        .read_addr       (host_read_addr),
        .read_data       (host_read_data),
        .read_valid      (host_read_valid),
        .result_available(host_result_available)
    );

endmodule

`default_nettype wire
