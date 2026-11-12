// matrix_interface.v
// Data Management subsystem - Host and Control Interface
//
// Responsibilities:
//   - Route host matrix writes to the input buffer only while controller is idle.
//   - Synchronize host operation requests (host_start):
//       * Accept only when controller is idle and matrices_ready is asserted.
//       * Generate a clean 1-cycle start pulse for the controller.
//       * Generate a clean 1-cycle out_buf_clear pulse to invalidate prior results.
//       * Provide 1-cycle start_ack on acceptance or start_err on rejection.
//       * Reject start if matrices are incomplete or controller is busy.
//       * Require host_start to fall and rise again (no auto-restart on held high).
//   - Expose accelerator status to host:
//       * host_ready: controller is idle AND matrices are ready.
//       * host_busy: controller is busy.
//       * host_done: controller completion pulse.
//       * host_result_available: result ready in output buffer.
//   - Route host read requests and read responses to/from output buffer.

`timescale 1ns / 1ps
`default_nettype none

module matrix_interface #(
    parameter integer ARRAY_SIZE = 3,
    parameter integer DATA_WIDTH = 8,
    parameter integer ACC_WIDTH  = 32,
    parameter integer ADDR_WIDTH = (ARRAY_SIZE * ARRAY_SIZE <= 1) ? 1 : $clog2(ARRAY_SIZE * ARRAY_SIZE)
) (
    input  wire                         clk,
    input  wire                         rst_n,

    // Host operation request & status
    input  wire                         host_start,
    output wire                         host_ready,
    output wire                         host_busy,
    output wire                         host_done,
    output reg                          start_ack,
    output reg                          start_err,

    // Controller coordination interface
    output reg                          start,
    input  wire                         controller_idle,
    input  wire                         controller_busy,
    input  wire                         controller_done,

    // Host matrix write interface
    input  wire                         host_write_en,
    input  wire                         host_write_is_b,
    input  wire [ADDR_WIDTH-1:0]        host_write_addr,
    input  wire signed [DATA_WIDTH-1:0] host_write_data,
    output wire                         host_write_ack,

    // Input buffer write interface
    output wire                         write_en,
    output wire                         write_is_b,
    output wire [ADDR_WIDTH-1:0]        write_addr,
    output wire signed [DATA_WIDTH-1:0] write_data,
    input  wire                         matrices_ready,

    // Output buffer clear / invalidate interface
    output reg                          out_buf_clear,

    // Host result read interface
    input  wire                         host_read_en,
    input  wire [ADDR_WIDTH-1:0]        host_read_addr,
    output wire signed [ACC_WIDTH-1:0]  host_read_data,
    output wire                         host_read_valid,
    output wire                         host_result_available,

    // Output buffer read interface
    output wire                         read_en,
    output wire [ADDR_WIDTH-1:0]        read_addr,
    input  wire signed [ACC_WIDTH-1:0]  result_read_data,
    input  wire                         result_read_valid,
    input  wire                         result_available
);

    // Host matrix write routing: only permit writes while controller is idle
    assign write_en       = host_write_en && controller_idle;
    assign write_is_b     = host_write_is_b;
    assign write_addr     = host_write_addr;
    assign write_data     = host_write_data;
    assign host_write_ack = controller_idle;

    // Host status indications
    assign host_ready            = controller_idle && matrices_ready;
    assign host_busy             = controller_busy;
    assign host_done             = controller_done;
    assign host_result_available = result_available;

    // Result read routing
    assign read_en         = host_read_en;
    assign read_addr       = host_read_addr;
    assign host_read_data  = result_read_data;
    assign host_read_valid = result_read_valid;

    // Start request synchronization and edge detection
    reg host_start_q;
    reg reset_lock;
    wire host_start_pulse = host_start & ~host_start_q & ~reset_lock;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            host_start_q  <= 1'b0;
            reset_lock    <= 1'b1;
            start         <= 1'b0;
            start_ack     <= 1'b0;
            start_err     <= 1'b0;
            out_buf_clear <= 1'b0;
        end else begin
            host_start_q  <= host_start;
            reset_lock    <= 1'b0;
            start         <= 1'b0;
            start_ack     <= 1'b0;
            start_err     <= 1'b0;
            out_buf_clear <= 1'b0;

            if (host_start_pulse) begin
                if (controller_idle && matrices_ready) begin
                    start         <= 1'b1;
                    start_ack     <= 1'b1;
                    out_buf_clear <= 1'b1;
                end else begin
                    start_err     <= 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
