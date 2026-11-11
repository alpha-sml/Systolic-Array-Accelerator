// control_fsm
// Synchronous controller FSM for an N x N output-stationary systolic GEMM.
//
// States
//   IDLE    -- waiting for a rising edge of start
//   LOAD    -- N operand-load beats; last beat clears PE accumulators
//   COMPUTE -- 3N-2 skewed MAC / shift cycles
//   DONE    -- one cycle, result capture, then back to IDLE
//
// start_pulse is honored only in IDLE. load_done and compute_done are
// produced by systolic_controller from the cycle counters.
//
// Encoding is binary and fixed at two bits. The four parameter values must
// stay unique; systolic_controller decodes the one-hot status flags below
// rather than re-interpreting the encoding.

`timescale 1ns / 1ps
`default_nettype none

module control_fsm #(
    parameter [1:0] ST_IDLE    = 2'b00,
    parameter [1:0] ST_LOAD    = 2'b01,
    parameter [1:0] ST_COMPUTE = 2'b10,
    parameter [1:0] ST_DONE    = 2'b11
) (
    input  wire       clk,
    input  wire       rst_n,          // async assert, active-low
    input  wire       start_pulse,    // one-cycle pulse; accepted only in IDLE
    input  wire       load_done,      // last operand beat is in progress
    input  wire       compute_done,   // last MAC / shift cycle is in progress
    output reg  [1:0] state,
    output wire       state_idle,
    output wire       state_load,
    output wire       state_compute,
    output wire       state_done
);

    reg [1:0] state_n;

    // Asynchronous reset so control outputs are defined without a clock edge.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= ST_IDLE;
        else
            state <= state_n;
    end

    // Every branch assigns state_n, including default, so this is latch-free.
    always @(*) begin
        state_n = state;
        case (state)
            ST_IDLE: begin
                if (start_pulse)
                    state_n = ST_LOAD;
            end
            ST_LOAD: begin
                if (load_done)
                    state_n = ST_COMPUTE;
            end
            ST_COMPUTE: begin
                if (compute_done)
                    state_n = ST_DONE;
            end
            ST_DONE: begin
                state_n = ST_IDLE;
            end
            default: begin
                state_n = ST_IDLE;
            end
        endcase
    end

    assign state_idle    = (state == ST_IDLE);
    assign state_load    = (state == ST_LOAD);
    assign state_compute = (state == ST_COMPUTE);
    assign state_done    = (state == ST_DONE);

endmodule

`default_nettype wire
