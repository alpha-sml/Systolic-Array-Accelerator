// input_buffer.v
// Data Management subsystem - Matrix Input Buffer & Operand Skewing
//
// Responsibilities:
//   - Accept and store Matrix A and Matrix B (N x N signed elements each).
//   - Support individual element host writes using row-major linear addressing:
//       address = row * ARRAY_SIZE + col
//   - Track written matrix elements and assert matrices_ready only when all
//     2 * (ARRAY_SIZE * ARRAY_SIZE) elements across A and B have been written.
//   - Stage matrix rows (A) and columns (B) during the controller's LOAD phase.
//   - Generate correctly skewed boundary operand streams (a_west, b_north)
//     during the controller's COMPUTE phase.
//   - Drive zero operands when compute_en is low or outside the valid skew window.

`timescale 1ns / 1ps
`default_nettype none

module input_buffer #(
    parameter integer ARRAY_SIZE     = 3,
    parameter integer DATA_WIDTH     = 8,
    parameter integer LOAD_IDX_W     = (ARRAY_SIZE <= 1) ? 1 : $clog2(ARRAY_SIZE),
    parameter integer COMPUTE_CYCLES = (3 * ARRAY_SIZE) - 2,
    parameter integer CYCLE_W        = (COMPUTE_CYCLES <= 1) ? 1 : $clog2(COMPUTE_CYCLES),
    parameter integer ADDR_WIDTH     = (ARRAY_SIZE * ARRAY_SIZE <= 1) ? 1 : $clog2(ARRAY_SIZE * ARRAY_SIZE)
) (
    input  wire                               clk,
    input  wire                               rst_n,

    // Host / matrix_interface write interface
    input  wire                               write_en,
    input  wire                               write_is_b,
    input  wire [ADDR_WIDTH-1:0]              write_addr,
    input  wire signed [DATA_WIDTH-1:0]       write_data,

    // Status: asserted only when all elements of both A and B have been written
    output wire                               matrices_ready,

    // Controller LOAD phase interface
    input  wire                               load_en,
    input  wire [LOAD_IDX_W-1:0]              load_idx,

    // Controller COMPUTE phase interface
    input  wire                               compute_en,
    input  wire [CYCLE_W-1:0]                 cycle_count,

    // Systolic array boundary inputs (packed vectors)
    output wire [(ARRAY_SIZE*DATA_WIDTH)-1:0] a_west,
    output wire [(ARRAY_SIZE*DATA_WIDTH)-1:0] b_north
);

    localparam integer NUM_ELEMENTS = ARRAY_SIZE * ARRAY_SIZE;

    // Matrix storage: row-major storage for matrices A and B
    reg signed [DATA_WIDTH-1:0] mem_a [0:NUM_ELEMENTS-1];
    reg signed [DATA_WIDTH-1:0] mem_b [0:NUM_ELEMENTS-1];

    // Tracking flags: 1 bit per element
    reg [NUM_ELEMENTS-1:0] written_a;
    reg [NUM_ELEMENTS-1:0] written_b;

    // Staging registers loaded during LOAD phase (packed vectors avoid array-sensitivity warnings)
    reg [(NUM_ELEMENTS*DATA_WIDTH)-1:0] staged_a;
    reg [(NUM_ELEMENTS*DATA_WIDTH)-1:0] staged_b;

    // Ready indication when all elements of both matrices are written
    assign matrices_ready = (&written_a) & (&written_b);

    // Synchronous write and staging logic
    integer init_m;
    integer load_col, load_row;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            written_a <= {NUM_ELEMENTS{1'b0}};
            written_b <= {NUM_ELEMENTS{1'b0}};
            for (init_m = 0; init_m < NUM_ELEMENTS; init_m = init_m + 1) begin
                mem_a[init_m] <= {DATA_WIDTH{1'b0}};
                mem_b[init_m] <= {DATA_WIDTH{1'b0}};
            end
            staged_a <= {(NUM_ELEMENTS*DATA_WIDTH){1'b0}};
            staged_b <= {(NUM_ELEMENTS*DATA_WIDTH){1'b0}};
        end else begin
            // Host matrix writes (accepted when write_en is high and address within range)
            if (write_en && (write_addr < NUM_ELEMENTS)) begin
                if (!write_is_b) begin
                    mem_a[write_addr]     <= write_data;
                    written_a[write_addr] <= 1'b1;
                end else begin
                    mem_b[write_addr]     <= write_data;
                    written_b[write_addr] <= 1'b1;
                end
            end

            // LOAD phase: beat k transfers row k of A and col k of B to staging registers
            if (load_en && (load_idx < ARRAY_SIZE)) begin
                for (load_col = 0; load_col < ARRAY_SIZE; load_col = load_col + 1) begin
                    staged_a[(((load_idx * ARRAY_SIZE) + load_col) * DATA_WIDTH) +: DATA_WIDTH] <=
                        mem_a[(load_idx * ARRAY_SIZE) + load_col];
                end
                for (load_row = 0; load_row < ARRAY_SIZE; load_row = load_row + 1) begin
                    staged_b[(((load_row * ARRAY_SIZE) + load_idx) * DATA_WIDTH) +: DATA_WIDTH] <=
                        mem_b[(load_row * ARRAY_SIZE) + load_idx];
                end
            end
        end
    end

    // COMPUTE phase: operand skewing combinational generation
    reg [(ARRAY_SIZE*DATA_WIDTH)-1:0] a_west_comb;
    reg [(ARRAY_SIZE*DATA_WIDTH)-1:0] b_north_comb;

    assign a_west  = a_west_comb;
    assign b_north = b_north_comb;

    integer row_i, col_j;
    integer k_a, k_b;

    always @(*) begin
        a_west_comb  = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
        b_north_comb = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};

        if (compute_en) begin
            // For row i: a_west[i] = A[i][k] where k = cycle_count - i (0 <= k < ARRAY_SIZE)
            for (row_i = 0; row_i < ARRAY_SIZE; row_i = row_i + 1) begin
                k_a = $signed({1'b0, cycle_count}) - row_i;
                if ((k_a >= 0) && (k_a < ARRAY_SIZE)) begin
                    a_west_comb[(row_i * DATA_WIDTH) +: DATA_WIDTH] =
                        staged_a[(((row_i * ARRAY_SIZE) + k_a) * DATA_WIDTH) +: DATA_WIDTH];
                end
            end

            // For column j: b_north[j] = B[k][j] where k = cycle_count - j (0 <= k < ARRAY_SIZE)
            for (col_j = 0; col_j < ARRAY_SIZE; col_j = col_j + 1) begin
                k_b = $signed({1'b0, cycle_count}) - col_j;
                if ((k_b >= 0) && (k_b < ARRAY_SIZE)) begin
                    b_north_comb[(col_j * DATA_WIDTH) +: DATA_WIDTH] =
                        staged_b[((((k_b * ARRAY_SIZE) + col_j)) * DATA_WIDTH) +: DATA_WIDTH];
                end
            end
        end
    end

endmodule

`default_nettype wire
