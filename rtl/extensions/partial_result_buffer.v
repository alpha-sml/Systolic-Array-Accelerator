// partial_result_buffer.v
// Phase II Scalability - Partial Result Storage and Inter-Tile Accumulation
//
// Responsibilities:
//   - Preserve intermediate accumulator tiles across multiple systolic array tile runs.
//   - Support inter-tile accumulation:
//       * On first reduction step (accumulate_en = 0): overwrite destination tile elements.
//       * On subsequent reduction steps (accumulate_en = 1): add incoming partial tile results
//         to stored partial results using full signed ACC_WIDTH arithmetic.
//   - Store completed output tiles into a unified result matrix memory.
//   - Provide indexed synchronous readback to the host using row-major linear addressing:
//       address = row * matrix_dim + col
//   - Preserve Phase I output buffer read handshake:
//       * Returns valid data and asserts read_valid for 1 cycle when reading in-range address
//         while result_available is high.
//       * Rejects out-of-range reads and reads when no result is available (read_valid = 0, read_data = 0).
//   - Clear and reset semantics:
//       * Asynchronous active-low reset rst_n clears all storage and status flags.
//       * Synchronous clear invalidates results on new operation start.

`timescale 1ns / 1ps
`default_nettype none

module partial_result_buffer #(
    parameter integer ARRAY_SIZE     = 3,
    parameter integer MAX_MATRIX_DIM = 6,
    parameter integer ACC_WIDTH      = 32,
    parameter integer ADDR_WIDTH     = (MAX_MATRIX_DIM * MAX_MATRIX_DIM <= 1) ? 1 : $clog2(MAX_MATRIX_DIM * MAX_MATRIX_DIM)
) (
    input  wire                                         clk,
    input  wire                                         rst_n,

    // Control and tile context from matrix_tiling_controller
    input  wire                                         clear,
    input  wire [3:0]                                   matrix_dim,
    input  wire [1:0]                                   tile_i,
    input  wire [1:0]                                   tile_j,
    input  wire                                         accumulate_en,
    input  wire                                         capture_en,
    input  wire                                         all_tiles_done,

    // Systolic array accumulator outputs (packed vector)
    input  wire [(ARRAY_SIZE*ARRAY_SIZE*ACC_WIDTH)-1:0] acc_in,

    // Host readback interface
    input  wire                                         read_en,
    input  wire [ADDR_WIDTH-1:0]                        read_addr,
    output reg  signed [ACC_WIDTH-1:0]                  read_data,
    output reg                                          read_valid,
    output reg                                          result_available
);

    localparam integer MAX_ELEMENTS = MAX_MATRIX_DIM * MAX_MATRIX_DIM;

    // Storage for the complete output matrix (up to MAX_MATRIX_DIM x MAX_MATRIX_DIM)
    reg signed [ACC_WIDTH-1:0] c_mem [0:MAX_ELEMENTS-1];

    integer init_i;
    integer r, c;
    integer g_row, g_col, g_idx;
    reg signed [ACC_WIDTH-1:0] elem_in;

    wire [ADDR_WIDTH:0] total_elements = matrix_dim * matrix_dim;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_available <= 1'b0;
            read_valid       <= 1'b0;
            read_data        <= {ACC_WIDTH{1'b0}};
            for (init_i = 0; init_i < MAX_ELEMENTS; init_i = init_i + 1) begin
                c_mem[init_i] <= {ACC_WIDTH{1'b0}};
            end
        end else begin
            // Result availability & clear handling
            if (clear) begin
                result_available <= 1'b0;
            end else if (all_tiles_done) begin
                result_available <= 1'b1;
            end

            // Partial result capture and inter-tile accumulation
            if (capture_en) begin
                for (r = 0; r < ARRAY_SIZE; r = r + 1) begin
                    for (c = 0; c < ARRAY_SIZE; c = c + 1) begin
                        g_row   = (tile_i * ARRAY_SIZE) + r;
                        g_col   = (tile_j * ARRAY_SIZE) + c;
                        g_idx   = (g_row * matrix_dim) + g_col;
                        elem_in = acc_in[((r * ARRAY_SIZE + c) * ACC_WIDTH) +: ACC_WIDTH];

                        if (g_idx < MAX_ELEMENTS) begin
                            if (!accumulate_en) begin
                                // First tile product for this output block: store directly
                                c_mem[g_idx] <= elem_in;
                            end else begin
                                // Subsequent tile products: accumulate with existing partial sum
                                c_mem[g_idx] <= c_mem[g_idx] + elem_in;
                            end
                        end
                    end
                end
            end

            // Synchronous indexed readback interface
            if (read_en && result_available && !clear && (read_addr < total_elements)) begin
                read_data  <= c_mem[read_addr];
                read_valid <= 1'b1;
            end else begin
                read_data  <= {ACC_WIDTH{1'b0}};
                read_valid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
