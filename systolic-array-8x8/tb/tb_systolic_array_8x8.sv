`timescale 1ns/1ps

module tb_systolic_array_8x8;
    localparam int ROWS = 8;
    localparam int COLS = 8;
    localparam int KMAX = 8;

    logic clk = 0;
    logic rst_n = 0;
    logic start = 0;
    logic start_ready;
    logic [3:0] active_rows;
    logic [3:0] active_cols;
    logic [3:0] k_len;
    logic [511:0] a_matrix_flat;
    logic [511:0] b_matrix_flat;
    logic busy;
    logic done;
    logic c_valid;
    logic config_error;
    logic [2047:0] c_matrix_flat;
    logic [63:0] mac_fire_flat;

    integer signed a_mem [0:ROWS-1][0:KMAX-1];
    integer signed b_mem [0:KMAX-1][0:COLS-1];
    integer errors = 0;
    integer mac_count = 0;
    integer test_id = 0;
    integer i;
    integer fires_this_cycle;

    always #5 clk = ~clk;

    systolic_array_8x8 dut (.*);

    always_comb begin
        fires_this_cycle = 0;
        for (i = 0; i < 64; i++)
            fires_this_cycle = fires_this_cycle + (mac_fire_flat[i] ? 1 : 0);
    end

    always @(posedge clk) begin
        if (start && start_ready)
            mac_count <= 0;
        else if (busy)
            mac_count <= mac_count + fires_this_cycle;
    end

    task automatic pack_inputs;
        integer r, c, k;
        begin
            a_matrix_flat = '0;
            b_matrix_flat = '0;
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < KMAX; k++)
                    a_matrix_flat[(r*KMAX+k)*8 +: 8] = a_mem[r][k][7:0];
            for (k = 0; k < KMAX; k++)
                for (c = 0; c < COLS; c++)
                    b_matrix_flat[(k*COLS+c)*8 +: 8] = b_mem[k][c][7:0];
        end
    endtask

    task automatic launch_and_check(input integer ar, input integer ac, input integer kl);
        integer r, c, k;
        integer signed expected;
        integer signed got;
        integer expected_macs;
        begin
            test_id = test_id + 1;
            active_rows = ar[3:0];
            active_cols = ac[3:0];
            k_len = kl[3:0];
            pack_inputs();

            @(negedge clk);
            if (!start_ready) begin
                $display("FAIL test %0d: engine was not ready", test_id);
                errors = errors + 1;
            end
            start = 1;
            @(negedge clk);
            start = 0;

            wait ((c_valid === 1'b1) && (done === 1'b1));
            #1;
            for (r = 0; r < ROWS; r++) begin
                for (c = 0; c < COLS; c++) begin
                    expected = 0;
                    if ((r < ar) && (c < ac))
                        for (k = 0; k < kl; k++)
                            expected = expected + a_mem[r][k] * b_mem[k][c];
                    got = $signed(c_matrix_flat[(r*COLS+c)*32 +: 32]);
                    if (got !== expected) begin
                        $display("FAIL test %0d C[%0d,%0d]: got %0d expected %0d",
                                 test_id, r, c, got, expected);
                        errors = errors + 1;
                    end
                end
            end

            expected_macs = ar * ac * kl;
            if (mac_count !== expected_macs) begin
                $display("FAIL test %0d MAC count: got %0d expected %0d",
                         test_id, mac_count, expected_macs);
                errors = errors + 1;
            end
        end
    endtask

    task automatic clear_memories;
        integer r, c, k;
        begin
            for (r = 0; r < ROWS; r++)
                for (k = 0; k < KMAX; k++) a_mem[r][k] = 0;
            for (k = 0; k < KMAX; k++)
                for (c = 0; c < COLS; c++) b_mem[k][c] = 0;
        end
    endtask

    integer init_r, init_c, init_k;
    initial begin
        active_rows = 0;
        active_cols = 0;
        k_len = 0;
        a_matrix_flat = '0;
        b_matrix_flat = '0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1;

        // Full 8x8 identity multiplication.
        clear_memories();
        for (init_r = 0; init_r < ROWS; init_r++)
            for (init_k = 0; init_k < KMAX; init_k++)
                a_mem[init_r][init_k] = ((init_r*17+init_k*3) % 31) - 15;
        for (init_k = 0; init_k < KMAX; init_k++) b_mem[init_k][init_k] = 1;
        launch_and_check(8, 8, 8);

        // Full signed-boundary stress.
        clear_memories();
        for (init_r = 0; init_r < ROWS; init_r++)
            for (init_k = 0; init_k < KMAX; init_k++)
                a_mem[init_r][init_k] = ((init_r+init_k) & 1) ? -128 : 127;
        for (init_k = 0; init_k < KMAX; init_k++)
            for (init_c = 0; init_c < COLS; init_c++)
                b_mem[init_k][init_c] = ((init_k+init_c) & 1) ? 127 : -128;
        launch_and_check(8, 8, 8);

        // Partial tile: 3x5 output with K=7; inactive outputs must remain zero.
        clear_memories();
        for (init_r = 0; init_r < ROWS; init_r++)
            for (init_k = 0; init_k < KMAX; init_k++)
                a_mem[init_r][init_k] = ((init_r*11+init_k*7) % 23) - 11;
        for (init_k = 0; init_k < KMAX; init_k++)
            for (init_c = 0; init_c < COLS; init_c++)
                b_mem[init_k][init_c] = ((init_k*5-init_c*9) % 19) - 9;
        launch_and_check(3, 5, 7);

        // Invalid zero-size request must be rejected without becoming busy.
        @(negedge clk);
        active_rows = 0;
        active_cols = 8;
        k_len = 8;
        start = 1;
        @(negedge clk);
        start = 0;
        if (!config_error || busy) begin
            $display("FAIL invalid configuration handling");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS tb_systolic_array_8x8: all tests matched");
        else
            $display("FAIL tb_systolic_array_8x8: %0d errors", errors);
        $finish;
    end

    initial begin
        repeat (5000) @(posedge clk);
        $display("FAIL watchdog timeout");
        $finish;
    end
endmodule
