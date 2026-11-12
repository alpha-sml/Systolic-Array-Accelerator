// output_buffer.v
// Data Management subsystem - Matrix Multiplication Result Buffer
//
// Responsibilities:
//   - Capture N x N accumulator values from systolic_array on controller's
//     single-cycle result_valid pulse during DONE state.
//   - Set result_available high upon result capture and retain values until
//     reset or a newly accepted operation invalidates them via clear.
//   - Clear-versus-capture priority: result_valid has higher priority than clear.
//   - Provide indexed synchronous read interface with row-major addressing:
//       address = row * ARRAY_SIZE + col
//   - Return read_data and a single-cycle read_valid pulse when reading an
//     in-range address while a result is available.
//   - Asynchronous active-low reset clears all registers and status flags.

`timescale 1ns / 1ps
`default_nettype none

module output_buffer #(
    parameter integer ARRAY_SIZE = 3,
    parameter integer ACC_WIDTH  = 32,
    parameter integer ADDR_WIDTH = (ARRAY_SIZE * ARRAY_SIZE <= 1) ? 1 : $clog2(ARRAY_SIZE * ARRAY_SIZE)
) (
    input  wire                                         clk,
    input  wire                                         rst_n,

    // Systolic array accumulator snapshot and controller valid flag
    input  wire                                         result_valid,
    input  wire [(ARRAY_SIZE*ARRAY_SIZE*ACC_WIDTH)-1:0] acc_in,

    // Invalidation / clear signal for newly accepted operation
    input  wire                                         clear,

    // Host read interface
    input  wire                                         read_en,
    input  wire [ADDR_WIDTH-1:0]                        read_addr,
    output reg  signed [ACC_WIDTH-1:0]                  read_data,
    output reg                                          read_valid,
    output reg                                          result_available
);

    localparam integer NUM_ELEMENTS = ARRAY_SIZE * ARRAY_SIZE;

    // Storage for the captured result matrix elements
    reg signed [ACC_WIDTH-1:0] result_mem [0:NUM_ELEMENTS-1];

    integer idx, init_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            result_available <= 1'b0;
            read_valid       <= 1'b0;
            read_data        <= {ACC_WIDTH{1'b0}};
            for (init_idx = 0; init_idx < NUM_ELEMENTS; init_idx = init_idx + 1) begin
                result_mem[init_idx] <= {ACC_WIDTH{1'b0}};
            end
        end else begin
            // Result capture and invalidation
            // Valid capture takes priority over clear if both overlap
            if (result_valid) begin
                for (idx = 0; idx < NUM_ELEMENTS; idx = idx + 1) begin
                    result_mem[idx] <= acc_in[(idx * ACC_WIDTH) +: ACC_WIDTH];
                end
                result_available <= 1'b1;
            end else if (clear) begin
                result_available <= 1'b0;
            end

            // Synchronous indexed read interface
            // Returns data and pulses read_valid only when result is available and address is valid
            if (read_en && result_available && (read_addr < NUM_ELEMENTS)) begin
                read_data  <= result_mem[read_addr];
                read_valid <= 1'b1;
            end else begin
                read_data  <= {ACC_WIDTH{1'b0}};
                read_valid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
