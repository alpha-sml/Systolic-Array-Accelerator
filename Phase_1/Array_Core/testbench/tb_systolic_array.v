// tb_systolic_array.v
// Self-checking testbench for systolic_array and pe_interconnect.
//
// Verification scope:
//   Test 1: Active-low asynchronous reset (accumulators and propagation regs)
//   Test 2: Synchronous array_clear and clear priority over compute_en
//   Test 3: Horizontal A propagation (west -> east, 1 cycle per PE, halt when disabled)
//   Test 4: Vertical B propagation (north -> south, 1 cycle per PE, halt when disabled)
//   Test 5: Signed MAC behavior inside the array across all four quadrants
//   Test 6: Full 3x3 matrix multiplication following controller LOAD/COMPUTE/DONE timing
//           plus back-to-back signed 3x3 GEMM without reset
//   Test 7: Compute disable and hold behavior
//   Test 8: Mid-operation asynchronous reset
//   Test 9: Parameterization verification on a 2x2 systolic_array instance

`timescale 1ns / 1ps
`default_nettype none

module tb_systolic_array;

    localparam integer ARRAY_SIZE = 3;
    localparam integer DATA_WIDTH = 8;
    localparam integer ACC_WIDTH  = 32;
    localparam integer CLK_PERIOD = 10;

    localparam integer SIZE_2 = 2;

    // 3x3 DUT signals
    reg                                          clk;
    reg                                          rst_n;
    reg                                          compute_en;
    reg                                          array_clear;
    reg  [(ARRAY_SIZE*DATA_WIDTH)-1:0]           a_west;
    reg  [(ARRAY_SIZE*DATA_WIDTH)-1:0]           b_north;
    wire [(ARRAY_SIZE*DATA_WIDTH)-1:0]           a_east;
    wire [(ARRAY_SIZE*DATA_WIDTH)-1:0]           b_south;
    wire [(ARRAY_SIZE*ARRAY_SIZE*ACC_WIDTH)-1:0] acc_out;

    // 2x2 Parameterization DUT signals
    reg                                          rst_n_2;
    reg                                          compute_en_2;
    reg                                          array_clear_2;
    reg  [(SIZE_2*DATA_WIDTH)-1:0]               a_west_2;
    reg  [(SIZE_2*DATA_WIDTH)-1:0]               b_north_2;
    wire [(SIZE_2*DATA_WIDTH)-1:0]               a_east_2;
    wire [(SIZE_2*DATA_WIDTH)-1:0]               b_south_2;
    wire [(SIZE_2*SIZE_2*ACC_WIDTH)-1:0]         acc_out_2;

    integer errors;
    integer test_count;
    integer r;
    integer c;
    integer cyc;

    // Matrix storage for 3x3 GEMM tests
    reg signed [DATA_WIDTH-1:0] mat_a   [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [DATA_WIDTH-1:0] mat_b   [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [ACC_WIDTH-1:0]  mat_exp [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    // Matrix storage for 2x2 GEMM test
    reg signed [DATA_WIDTH-1:0] mat2_a   [0:SIZE_2-1][0:SIZE_2-1];
    reg signed [DATA_WIDTH-1:0] mat2_b   [0:SIZE_2-1][0:SIZE_2-1];
    reg signed [ACC_WIDTH-1:0]  mat2_exp [0:SIZE_2-1][0:SIZE_2-1];

    // Snapshot buffers for hold test
    reg [(ARRAY_SIZE*ARRAY_SIZE*ACC_WIDTH)-1:0] snap_acc;
    reg [(ARRAY_SIZE*DATA_WIDTH)-1:0]           snap_a_east;
    reg [(ARRAY_SIZE*DATA_WIDTH)-1:0]           snap_b_south;

    // Default 3x3 Systolic Array DUT
    systolic_array #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)
    ) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .compute_en (compute_en),
        .array_clear(array_clear),
        .a_west     (a_west),
        .b_north    (b_north),
        .a_east     (a_east),
        .b_south    (b_south),
        .acc_out    (acc_out)
    );

    // Parameterized 2x2 Systolic Array DUT
    systolic_array #(
        .ARRAY_SIZE(SIZE_2),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH)
    ) dut_2x2 (
        .clk        (clk),
        .rst_n      (rst_n_2),
        .compute_en (compute_en_2),
        .array_clear(array_clear_2),
        .a_west     (a_west_2),
        .b_north    (b_north_2),
        .a_east     (a_east_2),
        .b_south    (b_south_2),
        .acc_out    (acc_out_2)
    );

    // 100 MHz clock
    initial clk = 1'b0;
    always #(CLK_PERIOD / 2) clk = ~clk;

    // Advance one rising clock edge and wait shortly for NBA propagation
    task automatic step;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Check single PE accumulator in 3x3 DUT
    task automatic check_pe_acc;
        input integer row;
        input integer col;
        input signed [ACC_WIDTH-1:0] expected;
        input [1023:0] test_name;
        reg signed [ACC_WIDTH-1:0] actual;
        begin
            test_count = test_count + 1;
            actual = $signed(acc_out[(((row * ARRAY_SIZE) + col) * ACC_WIDTH) +: ACC_WIDTH]);
            if (^actual === 1'bx || actual !== expected) begin
                $display("FAIL  [Test %0d: %0s] PE(%0d,%0d): expected %0d, got %0d (0x%08h)",
                         test_count, test_name, row, col, expected, actual, actual);
                errors = errors + 1;
            end else begin
                $display("PASS  [Test %0d: %0s] PE(%0d,%0d): acc = %0d",
                         test_count, test_name, row, col, actual);
            end
        end
    endtask

    // Check all 9 accumulators equal a uniform expected value
    task automatic check_all_acc_const;
        input signed [ACC_WIDTH-1:0] expected;
        input [1023:0] test_name;
        integer row_i;
        integer col_i;
        integer local_err;
        reg signed [ACC_WIDTH-1:0] actual;
        begin
            test_count = test_count + 1;
            local_err = 0;
            for (row_i = 0; row_i < ARRAY_SIZE; row_i = row_i + 1) begin
                for (col_i = 0; col_i < ARRAY_SIZE; col_i = col_i + 1) begin
                    actual = $signed(acc_out[(((row_i * ARRAY_SIZE) + col_i) * ACC_WIDTH) +: ACC_WIDTH]);
                    if (^actual === 1'bx || actual !== expected) begin
                        $display("FAIL  [Test %0d: %0s] PE(%0d,%0d): expected %0d, got %0d",
                                 test_count, test_name, row_i, col_i, expected, actual);
                        local_err = local_err + 1;
                    end
                end
            end
            if (local_err == 0) begin
                $display("PASS  [Test %0d: %0s] All 9 accumulators == %0d",
                         test_count, test_name, expected);
            end else begin
                errors = errors + local_err;
            end
        end
    endtask

    // Check boundary outputs a_east and b_south against expected per-lane values
    task automatic check_boundaries;
        input signed [DATA_WIDTH-1:0] exp_e0;
        input signed [DATA_WIDTH-1:0] exp_e1;
        input signed [DATA_WIDTH-1:0] exp_e2;
        input signed [DATA_WIDTH-1:0] exp_s0;
        input signed [DATA_WIDTH-1:0] exp_s1;
        input signed [DATA_WIDTH-1:0] exp_s2;
        input [1023:0] test_name;
        reg signed [DATA_WIDTH-1:0] e0, e1, e2, s0, s1, s2;
        begin
            test_count = test_count + 1;
            e0 = $signed(a_east[(0 * DATA_WIDTH) +: DATA_WIDTH]);
            e1 = $signed(a_east[(1 * DATA_WIDTH) +: DATA_WIDTH]);
            e2 = $signed(a_east[(2 * DATA_WIDTH) +: DATA_WIDTH]);
            s0 = $signed(b_south[(0 * DATA_WIDTH) +: DATA_WIDTH]);
            s1 = $signed(b_south[(1 * DATA_WIDTH) +: DATA_WIDTH]);
            s2 = $signed(b_south[(2 * DATA_WIDTH) +: DATA_WIDTH]);

            if (e0 !== exp_e0 || e1 !== exp_e1 || e2 !== exp_e2 ||
                s0 !== exp_s0 || s1 !== exp_s1 || s2 !== exp_s2) begin
                $display("FAIL  [Test %0d: %0s] Boundary mismatch: a_east=(%0d,%0d,%0d) exp=(%0d,%0d,%0d), b_south=(%0d,%0d,%0d) exp=(%0d,%0d,%0d)",
                         test_count, test_name,
                         e0, e1, e2, exp_e0, exp_e1, exp_e2,
                         s0, s1, s2, exp_s0, exp_s1, exp_s2);
                errors = errors + 1;
            end else begin
                $display("PASS  [Test %0d: %0s] a_east=(%0d,%0d,%0d), b_south=(%0d,%0d,%0d)",
                         test_count, test_name, e0, e1, e2, s0, s1, s2);
            end
        end
    endtask

    // Clear and flush the 3x3 array cleanly via async reset
    task automatic pulse_reset;
        begin
            compute_en  = 1'b0;
            array_clear = 1'b0;
            a_west      = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
            b_north     = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
            rst_n       = 1'b0;
            step;
            rst_n       = 1'b1;
            step;
        end
    endtask

    // Execute 3x3 GEMM using exact systolic_controller timing contract:
    //   LOAD:    3 cycles (array_clear=1 on beat 2)
    //   COMPUTE: 7 cycles (cycle_count = 0..6, skewed A & B streams)
    //   DONE:    1 cycle  (compute_en=0, accumulators stable)
    task automatic run_3x3_gemm;
        input [1023:0] gemm_label;
        integer beat;
        integer row_i;
        integer col_i;
        integer k_idx;
        begin
            // LOAD phase: N = 3 cycles
            compute_en = 1'b0;
            a_west     = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
            b_north    = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
            for (beat = 0; beat < ARRAY_SIZE; beat = beat + 1) begin
                array_clear = (beat == (ARRAY_SIZE - 1)) ? 1'b1 : 1'b0;
                step;
            end
            array_clear = 1'b0;

            // COMPUTE phase: 3N - 2 = 7 cycles
            compute_en = 1'b1;
            for (beat = 0; beat < ((3 * ARRAY_SIZE) - 2); beat = beat + 1) begin
                for (row_i = 0; row_i < ARRAY_SIZE; row_i = row_i + 1) begin
                    k_idx = beat - row_i;
                    if (k_idx >= 0 && k_idx < ARRAY_SIZE)
                        a_west[(row_i * DATA_WIDTH) +: DATA_WIDTH] = mat_a[row_i][k_idx];
                    else
                        a_west[(row_i * DATA_WIDTH) +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
                end

                for (col_i = 0; col_i < ARRAY_SIZE; col_i = col_i + 1) begin
                    k_idx = beat - col_i;
                    if (k_idx >= 0 && k_idx < ARRAY_SIZE)
                        b_north[(col_i * DATA_WIDTH) +: DATA_WIDTH] = mat_b[k_idx][col_i];
                    else
                        b_north[(col_i * DATA_WIDTH) +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
                end
                step;
            end

            // DONE phase: 1 cycle
            compute_en = 1'b0;
            a_west     = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
            b_north    = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
            step;

            $display("--- %0s Result Matrix ---", gemm_label);
            for (row_i = 0; row_i < ARRAY_SIZE; row_i = row_i + 1) begin
                for (col_i = 0; col_i < ARRAY_SIZE; col_i = col_i + 1) begin
                    check_pe_acc(row_i, col_i, mat_exp[row_i][col_i], gemm_label);
                end
            end
        end
    endtask

    initial begin
        $dumpfile("Phase_1/Array_Core/testbench/tb_systolic_array.vcd");
        $dumpvars(0, tb_systolic_array);

        errors        = 0;
        test_count    = 0;
        clk           = 1'b0;
        rst_n         = 1'b1;
        compute_en    = 1'b0;
        array_clear   = 1'b0;
        a_west        = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
        b_north       = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
        rst_n_2       = 1'b0;
        compute_en_2  = 1'b0;
        array_clear_2 = 1'b0;
        a_west_2      = {(SIZE_2*DATA_WIDTH){1'b0}};
        b_north_2     = {(SIZE_2*DATA_WIDTH){1'b0}};

        $display("================================================================");
        $display("Starting Systolic Array Core Testbench (tb_systolic_array)");
        $display("================================================================");

        // -----------------------------------------------------------------
        // Test 1: Reset
        // -----------------------------------------------------------------
        $display("[Test 1] Active-low asynchronous reset");
        #2;
        rst_n = 1'b0;
        #1;
        check_all_acc_const(32'sd0, "Test 1: Async reset accumulators == 0");
        check_boundaries(8'sd0, 8'sd0, 8'sd0, 8'sd0, 8'sd0, 8'sd0,
                         "Test 1: Async reset boundary regs == 0");

        step;
        check_all_acc_const(32'sd0, "Test 1: Reset held across clock edge");
        rst_n = 1'b1;
        step;

        // -----------------------------------------------------------------
        // Test 2: Synchronous Clear and Clear Priority over compute_en
        // -----------------------------------------------------------------
        $display("[Test 2] Synchronous array_clear and priority");
        compute_en = 1'b1;
        a_west     = {8'sd3, 8'sd2, 8'sd1};
        b_north    = {8'sd6, 8'sd5, 8'sd4};
        for (cyc = 0; cyc < 5; cyc = cyc + 1)
            step;

        // Verify all 9 PEs accumulated non-zero values before clear
        test_count = test_count + 1;
        begin : blk_pre_clear_chk
            integer nz_err;
            nz_err = 0;
            for (r = 0; r < ARRAY_SIZE; r = r + 1) begin
                for (c = 0; c < ARRAY_SIZE; c = c + 1) begin
                    if ($signed(acc_out[(((r * ARRAY_SIZE) + c) * ACC_WIDTH) +: ACC_WIDTH]) === 32'sd0 ||
                        ^acc_out[(((r * ARRAY_SIZE) + c) * ACC_WIDTH) +: ACC_WIDTH] === 1'bx) begin
                        $display("FAIL  [Test %0d: Test 2 pre-clear non-zero] PE(%0d,%0d) was 0 or X",
                                 test_count, r, c);
                        nz_err = nz_err + 1;
                    end
                end
            end
            if (nz_err == 0) begin
                $display("PASS  [Test %0d: Test 2 pre-clear non-zero] All 9 PEs accumulated non-zero values",
                         test_count);
            end else begin
                errors = errors + nz_err;
            end
        end

        // Assert array_clear with compute_en = 0
        compute_en  = 1'b0;
        array_clear = 1'b1;
        step;
        check_all_acc_const(32'sd0, "Test 2: array_clear clears all 9 accumulators");

        // Verify clear priority over compute_en
        compute_en  = 1'b1;
        array_clear = 1'b1;
        a_west      = {8'sd10, 8'sd10, 8'sd10};
        b_north     = {8'sd10, 8'sd10, 8'sd10};
        step;
        check_all_acc_const(32'sd0, "Test 2: array_clear overrides compute_en");
        array_clear = 1'b0;
        compute_en  = 1'b0;

        // -----------------------------------------------------------------
        // Test 3: Horizontal A Propagation (West -> East)
        // -----------------------------------------------------------------
        $display("[Test 3] Horizontal A propagation");
        pulse_reset;

        // Pre-fill B = 1 across every PE while A = 0 (acc stays 0)
        compute_en = 1'b1;
        a_west     = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
        b_north    = {8'sd1, 8'sd1, 8'sd1};
        for (cyc = 0; cyc < ARRAY_SIZE; cyc = cyc + 1)
            step;

        // Cycle 0: Inject [11, -22, 33] on west boundary
        a_west = {8'sd33, -8'sd22, 8'sd11};
        step;
        check_pe_acc(0, 0,  32'sd11, "Test 3 cyc0 col0 row0");
        check_pe_acc(1, 0, -32'sd22, "Test 3 cyc0 col0 row1");
        check_pe_acc(2, 0,  32'sd33, "Test 3 cyc0 col0 row2");
        check_pe_acc(0, 1,  32'sd0,  "Test 3 cyc0 col1 still 0");
        check_pe_acc(0, 2,  32'sd0,  "Test 3 cyc0 col2 still 0");
        check_boundaries(8'sd0, 8'sd0, 8'sd0, 8'sd1, 8'sd1, 8'sd1, "Test 3 cyc0 a_east == 0");

        // Cycle 1: Values propagate from col 0 -> col 1
        a_west = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
        step;
        check_pe_acc(0, 1,  32'sd11, "Test 3 cyc1 col1 row0");
        check_pe_acc(1, 1, -32'sd22, "Test 3 cyc1 col1 row1");
        check_pe_acc(2, 1,  32'sd33, "Test 3 cyc1 col1 row2");
        check_pe_acc(0, 2,  32'sd0,  "Test 3 cyc1 col2 still 0");
        check_boundaries(8'sd0, 8'sd0, 8'sd0, 8'sd1, 8'sd1, 8'sd1, "Test 3 cyc1 a_east == 0");

        // Disable compute_en and verify propagation stops
        compute_en = 1'b0;
        a_west     = {8'sd99, 8'sd99, 8'sd99};
        step;
        step;
        check_pe_acc(0, 2, 32'sd0, "Test 3 paused: col2 remains 0");
        check_boundaries(8'sd0, 8'sd0, 8'sd0, 8'sd1, 8'sd1, 8'sd1, "Test 3 paused: a_east remains 0");

        // Re-enable compute_en: col 1 -> col 2 and exits a_east
        compute_en = 1'b1;
        a_west     = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
        step;
        check_pe_acc(0, 2,  32'sd11, "Test 3 cyc2 col2 row0");
        check_pe_acc(1, 2, -32'sd22, "Test 3 cyc2 col2 row1");
        check_pe_acc(2, 2,  32'sd33, "Test 3 cyc2 col2 row2");
        check_boundaries(8'sd11, -8'sd22, 8'sd33, 8'sd1, 8'sd1, 8'sd1, "Test 3 cyc2 a_east output");

        // -----------------------------------------------------------------
        // Test 4: Vertical B Propagation (North -> South)
        // -----------------------------------------------------------------
        $display("[Test 4] Vertical B propagation");
        pulse_reset;

        // Pre-fill A = 1 across every PE while B = 0 (acc stays 0)
        compute_en = 1'b1;
        a_west     = {8'sd1, 8'sd1, 8'sd1};
        b_north    = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
        for (cyc = 0; cyc < ARRAY_SIZE; cyc = cyc + 1)
            step;

        // Cycle 0: Inject [15, -27, 41] on north boundary
        b_north = {8'sd41, -8'sd27, 8'sd15};
        step;
        check_pe_acc(0, 0,  32'sd15, "Test 4 cyc0 row0 col0");
        check_pe_acc(0, 1, -32'sd27, "Test 4 cyc0 row0 col1");
        check_pe_acc(0, 2,  32'sd41, "Test 4 cyc0 row0 col2");
        check_pe_acc(1, 0,  32'sd0,  "Test 4 cyc0 row1 still 0");
        check_pe_acc(2, 0,  32'sd0,  "Test 4 cyc0 row2 still 0");
        check_boundaries(8'sd1, 8'sd1, 8'sd1, 8'sd0, 8'sd0, 8'sd0, "Test 4 cyc0 b_south == 0");

        // Cycle 1: Values propagate from row 0 -> row 1
        b_north = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
        step;
        check_pe_acc(1, 0,  32'sd15, "Test 4 cyc1 row1 col0");
        check_pe_acc(1, 1, -32'sd27, "Test 4 cyc1 row1 col1");
        check_pe_acc(1, 2,  32'sd41, "Test 4 cyc1 row1 col2");
        check_pe_acc(2, 0,  32'sd0,  "Test 4 cyc1 row2 still 0");
        check_boundaries(8'sd1, 8'sd1, 8'sd1, 8'sd0, 8'sd0, 8'sd0, "Test 4 cyc1 b_south == 0");

        // Disable compute_en and verify vertical propagation stops
        compute_en = 1'b0;
        b_north    = {8'sd77, 8'sd77, 8'sd77};
        step;
        step;
        check_pe_acc(2, 0, 32'sd0, "Test 4 paused: row2 remains 0");
        check_boundaries(8'sd1, 8'sd1, 8'sd1, 8'sd0, 8'sd0, 8'sd0, "Test 4 paused: b_south remains 0");

        // Re-enable compute_en: row 1 -> row 2 and exits b_south
        compute_en = 1'b1;
        b_north    = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
        step;
        check_pe_acc(2, 0,  32'sd15, "Test 4 cyc2 row2 col0");
        check_pe_acc(2, 1, -32'sd27, "Test 4 cyc2 row2 col1");
        check_pe_acc(2, 2,  32'sd41, "Test 4 cyc2 row2 col2");
        check_boundaries(8'sd1, 8'sd1, 8'sd1, 8'sd15, -8'sd27, 8'sd41, "Test 4 cyc2 b_south output");

        // -----------------------------------------------------------------
        // Test 5: Signed PE MAC Behavior Inside Array (All 4 Quadrants)
        // -----------------------------------------------------------------
        $display("[Test 5] Signed MAC quadrants inside array");
        pulse_reset;
        compute_en = 1'b1;

        // Cycle 0: (+12)*(+10) at PE(0,0); launch B[0]=+6 on col 1 for PE(2,1)
        a_west[(0*DATA_WIDTH) +: DATA_WIDTH]  = 8'sd12;
        b_north[(0*DATA_WIDTH) +: DATA_WIDTH] = 8'sd10;
        b_north[(1*DATA_WIDTH) +: DATA_WIDTH] = 8'sd6;
        step;
        check_pe_acc(0, 0, 32'sd120, "Test 5 (+)*(+) at PE(0,0)");

        // Cycle 1: (+15)*(-4) at PE(0,0); launch A=-7 on row 2 and B=-9 on col 1
        a_west[(0*DATA_WIDTH) +: DATA_WIDTH]  = 8'sd15;
        b_north[(0*DATA_WIDTH) +: DATA_WIDTH] = -8'sd4;
        a_west[(2*DATA_WIDTH) +: DATA_WIDTH]  = -8'sd7;
        b_north[(1*DATA_WIDTH) +: DATA_WIDTH] = -8'sd9;
        step;
        check_pe_acc(0, 0, 32'sd60, "Test 5 (+)*(-) at PE(0,0)");

        // Cycle 2: (-9)*(+7) at PE(0,0); launch A=+5 on row 2; PE(2,1) receives (-7)*(+6)
        a_west[(0*DATA_WIDTH) +: DATA_WIDTH]  = -8'sd9;
        b_north[(0*DATA_WIDTH) +: DATA_WIDTH] = 8'sd7;
        a_west[(2*DATA_WIDTH) +: DATA_WIDTH]  = 8'sd5;
        b_north[(1*DATA_WIDTH) +: DATA_WIDTH] = 8'sd0;
        step;
        check_pe_acc(0, 0, -32'sd3,  "Test 5 (-)*(+) at PE(0,0)");
        check_pe_acc(2, 1, -32'sd42, "Test 5 (-)*(+) at PE(2,1)");

        // Cycle 3: (-8)*(-11) at PE(0,0); PE(2,1) receives (+5)*(-9)
        a_west[(0*DATA_WIDTH) +: DATA_WIDTH]  = -8'sd8;
        b_north[(0*DATA_WIDTH) +: DATA_WIDTH] = -8'sd11;
        a_west[(2*DATA_WIDTH) +: DATA_WIDTH]  = 8'sd0;
        step;
        check_pe_acc(0, 0,  32'sd85, "Test 5 (-)*(-) at PE(0,0)");
        check_pe_acc(2, 1, -32'sd87, "Test 5 (+)*(-) at PE(2,1)");

        compute_en = 1'b0;

        // -----------------------------------------------------------------
        // Test 6: Full 3x3 Matrix Multiplication (Controller Timing)
        // -----------------------------------------------------------------
        $display("[Test 6] Full 3x3 Matrix Multiplication");
        pulse_reset;

        // Primary reference matrices from specification
        mat_a[0][0] = 8'sd1; mat_a[0][1] = 8'sd2; mat_a[0][2] = 8'sd3;
        mat_a[1][0] = 8'sd4; mat_a[1][1] = 8'sd5; mat_a[1][2] = 8'sd6;
        mat_a[2][0] = 8'sd7; mat_a[2][1] = 8'sd8; mat_a[2][2] = 8'sd9;

        mat_b[0][0] = 8'sd9; mat_b[0][1] = 8'sd8; mat_b[0][2] = 8'sd7;
        mat_b[1][0] = 8'sd6; mat_b[1][1] = 8'sd5; mat_b[1][2] = 8'sd4;
        mat_b[2][0] = 8'sd3; mat_b[2][1] = 8'sd2; mat_b[2][2] = 8'sd1;

        mat_exp[0][0] = 32'sd30;  mat_exp[0][1] = 32'sd24;  mat_exp[0][2] = 32'sd18;
        mat_exp[1][0] = 32'sd84;  mat_exp[1][1] = 32'sd69;  mat_exp[1][2] = 32'sd54;
        mat_exp[2][0] = 32'sd138; mat_exp[2][1] = 32'sd114; mat_exp[2][2] = 32'sd90;

        run_3x3_gemm("Test 6 Primary 3x3 GEMM");

        // Back-to-back signed 3x3 GEMM without reset (relies on array_clear)
        mat_a[0][0] =  8'sd2; mat_a[0][1] = -8'sd1; mat_a[0][2] =  8'sd3;
        mat_a[1][0] =  8'sd0; mat_a[1][1] =  8'sd4; mat_a[1][2] = -8'sd2;
        mat_a[2][0] = -8'sd3; mat_a[2][1] =  8'sd5; mat_a[2][2] =  8'sd1;

        mat_b[0][0] =  8'sd1; mat_b[0][1] =  8'sd2; mat_b[0][2] = -8'sd1;
        mat_b[1][0] = -8'sd2; mat_b[1][1] =  8'sd0; mat_b[1][2] =  8'sd3;
        mat_b[2][0] =  8'sd4; mat_b[2][1] = -8'sd1; mat_b[2][2] =  8'sd2;

        mat_exp[0][0] =  32'sd16; mat_exp[0][1] =  32'sd1; mat_exp[0][2] =  32'sd1;
        mat_exp[1][0] = -32'sd16; mat_exp[1][1] =  32'sd2; mat_exp[1][2] =  32'sd8;
        mat_exp[2][0] = -32'sd9;  mat_exp[2][1] = -32'sd7; mat_exp[2][2] = 32'sd20;

        run_3x3_gemm("Test 6 Back-to-Back Signed 3x3 GEMM");

        // -----------------------------------------------------------------
        // Test 7: Compute Disable and Hold
        // -----------------------------------------------------------------
        $display("[Test 7] Compute disable and hold");
        pulse_reset;

        // Populate PEs and boundary outputs with known non-zero values
        compute_en = 1'b1;
        a_west     = {8'sd6, 8'sd5, 8'sd4};
        b_north    = {8'sd9, 8'sd8, 8'sd7};
        for (cyc = 0; cyc < 5; cyc = cyc + 1)
            step;

        snap_acc     = acc_out;
        snap_a_east  = a_east;
        snap_b_south = b_south;

        // Deassert compute_en and change boundary inputs aggressively
        compute_en = 1'b0;
        a_west     = {8'sd55, -8'sd128, 8'sd127};
        b_north    = {-8'sd33, 8'sd64, -8'sd90};
        for (cyc = 0; cyc < 4; cyc = cyc + 1) begin
            step;
            test_count = test_count + 1;
            if (acc_out !== snap_acc || a_east !== snap_a_east || b_south !== snap_b_south) begin
                $display("FAIL  [Test %0d: Test 7 hold cycle %0d] Outputs changed while compute_en=0",
                         test_count, cyc);
                errors = errors + 1;
            end else begin
                $display("PASS  [Test %0d: Test 7 hold cycle %0d] All accumulators and boundary regs held",
                         test_count, cyc);
            end
        end

        // Re-enable compute_en with zeroed boundary inputs: PE(1,1) must
        // receive the held PE(1,0).a_out=5 and PE(0,1).b_out=8 -> +40,
        // confirming internal propagation registers did not sample -128 or 64.
        a_west     = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
        b_north    = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
        compute_en = 1'b1;
        step;
        check_pe_acc(1, 1,
                     $signed(snap_acc[(((1 * ARRAY_SIZE) + 1) * ACC_WIDTH) +: ACC_WIDTH]) + 32'sd40,
                     "Test 7: Internal propagation regs held prior operands");
        compute_en = 1'b0;

        // -----------------------------------------------------------------
        // Test 8: Asynchronous Reset During Operation
        // -----------------------------------------------------------------
        $display("[Test 8] Asynchronous reset during active computation");
        compute_en = 1'b1;
        a_west     = {8'sd12, -8'sd11, 8'sd10};
        b_north    = {-8'sd9, 8'sd8, -8'sd7};
        for (cyc = 0; cyc < 5; cyc = cyc + 1)
            step;

        // Assert reset mid-cycle and inspect immediately before any clock edge
        #2;
        rst_n = 1'b0;
        #1;
        check_all_acc_const(32'sd0, "Test 8: Immediate mid-cycle async reset accumulators == 0");
        check_boundaries(8'sd0, 8'sd0, 8'sd0, 8'sd0, 8'sd0, 8'sd0,
                         "Test 8: Immediate mid-cycle async reset boundaries == 0");

        step;
        rst_n  = 1'b1;
        a_west = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
        b_north = {8'sd1, 8'sd1, 8'sd1};
        compute_en = 1'b1;
        for (cyc = 0; cyc < ARRAY_SIZE; cyc = cyc + 1)
            step;
        check_all_acc_const(32'sd0, "Test 8: No stale A values remained after async reset");

        pulse_reset;
        a_west     = {8'sd1, 8'sd1, 8'sd1};
        b_north    = {(ARRAY_SIZE*DATA_WIDTH){1'b0}};
        compute_en = 1'b1;
        for (cyc = 0; cyc < ARRAY_SIZE; cyc = cyc + 1)
            step;
        check_all_acc_const(32'sd0, "Test 8: No stale B values remained after async reset");
        compute_en = 1'b0;

        // -----------------------------------------------------------------
        // Test 9: Parameterization Verification (2x2 Array)
        // -----------------------------------------------------------------
        $display("[Test 9] Parameterized 2x2 Array Matrix Multiplication");
        rst_n_2       = 1'b0;
        compute_en_2  = 1'b0;
        array_clear_2 = 1'b0;
        a_west_2      = {(SIZE_2*DATA_WIDTH){1'b0}};
        b_north_2     = {(SIZE_2*DATA_WIDTH){1'b0}};
        step;
        rst_n_2 = 1'b1;
        step;

        mat2_a[0][0] = 8'sd2; mat2_a[0][1] = -8'sd3;
        mat2_a[1][0] = 8'sd4; mat2_a[1][1] =  8'sd5;

        mat2_b[0][0] =  8'sd6; mat2_b[0][1] = 8'sd7;
        mat2_b[1][0] = -8'sd1; mat2_b[1][1] = 8'sd8;

        mat2_exp[0][0] = 32'sd15; mat2_exp[0][1] = -32'sd10;
        mat2_exp[1][0] = 32'sd19; mat2_exp[1][1] =  32'sd68;

        // LOAD phase: N = 2 cycles
        array_clear_2 = 1'b0;
        step;
        array_clear_2 = 1'b1;
        step;
        array_clear_2 = 1'b0;

        // COMPUTE phase: 3N - 2 = 4 cycles
        compute_en_2 = 1'b1;
        for (cyc = 0; cyc < ((3 * SIZE_2) - 2); cyc = cyc + 1) begin
            for (r = 0; r < SIZE_2; r = r + 1) begin
                if ((cyc - r) >= 0 && (cyc - r) < SIZE_2)
                    a_west_2[(r * DATA_WIDTH) +: DATA_WIDTH] = mat2_a[r][cyc - r];
                else
                    a_west_2[(r * DATA_WIDTH) +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
            end
            for (c = 0; c < SIZE_2; c = c + 1) begin
                if ((cyc - c) >= 0 && (cyc - c) < SIZE_2)
                    b_north_2[(c * DATA_WIDTH) +: DATA_WIDTH] = mat2_b[cyc - c][c];
                else
                    b_north_2[(c * DATA_WIDTH) +: DATA_WIDTH] = {DATA_WIDTH{1'b0}};
            end
            step;
        end

        // DONE phase
        compute_en_2 = 1'b0;
        a_west_2     = {(SIZE_2*DATA_WIDTH){1'b0}};
        b_north_2    = {(SIZE_2*DATA_WIDTH){1'b0}};
        step;

        for (r = 0; r < SIZE_2; r = r + 1) begin
            for (c = 0; c < SIZE_2; c = c + 1) begin
                test_count = test_count + 1;
                if ($signed(acc_out_2[(((r * SIZE_2) + c) * ACC_WIDTH) +: ACC_WIDTH]) !== mat2_exp[r][c] ||
                    ^acc_out_2[(((r * SIZE_2) + c) * ACC_WIDTH) +: ACC_WIDTH] === 1'bx) begin
                    $display("FAIL  [Test %0d: Test 9 2x2 GEMM] PE(%0d,%0d): expected %0d, got %0d",
                             test_count, r, c, mat2_exp[r][c],
                             $signed(acc_out_2[(((r * SIZE_2) + c) * ACC_WIDTH) +: ACC_WIDTH]));
                    errors = errors + 1;
                end else begin
                    $display("PASS  [Test %0d: Test 9 2x2 GEMM] PE(%0d,%0d): acc = %0d",
                             test_count, r, c,
                             $signed(acc_out_2[(((r * SIZE_2) + c) * ACC_WIDTH) +: ACC_WIDTH]));
                end
            end
        end

        // -----------------------------------------------------------------
        // Summary
        // -----------------------------------------------------------------
        $display("================================================================");
        if (errors == 0) begin
            $display("RESULT: ALL %0d SYSTOLIC ARRAY TESTS PASSED!", test_count);
        end else begin
            $display("RESULT: SYSTOLIC ARRAY TEST FAILED with %0d errors out of %0d tests!",
                     errors, test_count);
            $fatal(1);
        end
        $display("================================================================");
        $finish;
    end

    // Watchdog timer (100 us)
    initial begin
        #100000;
        $display("ERROR: Watchdog timeout in tb_systolic_array!");
        $fatal(1);
    end

endmodule

`default_nettype wire
