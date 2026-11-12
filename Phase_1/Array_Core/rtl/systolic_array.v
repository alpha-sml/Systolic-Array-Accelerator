// systolic_array
// Parameterized 2D output-stationary systolic array accelerator core.
// Default configuration: 3 x 3 array (9 PEs), 8-bit signed operands,
// 32-bit signed accumulators.
//
// Architecture
//   - Instantiates ARRAY_SIZE x ARRAY_SIZE instances of processing_element.
//   - Instantiates pe_interconnect to route west/north boundary operands and
//     neighbor-to-neighbor registered links (A eastwards, B southwards).
//   - Broadcasts common clk, rst_n (active-low async reset), compute_en, and
//     array_clear (synchronous clear with priority over compute_en) to all PEs.
//
// Controller Timing Contract (N = ARRAY_SIZE)
//   - LOAD phase: N cycles; array_clear is asserted on the final LOAD beat
//     to clear all PE accumulators before COMPUTE begins.
//   - COMPUTE phase: 3N - 2 cycles with compute_en = 1 and array_clear = 0.
//     A[i][k] and B[k][j] meet at PE(i, j) on compute cycle i + j + k.
//   - DONE phase: compute_en = 0; all PE accumulators hold C = A x B.
//
// Packed-Vector Indexing Convention (0-indexed row i, column j):
//   - a_west [(i * DATA_WIDTH) +: DATA_WIDTH]                     : A input for row i
//   - b_north[(j * DATA_WIDTH) +: DATA_WIDTH]                     : B input for column j
//   - a_east [(i * DATA_WIDTH) +: DATA_WIDTH]                     : Final eastward A output for row i
//   - b_south[(j * DATA_WIDTH) +: DATA_WIDTH]                     : Final southward B output for column j
//   - acc_out[((i * ARRAY_SIZE + j) * ACC_WIDTH) +: ACC_WIDTH]    : Accumulator output of PE(i, j)

`timescale 1ns / 1ps
`default_nettype none

module systolic_array #(
    parameter integer ARRAY_SIZE = 3,
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH  = 32
) (
    input  wire                                         clk,
    input  wire                                         rst_n,
    input  wire                                         compute_en,
    input  wire                                         array_clear,
    input  wire [(ARRAY_SIZE*DATA_WIDTH)-1:0]           a_west,
    input  wire [(ARRAY_SIZE*DATA_WIDTH)-1:0]           b_north,
    output wire [(ARRAY_SIZE*DATA_WIDTH)-1:0]           a_east,
    output wire [(ARRAY_SIZE*DATA_WIDTH)-1:0]           b_south,
    output wire [(ARRAY_SIZE*ARRAY_SIZE*ACC_WIDTH)-1:0] acc_out
);

    wire [(ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH)-1:0] pe_a_in;
    wire [(ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH)-1:0] pe_b_in;
    wire [(ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH)-1:0] pe_a_out;
    wire [(ARRAY_SIZE*ARRAY_SIZE*DATA_WIDTH)-1:0] pe_b_out;

    pe_interconnect #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH)
    ) u_interconnect (
        .a_west  (a_west),
        .b_north (b_north),
        .pe_a_out(pe_a_out),
        .pe_b_out(pe_b_out),
        .pe_a_in (pe_a_in),
        .pe_b_in (pe_b_in),
        .a_east  (a_east),
        .b_south (b_south)
    );

    genvar i;
    genvar j;

    generate
        for (i = 0; i < ARRAY_SIZE; i = i + 1) begin : gen_row
            for (j = 0; j < ARRAY_SIZE; j = j + 1) begin : gen_col
                // Signed local wires match the processing_element port contract.
                wire signed [DATA_WIDTH-1:0] local_a_in;
                wire signed [DATA_WIDTH-1:0] local_b_in;
                wire signed [DATA_WIDTH-1:0] local_a_out;
                wire signed [DATA_WIDTH-1:0] local_b_out;
                wire signed [ACC_WIDTH-1:0]  local_acc_out;

                assign local_a_in = pe_a_in[(((i * ARRAY_SIZE) + j) * DATA_WIDTH) +: DATA_WIDTH];
                assign local_b_in = pe_b_in[(((i * ARRAY_SIZE) + j) * DATA_WIDTH) +: DATA_WIDTH];

                assign pe_a_out[(((i * ARRAY_SIZE) + j) * DATA_WIDTH) +: DATA_WIDTH] = local_a_out;
                assign pe_b_out[(((i * ARRAY_SIZE) + j) * DATA_WIDTH) +: DATA_WIDTH] = local_b_out;
                assign acc_out[(((i * ARRAY_SIZE) + j) * ACC_WIDTH) +: ACC_WIDTH]    = local_acc_out;

                processing_element #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACC_WIDTH (ACC_WIDTH)
                ) u_pe (
                    .clk        (clk),
                    .rst_n      (rst_n),
                    .compute_en (compute_en),
                    .array_clear(array_clear),
                    .a_in       (local_a_in),
                    .b_in       (local_b_in),
                    .a_out      (local_a_out),
                    .b_out      (local_b_out),
                    .acc_out    (local_acc_out)
                );
            end
        end
    endgenerate

endmodule

`default_nettype wire
