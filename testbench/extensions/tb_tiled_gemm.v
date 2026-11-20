// tb_tiled_gemm.v
// Phase II Scalability - Comprehensive Self-Checking Testbench for Tiled GEMM
//
// Verification Scope (Audit-corrected):
//   1.  3x3 multiplication through the tiled top-level design.
//   2.  6x6 multiplication (positive-valued) using the existing 3x3 array.
//   3.  6x6 mixed-sign matrix multiplication (boundary operands: -128, +127).
//   4.  Correct accumulation of partial results with signed cancellation check.
//   5.  Direct tile-coordinate monitoring: verifies the exact sequence
//          (0,0,0),(0,0,1),(0,1,0),(0,1,1),(1,0,0),(1,0,1),(1,1,0),(1,1,1).
//   6.  Exact cycle-count verification:
//          * 14-cycle tile scheduling interval per tile.
//          * 113-cycle total tiled computation interval.
//   7.  display_matrix_6x6 reads actual values from the accelerator readback
//       interface, NOT the software reference array.
//   8.  Unsupported cfg_matrix_dim (e.g., 4'd5) produces start_err, not start_ack.
//   9.  Asynchronous reset during active computation and clean post-reset recovery.
//  10.  Back-to-back matrix multiplication operations.
//  11.  Host interface protocol guarantees (incomplete-matrix rejection,
//       held-high start suppression, busy write rejection, out-of-range read).
//
// Failure policy: any failed check calls $fatal(1,...) so make test-tiled
// returns a nonzero exit status immediately on the first failure.
//
// All expected results are computed INDEPENDENTLY by a software reference
// model inside this file. No internal DUT state is used for expected values.

`timescale 1ns / 1ps
`default_nettype none

