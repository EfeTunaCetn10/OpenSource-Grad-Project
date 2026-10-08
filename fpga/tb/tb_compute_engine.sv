`timescale 1ns/1ps

module tb_compute_engine;
    localparam int ROWS = 8;
    localparam int COLS = 8;
    // The normal network cases are 75/150/400.  A larger verification
    // instance is needed for the separate INT32-wrap directed case: with
    // INT8 products, K<=1024 cannot overflow a 32-bit accumulator.
    localparam int KMAX = 131200;
    localparam int KW = $clog2(KMAX+1);

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic start = 1'b0;
    logic start_ready;
    logic [3:0] active_rows, active_cols;
    logic [KW-1:0] k_len;
    logic weight_valid = 1'b0;
    logic weight_ready;
    logic [ROWS*8-1:0] weight_data = '0;
    logic activation_valid = 1'b0;
    logic activation_ready;
    logic [COLS*8-1:0] activation_data = '0;
    logic busy, done, config_error;
    logic out_valid, out_ready = 1'b1;
    logic [ROWS*32-1:0] out_acc_flat;
    logic [ROWS-1:0] out_lane_valid;
    logic [3:0] out_col;
    logic out_k_last, out_last, drain_stall;
    logic [31:0] cycle_count;
    logic [ROWS*COLS-1:0] mac_fire_flat;

    integer signed a_mem [0:ROWS-1][0:KMAX-1];
    integer signed b_mem [0:KMAX-1][0:COLS-1];
    logic signed [31:0] expected [0:ROWS-1][0:COLS-1];
    integer errors = 0;
    integer score_col;
    integer score_rows;
    integer score_cols;
    integer score_beats;
    integer score_case;
    integer signed prod;
    longint signed accum;
    integer r, c, k;

    always #5 clk = ~clk;

    function automatic logic signed [31:0] wrap32(input longint signed value);
        logic signed [31:0] low;
        begin
            low = value[31:0];
            wrap32 = low;
        end
    endfunction

    compute_engine #(
        .ROWS(ROWS), .COLS(COLS), .K_MAX(KMAX), .DATA_WIDTH(8), .ACC_WIDTH(32)
    ) dut (
        .clk(clk), .rst_n(rst_n), .start(start), .start_ready(start_ready),
        .active_rows(active_rows), .active_cols(active_cols), .k_len(k_len),
        .weight_valid(weight_valid), .weight_ready(weight_ready), .weight_data(weight_data),
        .activation_valid(activation_valid), .activation_ready(activation_ready),
        .activation_data(activation_data), .busy(busy), .done(done),
        .config_error(config_error), .out_valid(out_valid), .out_ready(out_ready),
        .out_acc_flat(out_acc_flat), .out_lane_valid(out_lane_valid), .out_col(out_col),
        .out_k_last(out_k_last), .out_last(out_last), .drain_stall(drain_stall),
        .cycle_count(cycle_count), .mac_fire_flat(mac_fire_flat)
    );

    // The DUT presents one column per output cycle and all row lanes together.
    always @(posedge clk) begin
        if (out_valid && out_ready) begin
            if (out_col !== score_col[3:0]) begin
                $display("FAIL T_ENG_DRAIN: case %0d column got %0d expected %0d", score_case, out_col, score_col);
                errors = errors + 1;
            end
            if (out_k_last !== 1'b1) begin
                $display("FAIL T_ENG_DRAIN: case %0d k_last was low", score_case);
                errors = errors + 1;
            end
            if (out_last !== (score_col == score_cols-1)) begin
                $display("FAIL T_ENG_DRAIN: case %0d out_last at column %0d", score_case, score_col);
                errors = errors + 1;
            end
            for (r = 0; r < ROWS; r = r + 1) begin
                if (out_lane_valid[r] !== (r < score_rows)) begin
                    $display("FAIL T_ENG_DRAIN: case %0d lane-valid r=%0d", score_case, r);
                    errors = errors + 1;
                end
                if ($signed(out_acc_flat[r*32 +: 32]) !== expected[r][score_col]) begin
                    $display("FAIL T_ENG_DRAIN: case %0d lane=%0d col=%0d got=%0d expected=%0d",
                             score_case, r, score_col,
                             $signed(out_acc_flat[r*32 +: 32]), expected[r][score_col]);
                    errors = errors + 1;
                end
            end
            score_col = score_col + 1;
            score_beats = score_beats + 1;
        end
    end

    task automatic fill_case(input integer ar, input integer ac, input integer kl,
                             input integer pattern);
        integer rr, cc, kk;
        begin
            for (rr = 0; rr < ROWS; rr = rr + 1)
                for (kk = 0; kk < KMAX; kk = kk + 1)
                    a_mem[rr][kk] = 0;
            for (kk = 0; kk < KMAX; kk = kk + 1)
                for (cc = 0; cc < COLS; cc = cc + 1)
                    b_mem[kk][cc] = 0;

            for (rr = 0; rr < ar; rr = rr + 1) begin
                for (kk = 0; kk < kl; kk = kk + 1) begin
                    case (pattern)
                        0: a_mem[rr][kk] = ((rr*29 + kk*7) % 127) - 63;
                        1: a_mem[rr][kk] = ((rr+kk) & 1) ? -128 : 127;
                        2: a_mem[rr][kk] = ((rr*13 + kk*5) % 31) - 15;
                        3: a_mem[rr][kk] = (rr*17 + kk*3 + 1);
                        4: a_mem[rr][kk] = -128;
                        default: a_mem[rr][kk] = ((rr*11 + kk*3) % 251) - 125;
                    endcase
                end
            end
            for (kk = 0; kk < kl; kk = kk + 1) begin
                for (cc = 0; cc < ac; cc = cc + 1) begin
                    case (pattern)
                        0: b_mem[kk][cc] = ((kk*19 + cc*23) % 127) - 63;
                        1: b_mem[kk][cc] = ((kk+cc) & 1) ? 127 : -128;
                        2: b_mem[kk][cc] = ((kk*7 - cc*9) % 37) - 18;
                        3: b_mem[kk][cc] = (kk+1)*(cc+1);
                        4: b_mem[kk][cc] = -128;
                        default: b_mem[kk][cc] = ((kk*5 + cc*17) % 253) - 126;
                    endcase
                end
            end

            for (rr = 0; rr < ROWS; rr = rr + 1)
                for (cc = 0; cc < COLS; cc = cc + 1) begin
                    accum = 0;
                    if ((rr < ar) && (cc < ac)) begin
                        for (kk = 0; kk < kl; kk = kk + 1) begin
                            prod = a_mem[rr][kk] * b_mem[kk][cc];
                            accum = accum + prod;
                            expected[rr][cc] = wrap32(accum);
                        end
                    end else begin
                        expected[rr][cc] = '0;
                    end
                end
        end
    endtask

    task automatic run_case(input integer ar, input integer ac, input integer kl,
                            input integer pattern, input integer stall_mode);
        integer kk;
        integer phase;
        integer accepted;
        begin
            score_case = score_case + 1;
            fill_case(ar, ac, kl, pattern);
            score_rows = ar;
            score_cols = ac;
            score_col = 0;
            score_beats = 0;
            active_rows = ar[3:0];
            active_cols = ac[3:0];
            k_len = kl[KW-1:0];

            @(negedge clk);
            if (!start_ready) begin
                $display("FAIL T_ENG_START: case %0d not ready", score_case);
                errors = errors + 1;
            end
            start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;
            if (config_error) begin
                $display("FAIL T_ENG_START: case %0d unexpectedly rejected", score_case);
                errors = errors + 1;
                $finish;
            end
            weight_valid = 1'b0;
            activation_valid = 1'b0;
            // CLEAR consumes the next edge and flushes both array link pipes.
            @(posedge clk);

            accepted = 0;
            while (accepted < kl) begin
                phase = stall_mode ? ((accepted + score_case) % 7) : 3;
                @(negedge clk);
                weight_data = '0;
                activation_data = '0;
                for (r = 0; r < ROWS; r = r + 1)
                    weight_data[r*8 +: 8] = a_mem[r][accepted][7:0];
                for (c = 0; c < COLS; c = c + 1)
                    activation_data[c*8 +: 8] = b_mem[accepted][c][7:0];

                // A one-sided valid is held until the pair is available.  The
                // engine's coupled ready therefore cannot drop that beat.
                if (phase == 0) begin
                    weight_valid = 1'b0;
                    activation_valid = 1'b1;
                    @(posedge clk);
                    @(negedge clk);
                    weight_valid = 1'b1;
                    activation_valid = 1'b1;
                end else if (phase == 1) begin
                    weight_valid = 1'b1;
                    activation_valid = 1'b0;
                    @(posedge clk);
                    @(negedge clk);
                    weight_valid = 1'b1;
                    activation_valid = 1'b1;
                end else if (phase == 2) begin
                    weight_valid = 1'b0;
                    activation_valid = 1'b0;
                    @(posedge clk);
                    @(negedge clk);
                    weight_valid = 1'b1;
                    activation_valid = 1'b1;
                end else begin
                    weight_valid = 1'b1;
                    activation_valid = 1'b1;
                end

                @(posedge clk);
                // Both valids were only driven together when the beat was
                // intended to be offered; the engine's coupled ready makes
                // that pair the only possible acceptance.
                if (weight_valid && activation_valid) begin
                    accepted = accepted + 1;
                    weight_valid = 1'b0;
                    activation_valid = 1'b0;
                end else begin
                    $display("FAIL T_ENG_SOURCE: case %0d beat %0d not accepted", score_case, accepted);
                    errors = errors + 1;
                end
            end

            wait (done === 1'b1);
            if (score_beats != ac) begin
                $display("FAIL T_ENG_DRAIN: case %0d got %0d beats expected %0d", score_case, score_beats, ac);
                errors = errors + 1;
            end
            if (score_col != ac) begin
                $display("FAIL T_ENG_DRAIN: case %0d final column counter %0d expected %0d", score_case, score_col, ac);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        active_rows = 0;
        active_cols = 0;
        k_len = 0;
        score_case = 0;
        score_col = 0;
        score_rows = 0;
        score_cols = 0;
        score_beats = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        // T_ENG_KSTREAM_001: the three ADR-002 reductions.
        run_case(8, 8, 75, 0, 0);
        run_case(8, 8, 150, 2, 0);
        run_case(8, 8, 400, 5, 0);

        // T_ENG_SKEW_001: every row, column, and K position changes the value.
        run_case(5, 6, 11, 3, 0);

        // Partial tiles, signed boundaries, and a repeated tile with stalls.
        run_case(1, 1, 13, 1, 0);
        run_case(3, 5, 7, 2, 1);
        run_case(8, 8, 9, 1, 1);

        // T_ENG_WRAP_001: 16384 * 131073 crosses the signed INT32 boundary.
        run_case(1, 1, 131073, 4, 0);

        // Validation guard: invalid requests neither start nor become busy.
        @(negedge clk);
        active_rows = 0;
        active_cols = 8;
        k_len = 8;
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;
        if (!config_error || busy) begin
            $display("FAIL T_ENG_CONFIG: zero dimension was not rejected");
            errors = errors + 1;
        end

        @(negedge clk);
        active_rows = 8;
        active_cols = 8;
        k_len = KMAX + 1;
        start = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;
        if (!config_error || busy) begin
            $display("FAIL T_ENG_CONFIG: over-ceiling K was not rejected");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS tb_compute_engine");
        else
            $display("FAIL tb_compute_engine: %0d errors", errors);
        $finish;
    end

    initial begin
        repeat (1500000) @(posedge clk);
        $display("FAIL tb_compute_engine watchdog timeout");
        $finish;
    end
endmodule
