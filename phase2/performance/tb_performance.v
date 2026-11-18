// tb_performance.v
// Phase II Task 2: Performance Measurement and Throughput Analysis Testbench
//
// Project: Systolic Array Matrix Multiplication Accelerator
// Evaluates:
//   1. 3x3 standalone output-stationary systolic accelerator (rtl/top_module.v)
//   2. 3x3 single-tile execution on tiled accelerator (phase2/scalability/tiled_gemm_top.v)
//   3. 6x6 multi-tile execution on tiled accelerator (phase2/scalability/tiled_gemm_top.v)
//
// Measures:
//   - Input matrix loading cycles (host write streaming)
//   - Computation latency (accepted host_start to host_done)
//   - Output result readback cycles (host read streaming)
//   - Active phase execution cycles (sum of active phases)
//   - End-to-end boundary latency (first write beat to final read valid)
//
// Verifies:
//   - Correctness against independent software reference calculations
//   - Positive and mixed-sign boundary operand sets
//   - Zero-variance determinism across repeated back-to-back runs
//   - Watchdog timeout protection against incomplete operations

`timescale 1ns / 1ps
`default_nettype none

module tb_performance;

    // Common Accelerator Parameters
    localparam integer ARRAY_SIZE      = 3;
    localparam integer DATA_WIDTH      = 8;
    localparam integer ACC_WIDTH       = 32;
    localparam integer MAX_MATRIX_SIZE = 6;
    localparam integer ADDR_W_3X3      = 4; // $clog2(9) = 4
    localparam integer ADDR_W_TILED    = 6; // $clog2(36) = 6

    // Clock and Reset
    reg clk;
    reg rst_n;

    // 100 MHz reference clock (10 ns period: 5 ns high, 5 ns low)
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Simulation cycle counter
    reg [31:0] cycle_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            cycle_cnt <= 32'd0;
        else
            cycle_cnt <= cycle_cnt + 32'd1;
    end

    // -------------------------------------------------------------
    // Interface Signals: 3x3 Standalone Accelerator (top_module)
    // -------------------------------------------------------------
    reg                         top3_start;
    wire                        top3_ready;
    wire                        top3_busy;
    wire                        top3_done;
    wire                        top3_start_ack;
    wire                        top3_start_err;

    reg                         top3_write_en;
    reg                         top3_write_is_b;
    reg  [ADDR_W_3X3-1:0]       top3_write_addr;
    reg  signed [DATA_WIDTH-1:0] top3_write_data;
    wire                        top3_write_ack;
    wire                        top3_matrices_ready;

    reg                         top3_read_en;
    reg  [ADDR_W_3X3-1:0]       top3_read_addr;
    wire signed [ACC_WIDTH-1:0] top3_read_data;
    wire                        top3_read_valid;
    wire                        top3_result_available;

    // -------------------------------------------------------------
    // Interface Signals: Tiled Accelerator (tiled_gemm_top)
    // -------------------------------------------------------------
    reg  [3:0]                  tiled_cfg_dim;
    reg                         tiled_start;
    wire                        tiled_ready;
    wire                        tiled_busy;
    wire                        tiled_done;
    wire                        tiled_start_ack;
    wire                        tiled_start_err;

    reg                         tiled_write_en;
    reg                         tiled_write_is_b;
    reg  [ADDR_W_TILED-1:0]     tiled_write_addr;
    reg  signed [DATA_WIDTH-1:0] tiled_write_data;
    wire                        tiled_write_ack;
    wire                        tiled_matrices_ready;

    reg                         tiled_read_en;
    reg  [ADDR_W_TILED-1:0]     tiled_read_addr;
    wire signed [ACC_WIDTH-1:0] tiled_read_data;
    wire                        tiled_read_valid;
    wire                        tiled_result_available;

    // -------------------------------------------------------------
    // DUT Instantiations
    // -------------------------------------------------------------
    // 1. Phase I 3x3 Standalone Accelerator Core
    top_module #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH),
        .ADDR_WIDTH(ADDR_W_3X3)
    ) u_top_3x3 (
        .clk                  (clk),
        .rst_n                (rst_n),
        .host_start           (top3_start),
        .host_ready           (top3_ready),
        .host_busy            (top3_busy),
        .host_done            (top3_done),
        .start_ack            (top3_start_ack),
        .start_err            (top3_start_err),
        .host_write_en        (top3_write_en),
        .host_write_is_b      (top3_write_is_b),
        .host_write_addr      (top3_write_addr),
        .host_write_data      (top3_write_data),
        .host_write_ack       (top3_write_ack),
        .matrices_ready       (top3_matrices_ready),
        .host_read_en         (top3_read_en),
        .host_read_addr       (top3_read_addr),
        .host_read_data       (top3_read_data),
        .host_read_valid      (top3_read_valid),
        .host_result_available(top3_result_available)
    );

    // 2. Phase II Tiled Accelerator Core (3x3 and 6x6)
    tiled_gemm_top #(
        .ARRAY_SIZE     (ARRAY_SIZE),
        .MAX_MATRIX_SIZE(MAX_MATRIX_SIZE),
        .DATA_WIDTH     (DATA_WIDTH),
        .ACC_WIDTH      (ACC_WIDTH),
        .ADDR_WIDTH     (ADDR_W_TILED)
    ) u_tiled_top (
        .clk                  (clk),
        .rst_n                (rst_n),
        .cfg_matrix_dim       (tiled_cfg_dim),
        .host_start           (tiled_start),
        .host_ready           (tiled_ready),
        .host_busy            (tiled_busy),
        .host_done            (tiled_done),
        .start_ack            (tiled_start_ack),
        .start_err            (tiled_start_err),
        .host_write_en        (tiled_write_en),
        .host_write_is_b      (tiled_write_is_b),
        .host_write_addr      (tiled_write_addr),
        .host_write_data      (tiled_write_data),
        .host_write_ack       (tiled_write_ack),
        .matrices_ready       (tiled_matrices_ready),
        .host_read_en         (tiled_read_en),
        .host_read_addr       (tiled_read_addr),
        .host_read_data       (tiled_read_data),
        .host_read_valid      (tiled_read_valid),
        .host_result_available(tiled_result_available)
    );

    // -------------------------------------------------------------
    // Test Tracking and Verification Data Structures
    // -------------------------------------------------------------
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_suite = 0;

    // Golden reference memories
    reg signed [DATA_WIDTH-1:0] mem_a_3x3 [0:8];
    reg signed [DATA_WIDTH-1:0] mem_b_3x3 [0:8];
    reg signed [ACC_WIDTH-1:0]  gold_c_3x3 [0:8];
    reg signed [ACC_WIDTH-1:0]  act_c_3x3  [0:8];

    reg signed [DATA_WIDTH-1:0] mem_a_6x6 [0:35];
    reg signed [DATA_WIDTH-1:0] mem_b_6x6 [0:35];
    reg signed [ACC_WIDTH-1:0]  gold_c_6x6 [0:35];
    reg signed [ACC_WIDTH-1:0]  act_c_6x6  [0:35];

    // Cycle measurement variables
    integer cyc_write;
    integer cyc_compute;
    integer cyc_read;
    integer cyc_active;
    integer cyc_e2e;
    integer t_mark_start;
    integer t_mark_stop;

    // Metric storage for final summary table
    integer m3_std_write,   m3_std_comp,   m3_std_read,   m3_std_act,   m3_std_e2e;
    integer m3_tile_write,  m3_tile_comp,  m3_tile_read,  m3_tile_act,  m3_tile_e2e;
    integer m6_tile_write,  m6_tile_comp,  m6_tile_read,  m6_tile_act,  m6_tile_e2e;
    integer m6_sign_write,  m6_sign_comp,  m6_sign_read,  m6_sign_act,  m6_sign_e2e;

    // -------------------------------------------------------------
    // Verification & Utility Tasks
    // -------------------------------------------------------------
    task check(input [1023:0] desc, input condition);
        begin
            if (condition) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s", desc);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s at simulation time %0t ps", desc, $time);
                $fatal(1, "Assertion failed: %0s", desc);
            end
        end
    endtask

    // Global reset task
    task reset_all;
        begin
            rst_n <= 1'b0;
            top3_start <= 1'b0;
            top3_write_en <= 1'b0;
            top3_write_is_b <= 1'b0;
            top3_write_addr <= {ADDR_W_3X3{1'b0}};
            top3_write_data <= {DATA_WIDTH{1'b0}};
            top3_read_en <= 1'b0;
            top3_read_addr <= {ADDR_W_3X3{1'b0}};

            tiled_cfg_dim <= 4'd3;
            tiled_start <= 1'b0;
            tiled_write_en <= 1'b0;
            tiled_write_is_b <= 1'b0;
            tiled_write_addr <= {ADDR_W_TILED{1'b0}};
            tiled_write_data <= {DATA_WIDTH{1'b0}};
            tiled_read_en <= 1'b0;
            tiled_read_addr <= {ADDR_W_TILED{1'b0}};

            #30;
            @(posedge clk);
            #1;
            rst_n <= 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    // Compute 3x3 golden reference in software
    task compute_gold_3x3;
        integer r, c, k;
        reg signed [ACC_WIDTH-1:0] sum;
        begin
            for (r = 0; r < 3; r = r + 1) begin
                for (c = 0; c < 3; c = c + 1) begin
                    sum = 32'sd0;
                    for (k = 0; k < 3; k = k + 1) begin
                        sum = sum + (mem_a_3x3[(r * 3) + k] * mem_b_3x3[(k * 3) + c]);
                    end
                    gold_c_3x3[(r * 3) + c] = sum;
                end
            end
        end
    endtask

    // Compute 6x6 golden reference in software
    task compute_gold_6x6;
        integer r, c, k;
        reg signed [ACC_WIDTH-1:0] sum;
        begin
            for (r = 0; r < 6; r = r + 1) begin
                for (c = 0; c < 6; c = c + 1) begin
                    sum = 32'sd0;
                    for (k = 0; k < 6; k = k + 1) begin
                        sum = sum + (mem_a_6x6[(r * 6) + k] * mem_b_6x6[(k * 6) + c]);
                    end
                    gold_c_6x6[(r * 6) + c] = sum;
                end
            end
        end
    endtask

    // -------------------------------------------------------------
    // Measurement Task: 3x3 Standalone Accelerator (top_module)
    // -------------------------------------------------------------
    task run_measure_top3(
        output integer out_write,
        output integer out_comp,
        output integer out_read,
        output integer out_act,
        output integer out_e2e
    );
        integer idx;
        integer t0, t_write_done, t_comp_start, t_comp_done, t_read_start, t_read_done;
        integer timeout;
        begin
            compute_gold_3x3();

            // Wait until idle
            wait(!top3_busy);
            @(posedge clk);
            #1;
            t0 = cycle_cnt;

            // 1. Streaming Write Phase: Matrix A (9 beats) then Matrix B (9 beats)
            for (idx = 0; idx < 9; idx = idx + 1) begin
                top3_write_en   <= 1'b1;
                top3_write_is_b <= 1'b0;
                top3_write_addr <= idx[ADDR_W_3X3-1:0];
                top3_write_data <= mem_a_3x3[idx];
                @(posedge clk);
                #1;
            end
            for (idx = 0; idx < 9; idx = idx + 1) begin
                top3_write_en   <= 1'b1;
                top3_write_is_b <= 1'b1;
                top3_write_addr <= idx[ADDR_W_3X3-1:0];
                top3_write_data <= mem_b_3x3[idx];
                @(posedge clk);
                #1;
            end
            top3_write_en <= 1'b0;
            t_write_done = cycle_cnt;
            out_write = t_write_done - t0;

            check("top3: matrices_ready asserted after 18 write beats", top3_matrices_ready == 1'b1);

            // 2. Launch Computation via host_start
            @(posedge clk);
            #1;
            top3_start <= 1'b1;
            @(posedge clk);
            #1;
            check("top3: start_ack asserted", top3_start_ack == 1'b1);
            t_comp_start = cycle_cnt;
            top3_start <= 1'b0;

            // Wait for completion with watchdog timeout
            timeout = 0;
            while (!top3_done && timeout < 200) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
            end
            check("top3: computation completed within watchdog window", timeout < 200);
            t_comp_done = cycle_cnt;
            out_comp = t_comp_done - t_comp_start;

            @(posedge clk);
            #1;
            check("top3: host_result_available asserted", top3_result_available == 1'b1);

            // 3. Streaming Readback Phase (9 beats)
            t_read_start = cycle_cnt;
            for (idx = 0; idx < 9; idx = idx + 1) begin
                top3_read_en   <= 1'b1;
                top3_read_addr <= idx[ADDR_W_3X3-1:0];
                @(posedge clk);
                #1;
                check("top3: host_read_valid asserted for result beat", top3_read_valid == 1'b1);
                act_c_3x3[idx] = top3_read_data;
            end
            top3_read_en <= 1'b0;
            t_read_done = cycle_cnt;
            out_read = t_read_done - t_read_start;

            out_act = out_write + out_comp + out_read;
            out_e2e = t_read_done - t0;

            // Verify output correctness
            begin : verify_top3
                reg correct;
                integer k;
                correct = 1'b1;
                for (k = 0; k < 9; k = k + 1) begin
                    if (act_c_3x3[k] !== gold_c_3x3[k]) begin
                        $display("  [ERROR] top3 mismatch at [%0d]: actual=%0d, expected=%0d",
                            k, act_c_3x3[k], gold_c_3x3[k]);
                        correct = 1'b0;
                    end
                end
                check("top3: all 9 output matrix elements match golden reference exactly", correct == 1'b1);
            end
        end
    endtask

    // -------------------------------------------------------------
    // Measurement Task: Tiled Accelerator (tiled_gemm_top)
    // -------------------------------------------------------------
    task run_measure_tiled(
        input  integer dim,
        output integer out_write,
        output integer out_comp,
        output integer out_read,
        output integer out_act,
        output integer out_e2e
    );
        integer num_elem;
        integer idx;
        integer t0, t_write_done, t_comp_start, t_comp_done, t_read_start, t_read_done;
        integer timeout;
        begin
            num_elem = dim * dim;
            if (dim == 3) compute_gold_3x3();
            else          compute_gold_6x6();

            // Configure dimension
            tiled_cfg_dim <= dim[3:0];
            wait(!tiled_busy);
            @(posedge clk);
            #1;
            t0 = cycle_cnt;

            // 1. Streaming Write Phase: A (num_elem beats) then B (num_elem beats)
            for (idx = 0; idx < num_elem; idx = idx + 1) begin
                tiled_write_en   <= 1'b1;
                tiled_write_is_b <= 1'b0;
                tiled_write_addr <= idx[ADDR_W_TILED-1:0];
                tiled_write_data <= (dim == 3) ? mem_a_3x3[idx] : mem_a_6x6[idx];
                @(posedge clk);
                #1;
            end
            for (idx = 0; idx < num_elem; idx = idx + 1) begin
                tiled_write_en   <= 1'b1;
                tiled_write_is_b <= 1'b1;
                tiled_write_addr <= idx[ADDR_W_TILED-1:0];
                tiled_write_data <= (dim == 3) ? mem_b_3x3[idx] : mem_b_6x6[idx];
                @(posedge clk);
                #1;
            end
            tiled_write_en <= 1'b0;
            t_write_done = cycle_cnt;
            out_write = t_write_done - t0;

            check("tiled: matrices_ready asserted after loading matrices", tiled_matrices_ready == 1'b1);

            // 2. Launch Computation via host_start
            @(posedge clk);
            #1;
            tiled_start <= 1'b1;
            @(posedge clk);
            #1;
            check("tiled: start_ack asserted", tiled_start_ack == 1'b1);
            t_comp_start = cycle_cnt;
            tiled_start <= 1'b0;

            // Wait for host_done with watchdog timeout
            timeout = 0;
            while (!tiled_done && timeout < 500) begin
                @(posedge clk);
                #1;
                timeout = timeout + 1;
            end
            check("tiled: computation completed within watchdog window", timeout < 500);
            t_comp_done = cycle_cnt;
            out_comp = t_comp_done - t_comp_start;

            @(posedge clk);
            #1;
            check("tiled: host_result_available asserted", tiled_result_available == 1'b1);

            // 3. Streaming Readback Phase (num_elem beats)
            t_read_start = cycle_cnt;
            for (idx = 0; idx < num_elem; idx = idx + 1) begin
                tiled_read_en   <= 1'b1;
                tiled_read_addr <= idx[ADDR_W_TILED-1:0];
                @(posedge clk);
                #1;
                check("tiled: host_read_valid asserted for result beat", tiled_read_valid == 1'b1);
                if (dim == 3) act_c_3x3[idx] = tiled_read_data;
                else          act_c_6x6[idx] = tiled_read_data;
            end
            tiled_read_en <= 1'b0;
            t_read_done = cycle_cnt;
            out_read = t_read_done - t_read_start;

            out_act = out_write + out_comp + out_read;
            out_e2e = t_read_done - t0;

            // Verify output correctness
            begin : verify_tiled
                reg correct;
                integer k;
                correct = 1'b1;
                for (k = 0; k < num_elem; k = k + 1) begin
                    if (dim == 3) begin
                        if (act_c_3x3[k] !== gold_c_3x3[k]) begin
                            $display("  [ERROR] tiled 3x3 mismatch at [%0d]: actual=%0d, expected=%0d",
                                k, act_c_3x3[k], gold_c_3x3[k]);
                            correct = 1'b0;
                        end
                    end else begin
                        if (act_c_6x6[k] !== gold_c_6x6[k]) begin
                            $display("  [ERROR] tiled 6x6 mismatch at [%0d]: actual=%0d, expected=%0d",
                                k, act_c_6x6[k], gold_c_6x6[k]);
                            correct = 1'b0;
                        end
                    end
                end
                check("tiled: all output matrix elements match golden reference exactly", correct == 1'b1);
            end
        end
    endtask

    // -------------------------------------------------------------
    // Main Verification Flow
    // -------------------------------------------------------------
    integer i;

    initial begin
        $dumpfile("build/tb_performance.vcd");
        $dumpvars(0, tb_performance);

        $display("==================================================================");
        $display("Phase II Task 2: Performance Measurement and Throughput Analysis");
        $display("==================================================================");

        // Initialize DUTs
        reset_all();

        // =============================================================
        // Suite 1: Standalone 3x3 Systolic Accelerator (top_module)
        // =============================================================
        test_suite = 1;
        $display("\n--- Suite 1: 3x3 Standalone Systolic Accelerator Performance ---");
        // Initialize 3x3 matrices:
        // A = [1, 2, 3; 4, 5, 6; 7, 8, 9]
        // B = [9, 8, 7; 6, 5, 4; 3, 2, 1]
        for (i = 0; i < 9; i = i + 1) begin
            mem_a_3x3[i] = 8'sd1 + i;
            mem_b_3x3[i] = 8'sd9 - i;
        end

        run_measure_top3(m3_std_write, m3_std_comp, m3_std_read, m3_std_act, m3_std_e2e);

        $display("  [MEASUREMENT] 3x3 Standalone: Loading  = %0d cycles (expected 18)", m3_std_write);
        $display("  [MEASUREMENT] 3x3 Standalone: Compute  = %0d cycles (expected 11)", m3_std_comp);
        $display("  [MEASUREMENT] 3x3 Standalone: Readback = %0d cycles (expected 9)", m3_std_read);
        $display("  [MEASUREMENT] 3x3 Standalone: Active   = %0d cycles (expected 38)", m3_std_act);
        $display("  [MEASUREMENT] 3x3 Standalone: E2E Bnd  = %0d cycles (expected 41)", m3_std_e2e);

        check("top3: loading cycle count matches exact 2*N^2 = 18", m3_std_write == 18);
        check("top3: compute latency matches exact 4*N - 1 = 11", m3_std_comp == 11);
        check("top3: readback cycle count matches exact N^2 = 9", m3_std_read == 9);
        check("top3: active phase sum matches exact 38 cycles", m3_std_act == 38);
        check("top3: end-to-end boundary latency matches exact 41 cycles", m3_std_e2e == 41);

        // =============================================================
        // Suite 2: Tiled 3x3 Single-Tile Accelerator (tiled_gemm_top)
        // =============================================================
        test_suite = 2;
        $display("\n--- Suite 2: 3x3 Tiled Single-Tile Accelerator Performance ---");
        run_measure_tiled(3, m3_tile_write, m3_tile_comp, m3_tile_read, m3_tile_act, m3_tile_e2e);

        $display("  [MEASUREMENT] 3x3 Tiled Top: Loading  = %0d cycles (expected 18)", m3_tile_write);
        $display("  [MEASUREMENT] 3x3 Tiled Top: Compute  = %0d cycles (expected 15)", m3_tile_comp);
        $display("  [MEASUREMENT] 3x3 Tiled Top: Readback = %0d cycles (expected 9)", m3_tile_read);
        $display("  [MEASUREMENT] 3x3 Tiled Top: Active   = %0d cycles (expected 42)", m3_tile_act);
        $display("  [MEASUREMENT] 3x3 Tiled Top: E2E Bnd  = %0d cycles (expected 45)", m3_tile_e2e);

        check("tiled 3x3: loading matches exact 18 cycles", m3_tile_write == 18);
        check("tiled 3x3: compute latency matches 15 cycles (11 array + 4 tiling wrapper)", m3_tile_comp == 15);
        check("tiled 3x3: readback matches exact 9 cycles", m3_tile_read == 9);
        check("tiled 3x3: active phase sum matches exact 42 cycles", m3_tile_act == 42);
        check("tiled 3x3: end-to-end boundary latency matches exact 45 cycles", m3_tile_e2e == 45);

        // =============================================================
        // Suite 3: Tiled 6x6 Accelerator (Positive Values)
        // =============================================================
        test_suite = 3;
        $display("\n--- Suite 3: 6x6 Tiled Accelerator Performance (Positive Values) ---");
        // Matrix initialization (elements 1..36 and 36..1)
        for (i = 0; i < 36; i = i + 1) begin
            mem_a_6x6[i] = 8'sd1 + (i % 7);
            mem_b_6x6[i] = 8'sd7 - (i % 7);
        end

        run_measure_tiled(6, m6_tile_write, m6_tile_comp, m6_tile_read, m6_tile_act, m6_tile_e2e);

        $display("  [MEASUREMENT] 6x6 Tiled: Loading  = %0d cycles (expected 72)", m6_tile_write);
        $display("  [MEASUREMENT] 6x6 Tiled: Compute  = %0d cycles (expected 113)", m6_tile_comp);
        $display("  [MEASUREMENT] 6x6 Tiled: Readback = %0d cycles (expected 36)", m6_tile_read);
        $display("  [MEASUREMENT] 6x6 Tiled: Active   = %0d cycles (expected 221)", m6_tile_act);
        $display("  [MEASUREMENT] 6x6 Tiled: E2E Bnd  = %0d cycles (expected 224)", m6_tile_e2e);

        check("tiled 6x6: loading matches exact 2*M^2 = 72 cycles", m6_tile_write == 72);
        check("tiled 6x6: compute latency matches exact 113 cycles (8 tiles * 14 + 1)", m6_tile_comp == 113);
        check("tiled 6x6: readback matches exact M^2 = 36 cycles", m6_tile_read == 36);
        check("tiled 6x6: active phase sum matches exact 221 cycles", m6_tile_act == 221);
        check("tiled 6x6: end-to-end boundary latency matches exact 224 cycles", m6_tile_e2e == 224);

        // =============================================================
        // Suite 4: Tiled 6x6 Accelerator (Mixed-Sign Boundary Operands)
        // =============================================================
        test_suite = 4;
        $display("\n--- Suite 4: 6x6 Tiled Performance with Mixed-Sign Values ---");
        // Full range signed boundary values: -128, +127, -1, 0, +1, etc.
        for (i = 0; i < 36; i = i + 1) begin
            case (i % 6)
                0: begin mem_a_6x6[i] = -8'sd128; mem_b_6x6[i] =  8'sd1;   end
                1: begin mem_a_6x6[i] =  8'sd127; mem_b_6x6[i] = -8'sd1;   end
                2: begin mem_a_6x6[i] = -8'sd1;   mem_b_6x6[i] =  8'sd127; end
                3: begin mem_a_6x6[i] =  8'sd0;   mem_b_6x6[i] = -8'sd128; end
                4: begin mem_a_6x6[i] =  8'sd64;  mem_b_6x6[i] = -8'sd2;   end
                5: begin mem_a_6x6[i] = -8'sd75;  mem_b_6x6[i] =  8'sd3;   end
            endcase
        end

        run_measure_tiled(6, m6_sign_write, m6_sign_comp, m6_sign_read, m6_sign_act, m6_sign_e2e);

        $display("  [MEASUREMENT] 6x6 Mixed-Sign: Loading  = %0d cycles (expected 72)", m6_sign_write);
        $display("  [MEASUREMENT] 6x6 Mixed-Sign: Compute  = %0d cycles (expected 113)", m6_sign_comp);
        $display("  [MEASUREMENT] 6x6 Mixed-Sign: Readback = %0d cycles (expected 36)", m6_sign_read);
        $display("  [MEASUREMENT] 6x6 Mixed-Sign: Active   = %0d cycles (expected 221)", m6_sign_act);
        $display("  [MEASUREMENT] 6x6 Mixed-Sign: E2E Bnd  = %0d cycles (expected 224)", m6_sign_e2e);

        check("tiled 6x6 signed: loading is strictly data-independent (72 cycles)", m6_sign_write == 72);
        check("tiled 6x6 signed: compute latency is strictly data-independent (113 cycles)", m6_sign_comp == 113);
        check("tiled 6x6 signed: readback is strictly data-independent (36 cycles)", m6_sign_read == 36);
        check("tiled 6x6 signed: active sum is 221 cycles", m6_sign_act == 221);
        check("tiled 6x6 signed: end-to-end boundary latency is 224 cycles", m6_sign_e2e == 224);

        // =============================================================
        // Suite 5: Determinism and Consistency across Repeated Runs
        // =============================================================
        test_suite = 5;
        $display("\n--- Suite 5: Determinism & Zero-Variance Consistency ---");
        begin : check_determinism
            integer r2_write, r2_comp, r2_read, r2_act, r2_e2e;
            integer r3_write, r3_comp, r3_read, r3_act, r3_e2e;

            // Run 2 of 3x3 standalone
            run_measure_top3(r2_write, r2_comp, r2_read, r2_act, r2_e2e);
            check("top3 run 2 matches run 1 compute cycles exactly (zero jitter)", r2_comp == m3_std_comp);
            check("top3 run 2 matches run 1 E2E cycles exactly (zero jitter)", r2_e2e == m3_std_e2e);

            // Run 3 of 6x6 tiled
            run_measure_tiled(6, r3_write, r3_comp, r3_read, r3_act, r3_e2e);
            check("tiled 6x6 run 3 matches run 1 compute cycles exactly (zero jitter)", r3_comp == m6_tile_comp);
            check("tiled 6x6 run 3 matches run 1 E2E cycles exactly (zero jitter)", r3_e2e == m6_tile_e2e);
        end

        // =============================================================
        // Suite 6: Watchdog Timeout & Protocol Protection
        // =============================================================
        test_suite = 6;
        $display("\n--- Suite 6: Watchdog Timeout & Rejection Checks ---");
        begin : check_timeout_rejection
            // 1. Verify unsupported dimension rejects cleanly without launching operations
            tiled_cfg_dim <= 4'd5; // unsupported
            @(posedge clk);
            #1;
            tiled_start <= 1'b1;
            @(posedge clk);
            #1;
            check("tiled: unsupported dim 5 asserts start_err", tiled_start_err == 1'b1);
            check("tiled: unsupported dim 5 deasserts start_ack", tiled_start_ack == 1'b0);
            tiled_start <= 1'b0;
            @(posedge clk);
            #1;
            check("tiled: controller remained idle (busy=0)", tiled_busy == 1'b0);
        end

        // =============================================================
        // Summary Performance Table Display
        // =============================================================
        $display("\n==========================================================================================");
        $display("PERFORMANCE MEASUREMENT AND THROUGHPUT ANALYSIS SUMMARY");
        $display("==========================================================================================");
        $display("Measurement Assumptions & Reference Parameters:");
        $display("  - Physical Array Size (N)       : %0d x %0d physical Processing Elements", ARRAY_SIZE, ARRAY_SIZE);
        $display("  - Reference Clock Frequency     : 100.0 MHz (Period = 10.0 ns)");
        $display("  - Arithmetic Precision          : 8-bit signed two's-complement operands, 32-bit accumulators");
        $display("------------------------------------------------------------------------------------------");
        $display("%-28s | %-16s | %-16s | %-16s", "Metric", "3x3 Standalone", "3x3 Tiled Top", "6x6 Tiled Top");
        $display("------------------------------------------------------------------------------------------");
        $display("%-28s | %-16s | %-16s | %-16s", "Matrix Dimension (M x M)", "3 x 3", "3 x 3", "6 x 6");
        $display("%-28s | %-16d | %-16d | %-16d", "Total Elements per Matrix", 9, 9, 36);
        $display("%-28s | %-16d | %-16d | %-16d", "Total Scalar Multiplications", 27, 27, 216);
        $display("%-28s | %-16d | %-16d | %-16d", "Total MAC Operations", 27, 27, 216);
        $display("%-28s | %-16d | %-16d | %-16d", "Number of Tile Operations", 1, 1, 8);
        $display("------------------------------------------------------------------------------------------");
        $display("%-28s | %-16d | %-16d | %-16d", "Input Loading (cycles)", m3_std_write, m3_tile_write, m6_tile_write);
        $display("%-28s | %-16d | %-16d | %-16d", "Compute Latency (cycles)", m3_std_comp, m3_tile_comp, m6_tile_comp);
        $display("%-28s | %-16d | %-16d | %-16d", "Output Readback (cycles)", m3_std_read, m3_tile_read, m6_tile_read);
        $display("%-28s | %-16d | %-16d | %-16d", "Active Phase Sum (cycles)", m3_std_act, m3_tile_act, m6_tile_act);
        $display("%-28s | %-16d | %-16d | %-16d", "End-to-End Elapsed (cycles)", m3_std_e2e, m3_tile_e2e, m6_tile_e2e);
        $display("------------------------------------------------------------------------------------------");
        $display("%-28s | %-16.4f | %-16.4f | %-16.4f", "Compute MACs / cycle",
            27.0 / m3_std_comp, 27.0 / m3_tile_comp, 216.0 / m6_tile_comp);
        $display("%-28s | %-16.4f | %-16.4f | %-16.4f", "Active MACs / cycle",
            27.0 / m3_std_act, 27.0 / m3_tile_act, 216.0 / m6_tile_act);
        $display("%-28s | %-16.4f | %-16.4f | %-16.4f", "End-to-End MACs / cycle",
            27.0 / m3_std_e2e, 27.0 / m3_tile_e2e, 216.0 / m6_tile_e2e);
        $display("------------------------------------------------------------------------------------------");
        $display("%-28s | %-16.2f | %-16.2f | %-16.2f", "Compute Throughput (MMAC/s)",
            (27.0 / m3_std_comp) * 100.0, (27.0 / m3_tile_comp) * 100.0, (216.0 / m6_tile_comp) * 100.0);
        $display("%-28s | %-16.2f | %-16.2f | %-16.2f", "E2E Throughput (MMAC/s)",
            (27.0 / m3_std_e2e) * 100.0, (27.0 / m3_tile_e2e) * 100.0, (216.0 / m6_tile_e2e) * 100.0);
        $display("------------------------------------------------------------------------------------------");
        $display("%-28s | %-16.2f%%| %-16.2f%%| %-16.2f%%", "Compute PE Utilisation",
            (27.0 / (9.0 * m3_std_comp)) * 100.0, (27.0 / (9.0 * m3_tile_comp)) * 100.0, (216.0 / (9.0 * m6_tile_comp)) * 100.0);
        $display("%-28s | %-16.2f%%| %-16.2f%%| %-16.2f%%", "Active PE Utilisation",
            (27.0 / (9.0 * m3_std_act)) * 100.0, (27.0 / (9.0 * m3_tile_act)) * 100.0, (216.0 / (9.0 * m6_tile_act)) * 100.0);
        $display("%-28s | %-16.2f%%| %-16.2f%%| %-16.2f%%", "End-to-End PE Utilisation",
            (27.0 / (9.0 * m3_std_e2e)) * 100.0, (27.0 / (9.0 * m3_tile_e2e)) * 100.0, (216.0 / (9.0 * m6_tile_e2e)) * 100.0);
        $display("------------------------------------------------------------------------------------------");
        $display("%-28s | %-16s | %-16s | %-16s", "Sequential Baseline Speedup",
            "Pending (Sep Task)", "Pending (Sep Task)", "Pending (Sep Task)");
        $display("==========================================================================================\n");

        $display("==================================================================");
        $display("PERFORMANCE VERIFICATION SUMMARY:");
        $display("  PASSED CHECKS : %0d", pass_count);
        $display("  FAILED CHECKS : %0d", fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("RESULT: ALL PERFORMANCE TESTS AND MEASUREMENTS PASSED!\n");
            $finish;
        end else begin
            $display("RESULT: PERFORMANCE VERIFICATION FAILED WITH %0d ERRORS!\n", fail_count);
            $fatal(1, "Performance verification testbench failed.");
        end
    end

endmodule

`default_nettype wire
