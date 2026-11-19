// ============================================================================
// File: tb_phase2_top.v
// Module: tb_phase2_top
// Description: Comprehensive End-to-End System Integration Testbench for Phase 2
//              Systolic Array Accelerator with High-Bandwidth Burst Host Interface.
//
// Test Coverage:
//   1. System Reset & Idle Verification
//   2. 3x3 Matrix Multiplication (Streaming Burst Mode) with Golden SW Model
//   3. 6x6 Tiled Matrix Multiplication (Packed 32-bit Mode) with Golden SW Model
//   4. 6x6 Tiled GEMM with Extreme Signed Boundary Operands (-128, +127, -1, 0, 1)
//   5. Back-to-Back Operations without Reset (out_buf_clear validation)
//   6. Error Rejection & Protocol Robustness (busy write, start before ready, bad dim)
//   7. Asynchronous Reset Mid-Compute & Clean System Recovery
//   8. 6x6 Result Readback with Host Backpressure Handshaking
// ============================================================================

`timescale 1ns / 1ps
`default_nettype none

module tb_phase2_top;

    // Simulation Parameters
    localparam integer ARRAY_SIZE       = 3;
    localparam integer MAX_MATRIX_SIZE  = 6;
    localparam integer DATA_WIDTH       = 8;
    localparam integer ACC_WIDTH        = 32;
    localparam integer WORDS_PER_BEAT   = 4;
    localparam integer BUS_DATA_WIDTH   = DATA_WIDTH * WORDS_PER_BEAT;
    localparam integer MAX_ELEMENTS     = MAX_MATRIX_SIZE * MAX_MATRIX_SIZE;
    localparam integer ADDR_WIDTH       = 6;
    localparam integer BURST_LEN_WIDTH  = 7;

    localparam CLK_PERIOD = 10; // 100 MHz clock

    // DUT Signals
    reg                               clk;
    reg                               rst_n;
    reg  [3:0]                        cfg_matrix_dim;

    // Burst Write Interface
    reg                               burst_write_req;
    reg                               burst_write_is_b;
    reg  [ADDR_WIDTH-1:0]             burst_write_addr;
    reg  [BURST_LEN_WIDTH-1:0]        burst_write_len;
    reg                               burst_write_packed;
    reg                               burst_write_valid;
    wire                              burst_write_ready;
    reg  [BUS_DATA_WIDTH-1:0]         burst_write_data;
    wire                              burst_write_ack;
    wire                              burst_write_done;
    wire                              burst_write_err;
    wire [2:0]                        burst_err_code;

    // Accelerator Control & Status
    reg                               host_start;
    wire                              host_ready;
    wire                              host_busy;
    wire                              host_done;
    wire                              start_ack;
    wire                              start_err;
    wire                              matrices_ready;
    wire                              host_result_available;

    // Burst Readback Interface
    reg                               burst_read_req;
    reg  [ADDR_WIDTH-1:0]             burst_read_addr;
    reg  [BURST_LEN_WIDTH-1:0]        burst_read_len;
    reg                               burst_read_ready;
    wire                              burst_read_valid;
    wire signed [ACC_WIDTH-1:0]       burst_read_data;
    wire                              burst_read_done;
    wire                              burst_read_err;

    // Testbench Statistics & Golden Arrays
    integer pass_count;
    integer fail_count;
    integer k, idx;

    reg signed [DATA_WIDTH-1:0] test_a [0:MAX_ELEMENTS-1];
    reg signed [DATA_WIDTH-1:0] test_b [0:MAX_ELEMENTS-1];
    reg signed [ACC_WIDTH-1:0]  golden_c [0:MAX_ELEMENTS-1];
    reg signed [ACC_WIDTH-1:0]  actual_c [0:MAX_ELEMENTS-1];

    // DUT Instantiation
    phase2_top_module #(
        .ARRAY_SIZE      (ARRAY_SIZE),
        .MAX_MATRIX_SIZE (MAX_MATRIX_SIZE),
        .DATA_WIDTH      (DATA_WIDTH),
        .ACC_WIDTH       (ACC_WIDTH),
        .WORDS_PER_BEAT  (WORDS_PER_BEAT),
        .ADDR_WIDTH      (ADDR_WIDTH),
        .BURST_LEN_WIDTH (BURST_LEN_WIDTH)
    ) dut (
        .clk                  (clk),
        .rst_n                (rst_n),
        .cfg_matrix_dim       (cfg_matrix_dim),
        .burst_write_req      (burst_write_req),
        .burst_write_is_b     (burst_write_is_b),
        .burst_write_addr     (burst_write_addr),
        .burst_write_len      (burst_write_len),
        .burst_write_packed   (burst_write_packed),
        .burst_write_valid    (burst_write_valid),
        .burst_write_ready    (burst_write_ready),
        .burst_write_data     (burst_write_data),
        .burst_write_ack      (burst_write_ack),
        .burst_write_done     (burst_write_done),
        .burst_write_err      (burst_write_err),
        .burst_err_code       (burst_err_code),
        .host_start           (host_start),
        .host_ready           (host_ready),
        .host_busy            (host_busy),
        .host_done            (host_done),
        .start_ack            (start_ack),
        .start_err            (start_err),
        .matrices_ready       (matrices_ready),
        .host_result_available(host_result_available),
        .burst_read_req       (burst_read_req),
        .burst_read_addr      (burst_read_addr),
        .burst_read_len       (burst_read_len),
        .burst_read_ready     (burst_read_ready),
        .burst_read_valid     (burst_read_valid),
        .burst_read_data      (burst_read_data),
        .burst_read_done      (burst_read_done),
        .burst_read_err       (burst_read_err)
    );

    // 100 MHz Clock Generator
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // Check assertion task
    task automatic check(input condition, input [511:0] msg);
        begin
            if (condition) begin
                pass_count = pass_count + 1;
                $display("  [PASS] %0s", msg);
            end else begin
                fail_count = fail_count + 1;
                $display("  [FAIL] %0s at time %0t ps", msg, $time);
                $fatal(1, "Integration Test Assertion Failed!");
            end
        end
    endtask

    // Clock step task
    task automatic step;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Software Golden Reference GEMM Model (C = A x B)
    task automatic compute_golden(input integer dim);
        integer r, c, m;
        integer sum;
        begin
            for (r = 0; r < dim; r = r + 1) begin
                for (c = 0; c < dim; c = c + 1) begin
                    sum = 0;
                    for (m = 0; m < dim; m = m + 1) begin
                        sum = sum + (test_a[(r * dim) + m] * test_b[(m * dim) + c]);
                    end
                    golden_c[(r * dim) + c] = sum;
                end
            end
        end
    endtask

    // Helper: Stream matrix elements via single-element burst beats
    task automatic load_matrix_streaming(
        input                         is_b,
        input integer                 count
    );
        integer elem_idx;
        begin
            burst_write_req    = 1'b1;
            burst_write_is_b   = is_b;
            burst_write_addr   = 6'd0;
            burst_write_len    = count[BURST_LEN_WIDTH-1:0];
            burst_write_packed = 1'b0;

            for (elem_idx = 0; elem_idx < count; elem_idx = elem_idx + 1) begin
                burst_write_valid = 1'b1;
                if (!is_b)
                    burst_write_data = {24'd0, test_a[elem_idx]};
                else
                    burst_write_data = {24'd0, test_b[elem_idx]};

                step;
                burst_write_req = 1'b0;
                check(burst_write_ack === 1'b1, "streaming beat write acknowledged");
            end

            burst_write_valid = 1'b0;
            check(burst_write_done === 1'b1, "burst_write_done asserted on final streaming element");
            step;
            check(burst_write_done === 1'b0, "burst_write_done deasserts after single-cycle pulse");
        end
    endtask

    // Helper: Load matrix elements via packed 32-bit burst words (4 elements / word)
    task automatic load_matrix_packed(
        input                         is_b,
        input integer                 count
    );
        integer word_idx, num_words, sub;
        reg [BUS_DATA_WIDTH-1:0] packed_word;
        begin
            num_words = count / WORDS_PER_BEAT;
            burst_write_req    = 1'b1;
            burst_write_is_b   = is_b;
            burst_write_addr   = 6'd0;
            burst_write_len    = count[BURST_LEN_WIDTH-1:0];
            burst_write_packed = 1'b1;

            for (word_idx = 0; word_idx < num_words; word_idx = word_idx + 1) begin
                // Pack 4 elements: {sub3, sub2, sub1, sub0}
                if (!is_b) begin
                    packed_word = {test_a[word_idx*4 + 3], test_a[word_idx*4 + 2],
                                   test_a[word_idx*4 + 1], test_a[word_idx*4 + 0]};
                end else begin
                    packed_word = {test_b[word_idx*4 + 3], test_b[word_idx*4 + 2],
                                   test_b[word_idx*4 + 1], test_b[word_idx*4 + 0]};
                end

                // Wait until interface is ready for next beat
                while (!burst_write_ready) step;

                burst_write_valid = 1'b1;
                burst_write_data  = packed_word;
                step;
                burst_write_req = 1'b0;
                check(burst_write_ack === 1'b1, "sub-word 0 write acknowledged");

                // Interface automatically drains sub-words 1, 2, 3 into memory with backpressure
                for (sub = 1; sub < WORDS_PER_BEAT; sub = sub + 1) begin
                    step;
                    check(burst_write_ack === 1'b1, "drained sub-word write acknowledged");
                end
            end

            burst_write_valid = 1'b0;
            check(burst_write_done === 1'b1, "burst_write_done asserted on final packed word");
            step;
            check(burst_write_done === 1'b0, "burst_write_done deasserts after single-cycle pulse");
        end
    endtask

    // Helper: Trigger accelerator operation and wait for completion
    task automatic run_accelerator;
        integer timeout;
        begin
            check(host_ready === 1'b1, "host_ready asserted before launch");
            host_start = 1'b1;
            step;
            host_start = 1'b0;
            check(start_ack === 1'b1, "start_ack pulsed on launch");
            check(host_busy === 1'b1, "host_busy asserted during computation");

            timeout = 0;
            while (!host_done && timeout < 500) begin
                step;
                timeout = timeout + 1;
            end

            check(host_done === 1'b1, "host_done completion pulse detected");
            check(timeout < 500, "computation finished within timeout");
            step; // 1-cycle Done-to-Read handoff
            check(host_result_available === 1'b1, "host_result_available asserted upon completion");
            check(host_busy === 1'b0, "host_busy deasserted after completion");
        end
    endtask

    // Helper: Burst readback of result matrix and verify against golden model
    task automatic readback_and_verify(input integer dim);
        integer total, el_idx;
        begin
            total = dim * dim;
            burst_read_req   = 1'b1;
            burst_read_addr  = 6'd0;
            burst_read_len   = total[BURST_LEN_WIDTH-1:0];
            burst_read_ready = 1'b1;
            step;
            burst_read_req = 1'b0;

            for (el_idx = 0; el_idx < total; el_idx = el_idx + 1) begin
                step;
                check(burst_read_valid === 1'b1, "burst_read_valid asserted on read beat");
                actual_c[el_idx] = burst_read_data;
                check(actual_c[el_idx] === golden_c[el_idx], "readback result matches golden reference");
            end

            check(burst_read_done === 1'b1, "burst_read_done asserted on final read beat");
            step;
            check(burst_read_done === 1'b0, "burst_read_done deasserts after completion");
        end
    endtask

    // Main Test Execution Flow
    initial begin
        $dumpfile("build/tb_phase2_top.vcd");
        $dumpvars(0, tb_phase2_top);

        pass_count = 0;
        fail_count = 0;

        $display("==================================================================");
        $display("STARTING PHASE 2 TOP-LEVEL SYSTEM INTEGRATION VERIFICATION");
        $display("==================================================================");

        // Initialize all inputs
        rst_n              = 1'b0;
        cfg_matrix_dim     = 4'd3;
        burst_write_req    = 1'b0;
        burst_write_is_b   = 1'b0;
        burst_write_addr   = 6'd0;
        burst_write_len    = 7'd0;
        burst_write_packed = 1'b0;
        burst_write_valid  = 1'b0;
        burst_write_data   = {BUS_DATA_WIDTH{1'b0}};
        host_start         = 1'b0;
        burst_read_req     = 1'b0;
        burst_read_addr    = 6'd0;
        burst_read_len     = 7'd0;
        burst_read_ready   = 1'b0;

        // Apply reset for 3 cycles
        repeat (3) step;
        rst_n = 1'b1;
        step;

        // -------------------------------------------------------------
        // Test Suite 1: System Reset & Idle Verification
        // -------------------------------------------------------------
        $display("\n--- Test Suite 1: System Reset & Idle Verification ---");
        check(host_ready === 1'b0, "host_ready low before matrices loaded");
        check(host_busy === 1'b0, "host_busy low after reset");
        check(host_done === 1'b0, "host_done low after reset");
        check(matrices_ready === 1'b0, "matrices_ready low after reset");
        check(host_result_available === 1'b0, "host_result_available low after reset");
        check(burst_write_ready === 1'b1, "burst_write_ready asserted after reset");

        // -------------------------------------------------------------
        // Test Suite 2: 3x3 Matrix Multiplication (Streaming Mode)
        // -------------------------------------------------------------
        $display("\n--- Test Suite 2: 3x3 GEMM via Streaming Burst ---");
        cfg_matrix_dim = 4'd3;

        // Initialize 3x3 Test Matrices:
        // A = [[ 1,  2,  3],
        //      [ 4, -5,  6],
        //      [-7,  8, -9]]
        test_a[0] = 8'sd1;   test_a[1] = 8'sd2;   test_a[2] = 8'sd3;
        test_a[3] = 8'sd4;   test_a[4] = -8'sd5;  test_a[5] = 8'sd6;
        test_a[6] = -8'sd7;  test_a[7] = 8'sd8;   test_a[8] = -8'sd9;

        // B = [[ 9, -8,  7],
        //      [ 6,  5, -4],
        //      [-3,  2,  1]]
        test_b[0] = 8'sd9;   test_b[1] = -8'sd8;  test_b[2] = 8'sd7;
        test_b[3] = 8'sd6;   test_b[4] = 8'sd5;   test_b[5] = -8'sd4;
        test_b[6] = -8'sd3;  test_b[7] = 8'sd2;   test_b[8] = 8'sd1;

        compute_golden(3);

        // Load Matrix A via streaming burst
        load_matrix_streaming(1'b0, 9);
        check(matrices_ready === 1'b0, "matrices_ready still low after only loading A");

        // Load Matrix B via streaming burst
        load_matrix_streaming(1'b1, 9);
        check(matrices_ready === 1'b1, "matrices_ready high after loading both A and B");
        check(host_ready === 1'b1, "host_ready asserted after loading 3x3 matrices");

        // Launch and compute
        run_accelerator;

        // Burst read results and verify against golden reference
        readback_and_verify(3);

        // -------------------------------------------------------------
        // Test Suite 3: 6x6 Tiled GEMM (Packed 32-bit Mode)
        // -------------------------------------------------------------
        $display("\n--- Test Suite 3: 6x6 Tiled GEMM via Packed 32-bit Bursts ---");
        cfg_matrix_dim = 4'd6;

        // Generate pseudorandom 6x6 matrices
        for (idx = 0; idx < 36; idx = idx + 1) begin
            test_a[idx] = $signed((idx * 3 + 7) % 25 - 12);
            test_b[idx] = $signed((idx * 5 + 13) % 29 - 14);
        end

        compute_golden(6);

        // Load Matrix A via packed 32-bit burst (9 words of 4 bytes)
        load_matrix_packed(1'b0, 36);
        check(matrices_ready === 1'b0, "matrices_ready low after loading 6x6 A");

        // Load Matrix B via packed 32-bit burst
        load_matrix_packed(1'b1, 36);
        check(matrices_ready === 1'b1, "matrices_ready asserted after loading 6x6 A & B");
        check(host_ready === 1'b1, "host_ready asserted for 6x6 tiled operation");

        // Execute full tiled computation (113 clock cycles across 4 output tiles)
        run_accelerator;

        // Burst read back all 36 results and verify
        readback_and_verify(6);

        // -------------------------------------------------------------
        // Test Suite 4: 6x6 Tiled GEMM with Extreme Signed Boundaries
        // -------------------------------------------------------------
        $display("\n--- Test Suite 4: 6x6 Tiled GEMM with Boundary Operands ---");
        // Use -128, +127, -1, 0, 1
        for (idx = 0; idx < 36; idx = idx + 1) begin
            case (idx % 5)
                0: test_a[idx] = -8'sd128;
                1: test_a[idx] = 8'sd127;
                2: test_a[idx] = -8'sd1;
                3: test_a[idx] = 8'sd0;
                4: test_a[idx] = 8'sd1;
            endcase

            case ((idx + 2) % 5)
                0: test_b[idx] = 8'sd1;
                1: test_b[idx] = -8'sd128;
                2: test_b[idx] = 8'sd127;
                3: test_b[idx] = 8'sd0;
                4: test_b[idx] = -8'sd1;
            endcase
        end

        compute_golden(6);

        // Load both matrices via packed bursts
        load_matrix_packed(1'b0, 36);
        load_matrix_packed(1'b1, 36);

        // Run accelerator and verify boundary signed math
        run_accelerator;
        readback_and_verify(6);

        // -------------------------------------------------------------
        // Test Suite 5: Back-to-Back Operations Without Reset
        // -------------------------------------------------------------
        $display("\n--- Test Suite 5: Back-to-Back Operations Without Reset ---");
        cfg_matrix_dim = 4'd3;

        // Matrix A & B with new values
        for (idx = 0; idx < 9; idx = idx + 1) begin
            test_a[idx] = $signed(idx + 5);
            test_b[idx] = $signed(15 - idx);
        end
        compute_golden(3);

        load_matrix_streaming(1'b0, 9);
        load_matrix_streaming(1'b1, 9);

        // Verify out_buf_clear pulses and new results replace old ones
        run_accelerator;
        readback_and_verify(3);

        // -------------------------------------------------------------
        // Test Suite 6: Host Protocol Error Detection & Rejection
        // -------------------------------------------------------------
        $display("\n--- Test Suite 6: Host Error Detection & Rejections ---");

        // Reset to clear memory written flags
        rst_n = 1'b0;
        step;
        rst_n = 1'b1;
        step;

        // 6.1: Start attempt before matrices ready
        // Clear matrices by loading partial matrix
        cfg_matrix_dim = 4'd6;
        burst_write_req    = 1'b1;
        burst_write_is_b   = 1'b0;
        burst_write_addr   = 6'd0;
        burst_write_len    = 7'd1;
        burst_write_packed = 1'b0;
        burst_write_valid  = 1'b1;
        burst_write_data   = {24'd0, 8'sd10};
        step;
        burst_write_req   = 1'b0;
        burst_write_valid = 1'b0;
        step;
        check(matrices_ready === 1'b0, "matrices_ready false during incomplete matrix");

        host_start = 1'b1;
        step;
        host_start = 1'b0;
        check(start_err === 1'b1, "start_err asserted when attempting start before ready");
        check(start_ack === 1'b0, "start_ack suppressed during invalid start");
        check(host_busy === 1'b0, "host_busy remains low on rejected start");

        // 6.2: Write attempt while accelerator is active
        // Complete loading 6x6 matrices and start
        load_matrix_packed(1'b0, 36);
        load_matrix_packed(1'b1, 36);
        host_start = 1'b1;
        step;
        host_start = 1'b0;
        check(start_ack === 1'b1, "start accepted for error rejection test");

        // Attempt host burst write during computation
        burst_write_req    = 1'b1;
        burst_write_is_b   = 1'b0;
        burst_write_addr   = 6'd0;
        burst_write_len    = 7'd4;
        burst_write_packed = 1'b0;
        burst_write_valid  = 1'b1;
        burst_write_data   = {24'd0, 8'sd99};
        step;
        burst_write_req   = 1'b0;
        burst_write_valid = 1'b0;
        check(burst_write_err === 1'b1, "burst_write_err asserted on write attempt while busy");
        check(burst_err_code === 3'b001, "burst_err_code is ERR_BUSY (1)");

        // Wait for current computation to complete
        while (!host_done) step;
        step;

        // 6.3: Unsupported Matrix Dimension Configuration
        cfg_matrix_dim = 4'd5; // Dimension 5 not supported
        step;
        burst_write_req    = 1'b1;
        burst_write_is_b   = 1'b0;
        burst_write_addr   = 6'd0;
        burst_write_len    = 7'd4;
        burst_write_packed = 1'b0;
        burst_write_valid  = 1'b1;
        step;
        burst_write_req   = 1'b0;
        burst_write_valid = 1'b0;
        check(burst_write_err === 1'b1, "burst_write_err on unsupported dimension 5");
        check(burst_err_code === 3'b100, "burst_err_code is ERR_DIM (4)");

        cfg_matrix_dim = 4'd6;
        step;

        // -------------------------------------------------------------
        // Test Suite 7: Asynchronous Reset Mid-Compute & System Recovery
        // -------------------------------------------------------------
        $display("\n--- Test Suite 7: Asynchronous Reset Mid-Compute & Recovery ---");
        // Launch 6x6 operation
        load_matrix_packed(1'b0, 36);
        load_matrix_packed(1'b1, 36);
        host_start = 1'b1;
        step;
        host_start = 1'b0;
        check(start_ack === 1'b1, "operation launched before async reset");

        // Wait 15 cycles into computation
        repeat (15) step;
        check(host_busy === 1'b1, "computation in progress");

        // Assert asynchronous reset mid-compute
        rst_n = 1'b0;
        #2;
        check(host_busy === 1'b0, "host_busy immediately cleared on async reset");
        check(dut.u_tile_controller.idle === 1'b1, "systolic controller returned to idle on reset");
        step;

        // Release reset and verify clean recovery with 3x3 GEMM
        rst_n = 1'b1;
        step;
        check(burst_write_ready === 1'b1, "burst_write_ready asserted after reset recovery");

        cfg_matrix_dim = 4'd3;
        for (idx = 0; idx < 9; idx = idx + 1) begin
            test_a[idx] = $signed(idx + 1);
            test_b[idx] = $signed(9 - idx);
        end
        compute_golden(3);

        load_matrix_streaming(1'b0, 9);
        load_matrix_streaming(1'b1, 9);
        run_accelerator;
        readback_and_verify(3);

        // -------------------------------------------------------------
        // Test Suite 8: Result Readback with Host Backpressure
        // -------------------------------------------------------------
        $display("\n--- Test Suite 8: Result Readback with Host Backpressure ---");
        cfg_matrix_dim = 4'd6;
        for (idx = 0; idx < 36; idx = idx + 1) begin
            test_a[idx] = $signed(idx % 7 - 3);
            test_b[idx] = $signed(idx % 5 - 2);
        end
        compute_golden(6);

        load_matrix_packed(1'b0, 36);
        load_matrix_packed(1'b1, 36);
        run_accelerator;

        // Read back all 36 elements, with intermittent host backpressure pauses
        burst_read_req   = 1'b1;
        burst_read_addr  = 6'd0;
        burst_read_len   = 7'd36;
        burst_read_ready = 1'b1;
        step;
        burst_read_req = 1'b0;

        for (idx = 0; idx < 36; idx = idx + 1) begin
            step;

            // Assert backpressure at specific elements
            if (idx == 8 || idx == 18 || idx == 28) begin
                burst_read_ready = 1'b0;
                step;
                check(burst_read_valid === 1'b1, "burst_read_valid held high during host pause");
                check(burst_read_data === golden_c[idx], "burst_read_data held during host pause");
                step;
                check(burst_read_valid === 1'b1, "burst_read_valid continues holding during host pause");
                check(burst_read_data === golden_c[idx], "burst_read_data continues holding during host pause");
                burst_read_ready = 1'b1;
            end

            check(burst_read_valid === 1'b1, "burst_read_valid asserted during streaming");
            check(burst_read_data === golden_c[idx], "burst read element matches golden model");
        end

        check(burst_read_done === 1'b1, "burst_read_done asserted on final element of backpressure read");
        step;
        check(burst_read_done === 1'b0, "burst_read_done cleared after read transaction");

        // -------------------------------------------------------------
        // Final Summary
        // -------------------------------------------------------------
        $display("\n==================================================================");
        $display("PHASE 2 SYSTEM INTEGRATION TEST SUMMARY:");
        $display("  PASSED CHECKS : %0d", pass_count);
        $display("  FAILED CHECKS : %0d", fail_count);
        $display("==================================================================");

        if (fail_count == 0) begin
            $display("RESULT: ALL PHASE 2 INTEGRATION TESTS PASSED SUCCESSFULLY!\n");
        end else begin
            $fatal(1, "PHASE 2 INTEGRATION TESTS FAILED with %0d errors", fail_count);
        end

        $finish;
    end

endmodule

`default_nettype wire
