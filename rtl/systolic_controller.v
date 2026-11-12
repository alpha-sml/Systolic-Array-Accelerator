// systolic_controller
// Control-only coordinator for a fixed-point N x N output-stationary
// systolic matrix-multiply accelerator. Default N is 3.
//
// This module does not carry matrix data or instantiate the PE, array,
// buffer, or matrix-interface blocks. It sequences those system-level blocks
// through the ports below, which form the integration contract.
//
// Integration contract (N = ARRAY_SIZE)
// ------------------------------------
// Reset
//   rst_n is active-low and asynchronous. While it is low the FSM is forced
//   to IDLE and every control strobe is low. Hold start low through reset.
//   Keep start low until idle has been observed, then start an operation
//   with a rising edge.
//
// Host status
//   idle  -- high only in IDLE. A new operation may be started.
//   busy  -- high in LOAD and COMPUTE. start edges in these states are ignored.
//   done  -- single-cycle pulse in DONE, aligned with result_valid.
//   state -- registered FSM encoding (see control_fsm). May be left open.
//
// Start
//   A rising edge of start is accepted only while the FSM is in IDLE.
//   Edges while LOAD, COMPUTE, or DONE are ignored and do not restart or
//   extend the operation. start must return low before the next edge is
//   recognized, so a level held across completion does not auto-restart.
//   The first clock after rst_n is released only samples start; it cannot
//   launch an operation. A start level that was already high through reset
//   therefore does not fire until it falls and rises again. Wait until
//   rst_n has been high for at least one clock and idle is high, then pulse
//   start.
//
// LOAD, N cycles
//   load_en is high. load_idx walks 0 .. N-1, one beat per clock.
//   On beat k the input buffer / matrix interface must accept one row of A
//   (A[k][*]) and one column of B (B[*][k]). The controller assumes both
//   matrices are already available when start is issued; there is no stall.
//   On the last beat (load_idx == N-1) array_clear is high for that cycle
//   only. Every PE accumulator must clear on that edge and must not also
//   accumulate. array_clear is low for the whole COMPUTE phase.
//
// COMPUTE, 3N-2 cycles
//   compute_en is high. cycle_count walks 0 .. 3N-3.
//   Why 3N-2: with registered neighbor links, operand A[i][k] meets B[k][j]
//   at PE(i,j) on cycle i+j+k. The last product is PE(N-1,N-1), k = N-1,
//   at cycle 3(N-1) = 3N-3. Inclusive cycle count is 3N-2.
//   The input buffer must drive the skewed edge operands while compute_en
//   is high, and drive zero on beats that fall outside a row or column:
//     west  port of row i gets A[i][k] when cycle_count == i+k
//     north port of col j gets B[k][j] when cycle_count == j+k
//   Each enabled PE does acc <= acc + a*b and registers a to the east and
//   b to the south. After the last compute cycle every accumulator holds
//   one element of C = A x B.
//
// DONE, 1 cycle
//   done and result_valid are high. load_en, compute_en, and array_clear
//   are low, so the accumulators are stable. The output buffer must capture
//   the full N x N accumulator snapshot on the rising clock edge at which
//   result_valid is still high. The following cycle is IDLE.
//
// Suggested wiring (no data ports on this module)
//   matrix_interface / host : start, idle, busy, done
//   input_buffer            : load_en, load_idx, compute_en, cycle_count
//   systolic_array / PEs    : array_clear, compute_en
//   output_buffer           : result_valid

`timescale 1ns / 1ps
`default_nettype none

