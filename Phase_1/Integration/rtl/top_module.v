`timescale 1ns / 1ps
`default_nettype none

module top_module #(
    parameter integer ARRAY_SIZE = 3,
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH  = 32,
    parameter integer ADDR_WIDTH = (ARRAY_SIZE * ARRAY_SIZE <= 1) ? 1 : $clog2(ARRAY_SIZE * ARRAY_SIZE)
) (
    input wire                         clk,
    input wire                         rst_n,

    input wire                         host_start,
    output wire                        host_ready,
    output wire                        host_busy,
    output wire                        host_done,
    output wire                        start_ack,
    output wire                        start_err,

    input wire                         host_write_en,
    input wire                         host_write_is_b,
    input wire [ADDR_WIDTH-1:0]        host_write_addr,
    input wire signed [DATA_WIDTH-1:0] host_write_data,
    output wire                        host_write_ack,
    output wire                        matrices_ready,

    input wire                         host_read_en,
    input wire [ADDR_WIDTH-1:0]        host_read_addr,
    output wire signed [ACC_WIDTH-1:0] host_read_data,
    output wire                        host_read_valid,
    output wire                        host_result_available
);

    localparam integer LOAD_IDX_W = (ARRAY_SIZE <= 1) ? 1 : $clog2(ARRAY_SIZE);
    localparam integer COMPUTE_CYCLES = (3 * ARRAY_SIZE) - 2;
    localparam integer CYCLE_W = (COMPUTE_CYCLES <= 1) ? 1 : $clog2(COMPUTE_CYCLES);

    wire controller_idle;
    wire controller_busy;
    wire controller_done;
    wire controller_start;
    wire load_en;
    wire [LOAD_IDX_W-1:0] load_idx;
    wire array_clear;
    wire compute_en;
    wire [CYCLE_W-1:0] cycle_count;
    wire controller_result_valid;
    wire [1:0] controller_state;

    wire input_write_en;
    wire input_write_is_b;
    wire [ADDR_WIDTH-1:0] input_write_addr;
    wire signed [DATA_WIDTH-1:0] input_write_data;
    wire [(ARRAY_SIZE * DATA_WIDTH)-1:0] a_west;
    wire [(ARRAY_SIZE * DATA_WIDTH)-1:0] b_north;

    wire [(ARRAY_SIZE * ARRAY_SIZE * ACC_WIDTH)-1:0] acc_out;
    wire out_buf_clear;
    wire result_read_en;
    wire [ADDR_WIDTH-1:0] result_read_addr;
    wire signed [ACC_WIDTH-1:0] result_read_data;
    wire result_read_valid;
    wire result_available;

    matrix_interface #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_matrix_interface (
        .clk                 (clk),
        .rst_n               (rst_n),
        .host_start          (host_start),
        .host_ready          (host_ready),
        .host_busy           (host_busy),
        .host_done           (host_done),
        .start_ack           (start_ack),
        .start_err           (start_err),
        .start               (controller_start),
        .controller_idle     (controller_idle),
        .controller_busy     (controller_busy),
        .controller_done     (controller_done),
        .host_write_en       (host_write_en),
        .host_write_is_b     (host_write_is_b),
        .host_write_addr     (host_write_addr),
        .host_write_data     (host_write_data),
        .host_write_ack      (host_write_ack),
        .write_en            (input_write_en),
        .write_is_b          (input_write_is_b),
        .write_addr          (input_write_addr),
        .write_data          (input_write_data),
        .matrices_ready      (matrices_ready),
        .out_buf_clear       (out_buf_clear),
        .host_read_en        (host_read_en),
        .host_read_addr      (host_read_addr),
        .host_read_data      (host_read_data),
        .host_read_valid     (host_read_valid),
        .host_result_available(host_result_available),
        .read_en             (result_read_en),
        .read_addr           (result_read_addr),
        .result_read_data    (result_read_data),
        .result_read_valid   (result_read_valid),
        .result_available    (result_available)
    );

    input_buffer #(
        .ARRAY_SIZE    (ARRAY_SIZE),
        .DATA_WIDTH    (DATA_WIDTH),
        .LOAD_IDX_W    (LOAD_IDX_W),
        .COMPUTE_CYCLES(COMPUTE_CYCLES),
        .CYCLE_W       (CYCLE_W),
        .ADDR_WIDTH    (ADDR_WIDTH)
    ) u_input_buffer (
        .clk          (clk),
        .rst_n        (rst_n),
        .write_en     (input_write_en),
        .write_is_b   (input_write_is_b),
        .write_addr   (input_write_addr),
        .write_data   (input_write_data),
        .matrices_ready(matrices_ready),
        .load_en      (load_en),
        .load_idx     (load_idx),
        .compute_en   (compute_en),
        .cycle_count  (cycle_count),
        .a_west       (a_west),
        .b_north      (b_north)
    );

    systolic_controller #(
        .ARRAY_SIZE    (ARRAY_SIZE),
        .LOAD_CYCLES   (ARRAY_SIZE),
        .COMPUTE_CYCLES(COMPUTE_CYCLES),
        .LOAD_IDX_W    (LOAD_IDX_W),
        .CYCLE_W       (CYCLE_W)
    ) u_controller (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (controller_start),
        .idle        (controller_idle),
        .busy        (controller_busy),
        .done        (controller_done),
        .load_en     (load_en),
        .load_idx    (load_idx),
        .array_clear (array_clear),
        .compute_en  (compute_en),
        .cycle_count (cycle_count),
        .result_valid(controller_result_valid),
        .state       (controller_state)
    );

    systolic_array #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)
    ) u_array (
        .clk        (clk),
        .rst_n      (rst_n),
        .compute_en (compute_en),
        .array_clear(array_clear),
        .a_west     (a_west),
        .b_north    (b_north),
        .a_east     (),
        .b_south    (),
        .acc_out    (acc_out)
    );

    output_buffer #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .ACC_WIDTH (ACC_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_output_buffer (
        .clk             (clk),
        .rst_n           (rst_n),
        .result_valid    (controller_result_valid),
        .acc_in          (acc_out),
        .clear           (out_buf_clear),
        .read_en         (result_read_en),
        .read_addr       (result_read_addr),
        .read_data       (result_read_data),
        .read_valid      (result_read_valid),
        .result_available(result_available)
    );

endmodule

`default_nettype wire
