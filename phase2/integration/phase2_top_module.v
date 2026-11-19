// phase2_top_module.v
// Phase II Integration - High-Bandwidth Tiled Systolic Matrix Accelerator Top Module
//
// Responsibilities:
//   - Integrates the Phase II burst host interface (burst_matrix_interface) with:
//       * Phase II multi-tile input buffer (tiled_input_buffer)
//       * Phase II matrix tiling controller (matrix_tiling_controller)
//       * Phase I single-tile systolic controller (systolic_controller)
//       * Phase I 3x3 physical processing element array (systolic_array)
//       * Phase II partial result storage and inter-tile accumulator (partial_result_buffer)
//   - Supports both single-tile 3x3 (1 tile operation) and multi-tile 6x6 (8 tile operations)
//     matrix multiplications with signed 8-bit operands and 32-bit accumulators.
//   - Exposes high-bandwidth streaming and packed burst write/read interfaces with
//     backpressure, error reporting, start synchronization, and result availability tracking.

`timescale 1ns / 1ps
`default_nettype none

module phase2_top_module #(
    parameter integer ARRAY_SIZE      = 3,
    parameter integer MAX_MATRIX_SIZE = 6,
    parameter integer DATA_WIDTH      = 8,
    parameter integer ACC_WIDTH       = 32,
    parameter integer WORDS_PER_BEAT  = 4,
    parameter integer BUS_DATA_WIDTH  = WORDS_PER_BEAT * DATA_WIDTH,
    parameter integer ADDR_WIDTH      = (MAX_MATRIX_SIZE * MAX_MATRIX_SIZE <= 1) ? 1 : $clog2(MAX_MATRIX_SIZE * MAX_MATRIX_SIZE),
    parameter integer BURST_LEN_WIDTH = $clog2(MAX_MATRIX_SIZE * MAX_MATRIX_SIZE + 1) + 1
) (
    input  wire                               clk,
    input  wire                               rst_n,

    // Runtime Matrix Dimension Configuration (3 for 3x3, 6 for 6x6)
    input  wire [3:0]                         cfg_matrix_dim,

    // -------------------------------------------------------------
    // High-Bandwidth Host Burst Write Interface
    // -------------------------------------------------------------
    input  wire                               burst_write_req,
    input  wire                               burst_write_is_b,
    input  wire [ADDR_WIDTH-1:0]              burst_write_addr,
    input  wire [BURST_LEN_WIDTH-1:0]         burst_write_len,
    input  wire                               burst_write_packed,
    input  wire                               burst_write_valid,
    output wire                               burst_write_ready,
    input  wire [BUS_DATA_WIDTH-1:0]          burst_write_data,
    output wire                               burst_write_ack,
    output wire                               burst_write_done,
    output wire                               burst_write_err,
    output wire [2:0]                         burst_err_code,

    // -------------------------------------------------------------
    // Host Accelerator Control & Status Interface
    // -------------------------------------------------------------
    input  wire                               host_start,
    output wire                               host_ready,
    output wire                               host_busy,
    output wire                               host_done,
    output wire                               start_ack,
    output wire                               start_err,
    output wire                               matrices_ready,
    output wire                               host_result_available,

    // -------------------------------------------------------------
    // High-Bandwidth Host Burst Result Readback Interface
    // -------------------------------------------------------------
    input  wire                               burst_read_req,
    input  wire [ADDR_WIDTH-1:0]              burst_read_addr,
    input  wire [BURST_LEN_WIDTH-1:0]         burst_read_len,
    input  wire                               burst_read_ready,
    output wire                               burst_read_valid,
    output wire signed [ACC_WIDTH-1:0]        burst_read_data,
    output wire                               burst_read_done,
    output wire                               burst_read_err
);

    localparam integer LOAD_IDX_W     = (ARRAY_SIZE <= 1) ? 1 : $clog2(ARRAY_SIZE);
    localparam integer COMPUTE_CYCLES = (3 * ARRAY_SIZE) - 2;
    localparam integer CYCLE_W        = (COMPUTE_CYCLES <= 1) ? 1 : $clog2(COMPUTE_CYCLES);

    // Active matrix dimension selection and validation
    wire       dim_unsupported   = (cfg_matrix_dim != 4'd3) && (cfg_matrix_dim != 4'd6);
    wire [3:0] active_matrix_dim = (cfg_matrix_dim == 4'd3) ? 4'd3 :
                                   (cfg_matrix_dim == 4'd6) ? 4'd6 : 4'd0;

    // Interconnect between burst_matrix_interface and input buffer
    wire                               buf_write_en;
    wire                               buf_write_is_b;
    wire [ADDR_WIDTH-1:0]              buf_write_addr;
    wire signed [DATA_WIDTH-1:0]       buf_write_data;
    wire                               buf_matrices_ready;

    // Interconnect between burst_matrix_interface and tiling controller
    wire                               ctrl_start;
    wire                               ctrl_idle;
    wire                               ctrl_busy;
    wire                               ctrl_done;

    // Interconnect between burst_matrix_interface and partial result buffer
    wire                               interface_out_buf_clear;
    wire                               res_read_en;
    wire [ADDR_WIDTH-1:0]              res_read_addr;
    wire signed [ACC_WIDTH-1:0]        res_read_data;
    wire                               res_read_valid;
    wire                               res_available;

    // Tiling controller to sub-controller signals
    wire                               sub_start;
    wire                               sub_idle;
    wire                               sub_busy;
    wire                               sub_done;
    wire                               sub_load_en;
    wire [LOAD_IDX_W-1:0]              sub_load_idx;
    wire                               sub_array_clear;
    wire                               sub_compute_en;
    wire [CYCLE_W-1:0]                 sub_cycle_count;
    wire                               sub_result_valid;

    // Tiling coordinates and partial buffer strobes
    wire [1:0]                         tile_i;
    wire [1:0]                         tile_j;
    wire [1:0]                         tile_k;
    wire                               accumulate_en;
    wire                               capture_en;
    wire                               all_tiles_done;
    wire                               tiling_out_buf_clear;
    wire [3:0]                         tile_count;

    // Systolic array boundary signals
    wire [(ARRAY_SIZE * DATA_WIDTH)-1:0]           a_west;
    wire [(ARRAY_SIZE * DATA_WIDTH)-1:0]           b_north;
    wire [(ARRAY_SIZE * ARRAY_SIZE * ACC_WIDTH)-1:0] acc_out;

    // 1. High-Bandwidth Host Burst Interface
    burst_matrix_interface #(
        .ARRAY_SIZE     (ARRAY_SIZE),
        .MAX_MATRIX_SIZE(MAX_MATRIX_SIZE),
        .DATA_WIDTH     (DATA_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .WORDS_PER_BEAT (WORDS_PER_BEAT),
        .BUS_DATA_WIDTH (BUS_DATA_WIDTH),
        .ADDR_WIDTH     (ADDR_WIDTH),
        .BURST_LEN_WIDTH(BURST_LEN_WIDTH)
    ) u_burst_interface (
        .clk                  (clk),
        .rst_n                (rst_n),
        .cfg_matrix_dim       (cfg_matrix_dim),
        .burst_write_req      (burst_write_req),
        .burst_write_is_b     (burst_write_is_b),
        .burst_write_addr     (burst_write_addr),
        .burst_write_len      (burst_write_len),
        .burst_write_packed   (burst_write_packed),
        .burst_write_valid    (burst_write_valid),
        .burst_write_ready    (burst_write_ready),
        .burst_write_data     (burst_write_data),
        .burst_write_ack      (burst_write_ack),
        .burst_write_done     (burst_write_done),
        .burst_write_err      (burst_write_err),
        .burst_err_code       (burst_err_code),
        .host_start           (host_start),
        .host_ready           (host_ready),
        .host_busy            (host_busy),
        .host_done            (host_done),
        .start_ack            (start_ack),
        .start_err            (start_err),
        .matrices_ready       (matrices_ready),
        .host_result_available(host_result_available),
        .burst_read_req       (burst_read_req),
        .burst_read_addr      (burst_read_addr),
        .burst_read_len       (burst_read_len),
        .burst_read_ready     (burst_read_ready),
        .burst_read_valid     (burst_read_valid),
        .burst_read_data      (burst_read_data),
        .burst_read_done      (burst_read_done),
        .burst_read_err       (burst_read_err),
        .curr_read_addr       (),
        .buf_write_en         (buf_write_en),
        .buf_write_is_b       (buf_write_is_b),
        .buf_write_addr       (buf_write_addr),
        .buf_write_data       (buf_write_data),
        .buf_matrices_ready   (buf_matrices_ready),
        .ctrl_start           (ctrl_start),
        .ctrl_idle            (ctrl_idle),
        .ctrl_busy            (ctrl_busy),
        .ctrl_done            (ctrl_done),
        .out_buf_clear        (interface_out_buf_clear),
        .res_read_en          (res_read_en),
        .res_read_addr        (res_read_addr),
        .res_read_data        (res_read_data),
        .res_read_valid       (res_read_valid),
        .res_available        (res_available)
    );

    // 2. Matrix Tiling Controller
    matrix_tiling_controller #(
        .ARRAY_SIZE    (ARRAY_SIZE),
        .MAX_MATRIX_DIM(MAX_MATRIX_SIZE)
    ) u_tiling_ctrl (
        .clk             (clk),
        .rst_n           (rst_n),
        .host_start      (ctrl_start),
        .matrices_ready  (buf_matrices_ready && !dim_unsupported),
        .matrix_dim      (active_matrix_dim),
        .host_ready      (ctrl_idle),
        .host_busy       (ctrl_busy),
        .host_done       (ctrl_done),
        .start_ack       (),
        .start_err       (),
        .out_buf_clear   (tiling_out_buf_clear),
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

    // 3. Multi-Tile Input Buffer
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
        .write_en      (buf_write_en),
        .write_is_b    (buf_write_is_b),
        .write_addr    (buf_write_addr),
        .write_data    (buf_write_data),
        .matrices_ready(buf_matrices_ready),
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

    // 4. Phase I Single-Tile Systolic Controller (reused unmodified from rtl/)
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

    // 5. Phase I Physical 3x3 Systolic Array (reused unmodified from rtl/)
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

    // 6. Partial Result Buffer & Inter-Tile Accumulator
    partial_result_buffer #(
        .ARRAY_SIZE    (ARRAY_SIZE),
        .MAX_MATRIX_DIM(MAX_MATRIX_SIZE),
        .ACC_WIDTH     (ACC_WIDTH),
        .ADDR_WIDTH    (ADDR_WIDTH)
    ) u_partial_buffer (
        .clk             (clk),
        .rst_n           (rst_n),
        .clear           (interface_out_buf_clear | tiling_out_buf_clear),
        .matrix_dim      (active_matrix_dim),
        .tile_i          (tile_i),
        .tile_j          (tile_j),
        .accumulate_en   (accumulate_en),
        .capture_en      (capture_en),
        .all_tiles_done  (all_tiles_done),
        .acc_in          (acc_out),
        .read_en         (res_read_en),
        .read_addr       (res_read_addr),
        .read_data       (res_read_data),
        .read_valid      (res_read_valid),
        .result_available(res_available)
    );

endmodule

`default_nettype wire

