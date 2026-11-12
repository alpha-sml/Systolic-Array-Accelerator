// tb_data_management.v
// Comprehensive self-checking testbench for Data Management Subsystem:
//   - input_buffer
//   - output_buffer
//   - matrix_interface
//
// Covers matrix storage, staging, host control, result capture, and reset.

`timescale 1ns / 1ps
`default_nettype none

module tb_data_management;

    // Parameters
    localparam integer ARRAY_SIZE     = 3;
    localparam integer DATA_WIDTH     = 8;
    localparam integer ACC_WIDTH      = 32;
    localparam integer LOAD_CYCLES    = ARRAY_SIZE;
    localparam integer COMPUTE_CYCLES = (3 * ARRAY_SIZE) - 2;
    localparam integer LOAD_IDX_W     = (ARRAY_SIZE <= 1) ? 1 : $clog2(ARRAY_SIZE);
    localparam integer CYCLE_W        = (COMPUTE_CYCLES <= 1) ? 1 : $clog2(COMPUTE_CYCLES);
    localparam integer ADDR_WIDTH     = (ARRAY_SIZE * ARRAY_SIZE <= 1) ? 1 : $clog2(ARRAY_SIZE * ARRAY_SIZE);
    localparam integer NUM_ELEMENTS   = ARRAY_SIZE * ARRAY_SIZE;

    // Clock and Reset
    reg clk;
    reg rst_n;

    // Host interface signals
    reg                         host_start;
    wire                        host_ready;
    wire                        host_busy;
    wire                        host_done;
    wire                        start_ack;
    wire                        start_err;

    reg                         host_write_en;
    reg                         host_write_is_b;
    reg  [ADDR_WIDTH-1:0]       host_write_addr;
    reg  signed [DATA_WIDTH-1:0] host_write_data;
    wire                        host_write_ack;

    reg                         host_read_en;
    reg  [ADDR_WIDTH-1:0]       host_read_addr;
    wire signed [ACC_WIDTH-1:0] host_read_data;
    wire                        host_read_valid;
    wire                        host_result_available;

    // Controller coordination model
    wire                        ctrl_start;
    reg                         controller_idle;
    reg                         controller_busy;
    reg                         controller_done;

    reg                         load_en;
    reg  [LOAD_IDX_W-1:0]       load_idx;
    reg                         compute_en;
    reg  [CYCLE_W-1:0]          cycle_count;

    // Output buffer capture interface
    reg                                         result_valid;
    reg  [(ARRAY_SIZE*ARRAY_SIZE*ACC_WIDTH)-1:0] acc_in;

    // Interconnect wires between modules
    wire                         buf_write_en;
    wire                         buf_write_is_b;
    wire [ADDR_WIDTH-1:0]        buf_write_addr;
    wire signed [DATA_WIDTH-1:0] buf_write_data;
    wire                         matrices_ready;

    wire                         out_buf_clear;

    wire                         buf_read_en;
    wire [ADDR_WIDTH-1:0]        buf_read_addr;
    wire signed [ACC_WIDTH-1:0]  buf_read_data;
    wire                         buf_read_valid;
    wire                         buf_result_available;

    wire [(ARRAY_SIZE*DATA_WIDTH)-1:0] a_west;
    wire [(ARRAY_SIZE*DATA_WIDTH)-1:0] b_north;

    // Test tracking
    integer pass_count = 0;
    integer fail_count = 0;
    integer test_num   = 0;

    // 100MHz clock generation (10ns period)
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Instantiate input_buffer
    input_buffer #(
        .ARRAY_SIZE    (ARRAY_SIZE),
        .DATA_WIDTH    (DATA_WIDTH),
        .LOAD_IDX_W    (LOAD_IDX_W),
        .COMPUTE_CYCLES(COMPUTE_CYCLES),
        .CYCLE_W       (CYCLE_W),
        .ADDR_WIDTH    (ADDR_WIDTH)
    ) u_input_buffer (
        .clk           (clk),
        .rst_n         (rst_n),
        .write_en      (buf_write_en),
        .write_is_b    (buf_write_is_b),
        .write_addr    (buf_write_addr),
        .write_data    (buf_write_data),
        .matrices_ready(matrices_ready),
        .load_en       (load_en),
        .load_idx      (load_idx),
        .compute_en    (compute_en),
        .cycle_count   (cycle_count),
        .a_west        (a_west),
        .b_north       (b_north)
    );

    // Instantiate output_buffer
    output_buffer #(
        .ARRAY_SIZE      (ARRAY_SIZE),
        .ACC_WIDTH       (ACC_WIDTH),
        .ADDR_WIDTH      (ADDR_WIDTH)
    ) u_output_buffer (
        .clk             (clk),
        .rst_n           (rst_n),
        .result_valid    (result_valid),
        .acc_in          (acc_in),
        .clear           (out_buf_clear),
        .read_en         (buf_read_en),
        .read_addr       (buf_read_addr),
        .read_data       (buf_read_data),
        .read_valid      (buf_read_valid),
        .result_available(buf_result_available)
    );

    // Instantiate matrix_interface
    matrix_interface #(
        .ARRAY_SIZE           (ARRAY_SIZE),
        .DATA_WIDTH           (DATA_WIDTH),
        .ACC_WIDTH            (ACC_WIDTH),
        .ADDR_WIDTH           (ADDR_WIDTH)
    ) u_matrix_interface (
        .clk                  (clk),
        .rst_n                (rst_n),
        .host_start           (host_start),
        .host_ready           (host_ready),
        .host_busy            (host_busy),
        .host_done            (host_done),
        .start_ack            (start_ack),
        .start_err            (start_err),
        .start                (ctrl_start),
        .controller_idle      (controller_idle),
        .controller_busy      (controller_busy),
        .controller_done      (controller_done),
        .host_write_en        (host_write_en),
        .host_write_is_b      (host_write_is_b),
        .host_write_addr      (host_write_addr),
        .host_write_data      (host_write_data),
        .host_write_ack       (host_write_ack),
        .write_en             (buf_write_en),
        .write_is_b           (buf_write_is_b),
        .write_addr           (buf_write_addr),
        .write_data           (buf_write_data),
        .matrices_ready       (matrices_ready),
        .out_buf_clear        (out_buf_clear),
        .host_read_en         (host_read_en),
        .host_read_addr       (host_read_addr),
        .host_read_data       (host_read_data),
        .host_read_valid      (host_read_valid),
        .host_result_available(host_result_available),
        .read_en              (buf_read_en),
        .read_addr            (buf_read_addr),
        .result_read_data     (buf_read_data),
        .result_read_valid    (buf_read_valid),
        .result_available     (buf_result_available)
    );

    // Helper functions and tasks
    function signed [DATA_WIDTH-1:0] get_staged_a(input integer idx);
        get_staged_a = u_input_buffer.staged_a[(idx * DATA_WIDTH) +: DATA_WIDTH];
    endfunction

    function signed [DATA_WIDTH-1:0] get_staged_b(input integer idx);
        get_staged_b = u_input_buffer.staged_b[(idx * DATA_WIDTH) +: DATA_WIDTH];
    endfunction

    task check_condition(input [1023:0] test_name, input condition);
        begin
            if (condition) begin
                $display("PASS [%0d]: %0s", test_num, test_name);
                pass_count = pass_count + 1;
            end else begin
                $display("FAIL [%0d]: %0s", test_num, test_name);
                fail_count = fail_count + 1;
            end
        end
    endtask

    // Write a single matrix element via host interface
    task write_matrix_elem(input is_b, input [ADDR_WIDTH-1:0] addr, input signed [DATA_WIDTH-1:0] data);
        begin
            @(posedge clk);
            host_write_en   <= 1'b1;
            host_write_is_b <= is_b;
            host_write_addr <= addr;
            host_write_data <= data;
            @(posedge clk);
            #1;
            host_write_en   <= 1'b0;
        end
    endtask

    // Reset sequence
    task apply_async_reset;
        begin
            rst_n <= 1'b0;
            host_start <= 1'b0;
            host_write_en <= 1'b0;
            host_read_en <= 1'b0;
            controller_idle <= 1'b1;
            controller_busy <= 1'b0;
            controller_done <= 1'b0;
            load_en <= 1'b0;
            load_idx <= {LOAD_IDX_W{1'b0}};
            compute_en <= 1'b0;
            cycle_count <= {CYCLE_W{1'b0}};
            result_valid <= 1'b0;
            acc_in <= {(NUM_ELEMENTS*ACC_WIDTH){1'b0}};
            #20;
            @(posedge clk);
            #1;
            rst_n <= 1'b1;
            @(posedge clk);
            #1;
        end
    endtask

    // Golden model matrices for 3x3 tests
    reg signed [DATA_WIDTH-1:0] mat_A [0:8];
    reg signed [DATA_WIDTH-1:0] mat_B [0:8];
    reg signed [ACC_WIDTH-1:0]  mat_C [0:8];

    integer i, cyc;
    reg signed [DATA_WIDTH-1:0] exp_a, act_a;
    reg signed [DATA_WIDTH-1:0] exp_b, act_b;
    reg skew_ok;

    initial begin
        // Waveform dump
        $dumpfile("build/tb_data_management.vcd");
        $dumpvars(0, tb_data_management);

        $display("================================================================");
        $display("Starting Data Management Subsystem Testbench (tb_data_management)");
        $display("================================================================");

        // -------------------------------------------------------------
        // Test 1: Asynchronous reset
        // -------------------------------------------------------------
        test_num = 1;
        $display("\n--- Test 1: Asynchronous Reset ---");
        rst_n <= 1'b0;
        host_start <= 1'b0;
        host_write_en <= 1'b0;
        host_read_en <= 1'b0;
        controller_idle <= 1'b1;
        controller_busy <= 1'b0;
        controller_done <= 1'b0;
        load_en <= 1'b0;
        compute_en <= 1'b0;
        result_valid <= 1'b0;
        #15;

        check_condition("Matrix written flags cleared on reset",
            (u_input_buffer.written_a == 9'b0) && (u_input_buffer.written_b == 9'b0));
        check_condition("matrices_ready is low on reset", matrices_ready == 1'b0);
        check_condition("Input streams a_west and b_north are zero", (a_west == 24'b0) && (b_north == 24'b0));
        check_condition("Output buffer reports no result available", buf_result_available == 1'b0);
        check_condition("Output buffer read_valid is low", buf_read_valid == 1'b0);
        check_condition("Matrix interface start output is inactive", ctrl_start == 1'b0);

        #10;
        @(posedge clk);
        #1;
        rst_n <= 1'b1;
        @(posedge clk);
        #1;

        // -------------------------------------------------------------
        // Test 2: Individual Matrix A writes
        // -------------------------------------------------------------
        test_num = 2;
        $display("\n--- Test 2: Individual Matrix A Writes ---");
        for (i = 0; i < 9; i = i + 1) begin
            mat_A[i] = i + 1;
            write_matrix_elem(1'b0, i[ADDR_WIDTH-1:0], mat_A[i]);
        end

        #1;
        check_condition("Written A flags all asserted", u_input_buffer.written_a == 9'b111111111);
        check_condition("Written B flags still 0", u_input_buffer.written_b == 9'b0);
        check_condition("matrices_ready still 0 after only A written", matrices_ready == 1'b0);

        begin : check_mem_a
            reg mem_a_ok;
            mem_a_ok = 1'b1;
            for (i = 0; i < 9; i = i + 1) begin
                if (u_input_buffer.mem_a[i] !== mat_A[i])
                    mem_a_ok = 1'b0;
            end
            check_condition("Matrix A elements correctly stored with row-major mapping", mem_a_ok == 1'b1);
        end

        // -------------------------------------------------------------
        // Test 3: Individual Matrix B writes
        // -------------------------------------------------------------
        test_num = 3;
        $display("\n--- Test 3: Individual Matrix B Writes ---");
        for (i = 0; i < 8; i = i + 1) begin
            mat_B[i] = 9 - i;
            write_matrix_elem(1'b1, i[ADDR_WIDTH-1:0], mat_B[i]);
        end

        #1;
        check_condition("Written B flags 8 of 9 asserted", u_input_buffer.written_b == 9'b011111111);

        mat_B[8] = 9 - 8; // 1
        write_matrix_elem(1'b1, 4'd8, mat_B[8]);
        #1;
        check_condition("Written B flags all 9 asserted", u_input_buffer.written_b == 9'b111111111);

        begin : check_mem_b
            reg mem_b_ok;
            mem_b_ok = 1'b1;
            for (i = 0; i < 9; i = i + 1) begin
                if (u_input_buffer.mem_b[i] !== mat_B[i])
                    mem_b_ok = 1'b0;
            end
            check_condition("Matrix B elements correctly stored with row-major mapping", mem_b_ok == 1'b1);
        end

        // -------------------------------------------------------------
        // Test 4: Written-element tracking
        // -------------------------------------------------------------
        test_num = 4;
        $display("\n--- Test 4: Written-Element Tracking ---");
        apply_async_reset();
        check_condition("Post-reset: written_a and written_b are 0",
            (u_input_buffer.written_a == 9'b0) && (u_input_buffer.written_b == 9'b0));

        // Write element 4 (center) of A and element 0 of B
        write_matrix_elem(1'b0, 4'd4, 8'sd42);
        write_matrix_elem(1'b1, 4'd0, -8'sd10);
        #1;
        check_condition("Tracking reflects exact written element indices independently",
            (u_input_buffer.written_a == (9'b1 << 4)) && (u_input_buffer.written_b == 9'b1));

        // -------------------------------------------------------------
        // Test 5: matrices_ready assertion only after all 18 elements written
        // -------------------------------------------------------------
        test_num = 5;
        $display("\n--- Test 5: matrices_ready Assertion Timing ---");
        apply_async_reset();

        // Write 9 elements of A and 8 elements of B
        for (i = 0; i < 9; i = i + 1) begin
            mat_A[i] = i + 1;
            write_matrix_elem(1'b0, i[ADDR_WIDTH-1:0], mat_A[i]);
        end
        for (i = 0; i < 8; i = i + 1) begin
            mat_B[i] = 9 - i;
            write_matrix_elem(1'b1, i[ADDR_WIDTH-1:0], mat_B[i]);
        end
        #1;
        check_condition("17 elements written: matrices_ready remains 0", matrices_ready == 1'b0);

        mat_B[8] = 8'sd1;
        write_matrix_elem(1'b1, 4'd8, mat_B[8]);
        #1;
        check_condition("All 18 elements written: matrices_ready becomes 1", matrices_ready == 1'b1);
        check_condition("host_ready is high when idle and matrices_ready is 1", host_ready == 1'b1);

        // -------------------------------------------------------------
        // Test 6: Invalid matrix write address rejection
        // -------------------------------------------------------------
        test_num = 6;
        $display("\n--- Test 6: Invalid Matrix Write Address Rejection ---");
        // Attempt writing out-of-range address 9 and 15
        @(posedge clk);
        host_write_en   <= 1'b1;
        host_write_is_b <= 1'b0;
        host_write_addr <= 4'd9;
        host_write_data <= 8'sd99;
        #1;
        check_condition("Write to address 9 not forwarded to buffer write_en", buf_write_en == 1'b0);
        @(posedge clk);
        #1;
        host_write_en   <= 1'b0;

        // Verify mem_a and tracking unaffected
        check_condition("Buffer memory not corrupted by invalid address write",
            (u_input_buffer.mem_a[8] == mat_A[8]));

        // -------------------------------------------------------------
        // Test 7: Write acknowledgement when a valid write is accepted
        // -------------------------------------------------------------
        test_num = 7;
        $display("\n--- Test 7: Valid Write Acknowledgement ---");
        controller_idle <= 1'b1;
        @(posedge clk);
        host_write_en   <= 1'b1;
        host_write_is_b <= 1'b0;
        host_write_addr <= 4'd3;
        host_write_data <= 8'sd12;
        #1;
        check_condition("host_write_ack asserted when write is enabled, idle, and valid address",
            host_write_ack == 1'b1);
        @(posedge clk);
        #1;
        host_write_en <= 1'b0;

        // -------------------------------------------------------------
        // Test 8: No acknowledgement when write enable is low
        // -------------------------------------------------------------
        test_num = 8;
        $display("\n--- Test 8: No Ack When Write Enable is Low ---");
        controller_idle <= 1'b1;
        host_write_en   <= 1'b0;
        host_write_addr <= 4'd0;
        #1;
        check_condition("host_write_ack is 0 when host_write_en is 0", host_write_ack == 1'b0);

        // -------------------------------------------------------------
        // Test 9: No acknowledgement while controller is busy
        // -------------------------------------------------------------
        test_num = 9;
        $display("\n--- Test 9: No Ack When Controller is Busy ---");
        controller_idle <= 1'b0;
        controller_busy <= 1'b1;
        host_write_en   <= 1'b1;
        host_write_addr <= 4'd0;
        host_write_data <= 8'sd55;
        #1;
        check_condition("host_write_ack is 0 while controller is busy", host_write_ack == 1'b0);
        check_condition("buf_write_en is 0 while controller is busy", buf_write_en == 1'b0);
        host_write_en   <= 1'b0;
        controller_busy <= 1'b0;
        controller_idle <= 1'b1;
        #1;

        // -------------------------------------------------------------
        // Test 10: No acknowledgement for invalid addresses
        // -------------------------------------------------------------
        test_num = 10;
        $display("\n--- Test 10: No Ack for Invalid Addresses ---");
        controller_idle <= 1'b1;
        host_write_en   <= 1'b1;
        host_write_addr <= 4'd9; // 9 is invalid for 3x3 array (0..8 valid)
        #1;
        check_condition("host_write_ack is 0 for address 9", host_write_ack == 1'b0);

        host_write_addr <= 4'd15; // max 4-bit address
        #1;
        check_condition("host_write_ack is 0 for address 15", host_write_ack == 1'b0);
        host_write_en   <= 1'b0;

        // -------------------------------------------------------------
        // Test 11: Incomplete-matrix start rejection
        // -------------------------------------------------------------
        test_num = 11;
        $display("\n--- Test 11: Incomplete-Matrix Start Rejection ---");
        apply_async_reset();
        for (i = 0; i < 5; i = i + 1) begin
            write_matrix_elem(1'b0, i[ADDR_WIDTH-1:0], 8'd10 + i);
            write_matrix_elem(1'b1, i[ADDR_WIDTH-1:0], 8'd20 + i);
        end
        #1;
        check_condition("matrices_ready is low for partial matrices", matrices_ready == 1'b0);

        @(posedge clk);
        host_start <= 1'b1;
        @(posedge clk);
        #1;
        check_condition("Start rejected: ctrl_start remained 0", ctrl_start == 1'b0);
        check_condition("Host informed of rejection via start_err pulse", start_err == 1'b1);
        check_condition("start_ack was NOT asserted", start_ack == 1'b0);

        @(posedge clk);
        host_start <= 1'b0;
        #1;
        check_condition("start_err cleared after 1 cycle", start_err == 1'b0);

        // Fill remaining matrix elements for subsequent tests
        for (i = 0; i < 9; i = i + 1) begin
            mat_A[i] = i + 1;
            mat_B[i] = 9 - i;
            write_matrix_elem(1'b0, i[ADDR_WIDTH-1:0], mat_A[i]);
            write_matrix_elem(1'b1, i[ADDR_WIDTH-1:0], mat_B[i]);
        end
        #1;

        // -------------------------------------------------------------
        // Test 12: Valid host start acceptance
        // -------------------------------------------------------------
        test_num = 12;
        $display("\n--- Test 12: Valid Host Start Acceptance ---");
        controller_idle <= 1'b1;
        @(posedge clk);
        host_start <= 1'b1;
        @(posedge clk);
        #1;
        check_condition("ctrl_start asserted for accepted start", ctrl_start == 1'b1);
        check_condition("start_ack asserted for accepted start", start_ack == 1'b1);
        check_condition("out_buf_clear asserted on accepted start", out_buf_clear == 1'b1);
        check_condition("start_err remains 0", start_err == 1'b0);

        @(posedge clk);
        #1;
        check_condition("ctrl_start is a single-cycle pulse", ctrl_start == 1'b0);
        check_condition("start_ack dropped after 1 cycle", start_ack == 1'b0);
        host_start <= 1'b0;
        @(posedge clk);

        // -------------------------------------------------------------
        // Test 13: Held-high host-start behavior
        // -------------------------------------------------------------
        test_num = 13;
        $display("\n--- Test 13: Held-High Host Start Behavior ---");
        @(posedge clk);
        host_start <= 1'b1;
        @(posedge clk);
        #1;
        check_condition("Cycle 1 of held start: ctrl_start pulsed", ctrl_start == 1'b1);

        @(posedge clk);
        #1;
        check_condition("Cycle 2 of held start: ctrl_start is 0", ctrl_start == 1'b0);

        @(posedge clk);
        @(posedge clk);
        #1;
        check_condition("Subsequent cycles of held start: ctrl_start remains 0", ctrl_start == 1'b0);
        host_start <= 1'b0;
        @(posedge clk);

        // -------------------------------------------------------------
        // Test 14: LOAD staging of A rows and B columns
        // -------------------------------------------------------------
        test_num = 14;
        $display("\n--- Test 14: LOAD Staging ---");
        controller_idle <= 1'b0;
        controller_busy <= 1'b1;
        load_en <= 1'b1;

        // Beat 0
        load_idx <= 2'd0;
        @(posedge clk);
        #1;
        check_condition("Beat 0 staging row 0 of A and col 0 of B",
            (get_staged_a(0) == mat_A[0]) &&
            (get_staged_a(1) == mat_A[1]) &&
            (get_staged_a(2) == mat_A[2]) &&
            (get_staged_b(0) == mat_B[0]) &&
            (get_staged_b(3) == mat_B[3]) &&
            (get_staged_b(6) == mat_B[6]));

        // Beat 1
        load_idx <= 2'd1;
        @(posedge clk);
        #1;
        check_condition("Beat 1 staging row 1 of A and col 1 of B",
            (get_staged_a(3) == mat_A[3]) &&
            (get_staged_a(4) == mat_A[4]) &&
            (get_staged_a(5) == mat_A[5]) &&
            (get_staged_b(1) == mat_B[1]) &&
            (get_staged_b(4) == mat_B[4]) &&
            (get_staged_b(7) == mat_B[7]));

        // Beat 2
        load_idx <= 2'd2;
        @(posedge clk);
        #1;
        load_en <= 1'b0;
        check_condition("Beat 2 staging row 2 of A and col 2 of B",
            (get_staged_a(6) == mat_A[6]) &&
            (get_staged_a(7) == mat_A[7]) &&
            (get_staged_a(8) == mat_A[8]) &&
            (get_staged_b(2) == mat_B[2]) &&
            (get_staged_b(5) == mat_B[5]) &&
            (get_staged_b(8) == mat_B[8]));

        begin : check_full_staging
            reg stage_ok;
            stage_ok = 1'b1;
            for (i = 0; i < 9; i = i + 1) begin
                if ((get_staged_a(i) !== mat_A[i]) ||
                    (get_staged_b(i) !== mat_B[i]))
                    stage_ok = 1'b0;
            end
            check_condition("Staging registers hold complete matrices A and B", stage_ok == 1'b1);
        end

        // -------------------------------------------------------------
        // Test 15: Complete A operand skew stream
        // -------------------------------------------------------------
        test_num = 15;
        $display("\n--- Test 15: Complete A Operand Skew Stream ---");
        compute_en <= 1'b1;
        skew_ok = 1'b1;
        for (cyc = 0; cyc < 7; cyc = cyc + 1) begin
            cycle_count <= cyc[CYCLE_W-1:0];
            #1;

            if (cyc >= 0 && cyc < 3) exp_a = mat_A[(0 * 3) + cyc];
            else exp_a = 8'd0;
            act_a = a_west[(0 * DATA_WIDTH) +: DATA_WIDTH];
            if (act_a !== exp_a) skew_ok = 1'b0;

            if (cyc >= 1 && cyc < 4) exp_a = mat_A[(1 * 3) + (cyc - 1)];
            else exp_a = 8'd0;
            act_a = a_west[(1 * DATA_WIDTH) +: DATA_WIDTH];
            if (act_a !== exp_a) skew_ok = 1'b0;

            if (cyc >= 2 && cyc < 5) exp_a = mat_A[(2 * 3) + (cyc - 2)];
            else exp_a = 8'd0;
            act_a = a_west[(2 * DATA_WIDTH) +: DATA_WIDTH];
            if (act_a !== exp_a) skew_ok = 1'b0;

            @(posedge clk);
        end
        check_condition("7-cycle A operand skew stream exactly matches specification", skew_ok == 1'b1);

        // -------------------------------------------------------------
        // Test 16: Complete B operand skew stream
        // -------------------------------------------------------------
        test_num = 16;
        $display("\n--- Test 16: Complete B Operand Skew Stream ---");
        skew_ok = 1'b1;
        for (cyc = 0; cyc < 7; cyc = cyc + 1) begin
            cycle_count <= cyc[CYCLE_W-1:0];
            #1;

            if (cyc >= 0 && cyc < 3) exp_b = mat_B[(cyc * 3) + 0];
            else exp_b = 8'd0;
            act_b = b_north[(0 * DATA_WIDTH) +: DATA_WIDTH];
            if (act_b !== exp_b) skew_ok = 1'b0;

            if (cyc >= 1 && cyc < 4) exp_b = mat_B[((cyc - 1) * 3) + 1];
            else exp_b = 8'd0;
            act_b = b_north[(1 * DATA_WIDTH) +: DATA_WIDTH];
            if (act_b !== exp_b) skew_ok = 1'b0;

            if (cyc >= 2 && cyc < 5) exp_b = mat_B[((cyc - 2) * 3) + 2];
            else exp_b = 8'd0;
            act_b = b_north[(2 * DATA_WIDTH) +: DATA_WIDTH];
            if (act_b !== exp_b) skew_ok = 1'b0;

            @(posedge clk);
        end
        check_condition("7-cycle B operand skew stream exactly matches specification", skew_ok == 1'b1);

        // -------------------------------------------------------------
        // Test 17: Compute-disabled zero streams
        // -------------------------------------------------------------
        test_num = 17;
        $display("\n--- Test 17: Compute-Disabled Zero Streams ---");
        compute_en <= 1'b0;
        cycle_count <= 3'd2;
        #1;
        check_condition("With compute_en=0, a_west is zero", a_west == 24'b0);
        check_condition("With compute_en=0, b_north is zero", b_north == 24'b0);

        // -------------------------------------------------------------
        // Test 18: Output-buffer result capture
        // -------------------------------------------------------------
        test_num = 18;
        $display("\n--- Test 18: Output-Buffer Result Capture ---");
        mat_C[0] = 32'sd30;  mat_C[1] = 32'sd24;  mat_C[2] = 32'sd18;
        mat_C[3] = 32'sd84;  mat_C[4] = 32'sd69;  mat_C[5] = 32'sd54;
        mat_C[6] = 32'sd138; mat_C[7] = 32'sd114; mat_C[8] = 32'sd90;

        for (i = 0; i < 9; i = i + 1) begin
            acc_in[(i * ACC_WIDTH) +: ACC_WIDTH] = mat_C[i];
        end

        @(posedge clk);
        result_valid <= 1'b1;
        controller_done <= 1'b1;
        controller_busy <= 1'b0;
        @(posedge clk);
        #1;
        result_valid <= 1'b0;
        controller_done <= 1'b0;
        controller_idle <= 1'b1;

        check_condition("result_available asserted after capture", buf_result_available == 1'b1);
        check_condition("host_result_available asserted", host_result_available == 1'b1);

        begin : check_captured_result
            reg cap_ok;
            cap_ok = 1'b1;
            for (i = 0; i < 9; i = i + 1) begin
                if (u_output_buffer.result_mem[i] !== mat_C[i]) cap_ok = 1'b0;
            end
            check_condition("All 9 accumulator values accurately captured", cap_ok == 1'b1);
        end

        // -------------------------------------------------------------
        // Test 19: Correct indexed readback of all nine results
        // -------------------------------------------------------------
        test_num = 19;
        $display("\n--- Test 19: Correct Indexed Readback ---");
        begin : test_read_all
            reg read_ok;
            read_ok = 1'b1;
            for (i = 0; i < 9; i = i + 1) begin
                @(posedge clk);
                host_read_en   <= 1'b1;
                host_read_addr <= i[ADDR_WIDTH-1:0];
                @(posedge clk);
                #1;
                host_read_en   <= 1'b0;
                if (!host_read_valid || (host_read_data !== mat_C[i])) read_ok = 1'b0;
            end
            check_condition("Row-major readback of all 9 elements matches captured values", read_ok == 1'b1);
        end

        // -------------------------------------------------------------
        // Test 20: One-cycle read_valid
        // -------------------------------------------------------------
        test_num = 20;
        $display("\n--- Test 20: One-Cycle read_valid Strobe ---");
        @(posedge clk);
        host_read_en   <= 1'b1;
        host_read_addr <= 4'd2;
        @(posedge clk);
        #1;
        host_read_en   <= 1'b0;
        check_condition("read_valid is 1 on completion cycle", host_read_valid == 1'b1);
        @(posedge clk);
        #1;
        check_condition("read_valid returns to 0 on subsequent cycle", host_read_valid == 1'b0);

        // -------------------------------------------------------------
        // Test 21: Out-of-range read rejection
        // -------------------------------------------------------------
        test_num = 21;
        $display("\n--- Test 21: Out-of-Range Read Rejection ---");
        @(posedge clk);
        host_read_en   <= 1'b1;
        host_read_addr <= 4'd9;
        @(posedge clk);
        #1;
        host_read_en   <= 1'b0;
        check_condition("Out-of-range read produces read_valid = 0", host_read_valid == 1'b0);
        check_condition("Out-of-range read returns zero data", host_read_data == 32'sd0);

        // -------------------------------------------------------------
        // Test 22: Read rejection when no result is available
        // -------------------------------------------------------------
        test_num = 22;
        $display("\n--- Test 22: Read Rejection When No Result Available ---");
        apply_async_reset();
        @(posedge clk);
        host_read_en   <= 1'b1;
        host_read_addr <= 4'd0;
        @(posedge clk);
        #1;
        host_read_en   <= 1'b0;
        check_condition("Read when result_available=0 rejected: read_valid=0", host_read_valid == 1'b0);
        check_condition("Read data is 0 when result not available", host_read_data == 32'sd0);

        // Re-write matrices and capture result for tests 23-24
        for (i = 0; i < 9; i = i + 1) begin
            mat_A[i] = i + 1;
            mat_B[i] = 9 - i;
            write_matrix_elem(1'b0, i[ADDR_WIDTH-1:0], mat_A[i]);
            write_matrix_elem(1'b1, i[ADDR_WIDTH-1:0], mat_B[i]);
        end
        @(posedge clk);
        for (i = 0; i < 9; i = i + 1) begin
            acc_in[(i * ACC_WIDTH) +: ACC_WIDTH] = 32'sd100 + i;
        end
        result_valid <= 1'b1;
        @(posedge clk);
        #1;
        result_valid <= 1'b0;

        // -------------------------------------------------------------
        // Test 23: Result invalidation on accepted start
        // -------------------------------------------------------------
        test_num = 23;
        $display("\n--- Test 23: Result Invalidation on Accepted Start ---");
        check_condition("Pre-condition: result_available is 1", buf_result_available == 1'b1);
        @(posedge clk);
        host_start <= 1'b1;
        @(posedge clk);
        #1;
        host_start <= 1'b0;
        check_condition("out_buf_clear asserted on accepted start", out_buf_clear == 1'b1);
        @(posedge clk);
        #1;
        check_condition("Accepted start invalidates previous result: result_available is 0",
            buf_result_available == 1'b0);

        // -------------------------------------------------------------
        // Test 24: Capture priority when result_valid and clear overlap
        // -------------------------------------------------------------
        test_num = 24;
        $display("\n--- Test 24: Capture Priority Over Clear ---");
        // Apply clear and result_valid simultaneously
        for (i = 0; i < 9; i = i + 1) begin
            acc_in[(i * ACC_WIDTH) +: ACC_WIDTH] = 32'sd777;
        end
        @(posedge clk);
        result_valid <= 1'b1;
        // host_start rising edge causes out_buf_clear
        host_start   <= 1'b1;
        @(posedge clk);
        #1;
        result_valid <= 1'b0;
        host_start   <= 1'b0;
        check_condition("Overlapping result_valid and clear: result_valid has priority",
            buf_result_available == 1'b1);
        check_condition("Captured element 0 is 777 despite concurrent clear",
            u_output_buffer.result_mem[0] == 32'sd777);

        // -------------------------------------------------------------
        // Test 25: Signed operand storage and streaming
        // -------------------------------------------------------------
        test_num = 25;
        $display("\n--- Test 25: Signed Operand Storage and Streaming ---");
        mat_A[0] = -8'sd128; mat_A[1] = -8'sd75; mat_A[2] = -8'sd1;
        mat_A[3] = 8'sd0;    mat_A[4] = 8'sd1;   mat_A[5] = 8'sd64;
        mat_A[6] = 8'sd127;  mat_A[7] = -8'sd50; mat_A[8] = 8'sd42;

        mat_B[0] = 8'sd127;  mat_B[1] = 8'sd64;  mat_B[2] = 8'sd1;
        mat_B[3] = 8'sd0;    mat_B[4] = -8'sd1;  mat_B[5] = -8'sd75;
        mat_B[6] = -8'sd128; mat_B[7] = 8'sd42;  mat_B[8] = -8'sd50;

        for (i = 0; i < 9; i = i + 1) begin
            write_matrix_elem(1'b0, i[ADDR_WIDTH-1:0], mat_A[i]);
            write_matrix_elem(1'b1, i[ADDR_WIDTH-1:0], mat_B[i]);
        end

        // Stage via LOAD
        load_en <= 1'b1;
        for (i = 0; i < 3; i = i + 1) begin
            load_idx <= i[LOAD_IDX_W-1:0];
            @(posedge clk);
        end
        #1;
        load_en <= 1'b0;

        // Verify signed stream on compute
        compute_en <= 1'b1;
        cycle_count <= 3'd0;
        #1;
        check_condition("Cycle 0 row 0 a_west is -128",
            $signed(a_west[(0 * DATA_WIDTH) +: DATA_WIDTH]) === -8'sd128);
        check_condition("Cycle 0 col 0 b_north is +127",
            $signed(b_north[(0 * DATA_WIDTH) +: DATA_WIDTH]) === 8'sd127);

        cycle_count <= 3'd2;
        #1;
        check_condition("Cycle 2 row 0 a_west is -1",
            $signed(a_west[(0 * DATA_WIDTH) +: DATA_WIDTH]) === -8'sd1);
        check_condition("Cycle 2 row 2 a_west is +127",
            $signed(a_west[(2 * DATA_WIDTH) +: DATA_WIDTH]) === 8'sd127);
        compute_en <= 1'b0;

        // -------------------------------------------------------------
        // Test 26: Back-to-back operations without stale matrix or result data
        // -------------------------------------------------------------
        test_num = 26;
        $display("\n--- Test 26: Back-to-Back Operations ---");
        // Sequence 1: Diagonal matrices
        for (i = 0; i < 9; i = i + 1) begin
            mat_A[i] = 8'd0;
            mat_B[i] = 8'd0;
        end
        mat_A[0] = 8'sd2; mat_A[4] = 8'sd3; mat_A[8] = 8'sd4;
        mat_B[0] = 8'sd1; mat_B[4] = 8'sd1; mat_B[8] = 8'sd1;

        for (i = 0; i < 9; i = i + 1) begin
            write_matrix_elem(1'b0, i[ADDR_WIDTH-1:0], mat_A[i]);
            write_matrix_elem(1'b1, i[ADDR_WIDTH-1:0], mat_B[i]);
        end

        // Start Op 1
        @(posedge clk);
        host_start <= 1'b1;
        @(posedge clk);
        #1;
        host_start <= 1'b0;

        // LOAD Op 1
        controller_idle <= 1'b0;
        controller_busy <= 1'b1;
        load_en <= 1'b1;
        for (i = 0; i < 3; i = i + 1) begin
            load_idx <= i[LOAD_IDX_W-1:0];
            @(posedge clk);
        end
        #1;
        load_en <= 1'b0;

        // COMPUTE Op 1
        compute_en <= 1'b1;
        for (i = 0; i < 7; i = i + 1) begin
            cycle_count <= i[CYCLE_W-1:0];
            @(posedge clk);
        end
        compute_en <= 1'b0;

        // Capture Result 1
        for (i = 0; i < 9; i = i + 1) acc_in[(i * ACC_WIDTH) +: ACC_WIDTH] = 32'sd11;
        result_valid <= 1'b1;
        @(posedge clk);
        #1;
        result_valid <= 1'b0;
        controller_busy <= 1'b0;
        controller_idle <= 1'b1;
        check_condition("Op 1 result captured and available", buf_result_available == 1'b1);

        // Sequence 2: Write all 5s and all 2s
        for (i = 0; i < 9; i = i + 1) begin
            mat_A[i] = 8'sd5;
            mat_B[i] = 8'sd2;
            write_matrix_elem(1'b0, i[ADDR_WIDTH-1:0], mat_A[i]);
            write_matrix_elem(1'b1, i[ADDR_WIDTH-1:0], mat_B[i]);
        end

        // Start Op 2
        @(posedge clk);
        host_start <= 1'b1;
        @(posedge clk);
        #1;
        host_start <= 1'b0;
        check_condition("Op 2 start accepted", start_ack == 1'b1);
        @(posedge clk);
        #1;
        check_condition("Op 2 start invalidated Op 1 result", buf_result_available == 1'b0);

        // LOAD Op 2
        controller_idle <= 1'b0;
        controller_busy <= 1'b1;
        load_en <= 1'b1;
        for (i = 0; i < 3; i = i + 1) begin
            load_idx <= i[LOAD_IDX_W-1:0];
            @(posedge clk);
        end
        #1;
        load_en <= 1'b0;

        // Verify fresh staging without stale Op 1 data
        begin : check_fresh_stage
            reg no_stale;
            no_stale = 1'b1;
            for (i = 0; i < 9; i = i + 1) begin
                if ((get_staged_a(i) !== 8'sd5) || (get_staged_b(i) !== 8'sd2)) no_stale = 1'b0;
            end
            check_condition("Op 2 staging verified without stale Op 1 data", no_stale == 1'b1);
        end

        // COMPUTE Op 2
        compute_en <= 1'b1;
        cycle_count <= 3'd0;
        #1;
        check_condition("Op 2 stream shows new A data (5)",
            $signed(a_west[(0 * DATA_WIDTH) +: DATA_WIDTH]) === 8'sd5);
        check_condition("Op 2 stream shows new B data (2)",
            $signed(b_north[(0 * DATA_WIDTH) +: DATA_WIDTH]) === 8'sd2);
        compute_en <= 1'b0;

        // Capture Result 2 (30)
        for (i = 0; i < 9; i = i + 1) acc_in[(i * ACC_WIDTH) +: ACC_WIDTH] = 32'sd30;
        result_valid <= 1'b1;
        @(posedge clk);
        #1;
        result_valid <= 1'b0;
        controller_busy <= 1'b0;
        controller_idle <= 1'b1;

        // Readback Result 2
        @(posedge clk);
        host_read_en   <= 1'b1;
        host_read_addr <= 4'd0;
        @(posedge clk);
        #1;
        host_read_en   <= 1'b0;
        check_condition("Op 2 readback verifies clean result replacement (30)",
            (host_read_valid == 1'b1) && (host_read_data === 32'sd30));

        // -------------------------------------------------------------
        // Test 27: Reset during normal operation
        // -------------------------------------------------------------
        test_num = 27;
        $display("\n--- Test 27: Reset During Normal Operation ---");
        // Start an active compute phase
        controller_idle <= 1'b0;
        controller_busy <= 1'b1;
        compute_en <= 1'b1;
        cycle_count <= 3'd3;
        #1;
        check_condition("Pre-reset: computation active", a_west !== 24'b0);

        // Assert asynchronous reset mid-cycle
        rst_n <= 1'b0;
        #5;
        check_condition("Mid-cycle async reset clears a_west immediately", a_west == 24'b0);
        check_condition("Mid-cycle async reset clears b_north immediately", b_north == 24'b0);
        check_condition("Mid-cycle async reset clears matrices_ready", matrices_ready == 1'b0);
        check_condition("Mid-cycle async reset clears result_available", buf_result_available == 1'b0);

        @(posedge clk);
        #1;
        rst_n <= 1'b1;
        controller_idle <= 1'b1;
        controller_busy <= 1'b0;
        compute_en <= 1'b0;
        @(posedge clk);
        #1;
        check_condition("Post-reset state idle and all registers clean",
            (matrices_ready == 1'b0) && (buf_result_available == 1'b0) && (ctrl_start == 1'b0));

        // -------------------------------------------------------------
        // Final Summary and Exit Status
        // -------------------------------------------------------------
        $display("\n================================================================");
        $display("TEST RESULTS SUMMARY:");
        $display("  PASSED: %0d", pass_count);
        $display("  FAILED: %0d", fail_count);
        $display("================================================================");

        if (fail_count == 0) begin
            $display("RESULT: ALL DATA MANAGEMENT TESTS PASSED!\n");
            $finish;
        end else begin
            $display("RESULT: TESTS FAILED WITH %0d ERRORS!\n", fail_count);
            $fatal(1, "Data Management testbench failed with %0d errors.", fail_count);
        end
    end

endmodule

`default_nettype wire
