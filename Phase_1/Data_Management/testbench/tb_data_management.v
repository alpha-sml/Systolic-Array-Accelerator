// tb_data_management.v
// Self-checking testbench for Data Management Subsystem:
//   - input_buffer
//   - output_buffer
//   - matrix_interface
//
// Covers Tests 1 through 14 as required by Task 4 specification.

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

    // Helper checking tasks
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

    integer i, j, k, cyc;
    reg signed [DATA_WIDTH-1:0] exp_a, act_a;
    reg signed [DATA_WIDTH-1:0] exp_b, act_b;
    reg skew_ok;

    initial begin
        // Waveform dump
        $dumpfile("Phase_1/Data_Management/testbench/tb_data_management.vcd");
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
        // Test 2: Matrix A writes
        // -------------------------------------------------------------
        test_num = 2;
        $display("\n--- Test 2: Matrix A Writes ---");
        // Matrix A:
        //  1  2  3
        //  4  5  6
        //  7  8  9
        for (i = 0; i < 9; i = i + 1) begin
            mat_A[i] = i + 1;
            write_matrix_elem(1'b0, i[ADDR_WIDTH-1:0], mat_A[i]);
        end

        // Verify storage in mem_a and written flags
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
        // Test 3: Matrix B writes
        // -------------------------------------------------------------
        test_num = 3;
        $display("\n--- Test 3: Matrix B Writes ---");
        // Matrix B:
        //  9  8  7
        //  6  5  4
        //  3  2  1
        for (i = 0; i < 8; i = i + 1) begin
            mat_B[i] = 9 - i;
            write_matrix_elem(1'b1, i[ADDR_WIDTH-1:0], mat_B[i]);
        end

        check_condition("matrices_ready remains low with 8/9 B elements written", matrices_ready == 1'b0);

        // Write 9th element of B
        mat_B[8] = 9 - 8; // 1
        write_matrix_elem(1'b1, 4'd8, mat_B[8]);

        check_condition("Written B flags all asserted", u_input_buffer.written_b == 9'b111111111);
        check_condition("matrices_ready goes high after all 18 elements written", matrices_ready == 1'b1);
        check_condition("host_ready is high when controller is idle and matrices_ready is 1", host_ready == 1'b1);

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
        // Test 4: Incomplete matrix rejection
        // -------------------------------------------------------------
        test_num = 4;
        $display("\n--- Test 4: Incomplete Matrix Rejection ---");
        // Reset DUT to clear written tracking
        apply_async_reset();
        check_condition("Post-reset matrices_ready is low", matrices_ready == 1'b0);

        // Write partial matrix A (5 elements) and B (5 elements)
        for (i = 0; i < 5; i = i + 1) begin
            write_matrix_elem(1'b0, i[ADDR_WIDTH-1:0], 8'd10 + i);
            write_matrix_elem(1'b1, i[ADDR_WIDTH-1:0], 8'd20 + i);
        end

        check_condition("Partial write: matrices_ready is 0", matrices_ready == 1'b0);

        // Attempt host_start while matrices are incomplete
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

        // Now write remaining elements of A and B
        for (i = 5; i < 9; i = i + 1) begin
            write_matrix_elem(1'b0, i[ADDR_WIDTH-1:0], 8'd1 + i); // 1..9
            write_matrix_elem(1'b1, i[ADDR_WIDTH-1:0], 8'd9 - i); // 9..1
        end
        // Overwrite 0..4 with 1..5 for A and 9..5 for B
        for (i = 0; i < 5; i = i + 1) begin
            mat_A[i] = i + 1;
            mat_B[i] = 9 - i;
            write_matrix_elem(1'b0, i[ADDR_WIDTH-1:0], mat_A[i]);
            write_matrix_elem(1'b1, i[ADDR_WIDTH-1:0], mat_B[i]);
        end
        for (i = 5; i < 9; i = i + 1) begin
            mat_A[i] = i + 1;
            mat_B[i] = 9 - i;
        end

        check_condition("All elements written: matrices_ready is now 1", matrices_ready == 1'b1);

        // -------------------------------------------------------------
        // Test 5: LOAD phase staging
        // -------------------------------------------------------------
        test_num = 5;
        $display("\n--- Test 5: LOAD Phase Staging ---");
        // Simulate controller LOAD phase: 3 cycles
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

        // Verify full staging content matches mem
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
        // Test 6: A operand skewing
        // -------------------------------------------------------------
        test_num = 6;
        $display("\n--- Test 6: A Operand Skewing ---");
        // COMPUTE phase: 7 cycles (0 to 6)
        compute_en <= 1'b1;

        skew_ok = 1'b1;
        for (cyc = 0; cyc < 7; cyc = cyc + 1) begin
            cycle_count <= cyc[CYCLE_W-1:0];
            #1; // combinational settle

            // Check row 0
            if (cyc >= 0 && cyc < 3) exp_a = mat_A[(0 * 3) + cyc];
            else exp_a = 8'd0;
            act_a = a_west[(0 * DATA_WIDTH) +: DATA_WIDTH];
            if (act_a !== exp_a) begin
                $display("Mismatch cycle %0d row 0: exp %0d, act %0d", cyc, exp_a, act_a);
                skew_ok = 1'b0;
            end

            // Check row 1
            if (cyc >= 1 && cyc < 4) exp_a = mat_A[(1 * 3) + (cyc - 1)];
            else exp_a = 8'd0;
            act_a = a_west[(1 * DATA_WIDTH) +: DATA_WIDTH];
            if (act_a !== exp_a) begin
                $display("Mismatch cycle %0d row 1: exp %0d, act %0d", cyc, exp_a, act_a);
                skew_ok = 1'b0;
            end

            // Check row 2
            if (cyc >= 2 && cyc < 5) exp_a = mat_A[(2 * 3) + (cyc - 2)];
            else exp_a = 8'd0;
            act_a = a_west[(2 * DATA_WIDTH) +: DATA_WIDTH];
            if (act_a !== exp_a) begin
                $display("Mismatch cycle %0d row 2: exp %0d, act %0d", cyc, exp_a, act_a);
                skew_ok = 1'b0;
            end

            @(posedge clk);
        end
        check_condition("A operand skewing stream exactly matches 7-cycle schedule", skew_ok == 1'b1);

        // -------------------------------------------------------------
        // Test 7: B operand skewing
        // -------------------------------------------------------------
        test_num = 7;
        $display("\n--- Test 7: B Operand Skewing ---");
        skew_ok = 1'b1;
        for (cyc = 0; cyc < 7; cyc = cyc + 1) begin
            cycle_count <= cyc[CYCLE_W-1:0];
            #1; // combinational settle

            // Check col 0
            if (cyc >= 0 && cyc < 3) exp_b = mat_B[(cyc * 3) + 0];
            else exp_b = 8'd0;
            act_b = b_north[(0 * DATA_WIDTH) +: DATA_WIDTH];
            if (act_b !== exp_b) begin
                $display("Mismatch cycle %0d col 0: exp %0d, act %0d", cyc, exp_b, act_b);
                skew_ok = 1'b0;
            end

            // Check col 1
            if (cyc >= 1 && cyc < 4) exp_b = mat_B[((cyc - 1) * 3) + 1];
            else exp_b = 8'd0;
            act_b = b_north[(1 * DATA_WIDTH) +: DATA_WIDTH];
            if (act_b !== exp_b) begin
                $display("Mismatch cycle %0d col 1: exp %0d, act %0d", cyc, exp_b, act_b);
                skew_ok = 1'b0;
            end

            // Check col 2
            if (cyc >= 2 && cyc < 5) exp_b = mat_B[((cyc - 2) * 3) + 2];
            else exp_b = 8'd0;
            act_b = b_north[(2 * DATA_WIDTH) +: DATA_WIDTH];
            if (act_b !== exp_b) begin
                $display("Mismatch cycle %0d col 2: exp %0d, act %0d", cyc, exp_b, act_b);
                skew_ok = 1'b0;
            end

            @(posedge clk);
        end
        check_condition("B operand skewing stream exactly matches 7-cycle schedule", skew_ok == 1'b1);

        // -------------------------------------------------------------
        // Test 8: Compute disable
        // -------------------------------------------------------------
        test_num = 8;
        $display("\n--- Test 8: Compute Disable ---");
        compute_en <= 1'b0;
        cycle_count <= 3'd2; // mid-range cycle
        #1;
        check_condition("With compute_en=0, a_west is 0", a_west == 24'b0);
        check_condition("With compute_en=0, b_north is 0", b_north == 24'b0);

        // Verify staging registers not modified
        begin : check_staging_preserved
            reg preserved_ok;
            preserved_ok = 1'b1;
            for (i = 0; i < 9; i = i + 1) begin
                if ((get_staged_a(i) !== mat_A[i]) ||
                    (get_staged_b(i) !== mat_B[i]))
                    preserved_ok = 1'b0;
            end
            check_condition("Staging registers unchanged when compute disabled", preserved_ok == 1'b1);
        end

        // -------------------------------------------------------------
        // Test 9: Output buffer result capture
        // -------------------------------------------------------------
        test_num = 9;
        $display("\n--- Test 9: Output Buffer Result Capture ---");
        // Compute golden C = A x B
        // A = [1 2 3; 4 5 6; 7 8 9]
        // B = [9 8 7; 6 5 4; 3 2 1]
        // C[0][0] = 1*9 + 2*6 + 3*3 = 9 + 12 + 9 = 30
        // C[0][1] = 1*8 + 2*5 + 3*2 = 8 + 10 + 6 = 24
        // C[0][2] = 1*7 + 2*4 + 3*1 = 7 + 8 + 3 = 18
        // C[1][0] = 4*9 + 5*6 + 6*3 = 36 + 30 + 18 = 84
        // C[1][1] = 4*8 + 5*5 + 6*2 = 32 + 25 + 12 = 69
        // C[1][2] = 4*7 + 5*4 + 6*1 = 28 + 20 + 6 = 54
        // C[2][0] = 7*9 + 8*6 + 9*3 = 63 + 48 + 27 = 138
        // C[2][1] = 7*8 + 8*5 + 9*2 = 56 + 40 + 18 = 114
        // C[2][2] = 7*7 + 8*4 + 9*1 = 49 + 32 + 9 = 90
        mat_C[0] = 32'sd30;
        mat_C[1] = 32'sd24;
        mat_C[2] = 32'sd18;
        mat_C[3] = 32'sd84;
        mat_C[4] = 32'sd69;
        mat_C[5] = 32'sd54;
        mat_C[6] = 32'sd138;
        mat_C[7] = 32'sd114;
        mat_C[8] = 32'sd90;

        for (i = 0; i < 9; i = i + 1) begin
            acc_in[(i * ACC_WIDTH) +: ACC_WIDTH] = mat_C[i];
        end

        // Assert result_valid for 1 clock cycle (DONE state)
        @(posedge clk);
        controller_busy <= 1'b0;
        controller_done <= 1'b1;
        result_valid    <= 1'b1;
        @(posedge clk);
        #1;
        result_valid    <= 1'b0;
        controller_done <= 1'b0;
        controller_idle <= 1'b1;

        check_condition("result_available asserted after result_valid edge", buf_result_available == 1'b1);
        check_condition("host_result_available asserted", host_result_available == 1'b1);

        // Check captured values in result_mem
        begin : check_capture
            reg cap_ok;
            cap_ok = 1'b1;
            for (i = 0; i < 9; i = i + 1) begin
                if (u_output_buffer.result_mem[i] !== mat_C[i])
                    cap_ok = 1'b0;
            end
            check_condition("All 9 elements captured accurately on rising clock edge", cap_ok == 1'b1);
        end

        // Ensure captured result remains stable after result_valid drops
        #20;
        @(posedge clk);
        #1;
        check_condition("Result available holds stable over multiple clock cycles", buf_result_available == 1'b1);

        // -------------------------------------------------------------
        // Test 10: Output buffer indexed readback
        // -------------------------------------------------------------
        test_num = 10;
        $display("\n--- Test 10: Output Buffer Indexed Readback ---");
        begin : test_readback
            reg read_ok;
            reg pulse_ok;
            read_ok  = 1'b1;
            pulse_ok = 1'b1;

            for (i = 0; i < 9; i = i + 1) begin
                @(posedge clk);
                host_read_en   <= 1'b1;
                host_read_addr <= i[ADDR_WIDTH-1:0];
                @(posedge clk);
                #1;
                host_read_en   <= 1'b0;
                if (!host_read_valid || (host_read_data !== mat_C[i])) begin
                    $display("Mismatch read addr %0d: exp %0d, act %0d (valid=%b)",
                        i, mat_C[i], host_read_data, host_read_valid);
                    read_ok = 1'b0;
                end
                @(posedge clk);
                #1;
                if (host_read_valid !== 1'b0) begin
                    pulse_ok = 1'b0;
                end
            end
            check_condition("Row-major indexed read returns exact signed 32-bit values", read_ok == 1'b1);
            check_condition("read_valid pulses for exactly 1 cycle per valid read", pulse_ok == 1'b1);
        end

        // Out-of-range address read test (addr = 9, 12)
        @(posedge clk);
        host_read_en   <= 1'b1;
        host_read_addr <= 4'd9;
        @(posedge clk);
        #1;
        host_read_en   <= 1'b0;
        check_condition("Out-of-range address produces read_valid = 0", host_read_valid == 1'b0);
        check_condition("Out-of-range address returns 0 data", host_read_data == 32'sd0);

        // -------------------------------------------------------------
        // Test 11: Result invalidation
        // -------------------------------------------------------------
        test_num = 11;
        $display("\n--- Test 11: Result Invalidation ---");
        check_condition("Pre-condition: result_available is currently 1", buf_result_available == 1'b1);

        // Issue new accepted start request
        @(posedge clk);
        host_start <= 1'b1;
        @(posedge clk);
        #1;
        host_start <= 1'b0;
        check_condition("out_buf_clear asserted on accepted start", out_buf_clear == 1'b1);

        @(posedge clk);
        #1;
        check_condition("Previous result invalidated: result_available is now 0", buf_result_available == 1'b0);
        check_condition("host_result_available is 0", host_result_available == 1'b0);

        // Attempt read while result_available = 0
        @(posedge clk);
        host_read_en   <= 1'b1;
        host_read_addr <= 4'd0;
        @(posedge clk);
        #1;
        host_read_en   <= 1'b0;
        check_condition("Read while invalidated returns read_valid = 0", host_read_valid == 1'b0);

        // Capture replacement result
        for (i = 0; i < 9; i = i + 1) begin
            acc_in[(i * ACC_WIDTH) +: ACC_WIDTH] = 32'sd500 + i;
        end
        @(posedge clk);
        result_valid <= 1'b1;
        @(posedge clk);
        #1;
        result_valid <= 1'b0;
        check_condition("Subsequent result_valid captures replacement result", buf_result_available == 1'b1);
        check_condition("Replacement value C[0] is 500", u_output_buffer.result_mem[0] == 32'sd500);

        // -------------------------------------------------------------
        // Test 12: Host start and status
        // -------------------------------------------------------------
        test_num = 12;
        $display("\n--- Test 12: Host Start and Status ---");
        // Start accepted when idle and matrices ready
        controller_idle <= 1'b1;
        controller_busy <= 1'b0;
        @(posedge clk);
        host_start <= 1'b1;
        @(posedge clk);
        #1;
        check_condition("Start accepted when idle & ready: ctrl_start asserted", ctrl_start == 1'b1);
        check_condition("start_ack asserted", start_ack == 1'b1);
        check_condition("start_err not asserted", start_err == 1'b0);

        // Verify held-high host_start does NOT re-trigger
        @(posedge clk);
        #1;
        check_condition("Held host_start: ctrl_start dropped after 1 cycle", ctrl_start == 1'b0);
        @(posedge clk);
        @(posedge clk);
        #1;
        check_condition("Held host_start across multiple cycles produces NO repeated start", ctrl_start == 1'b0);
        host_start <= 1'b0;
        @(posedge clk);

        // Start rejected when busy
        controller_idle <= 1'b0;
        controller_busy <= 1'b1;
        @(posedge clk);
        host_start <= 1'b1;
        @(posedge clk);
        #1;
        check_condition("Start rejected when busy: ctrl_start remained 0", ctrl_start == 1'b0);
        check_condition("start_err asserted on busy start attempt", start_err == 1'b1);
        host_start <= 1'b0;
        @(posedge clk);
        #1;

        // Controller busy and done exposed to host
        check_condition("host_busy correctly reflects controller_busy", host_busy == 1'b1);
        controller_busy <= 1'b0;
        controller_done <= 1'b1;
        #1;
        check_condition("host_done correctly reflects controller_done", host_done == 1'b1);
        controller_done <= 1'b0;
        controller_idle <= 1'b1;
        #1;

        // -------------------------------------------------------------
        // Test 13: Signed matrix values
        // -------------------------------------------------------------
        test_num = 13;
        $display("\n--- Test 13: Signed Matrix Values ---");
        // Test elements: -128, -75, -1, 0, 1, 64, 127, -50, 42
        mat_A[0] = -8'sd128;
        mat_A[1] = -8'sd75;
        mat_A[2] = -8'sd1;
        mat_A[3] = 8'sd0;
        mat_A[4] = 8'sd1;
        mat_A[5] = 8'sd64;
        mat_A[6] = 8'sd127;
        mat_A[7] = -8'sd50;
        mat_A[8] = 8'sd42;

        mat_B[0] = 8'sd127;
        mat_B[1] = 8'sd64;
        mat_B[2] = 8'sd1;
        mat_B[3] = 8'sd0;
        mat_B[4] = -8'sd1;
        mat_B[5] = -8'sd75;
        mat_B[6] = -8'sd128;
        mat_B[7] = 8'sd42;
        mat_B[8] = -8'sd50;

        for (i = 0; i < 9; i = i + 1) begin
            write_matrix_elem(1'b0, i[ADDR_WIDTH-1:0], mat_A[i]);
            write_matrix_elem(1'b1, i[ADDR_WIDTH-1:0], mat_B[i]);
        end

        // Verify signed storage
        begin : check_signed_mem
            reg signed_ok;
            signed_ok = 1'b1;
            for (i = 0; i < 9; i = i + 1) begin
                if ((u_input_buffer.mem_a[i] !== mat_A[i]) ||
                    (u_input_buffer.mem_b[i] !== mat_B[i]))
                    signed_ok = 1'b0;
            end
            check_condition("Negative and positive boundary values accurately stored in signed memory",
                signed_ok == 1'b1);
        end

        // Stage signed values through LOAD
        load_en <= 1'b1;
        for (i = 0; i < 3; i = i + 1) begin
            load_idx <= i[LOAD_IDX_W-1:0];
            @(posedge clk);
        end
        load_en <= 1'b0;
        #1;

        // Check skewed operand values at cycle 0
        compute_en <= 1'b1;
        cycle_count <= 3'd0;
        #1;
        check_condition("Row 0 west output holds signed -128",
            $signed(a_west[(0 * DATA_WIDTH) +: DATA_WIDTH]) === -8'sd128);
        check_condition("Col 0 north output holds signed +127",
            $signed(b_north[(0 * DATA_WIDTH) +: DATA_WIDTH]) === 8'sd127);

        // Cycle 2: A[0][2] = -1, A[1][1] = 1, A[2][0] = 127
        cycle_count <= 3'd2;
        #1;
        check_condition("Cycle 2 row 0 holds signed -1",
            $signed(a_west[(0 * DATA_WIDTH) +: DATA_WIDTH]) === -8'sd1);
        check_condition("Cycle 2 row 1 holds signed +1",
            $signed(a_west[(1 * DATA_WIDTH) +: DATA_WIDTH]) === 8'sd1);
        check_condition("Cycle 2 row 2 holds signed +127",
            $signed(a_west[(2 * DATA_WIDTH) +: DATA_WIDTH]) === 8'sd127);

        compute_en <= 1'b0;

        // -------------------------------------------------------------
        // Test 14: Back-to-back operations
        // -------------------------------------------------------------
        test_num = 14;
        $display("\n--- Test 14: Back-to-Back Operations ---");
        // Sequence 1:
        // Set up Identity for B, diagonal matrix for A
        // A = [2 0 0; 0 3 0; 0 0 4]
        // B = [1 0 0; 0 1 0; 0 0 1]
        // Expected C = [2 0 0; 0 3 0; 0 0 4]
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

        // Operation 1 Start
        @(posedge clk);
        host_start <= 1'b1;
        @(posedge clk);
        #1;
        host_start <= 1'b0;

        // LOAD Phase
        controller_idle <= 1'b0;
        controller_busy <= 1'b1;
        load_en <= 1'b1;
        for (i = 0; i < 3; i = i + 1) begin
            load_idx <= i[LOAD_IDX_W-1:0];
            @(posedge clk);
        end
        load_en <= 1'b0;

        // COMPUTE Phase
        compute_en <= 1'b1;
        for (i = 0; i < 7; i = i + 1) begin
            cycle_count <= i[CYCLE_W-1:0];
            @(posedge clk);
        end
        compute_en <= 1'b0;

        // DONE Phase & Capture Result 1
        mat_C[0] = 32'sd2; mat_C[4] = 32'sd3; mat_C[8] = 32'sd4;
        mat_C[1] = 32'sd0; mat_C[2] = 32'sd0; mat_C[3] = 32'sd0;
        mat_C[5] = 32'sd0; mat_C[6] = 32'sd0; mat_C[7] = 32'sd0;
        for (i = 0; i < 9; i = i + 1) begin
            acc_in[(i * ACC_WIDTH) +: ACC_WIDTH] = mat_C[i];
        end
        result_valid <= 1'b1;
        @(posedge clk);
        #1;
        result_valid <= 1'b0;
        controller_busy <= 1'b0;
        controller_idle <= 1'b1;

        check_condition("Op 1 result captured and available", buf_result_available == 1'b1);

        // Sequence 2: Write completely new matrix data
        // A = all 5s, B = all 2s
        // Expected C = 3 * (5 * 2) = 30 for all elements
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
        check_condition("Op 2 start immediately invalidated Op 1 result", buf_result_available == 1'b0);

        // LOAD Phase Op 2
        controller_idle <= 1'b0;
        controller_busy <= 1'b1;
        load_en <= 1'b1;
        for (i = 0; i < 3; i = i + 1) begin
            load_idx <= i[LOAD_IDX_W-1:0];
            @(posedge clk);
        end
        #1;
        load_en <= 1'b0;

        // Verify staging updated to 5 and 2 (no stale Op 1 values)
        begin : check_no_stale_staging
            reg fresh_staged;
            fresh_staged = 1'b1;
            for (i = 0; i < 9; i = i + 1) begin
                if ((get_staged_a(i) !== 8'sd5) ||
                    (get_staged_b(i) !== 8'sd2))
                    fresh_staged = 1'b0;
            end
            check_condition("Op 2 LOAD staged fresh matrix values without stale Op 1 data",
                fresh_staged == 1'b1);
        end

        // COMPUTE Phase Op 2
        compute_en <= 1'b1;
        cycle_count <= 3'd0;
        #1;
        check_condition("Op 2 operand stream reflects new matrix A value (5)",
            $signed(a_west[(0 * DATA_WIDTH) +: DATA_WIDTH]) === 8'sd5);
        check_condition("Op 2 operand stream reflects new matrix B value (2)",
            $signed(b_north[(0 * DATA_WIDTH) +: DATA_WIDTH]) === 8'sd2);

        for (i = 0; i < 7; i = i + 1) begin
            cycle_count <= i[CYCLE_W-1:0];
            @(posedge clk);
        end
        compute_en <= 1'b0;

        // Capture Result 2 (all 30)
        for (i = 0; i < 9; i = i + 1) begin
            acc_in[(i * ACC_WIDTH) +: ACC_WIDTH] = 32'sd30;
        end
        result_valid <= 1'b1;
        @(posedge clk);
        #1;
        result_valid <= 1'b0;
        controller_busy <= 1'b0;
        controller_idle <= 1'b1;

        check_condition("Op 2 result captured and available", buf_result_available == 1'b1);

        // Readback Op 2 result and verify replacement
        begin : read_op2
            reg op2_ok;
            op2_ok = 1'b1;
            for (i = 0; i < 9; i = i + 1) begin
                @(posedge clk);
                host_read_en   <= 1'b1;
                host_read_addr <= i[ADDR_WIDTH-1:0];
                @(posedge clk);
                #1;
                host_read_en   <= 1'b0;
                if (!host_read_valid || (host_read_data !== 32'sd30))
                    op2_ok = 1'b0;
            end
            check_condition("Op 2 readback confirms complete replacement of result (all 30)", op2_ok == 1'b1);
        end

        // -------------------------------------------------------------
        // Summary
        // -------------------------------------------------------------
        $display("\n================================================================");
        $display("TEST RESULTS SUMMARY:");
        $display("  PASSED: %0d", pass_count);
        $display("  FAILED: %0d", fail_count);
        $display("================================================================");

        if (fail_count == 0) begin
            $display("RESULT: ALL DATA MANAGEMENT TESTS PASSED!\n");
        end else begin
            $display("RESULT: TESTS FAILED WITH %0d ERRORS!\n", fail_count);
        end

        $finish;
    end

endmodule

`default_nettype wire
