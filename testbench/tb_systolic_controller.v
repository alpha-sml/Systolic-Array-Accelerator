// tb_systolic_controller
// Self-checking cycle-accurate test for the 3x3 systolic controller.
//
// Checks reset, the IDLE -> LOAD -> COMPUTE -> DONE -> IDLE sequence,
// load index and compute cycle counts, completion strobes, a second
// back-to-back operation, and start edges that arrive while the controller
// is busy or is in the one-cycle DONE state.

`timescale 1ns / 1ps
`default_nettype none

module tb_systolic_controller;

    localparam integer ARRAY_SIZE     = 3;
    localparam integer LOAD_CYCLES    = ARRAY_SIZE;
    localparam integer COMPUTE_CYCLES = (3 * ARRAY_SIZE) - 2; // 7
    localparam integer CLK_NS         = 10;

    localparam [1:0] ST_IDLE    = 2'b00;
    localparam [1:0] ST_LOAD    = 2'b01;
    localparam [1:0] ST_COMPUTE = 2'b10;
    localparam [1:0] ST_DONE    = 2'b11;

    reg        clk;
    reg        rst_n;
    reg        start;
    wire       idle;
    wire       busy;
    wire       done;
    wire       load_en;
    wire [1:0] load_idx;
    wire       array_clear;
    wire       compute_en;
    wire [2:0] cycle_count;
    wire       result_valid;
    wire [1:0] state;

    integer errors;
    integer cycles;
    integer guard;

    systolic_controller #(
        .ARRAY_SIZE(ARRAY_SIZE)
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .idle        (idle),
        .busy        (busy),
        .done        (done),
        .load_en     (load_en),
        .load_idx    (load_idx),
        .array_clear (array_clear),
        .compute_en  (compute_en),
        .cycle_count (cycle_count),
        .result_valid(result_valid),
        .state       (state)
    );

    initial clk = 1'b0;
    always #(CLK_NS / 2) clk = ~clk;

    task automatic check;
        input integer cond;
        input [255:0] msg;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FAIL cyc=%0d state=%b idle=%b busy=%b done=%b load_en=%b idx=%0d clear=%b comp_en=%b cyc_cnt=%0d rv=%b start=%b : %0s",
                         cycles, state, idle, busy, done, load_en, load_idx, array_clear,
                         compute_en, cycle_count, result_valid, start, msg);
            end
        end
    endtask

    task automatic show;
        input [255:0] tag;
        begin
            $display("cyc=%0d %-16s state=%b idle=%0b busy=%0b done=%0b load_en=%0b idx=%0d clear=%0b comp_en=%0b cnt=%0d rv=%0b start=%0b",
                     cycles, tag, state, idle, busy, done, load_en, load_idx,
                     array_clear, compute_en, cycle_count, result_valid, start);
        end
    endtask

    // Advance one rising edge, then sample after NBA updates.
    task automatic tick;
        begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;
            show("step");
        end
    endtask

    task automatic expect_idle;
        begin
            check(state == ST_IDLE, "state IDLE");
            check(idle == 1'b1, "idle high");
            check(busy == 1'b0, "busy low");
            check(done == 1'b0, "done low");
            check(load_en == 1'b0, "load_en low");
            check(load_idx == 2'd0, "load_idx zero");
            check(array_clear == 1'b0, "array_clear low");
            check(compute_en == 1'b0, "compute_en low");
            check(cycle_count == 3'd0, "cycle_count zero");
            check(result_valid == 1'b0, "result_valid low");
        end
    endtask

    task automatic expect_load;
        input integer idx;
        input integer is_last;
        begin
            check(state == ST_LOAD, "state LOAD");
            check(idle == 1'b0, "not idle during load");
            check(busy == 1'b1, "busy during load");
            check(done == 1'b0, "done low during load");
            check(load_en == 1'b1, "load_en high");
            check(load_idx == idx[1:0], "load_idx");
            check(array_clear == is_last[0], "array_clear on last beat only");
            check(compute_en == 1'b0, "compute_en low during load");
            check(cycle_count == 3'd0, "cycle_count zero during load");
            check(result_valid == 1'b0, "result_valid low during load");
        end
    endtask

    task automatic expect_compute;
        input integer cyc;
        begin
            check(state == ST_COMPUTE, "state COMPUTE");
            check(idle == 1'b0, "not idle during compute");
            check(busy == 1'b1, "busy during compute");
            check(done == 1'b0, "done low during compute");
            check(load_en == 1'b0, "load_en low during compute");
            check(load_idx == 2'd0, "load_idx zero during compute");
            check(array_clear == 1'b0, "array_clear low during compute");
            check(compute_en == 1'b1, "compute_en high");
            check(cycle_count == cyc[2:0], "cycle_count");
            check(result_valid == 1'b0, "result_valid low during compute");
        end
    endtask

    task automatic expect_done;
        begin
            check(state == ST_DONE, "state DONE");
            check(idle == 1'b0, "not idle during done");
            check(busy == 1'b0, "busy low during done");
            check(done == 1'b1, "done pulse");
            check(load_en == 1'b0, "load_en low during done");
            check(compute_en == 1'b0, "compute_en low during done");
            check(array_clear == 1'b0, "array_clear low during done");
            check(result_valid == 1'b1, "result_valid pulse");
            check(cycle_count == 3'd0, "cycle_count zero during done");
        end
    endtask

    // One full operation. start_mode:
    //   0 -- single-cycle pulse while idle
    //   1 -- level held from the launching edge until after DONE
    //   2 -- extra rising edge injected on the second LOAD beat
    //   3 -- extra rising edge injected on the first COMPUTE beat
    //   4 -- rising edge injected during DONE
    task automatic run_operation;
        input integer start_mode;
        integer k;
        integer done_pulses;
        begin
            done_pulses = 0;

            check(idle == 1'b1, "precondition: idle before start");
            start = 1'b1;
            tick;
            // The edge is sampled by this clock; LOAD is visible afterwards.
            expect_load(0, 0);

            if (start_mode != 1)
                start = 1'b0;

            for (k = 1; k < LOAD_CYCLES; k = k + 1) begin
                tick;
                expect_load(k, (k == LOAD_CYCLES - 1));
                if ((start_mode == 2) && (k == 1)) begin
                    // Rising edge while LOAD. Must be ignored.
                    start = 1'b1;
                    tick;
                    // Still the next load beat, not a restarted index 0.
                    // The loop index k is the beat we just checked. The extra
                    // tick consumes the following beat, so skip ahead.
                    k = k + 1;
                    expect_load(k, (k == LOAD_CYCLES - 1));
                    start = 1'b0;
                end
            end

            for (k = 0; k < COMPUTE_CYCLES; k = k + 1) begin
                tick;
                expect_compute(k);
                if ((start_mode == 3) && (k == 0)) begin
                    start = 1'b1;
                    tick;
                    k = k + 1;
                    expect_compute(k);
                    start = 1'b0;
                end
            end

            tick;
            expect_done;
            done_pulses = done_pulses + 1;
            if (start_mode == 4) begin
                // Rising edge in DONE must not cause LOAD on the next cycle.
                start = 1'b1;
            end

            tick;
            expect_idle;
            if (start_mode == 1) begin
                // Level still high. Stay idle.
                tick;
                expect_idle;
                tick;
                expect_idle;
                start = 1'b0;
                tick;
                expect_idle;
            end else if (start_mode == 4) begin
                tick;
                expect_idle;
                start = 1'b0;
                tick;
                expect_idle;
            end else begin
                // The busy-phase edge must not have been queued.
                tick;
                expect_idle;
            end

            check(done_pulses == 1, "exactly one completion in this operation");
        end
    endtask

    initial begin
        errors = 0;
        cycles = 0;
        start  = 1'b0;
        rst_n  = 1'b1;

        $dumpfile("build/tb_systolic_controller.vcd");
        $dumpvars(0, tb_systolic_controller);

        // ------------------------------------------------------------------
        // Reset: async assert, held across clocks, then released.
        // ------------------------------------------------------------------
        #1;
        rst_n = 1'b0;
        #1;
        expect_idle;
        show("reset-assert");
        tick;
        expect_idle;
        tick;
        expect_idle;

        // A start level held through reset release must not launch work.
        start = 1'b1;
        tick;
        expect_idle;
        rst_n = 1'b1;
        tick;
        expect_idle;
        show("start-through-reset");
        tick;
        expect_idle;
        start = 1'b0;
        tick;
        expect_idle;

        $display("TEST reset and idle               : observed");

        // ------------------------------------------------------------------
        // Nominal pulse start.
        // ------------------------------------------------------------------
        run_operation(0);
        $display("TEST nominal LOAD/COMPUTE/DONE    : checked");

        // ------------------------------------------------------------------
        // Start held high across the whole operation.
        // ------------------------------------------------------------------
        run_operation(1);
        $display("TEST start held through completion: checked");

        // ------------------------------------------------------------------
        // Rising edge during LOAD.
        // ------------------------------------------------------------------
        run_operation(2);
        $display("TEST start during LOAD            : checked");

        // ------------------------------------------------------------------
        // Rising edge during COMPUTE.
        // ------------------------------------------------------------------
        run_operation(3);
        $display("TEST start during COMPUTE         : checked");

        // ------------------------------------------------------------------
        // Rising edge during DONE, then a clean second operation.
        // ------------------------------------------------------------------
        run_operation(4);
        $display("TEST start during DONE            : checked");

        run_operation(0);
        $display("TEST back-to-back operation       : checked");

        // ------------------------------------------------------------------
        // Asynchronous reset mid-compute returns the machine to IDLE and
        // holds it there after release.
        // ------------------------------------------------------------------
        check(idle == 1'b1, "idle before mid-reset run");
        start = 1'b1;
        tick;
        expect_load(0, 0);
        start = 1'b0;
        guard = 0;
        while ((state != ST_COMPUTE) && (guard < 20)) begin
            tick;
            guard = guard + 1;
        end
        check(state == ST_COMPUTE, "reached COMPUTE before mid-reset");
        show("before-mid-reset");
        rst_n = 1'b0;
        #1;
        expect_idle;
        show("mid-reset-assert");
        tick;
        expect_idle;
        rst_n = 1'b1;
        tick;
        expect_idle;
        tick;
        expect_idle;
        $display("TEST reset during COMPUTE         : checked");

        // ------------------------------------------------------------------
        if (errors == 0) begin
            $display("RESULT: PASS (%0d cycles, LOAD=%0d, COMPUTE=%0d)",
                     cycles, LOAD_CYCLES, COMPUTE_CYCLES);
            $finish;
        end else begin
            $display("RESULT: FAIL with %0d error(s)", errors);
            $fatal(1);
        end
    end

    // Watchdog, in case the FSM never returns to idle.
    initial begin
        #20000;
        $display("RESULT: FAIL timeout");
        $fatal(1);
    end

endmodule

`default_nettype wire
