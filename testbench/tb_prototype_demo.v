`timescale 1ns / 1ps
`default_nettype none

module tb_prototype_demo;

    localparam integer ARRAY_SIZE   = 3;
    localparam integer DATA_WIDTH   = 8;
    localparam integer ACC_WIDTH    = 32;
    localparam integer NUM_ELEMENTS = ARRAY_SIZE * ARRAY_SIZE;
    localparam integer ADDR_WIDTH   = (NUM_ELEMENTS <= 1) ? 1 : $clog2(NUM_ELEMENTS);

    reg                                 clk;
    reg                                 rst_n;

    reg                                 host_start;
    wire                                host_ready;
    wire                                host_busy;
    wire                                host_done;
    wire                                start_ack;
    wire                                start_err;

    reg                                 host_write_en;
    reg                                 host_write_is_b;
    reg  [ADDR_WIDTH-1:0]               host_write_addr;
    reg  signed [DATA_WIDTH-1:0]        host_write_data;
    wire                                host_write_ack;
    wire                                matrices_ready;

    reg                                 host_read_en;
    reg  [ADDR_WIDTH-1:0]               host_read_addr;
    wire signed [ACC_WIDTH-1:0]         host_read_data;
    wire                                host_read_valid;
    wire                                host_result_available;

    // Test storage and verification variables
    reg signed [DATA_WIDTH-1:0] matrix_a [0:NUM_ELEMENTS-1];
    reg signed [DATA_WIDTH-1:0] matrix_b [0:NUM_ELEMENTS-1];
    reg signed [ACC_WIDTH-1:0]  expected_matrix [0:NUM_ELEMENTS-1];
    reg signed [ACC_WIDTH-1:0]  actual_matrix   [0:NUM_ELEMENTS-1];

    integer i, row, col, k;
    integer timeout;
    integer elements_checked;
    integer mismatches;

    // Instantiate the actual integrated top module
    top_module #(
        .ARRAY_SIZE(ARRAY_SIZE),
        .DATA_WIDTH(DATA_WIDTH),
        .ACC_WIDTH (ACC_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) dut (
        .clk                  (clk),
        .rst_n                (rst_n),
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

    // 10 ns clock generation (100 MHz)
    initial clk = 1'b0;
    always #5 clk = ~clk;

    // Write a single matrix element via host interface
    task automatic write_host_element;
        input matrix_b_sel;
        input integer addr;
        input integer val;
        begin
            @(negedge clk);
            host_write_en   = 1'b1;
            host_write_is_b = matrix_b_sel;
            host_write_addr = addr[ADDR_WIDTH-1:0];
            host_write_data = val[DATA_WIDTH-1:0];
            #1;
            if (!host_write_ack) begin
                $display("ERROR: host_write_ack not asserted at address %0d (is_b=%0d)", addr, matrix_b_sel);
                $fatal(1, "Matrix write failed");
            end
            @(negedge clk);
            host_write_en   = 1'b0;
        end
    endtask

    // Read a single result element via host interface
    task automatic read_host_element;
        input integer addr;
        output signed [ACC_WIDTH-1:0] data_out;
        begin
            @(negedge clk);
            host_read_en   = 1'b1;
            host_read_addr = addr[ADDR_WIDTH-1:0];
            @(posedge clk);
            #1;
            if (!host_read_valid) begin
                $display("ERROR: host_read_valid not asserted at address %0d", addr);
                $fatal(1, "Result read failed");
            end
            data_out = host_read_data;
            @(negedge clk);
            host_read_en   = 1'b0;
        end
    endtask

    initial begin
        // Waveform dump
        $dumpfile("build/tb_prototype_demo.vcd");
        $dumpvars(0, tb_prototype_demo);

        // Signal initialization
        clk             = 1'b0;
        rst_n           = 1'b0;
        host_start      = 1'b0;
        host_write_en   = 1'b0;
        host_write_is_b = 1'b0;
        host_write_addr = {ADDR_WIDTH{1'b0}};
        host_write_data = {DATA_WIDTH{1'b0}};
        host_read_en    = 1'b0;
        host_read_addr  = {ADDR_WIDTH{1'b0}};
        mismatches      = 0;
        elements_checked= 0;

        $display("=============================================");
        $display("   SYSTOLIC ARRAY MATRIX MULTIPLICATION");
        $display("              PROTOTYPE DEMO");
        $display("=============================================\n");

        // -------------------------------------------------------------
        // Step 1: Initialization and Reset
        // -------------------------------------------------------------
        $display("[1] Initializing accelerator...");
        #2;
        if (host_busy || host_done || host_result_available || matrices_ready || host_ready) begin
            $display("ERROR: Unexpected status during active reset");
            $fatal(1, "Reset initialization failed");
        end
        #8;
        rst_n = 1'b1;
        @(posedge clk);
        #1;
        if (host_busy) begin
            $display("ERROR: Accelerator busy after reset release");
            $fatal(1, "Post-reset idle check failed");
        end
        $display("    Reset completed.\n");

        // -------------------------------------------------------------
        // Step 2: Display Input Matrices
        // -------------------------------------------------------------
        matrix_a[0] = 8'sd1; matrix_a[1] = 8'sd2; matrix_a[2] = 8'sd3;
        matrix_a[3] = 8'sd4; matrix_a[4] = 8'sd5; matrix_a[5] = 8'sd6;
        matrix_a[6] = 8'sd7; matrix_a[7] = 8'sd8; matrix_a[8] = 8'sd9;

        matrix_b[0] = 8'sd9; matrix_b[1] = 8'sd8; matrix_b[2] = 8'sd7;
        matrix_b[3] = 8'sd6; matrix_b[4] = 8'sd5; matrix_b[5] = 8'sd4;
        matrix_b[6] = 8'sd3; matrix_b[7] = 8'sd2; matrix_b[8] = 8'sd1;

        $display("[2] Input Matrices\n");
        $display("Matrix A:");
        $display("  %0d   %0d   %0d", matrix_a[0], matrix_a[1], matrix_a[2]);
        $display("  %0d   %0d   %0d", matrix_a[3], matrix_a[4], matrix_a[5]);
        $display("  %0d   %0d   %0d\n", matrix_a[6], matrix_a[7], matrix_a[8]);

        $display("Matrix B:");
        $display("  %0d   %0d   %0d", matrix_b[0], matrix_b[1], matrix_b[2]);
        $display("  %0d   %0d   %0d", matrix_b[3], matrix_b[4], matrix_b[5]);
        $display("  %0d   %0d   %0d\n", matrix_b[6], matrix_b[7], matrix_b[8]);

        // -------------------------------------------------------------
        // Step 3: Load Matrices through Host Interface
        // -------------------------------------------------------------
        $display("[3] Loading matrices through host interface...");
        for (i = 0; i < NUM_ELEMENTS; i = i + 1) begin
            write_host_element(1'b0, i, matrix_a[i]);
        end
        $display("    Matrix A: loaded");

        for (i = 0; i < NUM_ELEMENTS; i = i + 1) begin
            write_host_element(1'b1, i, matrix_b[i]);
        end
        $display("    Matrix B: loaded");

        @(posedge clk);
        #1;
        if (!matrices_ready || !host_ready) begin
            $display("ERROR: matrices_ready (%b) or host_ready (%b) not asserted", matrices_ready, host_ready);
            $fatal(1, "Matrix loading completion check failed");
        end
        $display("    Matrices ready: YES\n");

        // -------------------------------------------------------------
        // Step 4: Start Computation
        // -------------------------------------------------------------
        $display("[4] Starting accelerator...");
        @(negedge clk);
        host_start = 1'b1;
        @(posedge clk);
        #1;
        if (!start_ack || start_err) begin
            $display("ERROR: Start failed (start_ack=%b, start_err=%b)", start_ack, start_err);
            $fatal(1, "Start transaction failed");
        end
        $display("    Start acknowledged: YES");

        @(negedge clk);
        host_start = 1'b0;
        @(posedge clk);
        #1;
        if (!host_busy) begin
            $display("ERROR: Accelerator failed to enter busy state");
            $fatal(1, "Busy transition failed");
        end
        $display("    Accelerator busy: YES\n");

        // -------------------------------------------------------------
        // Step 5: Wait for Computation Completion
        // -------------------------------------------------------------
        $display("[5] Waiting for computation...");
        timeout = 0;
        while (!host_result_available && timeout < 40) begin
            @(posedge clk);
            #1;
            timeout = timeout + 1;
        end

        if (!host_result_available) begin
            $display("ERROR: Timeout waiting for host_result_available (cycles=%0d)", timeout);
            $fatal(1, "Computation timed out");
        end

        if (host_busy) begin
            $display("ERROR: Accelerator remained busy after result available");
            $fatal(1, "Busy flag post-completion check failed");
        end
        $display("    Computation completed.");
        $display("    Result available: YES\n");

        // -------------------------------------------------------------
        // Step 6: Read Actual Output Matrix
        // -------------------------------------------------------------
        $display("[6] Reading actual output matrix...\n");
        for (i = 0; i < NUM_ELEMENTS; i = i + 1) begin
            read_host_element(i, actual_matrix[i]);
        end

        $display("Output Matrix C:");
        $display("%3d   %2d   %2d", actual_matrix[0], actual_matrix[1], actual_matrix[2]);
        $display("%3d   %2d   %2d", actual_matrix[3], actual_matrix[4], actual_matrix[5]);
        $display("%3d  %3d  %2d\n",  actual_matrix[6], actual_matrix[7], actual_matrix[8]);

        // -------------------------------------------------------------
        // Step 7: Independent Matrix Multiplication & Verification
        // -------------------------------------------------------------
        for (row = 0; row < 3; row = row + 1) begin
            for (col = 0; col < 3; col = col + 1) begin
                expected_matrix[(row * 3) + col] = 0;
                for (k = 0; k < 3; k = k + 1) begin
                    expected_matrix[(row * 3) + col] =
                        expected_matrix[(row * 3) + col] +
                        matrix_a[(row * 3) + k] * matrix_b[(k * 3) + col];
                end
            end
        end

        for (i = 0; i < NUM_ELEMENTS; i = i + 1) begin
            elements_checked = elements_checked + 1;
            if (actual_matrix[i] !== expected_matrix[i]) begin
                mismatches = mismatches + 1;
                $display("ERROR: Mismatch at element [%0d][%0d]: Expected %0d, Got %0d",
                         i / 3, i % 3, expected_matrix[i], actual_matrix[i]);
            end
        end

        $display("[7] Verification");
        $display("    Output elements checked: %0d", elements_checked);
        $display("    Output mismatches: %0d\n", mismatches);

        if (mismatches != 0) begin
            $display("=============================================");
            $display("       PROTOTYPE DEMONSTRATION FAIL");
            $display("=============================================");
            $fatal(1, "Verification failed");
        end else begin
            $display("=============================================");
            $display("       PROTOTYPE DEMONSTRATION PASS");
            $display("=============================================");
            $finish;
        end
    end

    // Watchdog timer (50 us)
    initial begin
        #50000;
        $display("ERROR: Watchdog timeout in tb_prototype_demo!");
        $fatal(1);
    end

endmodule

`default_nettype wire
