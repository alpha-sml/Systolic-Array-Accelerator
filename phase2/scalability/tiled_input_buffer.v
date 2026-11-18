// tiled_input_buffer.v
// Phase II Scalability - Matrix Input Buffer & Tiled Operand Skewing
//
// Responsibilities:
//   - Accept and store Matrix A and Matrix B elements up to MAX_MATRIX_DIM x MAX_MATRIX_DIM.
//   - Support individual element host writes using row-major linear addressing:
//       address = row * matrix_dim + col
//   - Track written matrix elements and assert matrices_ready when all elements
//     for the configured matrix dimension (3x3 or 6x6) have been loaded.
//   - During systolic array LOAD phase, stage the active tile operands:
//       * Row load_idx of tile A(tile_i, tile_k)
//       * Col load_idx of tile B(tile_k, tile_j)
//   - During systolic array COMPUTE phase, generate skewed boundary streams (a_west, b_north)
//     identical to Phase I array timing.

`timescale 1ns / 1ps
`default_nettype none

module tiled_input_buffer #(
    parameter integer ARRAY_SIZE     = 3,
    parameter integer MAX_MATRIX_DIM = 6,
    parameter integer DATA_WIDTH     = 8,
    parameter integer LOAD_IDX_W     = (ARRAY_SIZE <= 1) ? 1 : $clog2(ARRAY_SIZE),
    parameter integer COMPUTE_CYCLES = (3 * ARRAY_SIZE) - 2,
    parameter integer CYCLE_W        = (COMPUTE_CYCLES <= 1) ? 1 : $clog2(COMPUTE_CYCLES),
    parameter integer ADDR_WIDTH     = (MAX_MATRIX_DIM * MAX_MATRIX_DIM <= 1) ? 1 : $clog2(MAX_MATRIX_DIM * MAX_MATRIX_DIM)
) (
    input  wire                               clk,
    input  wire                               rst_n,

    // Configured matrix dimension (3 for 3x3, 6 for 6x6)
    input  wire [3:0]                         matrix_dim,

    // Host write interface
    input  wire                               write_en,
    input  wire                               write_is_b,
    input  wire [ADDR_WIDTH-1:0]              write_addr,
    input  wire signed [DATA_WIDTH-1:0]       write_data,

    // Readiness status
    output wire                               matrices_ready,

    // Tile selection context from tiling controller
    input  wire [1:0]                         tile_i,
    input  wire [1:0]                         tile_j,
    input  wire [1:0]                         tile_k,

    // Sub-controller LOAD phase interface
    input  wire                               load_en,
    input  wire [LOAD_IDX_W-1:0]              load_idx,

    // Sub-controller COMPUTE phase interface
    input  wire                               compute_en,
    input  wire [CYCLE_W-1:0]                 cycle_count,

    // Systolic array boundary inputs (packed vectors)
    output wire [(ARRAY_SIZE*DATA_WIDTH)-1:0] a_west,
    output wire [(ARRAY_SIZE*DATA_WIDTH)-1:0] b_north
);

    localparam integer MAX_ELEMENTS  = MAX_MATRIX_DIM * MAX_MATRIX_DIM;
    localparam integer TILE_ELEMENTS = ARRAY_SIZE * ARRAY_SIZE;

    // Matrix storage: row-major storage for full matrices A and B
    reg signed [DATA_WIDTH-1:0] mem_a [0:MAX_ELEMENTS-1];
    reg signed [DATA_WIDTH-1:0] mem_b [0:MAX_ELEMENTS-1];

    // Tracking flags: 1 bit per element
    reg [MAX_ELEMENTS-1:0] written_a;
    reg [MAX_ELEMENTS-1:0] written_b;

    // Staging registers for the active 3x3 tile operands
    reg [(TILE_ELEMENTS*DATA_WIDTH)-1:0] staged_a;
    reg [(TILE_ELEMENTS*DATA_WIDTH)-1:0] staged_b;

    // Readiness mask generation based on matrix_dim
    reg [MAX_ELEMENTS-1:0] expected_mask;
    always @(*) begin
        if (matrix_dim <= ARRAY_SIZE)
            expected_mask = { {(MAX_ELEMENTS - TILE_ELEMENTS){1'b0}}, {TILE_ELEMENTS{1'b1}} };
        else
            expected_mask = {MAX_ELEMENTS{1'b1}};
    end

    assign matrices_ready = ((written_a & expected_mask) == expected_mask) &&
                            ((written_b & expected_mask) == expected_mask);

    // Synchronous write and staging logic
    integer init_m;
    integer load_c, load_r;
    integer g_row_a, g_col_a, addr_a;
    integer g_row_b, g_col_b, addr_b;

    wire [ADDR_WIDTH:0] total_elements = matrix_dim * matrix_dim;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            written_a <= {MAX_ELEMENTS{1'b0}};
            written_b <= {MAX_ELEMENTS{1'b0}};
            for (init_m = 0; init_m < MAX_ELEMENTS; init_m = init_m + 1) begin
                mem_a[init_m] <= {DATA_WIDTH{1'b0}};
                mem_b[init_m] <= {DATA_WIDTH{1'b0}};
            end
            staged_a <= {(TILE_ELEMENTS*DATA_WIDTH){1'b0}};
            staged_b <= {(TILE_ELEMENTS*DATA_WIDTH){1'b0}};
        end else begin
            // Host matrix writes
            if (write_en && (write_addr < total_elements)) begin
                if (!write_is_b) begin
                    mem_a[write_addr]     <= write_data;
                    written_a[write_addr] <= 1'b1;
                end else begin
                    mem_b[write_addr]     <= write_data;
                    written_b[write_addr] <= 1'b1;
                end
            end

            // LOAD phase: beat load_idx transfers row load_idx of tile A and col load_idx of tile B
            if (load_en && (load_idx < ARRAY_SIZE)) begin
                // Transfer row load_idx of tile A(tile_i, tile_k)
                for (load_c = 0; load_c < ARRAY_SIZE; load_c = load_c + 1) begin
                    g_row_a = (tile_i * ARRAY_SIZE) + load_idx;
                    g_col_a = (tile_k * ARRAY_SIZE) + load_c;
                    addr_a  = (g_row_a * matrix_dim) + g_col_a;
                    if (addr_a < MAX_ELEMENTS) begin
                        staged_a[(((load_idx * ARRAY_SIZE) + load_c) * DATA_WIDTH) +: DATA_WIDTH] <= mem_a[addr_a];
                    end
                end

                // Transfer col load_idx of tile B(tile_k, tile_j)
                for (load_r = 0; load_r < ARRAY_SIZE; load_r = load_r + 1) begin
                    g_row_b = (tile_k * ARRAY_SIZE) + load_r;
                    g_col_b = (tile_j * ARRAY_SIZE) + load_idx;
                    addr_b  = (g_row_b * matrix_dim) + g_col_b;
                    if (addr_b < MAX_ELEMENTS) begin
                        staged_b[(((load_r * ARRAY_SIZE) + load_idx) * DATA_WIDTH) +: DATA_WIDTH] <= mem_b[addr_b];
                    end
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
            // For row i: a_west[i] = staged_a[i][k] where k = cycle_count - i (0 <= k < ARRAY_SIZE)
            for (row_i = 0; row_i < ARRAY_SIZE; row_i = row_i + 1) begin
                k_a = $signed({1'b0, cycle_count}) - row_i;
                if ((k_a >= 0) && (k_a < ARRAY_SIZE)) begin
                    a_west_comb[(row_i * DATA_WIDTH) +: DATA_WIDTH] =
                        staged_a[(((row_i * ARRAY_SIZE) + k_a) * DATA_WIDTH) +: DATA_WIDTH];
                end
            end

            // For column j: b_north[j] = staged_b[k][j] where k = cycle_count - j (0 <= k < ARRAY_SIZE)
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