module systolic_controller #(
    parameter integer ARRAY_SIZE     = 3,
    // Operand beats. One row of A and one column of B per beat.
    parameter integer LOAD_CYCLES    = ARRAY_SIZE,
    // Output-stationary skewed schedule, including the pipeline fill.
    parameter integer COMPUTE_CYCLES = (3 * ARRAY_SIZE) - 2,
    parameter integer LOAD_IDX_W     = (ARRAY_SIZE <= 1) ? 1 : $clog2(ARRAY_SIZE),
    parameter integer CYCLE_W        = (COMPUTE_CYCLES <= 1) ? 1 : $clog2(COMPUTE_CYCLES)
) (
    input  wire                      clk,
    input  wire                      rst_n,

    input  wire                      start,
    output wire                      idle,
    output wire                      busy,
    output wire                      done,

    output wire                      load_en,
    output wire [LOAD_IDX_W-1:0]     load_idx,

    output wire                      array_clear,
    output wire                      compute_en,
    output wire [CYCLE_W-1:0]        cycle_count,

    output wire                      result_valid,
    output wire [1:0]                state
);

    reg  [LOAD_IDX_W-1:0] load_cnt;
    reg  [CYCLE_W-1:0]    comp_cnt;
    reg                   start_q;
    reg                   reset_lock;

    wire                  start_pulse;
    wire                  load_done;
    wire                  compute_done;
    wire                  state_idle;
    wire                  state_load;
    wire                  state_compute;
    wire                  state_done;
    wire [LOAD_IDX_W-1:0] load_last;
    wire [CYCLE_W-1:0]    compute_last;

    assign load_last    = LOAD_CYCLES - 1;
    assign compute_last = COMPUTE_CYCLES - 1;

    // Rising-edge detector. The FSM further qualifies this with IDLE, so an
    // edge that lands in LOAD, COMPUTE, or DONE cannot open a new operation.
    // Sampling start into start_q also swallows that edge, which means a
    // start held high until the machine is idle again will not restart it.
    // reset_lock blanks the launch cycle that releases reset: start_q is 0
    // while rst_n is low, so a start already high at release must not look
    // like a fresh rising edge.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_q    <= 1'b0;
            reset_lock <= 1'b1;
        end else begin
            start_q    <= start;
            reset_lock <= 1'b0;
        end
    end

    assign start_pulse = start & ~start_q & ~reset_lock;

    // Counters run only in their own phase and return to zero otherwise.
    // The terminal value is held through the cycle that raises *_done; the
    // FSM consumes that flag on the same cycle and leaves the phase on the
    // next clock. The counter is then cleared because the phase flag drops.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            load_cnt <= {LOAD_IDX_W{1'b0}};
        else if (state_load && (load_cnt != load_last))
            load_cnt <= load_cnt + 1'b1;
        else if (!state_load)
            load_cnt <= {LOAD_IDX_W{1'b0}};
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            comp_cnt <= {CYCLE_W{1'b0}};
        else if (state_compute && (comp_cnt != compute_last))
            comp_cnt <= comp_cnt + 1'b1;
        else if (!state_compute)
            comp_cnt <= {CYCLE_W{1'b0}};
    end

    assign load_done    = state_load    && (load_cnt == load_last);
    assign compute_done = state_compute && (comp_cnt == compute_last);

    control_fsm u_fsm (
        .clk          (clk),
        .rst_n        (rst_n),
        .start_pulse  (start_pulse),
        .load_done    (load_done),
        .compute_done (compute_done),
        .state        (state),
        .state_idle   (state_idle),
        .state_load   (state_load),
        .state_compute(state_compute),
        .state_done   (state_done)
    );

    assign idle         = state_idle;
    assign busy         = state_load | state_compute;
    assign done         = state_done;

    assign load_en      = state_load;
    assign load_idx     = state_load ? load_cnt : {LOAD_IDX_W{1'b0}};

    // Clear on the last load beat only, so the first compute cycle accumulates
    // rather than being discarded by a same-cycle clear.
    assign array_clear  = load_done;
    assign compute_en   = state_compute;
    assign cycle_count  = state_compute ? comp_cnt : {CYCLE_W{1'b0}};

    assign result_valid = state_done;

endmodule

`default_nettype wire