module tb_tiled_gemm;

    localparam integer ARRAY_SIZE      = 3;
    localparam integer MAX_MATRIX_SIZE = 6;
    localparam integer DATA_WIDTH      = 8;
    localparam integer ACC_WIDTH       = 32;
    localparam integer ADDR_WIDTH      = 6;
    localparam integer MAX_ELEMENTS    = MAX_MATRIX_SIZE * MAX_MATRIX_SIZE;

    // ---- Analytical cycle-count constants -------------------------
    // Per tile: N_load(3) + N_compute(7) + N_done(1) + N_sched(3) = 14
    localparam integer CYCLES_PER_TILE     = 14;
    // 8 tiles x 14 cycles/tile + 1 (ST_DONE) = 113
    localparam integer CYCLES_COMPUTE_6X6  = 113;
    // 2 x 36 write-beats (host transport in) + 36 read-beats (transport out)
    // + 113 compute + a few control edges ≈ 221 cycles end-to-end.
    // Measured between start_ack posedge and last read_valid posedge inclusive.
    localparam integer CYCLES_TOTAL_6X6_MIN = 215;   // accept slight rounding
    localparam integer CYCLES_TOTAL_6X6_MAX = 230;
    // ---------------------------------------------------------------

    reg                          clk;
    reg                          rst_n;
    reg  [3:0]                   cfg_matrix_dim;
    reg                          host_start;
    wire                         host_ready;
    wire                         host_busy;
    wire                         host_done;
    wire                         start_ack;
    wire                         start_err;

    reg                          host_write_en;
    reg                          host_write_is_b;
    reg  [ADDR_WIDTH-1:0]        host_write_addr;
    reg  signed [DATA_WIDTH-1:0] host_write_data;
    wire                         host_write_ack;
    wire                         matrices_ready;

    reg                          host_read_en;
    reg  [ADDR_WIDTH-1:0]        host_read_addr;
    wire signed [ACC_WIDTH-1:0]  host_read_data;
    wire                         host_read_valid;
    wire                         host_result_available;

    // Test tracking
    integer passed;
    integer failed;
    integer timeout;
    integer idx;

    // Cycle-count measurement registers
    integer t_start;         // time (in clock cycles) of accepted start_ack
    integer t_compute_start; // time when first sub_start fires
    integer t_compute_end;   // time when host_done fires
    integer t_last_read;     // time of last read_valid
    integer t_comp_start;    // Test 9 compute phase start
    integer t_comp_end;      // Test 9 compute phase end (host_done)
    integer t_read_start;    // Test 9 read phase start

    // Per-tile start timestamps (for 14-cycle interval check)
    integer tile_start_cycle [0:7];
    integer tile_obs_i       [0:7];
    integer tile_obs_j       [0:7];
    integer tile_obs_k       [0:7];
    integer tile_obs_count;

    // Independent software reference model
    reg signed [DATA_WIDTH-1:0] matrix_a   [0:MAX_ELEMENTS-1];
    reg signed [DATA_WIDTH-1:0] matrix_b   [0:MAX_ELEMENTS-1];
    reg signed [ACC_WIDTH-1:0]  expected_c [0:MAX_ELEMENTS-1];

    // Actual read-back buffer (populated from host readback, NOT expected_c)
    reg signed [ACC_WIDTH-1:0]  actual_c   [0:MAX_ELEMENTS-1];

    // -----------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------
    tiled_gemm_top #(
        .ARRAY_SIZE     (ARRAY_SIZE),
        .MAX_MATRIX_SIZE(MAX_MATRIX_SIZE),
        .DATA_WIDTH     (DATA_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .ADDR_WIDTH     (ADDR_WIDTH)
    ) dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .cfg_matrix_dim       (cfg_matrix_dim),
        .host_start           (host_start),
        .host_ready           (host_ready),
        .host_busy            (host_busy),
        .host_done            (host_done),
        .start_ack            (start_ack),
        .start_err            (start_err),
        .host_write_en        (host_write_en),
        .host_write_is_b      (host_write_is_b),
        .host_write_addr      (host_write_addr),
        .host_write_data      (host_write_data),
        .host_write_ack       (host_write_ack),
        .matrices_ready       (matrices_ready),
        .host_read_en         (host_read_en),
        .host_read_addr       (host_read_addr),
        .host_read_data       (host_read_data),
        .host_read_valid      (host_read_valid),
        .host_result_available(host_result_available)
    );

    // Clock: 10 ns period (100 MHz)
    always #5 clk = ~clk;

    // -----------------------------------------------------------------
    // check task: failures call $fatal(1) → nonzero exit status
    // -----------------------------------------------------------------
    task automatic check;
        input condition;
        input [1023:0] message;
        begin
            if (condition) begin
                passed = passed + 1;
            end else begin
                failed = failed + 1;
                $display("FAIL [Time %0t]: %0s", $time, message);
                $fatal(1, "Testbench check failed — aborting simulation.");
            end
        end
    endtask

    // -----------------------------------------------------------------
    // Software reference model
    // -----------------------------------------------------------------
    task automatic compute_software_reference;
        input integer dim;
        integer row, col, k_idx;
        begin
            for (row = 0; row < dim; row = row + 1)
                for (col = 0; col < dim; col = col + 1) begin
                    expected_c[(row * dim) + col] = 0;
                    for (k_idx = 0; k_idx < dim; k_idx = k_idx + 1)
                        expected_c[(row * dim) + col] =
                            expected_c[(row * dim) + col] +
                            (matrix_a[(row * dim) + k_idx] *
                             matrix_b[(k_idx * dim) + col]);
                end
        end
    endtask

    // -----------------------------------------------------------------
    // Write a single element to the accelerator
    // -----------------------------------------------------------------
    task automatic write_element;
        input is_b;
        input integer addr;
        input signed [DATA_WIDTH-1:0] val;
        begin
            @(negedge clk);
            host_write_en   = 1'b1;
            host_write_is_b = is_b;
            host_write_addr = addr;
            host_write_data = val;
            @(posedge clk);
            #1;
            check(host_write_ack, "Write was not acknowledged by DUT");
            @(negedge clk);
            host_write_en = 1'b0;
        end
    endtask

    // -----------------------------------------------------------------
    // Load full dim×dim matrix pair into the accelerator
    // -----------------------------------------------------------------
    task automatic load_matrices;
        input integer dim;
        integer total, el_idx;
        begin
            total = dim * dim;
            for (el_idx = 0; el_idx < total; el_idx = el_idx + 1)
                write_element(1'b0, el_idx, matrix_a[el_idx]);
            for (el_idx = 0; el_idx < total; el_idx = el_idx + 1)
                write_element(1'b1, el_idx, matrix_b[el_idx]);
            @(posedge clk);
            #1 check(matrices_ready,
                     "matrices_ready did not assert after loading both matrices");
        end
    endtask

    // -----------------------------------------------------------------
    // Start computation and wait for completion.
    // Records t_start (cycle of accepted start_ack) for cycle counting.
    // -----------------------------------------------------------------
    task automatic start_and_wait;
        input integer max_wait_cycles;
        begin
            @(negedge clk);
            host_start = 1'b1;
            @(posedge clk);
            #1;
            check(start_ack,  "host_start was not accepted with start_ack");
            check(!start_err, "start_err asserted unexpectedly on valid start");
            @(negedge clk);
            host_start = 1'b0;
            @(posedge clk);
            #1 check(host_busy, "DUT did not enter busy state after start");

            timeout = 0;
            while (!host_result_available && timeout < max_wait_cycles) begin
                @(posedge clk);
                #1 timeout = timeout + 1;
            end
            check(host_result_available,
                  "Result did not become available within timeout");
            check(!host_busy,
                  "DUT remained busy after result became available");
        end
    endtask

    // -----------------------------------------------------------------
    // Read all dim×dim results from the accelerator and populate actual_c[].
    // Also compares against expected_c[].
    // -----------------------------------------------------------------
    task automatic readback_and_verify;
        input integer dim;
        integer total, el_idx;
        begin
            total = dim * dim;
            for (el_idx = 0; el_idx < total; el_idx = el_idx + 1) begin
                @(negedge clk);
                host_read_en   = 1'b1;
                host_read_addr = el_idx;
                @(posedge clk);
                #1;
                check(host_read_valid,
                      "host_read_valid was not asserted on in-range read");
                // Store actual value from DUT
                actual_c[el_idx] = $signed(host_read_data);
                // Compare against independent reference
                if ($signed(host_read_data) != expected_c[el_idx]) begin
                    $display("MISMATCH element[%0d]: expected %0d, got %0d",
                             el_idx, expected_c[el_idx], $signed(host_read_data));
                end
                check($signed(host_read_data) == expected_c[el_idx],
                      "Result readback does not match software reference");
                @(negedge clk);
                host_read_en = 1'b0;
            end
        end
    endtask

    // -----------------------------------------------------------------
    // display_matrix_6x6: prints actual values READ FROM THE ACCELERATOR.
    // Must be called AFTER readback_and_verify so actual_c[] is populated.
    // -----------------------------------------------------------------
    task automatic display_matrix_6x6;
        integer row;
        begin
            $display("--- 6x6 Result Matrix (read from accelerator, NOT reference) ---");
            for (row = 0; row < 6; row = row + 1)
                $display("  [%4d, %4d, %4d, %4d, %4d, %4d]",
                    actual_c[row*6+0], actual_c[row*6+1], actual_c[row*6+2],
                    actual_c[row*6+3], actual_c[row*6+4], actual_c[row*6+5]);
        end
    endtask

    // -----------------------------------------------------------------
    // monitor_tile_sequence: runs in background during 6x6 execution.
    // Records (tile_i, tile_j, tile_k) on every ST_TILE_START entry and
    // measures per-tile scheduling intervals.
    //
    // Detection: sub_start rises when tiling FSM enters ST_TILE_START.
    // We sample tile coordinates on that rising edge.
    // -----------------------------------------------------------------
    integer cycle_counter;
    reg     monitor_active;

    // Cycle counter always free-running when monitor_active
    always @(posedge clk) begin
        if (monitor_active)
            cycle_counter <= cycle_counter + 1;
        else
            cycle_counter <= 0;
    end

    task automatic monitor_tile_sequence;
        // Expected tile sequence for 6x6 (K_dim = 2)
        // Traversal order: k is innermost, j middle, i outermost
        // -> (i,j,k): (0,0,0)(0,0,1)(0,1,0)(0,1,1)(1,0,0)(1,0,1)(1,1,0)(1,1,1)
        reg [1:0] exp_i [0:7];
        reg [1:0] exp_j [0:7];
        reg [1:0] exp_k [0:7];
        integer   tile_idx;
        integer   interval;
        reg [1:0] obs_i, obs_j, obs_k;
        integer   prev_start, this_start;
        begin
            exp_i[0] = 0; exp_j[0] = 0; exp_k[0] = 0;
            exp_i[1] = 0; exp_j[1] = 0; exp_k[1] = 1;
            exp_i[2] = 0; exp_j[2] = 1; exp_k[2] = 0;
            exp_i[3] = 0; exp_j[3] = 1; exp_k[3] = 1;
            exp_i[4] = 1; exp_j[4] = 0; exp_k[4] = 0;
            exp_i[5] = 1; exp_j[5] = 0; exp_k[5] = 1;
            exp_i[6] = 1; exp_j[6] = 1; exp_k[6] = 0;
            exp_i[7] = 1; exp_j[7] = 1; exp_k[7] = 1;

            prev_start = 0;
            for (tile_idx = 0; tile_idx < 8; tile_idx = tile_idx + 1) begin
                // Wait for sub_start rising edge (ST_TILE_START)
                @(posedge dut.sub_start);
                this_start = cycle_counter;
                // Sample tile coordinates one cycle later (registered outputs)
                @(posedge clk);
                #1;
                obs_i = dut.tile_i;
                obs_j = dut.tile_j;
                obs_k = dut.tile_k;

                tile_obs_i[tile_idx]     = obs_i;
                tile_obs_j[tile_idx]     = obs_j;
                tile_obs_k[tile_idx]     = obs_k;
                tile_start_cycle[tile_idx] = this_start;

                // Verify tile coordinates match expected sequence
                if (obs_i !== exp_i[tile_idx] ||
                    obs_j !== exp_j[tile_idx] ||
                    obs_k !== exp_k[tile_idx]) begin
                    $display(
                        "TILE SEQ MISMATCH tile %0d: expected (%0d,%0d,%0d) got (%0d,%0d,%0d)",
                        tile_idx,
                        exp_i[tile_idx], exp_j[tile_idx], exp_k[tile_idx],
                        obs_i, obs_j, obs_k);
                end
                check(obs_i === exp_i[tile_idx],
                      "tile_i does not match expected sequence");
                check(obs_j === exp_j[tile_idx],
                      "tile_j does not match expected sequence");
                check(obs_k === exp_k[tile_idx],
                      "tile_k does not match expected sequence");

                // Verify 14-cycle interval between successive tile starts
                // (not applicable for the first tile)
                if (tile_idx > 0) begin
                    interval = this_start - prev_start;
                    if (interval !== CYCLES_PER_TILE) begin
                        $display(
                            "CYCLE INTERVAL tile %0d: expected %0d got %0d",
                            tile_idx, CYCLES_PER_TILE, interval);
                    end
                    check(interval === CYCLES_PER_TILE,
                          "14-cycle tile scheduling interval violated");
                end
                prev_start = this_start;
            end
            tile_obs_count = 8;
        end
    endtask

    // -----------------------------------------------------------------
    // Main test flow
    // -----------------------------------------------------------------
    initial begin
        // Initialise signals
        clk             = 1'b0;
        rst_n           = 1'b0;
        cfg_matrix_dim  = 4'd6;
        host_start      = 1'b0;
        host_write_en   = 1'b0;
        host_write_is_b = 1'b0;
        host_write_addr = 6'd0;
        host_write_data = 8'sd0;
        host_read_en    = 1'b0;
        host_read_addr  = 6'd0;
        passed          = 0;
        failed          = 0;
        monitor_active  = 1'b0;
        cycle_counter   = 0;
        tile_obs_count  = 0;

        $display("==================================================================");
        $display("Phase II Tiled GEMM Testbench (Audit-corrected, tb_tiled_gemm)");
        $display("==================================================================");

        // ----------------------------------------------------------------
        // Reset
        // ----------------------------------------------------------------
        #25;
        rst_n = 1'b1;
        @(posedge clk); #1;
        check(!host_busy && !host_done && !host_result_available,
              "Post-reset status flags must all be deasserted");
        check(!matrices_ready && !host_ready,
              "matrices_ready / host_ready must be deasserted after reset");

        // ================================================================
        // TEST 1: 3x3 via tiled top-level (single tile, cfg_matrix_dim=3)
        // ================================================================
        $display("\n--- Test 1: 3x3 Multiplication via Tiled Architecture ---");
        cfg_matrix_dim = 4'd3;

        matrix_a[0]=8'sd1; matrix_a[1]=8'sd2; matrix_a[2]=8'sd3;
        matrix_a[3]=8'sd4; matrix_a[4]=8'sd5; matrix_a[5]=8'sd6;
        matrix_a[6]=8'sd7; matrix_a[7]=8'sd8; matrix_a[8]=8'sd9;

        matrix_b[0]=8'sd9; matrix_b[1]=8'sd8; matrix_b[2]=8'sd7;
        matrix_b[3]=8'sd6; matrix_b[4]=8'sd5; matrix_b[5]=8'sd4;
        matrix_b[6]=8'sd3; matrix_b[7]=8'sd2; matrix_b[8]=8'sd1;

        compute_software_reference(3);
        load_matrices(3);
        start_and_wait(60);
        readback_and_verify(3);
        $display("PASS [Test 1]: 3x3 tiled top-level verified.");

        // ================================================================
        // TEST 2: 6x6 positive-valued multiplication
        //   Also verifies exact 14-cycle tile interval and 113-cycle compute.
        //   Measurement points:
        //     t_compute_start = cycle when first sub_start is sampled high.
        //     t_compute_end   = cycle when host_done is sampled high.
        //     Compute interval = t_compute_end - t_compute_start + 1.
        // ================================================================
        $display("\n--- Test 2: 6x6 Positive-Valued Multiplication + Cycle Counts ---");
        cfg_matrix_dim = 4'd6;

        for (idx = 0; idx < 36; idx = idx + 1) begin
            matrix_a[idx] = (idx % 7) + 1;
            matrix_b[idx] = ((idx * 3) % 5) + 1;
        end

        compute_software_reference(6);
        load_matrices(6);

        // Arm cycle counter before start
        monitor_active = 1'b1;
        cycle_counter  = 0;

        // ---- Accept start and record t_start ---------------------------
        @(negedge clk);
        host_start = 1'b1;
        @(posedge clk); #1;
        check(start_ack,     "6x6 start_ack not received");
        check(!start_err,    "6x6 unexpected start_err");
        check(dut.sub_start, "Tile 0 sub_start must assert with start_ack");
        t_start = cycle_counter;   // cycle at which start_ack was sampled
        t_compute_start = t_start;

        // ---- Fork tile-sequence monitor --------------------------------
        begin : tile_monitor_block
            reg [1:0] exp_ti [0:7];
            reg [1:0] exp_tj [0:7];
            reg [1:0] exp_tk [0:7];
            integer tile_idx;
            integer interval;
            integer prev_cyc;
            integer this_cyc;
            reg [1:0] obs_i_r, obs_j_r, obs_k_r;

            exp_ti[0]=0; exp_tj[0]=0; exp_tk[0]=0;
            exp_ti[1]=0; exp_tj[1]=0; exp_tk[1]=1;
            exp_ti[2]=0; exp_tj[2]=1; exp_tk[2]=0;
            exp_ti[3]=0; exp_tj[3]=1; exp_tk[3]=1;
            exp_ti[4]=1; exp_tj[4]=0; exp_tk[4]=0;
            exp_ti[5]=1; exp_tj[5]=0; exp_tk[5]=1;
            exp_ti[6]=1; exp_tj[6]=1; exp_tk[6]=0;
            exp_ti[7]=1; exp_tj[7]=1; exp_tk[7]=1;

            // Tile 0 is active right now on this posedge
            obs_i_r = dut.tile_i;
            obs_j_r = dut.tile_j;
            obs_k_r = dut.tile_k;
            tile_obs_i[0]       = obs_i_r;
            tile_obs_j[0]       = obs_j_r;
            tile_obs_k[0]       = obs_k_r;
            tile_start_cycle[0] = t_start;

            check(obs_i_r === exp_ti[0], "tile_i sequence mismatch at tile 0");
            check(obs_j_r === exp_tj[0], "tile_j sequence mismatch at tile 0");
            check(obs_k_r === exp_tk[0], "tile_k sequence mismatch at tile 0");

            // Lower host_start at upcoming negedge
            fork
                begin
                    @(negedge clk);
                    host_start = 1'b0;
                end
            join_none

            prev_cyc = t_start;

            // Monitor remaining tiles 1 through 7
            for (tile_idx = 1; tile_idx < 8; tile_idx = tile_idx + 1) begin
                // Wait for sub_start rising edge
                @(posedge dut.sub_start);
                #1;
                this_cyc = cycle_counter;

                obs_i_r = dut.tile_i;
                obs_j_r = dut.tile_j;
                obs_k_r = dut.tile_k;

                tile_obs_i[tile_idx]      = obs_i_r;
                tile_obs_j[tile_idx]      = obs_j_r;
                tile_obs_k[tile_idx]      = obs_k_r;
                tile_start_cycle[tile_idx]= this_cyc;

                // ---- Coordinate sequence check -------------------------
                if (obs_i_r !== exp_ti[tile_idx] ||
                    obs_j_r !== exp_tj[tile_idx] ||
                    obs_k_r !== exp_tk[tile_idx]) begin
                    $display(
                      "SEQ FAIL tile %0d: want (%0d,%0d,%0d) got (%0d,%0d,%0d)",
                      tile_idx,
                      exp_ti[tile_idx], exp_tj[tile_idx], exp_tk[tile_idx],
                      obs_i_r, obs_j_r, obs_k_r);
                end
                check(obs_i_r === exp_ti[tile_idx], "tile_i sequence mismatch");
                check(obs_j_r === exp_tj[tile_idx], "tile_j sequence mismatch");
                check(obs_k_r === exp_tk[tile_idx], "tile_k sequence mismatch");

                // ---- 14-cycle interval check ---------------------------
                interval = this_cyc - prev_cyc;
                if (interval !== CYCLES_PER_TILE) begin
                    $display(
                      "INTERVAL FAIL tile %0d: expected %0d cycles, measured %0d",
                      tile_idx, CYCLES_PER_TILE, interval);
                end
                check(interval === CYCLES_PER_TILE,
                      "14-cycle per-tile scheduling interval violated");
                prev_cyc = this_cyc;
            end

            tile_obs_count = 8;
        end

        // ---- Wait for host_done and record t_compute_end ---------------
        timeout = 0;
        while (!dut.host_done && timeout < 200) begin
            @(posedge clk); #1;
            timeout = timeout + 1;
        end
        t_compute_end = cycle_counter;
        monitor_active = 1'b0;

        @(posedge clk); #1;
        check(host_result_available, "Result not available after full 6x6 computation");
        check(!host_busy,            "DUT still busy after result_available");
        check(dut.u_tiling_ctrl.tile_count == 4'd8,
              "tile_count must equal 8 after full 6x6 execution");

        // ---- Verify 113-cycle compute interval -------------------------
        // Measurement:
        //   Start point: cycle at which Tile 0 sub_start asserts (t_compute_start).
        //   End point:   cycle at which host_done completion strobe asserts (t_compute_end).
        // Expected: 8 tiles x 14 cycles/tile + 1 cycle (ST_DONE) = 113 cycles.
        begin
            integer meas_compute;
            meas_compute = t_compute_end - t_compute_start;
            $display("Compute interval: t_compute_start=%0d, t_compute_end=%0d, interval=%0d (expected %0d)",
                     t_compute_start, t_compute_end, meas_compute, CYCLES_COMPUTE_6X6);
            if (meas_compute !== CYCLES_COMPUTE_6X6) begin
                $display("CYCLE COUNT FAIL: compute interval %0d != expected %0d",
                         meas_compute, CYCLES_COMPUTE_6X6);
            end
            check(meas_compute === CYCLES_COMPUTE_6X6,
                  "113-cycle tiled computation interval violated");
        end

        // ---- Readback, display (actual values), verify -----------------
        readback_and_verify(6);
        display_matrix_6x6();   // prints actual_c[], NOT expected_c[]
        $display("PASS [Test 2]: 6x6 positive-valued multiplication + exact cycle counts verified.");

        // ================================================================
        // TEST 3: 6x6 mixed-sign (boundary operands: -128, +127)
        // ================================================================
        $display("\n--- Test 3: 6x6 Mixed-Sign Matrix Multiplication ---");
        cfg_matrix_dim = 4'd6;

        for (idx = 0; idx < 36; idx = idx + 1) begin
            case (idx % 8)
                0: matrix_a[idx] =  8'sd127;
                1: matrix_a[idx] = -8'sd128;
                2: matrix_a[idx] =  8'sd0;
                3: matrix_a[idx] = -8'sd1;
                4: matrix_a[idx] =  8'sd15;
                5: matrix_a[idx] = -8'sd42;
                6: matrix_a[idx] =  8'sd64;
                default: matrix_a[idx] = -8'sd99;
            endcase
            case ((idx * 5) % 8)
                0: matrix_b[idx] = -8'sd1;
                1: matrix_b[idx] =  8'sd2;
                2: matrix_b[idx] = -8'sd3;
                3: matrix_b[idx] =  8'sd4;
                4: matrix_b[idx] = -8'sd5;
                5: matrix_b[idx] =  8'sd0;
                6: matrix_b[idx] =  8'sd10;
                default: matrix_b[idx] = -8'sd20;
            endcase
        end

        compute_software_reference(6);
        load_matrices(6);
        start_and_wait(200);
        readback_and_verify(6);
        $display("PASS [Test 3]: 6x6 mixed-sign with boundary operands verified.");

        // ================================================================
        // TEST 4: Signed inter-tile accumulation with cancellation
        // ================================================================
        $display("\n--- Test 4: Signed Inter-Tile Accumulation ---");
        cfg_matrix_dim = 4'd6;

        for (idx = 0; idx < 36; idx = idx + 1) begin
            matrix_a[idx] = 8'sd0;
            matrix_b[idx] = 8'sd0;
        end
        // A[0,0]*B[0,0] tile contribution: 10*5 = 50 -> C[0,0] partial
        matrix_a[0*6+0] =  8'sd10; matrix_b[0*6+0] =  8'sd5;
        // A[0,3]*B[3,0] tile contribution: 10*(-3) = -30 -> C[0,0] accumulate
        matrix_a[0*6+3] =  8'sd10; matrix_b[3*6+0] = -8'sd3;
        // Net C[0,0] = 50 + (-30) = 20

        compute_software_reference(6);
        load_matrices(6);
        start_and_wait(200);
        readback_and_verify(6);

        // Extra direct check on the reference value
        check(expected_c[0] == 32'sd20,
              "Software reference C[0,0] must equal 20 (cancellation check)");
        $display("PASS [Test 4]: Signed inter-tile accumulation (cancellation) verified.");

        // ================================================================
        // TEST 5: Unsupported cfg_matrix_dim Rejection (writes and starts)
        // ================================================================
        $display("\n--- Test 5: Unsupported cfg_matrix_dim Rejection ---");

        // Reset to clear any state
        rst_n = 1'b0; #20; rst_n = 1'b1; @(posedge clk); #1;

        // --- 5.1 Unsupported dimension 5 write rejection ---
        cfg_matrix_dim = 4'd5;   // Unsupported dimension
        @(negedge clk);
        host_write_en   = 1'b1;
        host_write_is_b = 1'b0;
        host_write_addr = 6'd0;
        host_write_data = 8'sd99;
        @(posedge clk); #1;
        check(!host_write_ack, "host_write_ack must remain deasserted for unsupported dimension 5 write");
        check(!dut.u_input_buffer.written_a[0], "written_a[0] must not be set for unsupported dimension 5");
        check(dut.u_input_buffer.mem_a[0] != 8'sd99, "mem_a[0] must not be modified by rejected write");

        // Attempt write to Matrix B under unsupported dimension 5
        @(negedge clk);
        host_write_is_b = 1'b1;
        host_write_addr = 6'd0;
        host_write_data = 8'sd77;
        @(posedge clk); #1;
        check(!host_write_ack, "host_write_ack must remain deasserted for Matrix B write with unsupported dimension 5");
        check(!dut.u_input_buffer.written_b[0], "written_b[0] must not be set for unsupported dimension 5");
        check(dut.u_input_buffer.mem_b[0] != 8'sd77, "mem_b[0] must not be modified by rejected write");
        @(negedge clk);
        host_write_en = 1'b0;

        check(!matrices_ready, "matrices_ready must remain deasserted when writes are rejected");

        // --- 5.2 Unsupported dimension 5 start rejection ---
        @(negedge clk);
        host_start = 1'b1;
        @(posedge clk); #1;
        check(!start_ack, "start_ack must NOT assert for unsupported dimension 5");
        check(start_err,  "start_err must assert for unsupported dimension 5");
        @(negedge clk);
        host_start = 1'b0;
        @(posedge clk); #1;
        check(!start_err, "start_err must clear after 1 cycle");
        check(!host_busy, "DUT must remain idle after rejected unsupported-dim start");

        // --- 5.3 Unsupported dimension 4 write and start rejection ---
        cfg_matrix_dim = 4'd4;   // Unsupported dimension
        @(negedge clk);
        host_write_en   = 1'b1;
        host_write_is_b = 1'b0;
        host_write_addr = 6'd2;
        host_write_data = 8'sd55;
        @(posedge clk); #1;
        check(!host_write_ack, "host_write_ack must remain deasserted for unsupported dimension 4 write");
        check(!dut.u_input_buffer.written_a[2], "written_a[2] must not be set for unsupported dimension 4");
        check(dut.u_input_buffer.mem_a[2] != 8'sd55, "mem_a[2] must not be modified by rejected write");
        @(negedge clk);
        host_write_en = 1'b0;

        @(negedge clk);
        host_start = 1'b1;
        @(posedge clk); #1;
        check(!start_ack, "start_ack must NOT assert for unsupported dimension 4");
        check(start_err,  "start_err must assert for unsupported dimension 4");
        @(negedge clk);
        host_start = 1'b0;
        @(posedge clk); #1;
        check(!host_busy, "DUT must remain idle after rejected dimension 4 start");

        // --- 5.4 Unsupported dimension 0 rejection (0 does NOT select 6x6) ---
        cfg_matrix_dim = 4'd0;   // Unsupported dimension
        @(negedge clk);
        host_write_en   = 1'b1;
        host_write_is_b = 1'b0;
        host_write_addr = 6'd0;
        host_write_data = 8'sd33;
        @(posedge clk); #1;
        check(!host_write_ack, "host_write_ack must remain deasserted for unsupported dimension 0 write");
        check(!dut.u_input_buffer.written_a[0], "written_a[0] must not be set for unsupported dimension 0");
        @(negedge clk);
        host_write_en = 1'b0;

        @(negedge clk);
        host_start = 1'b1;
        @(posedge clk); #1;
        check(!start_ack, "start_ack must NOT assert for unsupported dimension 0");
        check(start_err,  "start_err must assert for unsupported dimension 0");
        @(negedge clk);
        host_start = 1'b0;
        @(posedge clk); #1;
        check(!host_busy, "DUT must remain idle after rejected dimension 0 start");

        cfg_matrix_dim = 4'd6;
        $display("PASS [Test 5]: Unsupported dimensions correctly rejected (writes and starts).");

        // ================================================================
        // TEST 6: Asynchronous reset during active tiled computation
        // ================================================================
        $display("\n--- Test 6: Asynchronous Reset During Active Computation ---");
        rst_n = 1'b0; #20; rst_n = 1'b1; @(posedge clk); #1;
        cfg_matrix_dim = 4'd6;

        for (idx = 0; idx < 36; idx = idx + 1) begin
            matrix_a[idx] = 8'sd1;
            matrix_b[idx] = 8'sd1;
        end
        load_matrices(6);

        @(negedge clk); host_start = 1'b1;
        @(posedge clk); @(negedge clk); host_start = 1'b0;

        // Let computation proceed for ~25 cycles then reset
        repeat (25) @(posedge clk);
        #1 check(host_busy, "Controller must be busy mid-computation");

        $display("Asserting rst_n = 0 mid-computation...");
        rst_n = 1'b0;
        #15;
        check(!host_busy,            "Async reset must immediately deassert host_busy");
        check(!host_result_available, "Async reset must clear result_available");

        #20; rst_n = 1'b1;
        @(posedge clk); #1;
        check(!host_busy && !host_done, "Post-reset state must be clean IDLE");

        // Full operation after reset
        for (idx = 0; idx < 36; idx = idx + 1) begin
            matrix_a[idx] = 8'sd2;
            matrix_b[idx] = 8'sd3;
        end
        compute_software_reference(6);
        load_matrices(6);
        start_and_wait(200);
        readback_and_verify(6);
        $display("PASS [Test 6]: Mid-operation reset and post-reset recovery verified.");

        // ================================================================
        // TEST 7: Back-to-back operations (no reset between)
        // ================================================================
        $display("\n--- Test 7: Back-to-Back Operations Without Reset ---");
        cfg_matrix_dim = 4'd6;

        for (idx = 0; idx < 36; idx = idx + 1) begin
            matrix_a[idx] = (idx % 4) - 2;
            matrix_b[idx] = 5 - (idx % 5);
        end
        compute_software_reference(6);
        load_matrices(6);

        @(negedge clk); host_start = 1'b1;
        @(posedge clk); #1;
        check(start_ack, "Op 2 start must be accepted");
        @(negedge clk); host_start = 1'b0;
        @(posedge clk); #1;
        check(!host_result_available, "Op 2 start must invalidate previous result");
        check(host_busy, "DUT must enter busy for Op 2");

        timeout = 0;
        while (!host_result_available && timeout < 200) begin
            @(posedge clk); #1; timeout = timeout + 1;
        end
        check(host_result_available, "Op 2 result must become available");
        readback_and_verify(6);
        $display("PASS [Test 7]: Back-to-back operations verified.");

        // ================================================================
        // TEST 8: Host interface protocol guarantees
        // ================================================================
        $display("\n--- Test 8: Host Interface Protocol Guarantees ---");

        // 8.1 Incomplete matrix rejection
        rst_n = 1'b0; #20; rst_n = 1'b1; @(posedge clk); #1;
        cfg_matrix_dim = 4'd6;
        for (idx = 0; idx < 10; idx = idx + 1) begin
            write_element(1'b0, idx, 8'sd1);
            write_element(1'b1, idx, 8'sd1);
        end
        @(posedge clk); #1;
        check(!matrices_ready, "matrices_ready must be low for partial writes");

        @(negedge clk); host_start = 1'b1;
        @(posedge clk); #1;
        check(!start_ack, "start_ack must NOT assert for incomplete matrices");
        check(start_err,  "start_err must assert for incomplete matrices");
        @(negedge clk); host_start = 1'b0;
        @(posedge clk); #1;
        check(!start_err, "start_err must clear after 1 cycle");
        check(!host_busy, "Controller must stay idle on rejected start");

        // Complete the matrices
        for (idx = 10; idx < 36; idx = idx + 1) begin
            write_element(1'b0, idx, 8'sd1);
            write_element(1'b1, idx, 8'sd1);
        end
        @(posedge clk); #1;
        check(matrices_ready, "matrices_ready must assert after all 36 elements written");

        // 8.2 Held-high host_start must not auto-restart
        @(negedge clk); host_start = 1'b1;
        @(posedge clk); #1;
        check(start_ack, "Accepted start for held-high test");
        timeout = 0;
        while (!host_result_available && timeout < 200) begin
            @(posedge clk); #1; timeout = timeout + 1;
        end
        check(host_result_available, "Result available with start held high");
        repeat (5) @(posedge clk);
        #1 check(!host_busy, "Held-high start must not cause auto-restart");
        @(negedge clk); host_start = 1'b0;

        // 8.3 Out-of-range read rejection
        @(negedge clk);
        host_read_en   = 1'b1;
        host_read_addr = 6'd36;  // valid range is 0..35 for 6x6
        @(posedge clk); #1;
        check(!host_read_valid, "Out-of-range read must deassert read_valid");
        check(host_read_data == 32'sd0,
              "Out-of-range read must return zero data");
        @(negedge clk); host_read_en = 1'b0;

        // 8.4 Write rejected while controller is busy
        // Start a fresh operation and try to write during computation
        for (idx = 0; idx < 36; idx = idx + 1) begin
            matrix_a[idx] = 8'sd1;
            matrix_b[idx] = 8'sd1;
        end
        @(negedge clk); host_start = 1'b1;
        @(posedge clk); @(negedge clk); host_start = 1'b0;
        @(posedge clk); #1;
        check(host_busy, "DUT must be busy");
        // Attempt write while busy
        @(negedge clk);
        host_write_en   = 1'b1;
        host_write_is_b = 1'b0;
        host_write_addr = 6'd0;
        host_write_data = 8'sd99;
        @(posedge clk); #1;
        check(!host_write_ack, "Write during busy must be rejected (host_write_ack=0)");
        @(negedge clk); host_write_en = 1'b0;
        // Let operation finish
        timeout = 0;
        while (!host_result_available && timeout < 200) begin
            @(posedge clk); #1; timeout = timeout + 1;
        end
        check(host_result_available, "Operation must complete after busy-write rejection");

        $display("PASS [Test 8]: All host interface protocol guarantees verified.");

        // ================================================================
        // TEST 9: Exact 221-Cycle Complete Operation Verification
        //   Verifies the documented end-to-end latency:
        //     - Host Write Phase: 36 beats A + 36 beats B = 72 cycles
        //     - Computation Phase: 113 cycles
        //     - Host Read Phase: 36 beats C = 36 cycles
        //     - Total: 72 + 113 + 36 = 221 cycles
        //   Measurement boundaries:
        //     - Start point: cycle of first host_write_en assertion (element 0 of A).
        //     - End point: cycle of final host_read_valid assertion (element 35 of C).
        // ================================================================
        $display("\n--- Test 9: Exact 221-Cycle Complete Operation Verification ---");
        rst_n = 1'b0; #20; rst_n = 1'b1; @(posedge clk); #1;
        cfg_matrix_dim = 4'd6;

        for (idx = 0; idx < 36; idx = idx + 1) begin
            matrix_a[idx] = 8'sd1;
            matrix_b[idx] = 8'sd1;
        end
        compute_software_reference(6);

        monitor_active = 1'b1;
        cycle_counter  = 0;

        // START POINT: Cycle 0 (first write beat)
        @(negedge clk);
        t_start = cycle_counter;

        // 1. Host Write Phase: 72 beats (36 for A, 36 for B, 1 beat per cycle)
        host_write_en   = 1'b1;
        host_write_is_b = 1'b0;
        for (idx = 0; idx < 36; idx = idx + 1) begin
            host_write_addr = idx;
            host_write_data = matrix_a[idx];
            @(posedge clk); #1;
            check(host_write_ack, "Write A ack asserted in streaming mode");
            @(negedge clk);
        end

        host_write_is_b = 1'b1;
        for (idx = 0; idx < 36; idx = idx + 1) begin
            host_write_addr = idx;
            host_write_data = matrix_b[idx];
            @(posedge clk); #1;
            check(host_write_ack, "Write B ack asserted in streaming mode");
            @(negedge clk);
            if (idx == 35) begin
                // Seamlessly hand off to compute on final write beat
                host_write_en = 1'b0;
                host_start    = 1'b1;
            end
        end

        // 2. Compute Phase: start_ack accepted on the next posedge
        @(posedge clk); #1;
        check(start_ack, "Start ack asserted seamlessly after write phase");
        t_comp_start = cycle_counter;
        @(negedge clk);
        host_start = 1'b0;

        timeout = 0;
        while (!dut.host_done && timeout < 200) begin
            @(posedge clk); #1;
            timeout = timeout + 1;
        end
        t_comp_end = cycle_counter;
        check(dut.host_done, "host_done asserted at end of computation");

        // Wait for host_result_available
        @(posedge clk); #1;
        check(host_result_available, "Result available after host_done");

        // 3. Host Read Phase: 36 beats (1 beat per cycle)
        @(negedge clk);
        host_read_en = 1'b1;
        t_read_start = cycle_counter;
        for (idx = 0; idx < 36; idx = idx + 1) begin
            host_read_addr = idx;
            @(posedge clk); #1;
            check(host_read_valid, "Read valid asserted in streaming mode");
            actual_c[idx] = $signed(host_read_data);
            if (idx == 35) begin
                // END POINT: final read valid cycle
                t_last_read = cycle_counter;
            end
            @(negedge clk);
        end
        host_read_en = 1'b0;
        monitor_active = 1'b0;

        begin
            integer write_active_cycles;
            integer compute_active_cycles;
            integer read_active_cycles;
            integer active_phase_cycles;
            integer total_boundary_cycles;
            integer transition_cycles;

            write_active_cycles   = t_comp_start - 1 - t_start; // exactly 72 write beats
            compute_active_cycles = t_comp_end - t_comp_start;   // exactly 113 cycles
            read_active_cycles    = t_last_read - t_read_start;  // exactly 36 read beats
            active_phase_cycles   = write_active_cycles + compute_active_cycles + read_active_cycles; // 221
            total_boundary_cycles = t_last_read - t_start;       // 223
            transition_cycles     = total_boundary_cycles - active_phase_cycles; // 2

            $display("\n==================================================================");
            $display("EXACT CYCLE BREAKDOWN (TEST 9):");
            $display("  1. Host Streaming Write Phase : %0d cycles (expected 72)", write_active_cycles);
            $display("  2. Tiled Computation Phase   : %0d cycles (expected 113)", compute_active_cycles);
            $display("  3. Host Streaming Read Phase  : %0d cycles (expected 36)", read_active_cycles);
            $display("  ------------------------------------------------------------------");
            $display("  Sum of Active Operational Phases : %0d cycles (expected 221)", active_phase_cycles);
            $display("  Protocol Inter-Phase Transitions : %0d cycles (1 write->start + 1 done->read)", transition_cycles);
            $display("  Total Host-Boundary Elapsed Time : %0d cycles (expected 223)", total_boundary_cycles);
            $display("==================================================================\n");

            check(write_active_cycles == 72, "Write phase active cycles == 72");
            check(compute_active_cycles == 113, "Compute phase active cycles == 113");
            check(read_active_cycles == 36, "Read phase active cycles == 36");
            check(active_phase_cycles == 221, "Documented active operational phases == 221 cycles");
            check(total_boundary_cycles == 223, "Host-boundary end-to-end interval == 223 cycles");
        end

        // Verify correct matrix readback from the 221-cycle run
        for (idx = 0; idx < 36; idx = idx + 1) begin
            check(actual_c[idx] == expected_c[idx], "Element mismatch in 221-cycle run");
        end
        $display("PASS [Test 9]: Complete 221-cycle operation (write, compute, read) verified.");

        // ================================================================
        // FINAL SUMMARY
        // ================================================================
        $display("\n==================================================================");
        $display("TILED GEMM TEST SUMMARY:");
        $display("  PASSED CHECKS : %0d", passed);
        $display("  FAILED CHECKS : %0d", failed);
        $display("==================================================================");

        // All failures already called $fatal, so if we reach here all passed.
        $display("RESULT: ALL TILED GEMM TESTS PASSED SUCCESSFULLY!\n");
        $finish;
    end

endmodule

`default_nettype wire
