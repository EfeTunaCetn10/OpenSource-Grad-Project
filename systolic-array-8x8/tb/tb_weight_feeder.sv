`timescale 1ns/1ps

// Self-checking weight_feeder verification.  Every lane and address has a
// distinct byte pattern, so an address error or bank/lane swap is observable.
// Phases cover full-rate traffic, exact 1/2/9-cycle partner starvation,
// consecutive geometry changes, and every cfg_error guard.
module tb_weight_feeder;
    localparam int ROWS       = 8;
    localparam int DATA_WIDTH = 8;
    localparam int K_MAX      = 30;
    localparam int DEPTH      = 64;
    localparam int TILE_MAX   = 8;
    localparam int K_W        = $clog2(K_MAX+1);
    localparam int ADDR_W     = $clog2(DEPTH);
    localparam int TILE_W     = $clog2(TILE_MAX);
    localparam int WATCHDOG   = 10000;

    localparam int BANK_W = $clog2(ROWS);

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    logic wr_en = 1'b0;
    logic [BANK_W-1:0] wr_bank = '0;
    logic [ADDR_W-1:0] wr_addr = '0;
    logic [DATA_WIDTH-1:0] wr_data = '0;
    logic start = 1'b0;
    logic ready;
    logic [TILE_W-1:0] tile_idx = '0;
    logic [K_W-1:0] k_len = '0;
    logic weight_valid;
    logic weight_ready = 1'b0;
    logic [ROWS*DATA_WIDTH-1:0] weight_data;
    logic done;
    logic cfg_error;

    integer errors = 0;
    integer r, a;
    string phase;

    always #5 clk = ~clk;

    function automatic logic [7:0] mem_pattern(
        input integer bank,
        input integer addr
    );
        integer value;
        begin
            // The asymmetric cross-term makes f(bank,addr) != f(addr,bank)
            // for the exercised range and exposes both lane and address swaps.
            value = 8'h35 + bank*53 + addr*17 + bank*addr*3 + bank*bank*7;
            mem_pattern = value[7:0];
        end
    endfunction

    weight_feeder #(
        .ROWS       (ROWS),
        .DATA_WIDTH (DATA_WIDTH),
        .K_MAX      (K_MAX),
        .DEPTH      (DEPTH),
        .TILE_MAX   (TILE_MAX),
        .K_W        (K_W),
        .ADDR_W     (ADDR_W),
        .TILE_W     (TILE_W)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr_en        (wr_en),
        .wr_bank      (wr_bank),
        .wr_addr      (wr_addr),
        .wr_data      (wr_data),
        .start        (start),
        .ready        (ready),
        .tile_idx     (tile_idx),
        .k_len        (k_len),
        .weight_valid (weight_valid),
        .weight_ready (weight_ready),
        .weight_data  (weight_data),
        .done         (done),
        .cfg_error    (cfg_error)
    );

    task automatic fail(input string msg);
        begin
            $display("FAIL %s: %s", phase, msg);
            errors = errors + 1;
        end
    endtask

    task automatic check_word(
        input integer beat,
        input integer tile,
        input integer len
    );
        integer lane;
        integer addr;
        logic [7:0] got;
        logic [7:0] exp;
        begin
            addr = tile*len + beat;
            for (lane = 0; lane < ROWS; lane = lane + 1) begin
                got = weight_data[lane*DATA_WIDTH +: DATA_WIDTH];
                exp = mem_pattern(lane, addr);
                if (got !== exp) begin
                    $display("FAIL %s beat=%0d lane=%0d addr=%0d got=%02h exp=%02h",
                             phase, beat, lane, addr, got, exp);
                    errors = errors + 1;
                end
            end
        end
    endtask

    task automatic pulse_start(input integer tile, input integer len);
        begin
            while (!ready)
                @(negedge clk);
            @(negedge clk);
            tile_idx = tile[TILE_W-1:0];
            k_len    = len[K_W-1:0];
            start    = 1'b1;
            @(posedge clk);
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    task automatic run_tile(
        input integer tile,
        input integer len,
        input integer stall_cycles,
        input logic   demand_full_rate
    );
        integer accepted;
        integer guard;
        integer stall_left;
        logic   stall_done;
        logic   stream_started;
        logic   held_valid;
        logic [ROWS*DATA_WIDTH-1:0] held_data;
        begin
            pulse_start(tile, len);
            accepted      = 0;
            guard         = 0;
            stall_left    = stall_cycles;
            stall_done    = (stall_cycles == 0);
            stream_started = 1'b0;
            held_valid    = 1'b0;
            weight_ready  = 1'b1;

            while (!done && guard < 1000) begin
                // We are on a negedge.  First check the word held through the
                // preceding posedge, then choose readiness for the next one.
                if (held_valid &&
                    ((!weight_valid) || (weight_data !== held_data)))
                    fail("valid/data changed during backpressure");
                held_valid = 1'b0;

                if (!stall_done && stream_started && (accepted == 2)) begin
                    weight_ready = 1'b0;
                    stall_left = stall_left - 1;
                    if (stall_left == 0)
                        stall_done = 1'b1;
                end else begin
                    weight_ready = 1'b1;
                end

                if (weight_valid)
                    stream_started = 1'b1;

                if (demand_full_rate && stream_started &&
                    (accepted < len) && !weight_valid)
                    fail("bubble observed during full-rate streaming");

                if (weight_valid && weight_ready) begin
                    if (accepted >= len)
                        fail("extra accepted beat");
                    else
                        check_word(accepted, tile, len);
                    accepted = accepted + 1;
                end else if (weight_valid && !weight_ready) begin
                    held_valid = 1'b1;
                    held_data  = weight_data;
                end

                guard = guard + 1;
                @(posedge clk);
                @(negedge clk);
            end

            if (guard >= 1000)
                fail("tile timed out");
            if (accepted != len) begin
                $display("FAIL %s: accepted %0d beats, expected %0d", phase,
                         accepted, len);
                errors = errors + 1;
            end
            if (!stall_done)
                fail("requested stall was not exercised");
            if (cfg_error)
                fail("cfg_error asserted on valid geometry");

            weight_ready = 1'b0;
            @(posedge clk);
            @(negedge clk);
            if (done)
                fail("done was not a one-cycle pulse");
            if (!ready)
                fail("feeder did not return to idle after done");
            if (weight_valid)
                fail("weight_valid remained high after done");
        end
    endtask

    task automatic run_bad_cfg(input integer tile, input integer len);
        begin
            pulse_start(tile, len);
            if (!cfg_error)
                fail("cfg_error did not pulse for invalid geometry");
            if (!ready)
                fail("invalid geometry left feeder busy");
            if (weight_valid)
                fail("invalid geometry produced stream data");
            @(posedge clk);
            @(negedge clk);
            if (cfg_error)
                fail("cfg_error was not a one-cycle pulse");
            if (!ready)
                fail("invalid geometry did not remain idle");
        end
    endtask

    initial begin
        // Load the banks through the real wr_* port instead of poking the
        // arrays hierarchically.  Two reasons: it exercises the same path the
        // integration top uses, and a hierarchical name into a generate array
        // needs a constant index, which a loop variable is not.
        for (r = 0; r < ROWS; r = r + 1)
            for (a = 0; a < DEPTH; a = a + 1) begin
                @(negedge clk);
                wr_en   = 1'b1;
                wr_bank = r[BANK_W-1:0];
                wr_addr = a[ADDR_W-1:0];
                wr_data = mem_pattern(r, a);
                @(posedge clk);
            end
        @(negedge clk);
        wr_en = 1'b0;

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        phase = "T_WF_FULL_RATE";
        run_tile(2, 12, 0, 1'b1);

        phase = "T_WF_BP_1";
        run_tile(1, 9, 1, 1'b0);

        phase = "T_WF_BP_2";
        run_tile(3, 7, 2, 1'b0);

        phase = "T_WF_BP_MANY";
        run_tile(4, 6, 9, 1'b0);

        // No reset between these commands: different tile_idx and k_len prove
        // that base address and length restart at each accepted start.
        phase = "T_WF_CONSEC_A";
        run_tile(1, 11, 0, 1'b1);
        phase = "T_WF_CONSEC_B";
        run_tile(5, 5, 2, 1'b0);

        phase = "T_WF_ERR_ZERO";
        run_bad_cfg(0, 0);
        phase = "T_WF_ERR_KMAX";
        run_bad_cfg(0, K_MAX+1);
        phase = "T_WF_ERR_DEPTH";
        run_bad_cfg(7, 10);

        if (errors == 0)
            $display("PASS tb_weight_feeder");
        else
            $display("FAIL tb_weight_feeder: %0d errors", errors);
        $finish;
    end

    initial begin
        repeat (WATCHDOG) @(posedge clk);
        $display("FAIL tb_weight_feeder watchdog timeout");
        $finish;
    end
endmodule

// Proves the actual gap in the 2026-10-07 incident, not a restatement of it:
// tb_weight_feeder above is green only because it loads every bank through
// wr_en first.  This module never drives wr_en (tied to 0 for its entire
// life) and never pokes g_bank hierarchically either -- the DUT's own
// INIT_PREFIX $readmemh is the *only* thing that can put a weight where this
// test finds one. If that initial block were missing, mis-indexed, or
// quietly dropped into distributed RAM/registers that don't actually carry
// the init value through synthesis, this is the test that would go red; the
// original incident (bitstream has no weights, simulation stayed green)
// could not have hidden behind it. The golden data is the committed
// conv1 fixture, sim/vectors/c1_wbank<r>.mem, loaded here into a separate
// array with the same $readmemh used for the DUT so both sides depend on
// an identical file, not a value this testbench invents.
module tb_weight_feeder_init;
    // Matches conv1_top's actual instantiation (rtl/conv1_top.sv): every
    // weight_feeder parameter here is the module default. K_LEN=75 and
    // ROWS=8 match the committed conv1 fixture (model/conv1_ref.py:
    // C_IN*K_H*K_W = 3*5*5 = 75, C_OUT = 6 <= ROWS = 8).
    localparam int ROWS       = 8;
    localparam int DATA_WIDTH = 8;
    localparam int K_MAX      = 1024;
    localparam int DEPTH      = 8192;
    localparam int TILE_MAX   = 16;
    localparam int K_W        = $clog2(K_MAX+1);
    localparam int ADDR_W     = $clog2(DEPTH);
    localparam int TILE_W     = $clog2(TILE_MAX);
    localparam int BANK_W     = $clog2(ROWS);
    localparam int K_LEN      = 75;
    localparam int WATCHDOG   = 10000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    // Tied off for the entire simulation: this test's whole point is that
    // the weight path works with this port silent.
    logic wr_en = 1'b0;
    logic [BANK_W-1:0] wr_bank = '0;
    logic [ADDR_W-1:0] wr_addr = '0;
    logic [DATA_WIDTH-1:0] wr_data = '0;
    logic start = 1'b0;
    logic ready;
    logic [TILE_W-1:0] tile_idx = '0;
    logic [K_W-1:0] k_len = '0;
    logic weight_valid;
    logic weight_ready = 1'b0;
    logic [ROWS*DATA_WIDTH-1:0] weight_data;
    logic done;
    logic cfg_error;

    integer errors = 0;
    integer r, a, beat;
    logic [7:0] golden [0:ROWS-1][0:K_LEN-1];
    logic [7:0] wtmp    [0:K_LEN-1];

    always #5 clk = ~clk;

    weight_feeder #(
        .ROWS       (ROWS),
        .DATA_WIDTH (DATA_WIDTH),
        .K_MAX      (K_MAX),
        .DEPTH      (DEPTH),
        .TILE_MAX   (TILE_MAX),
        .INIT_PREFIX("../vectors/c1_wbank"),
        .K_W        (K_W),
        .ADDR_W     (ADDR_W),
        .TILE_W     (TILE_W)
    ) dut (
        .clk          (clk),
        .rst_n        (rst_n),
        .wr_en        (wr_en),
        .wr_bank      (wr_bank),
        .wr_addr      (wr_addr),
        .wr_data      (wr_data),
        .start        (start),
        .ready        (ready),
        .tile_idx     (tile_idx),
        .k_len        (k_len),
        .weight_valid (weight_valid),
        .weight_ready (weight_ready),
        .weight_data  (weight_data),
        .done         (done),
        .cfg_error    (cfg_error)
    );

    task automatic fail(input string msg);
        begin
            $display("FAIL T_WF_INIT: %s", msg);
            errors = errors + 1;
        end
    endtask

    initial begin
        // Same file, same $readmemh call the DUT's own initial block makes
        // (rtl/weight_feeder.sv, INIT_PREFIX branch) -- this array exists to
        // give the test an independent read of what the committed fixture
        // says, not to re-derive it. $readmemh needs a plain memory
        // identifier as its target: `golden[r]`, an indexed slice of a 2-D
        // unpacked array, type-checks but XSim silently loads nothing into
        // it (no error, no warning -- golden stayed all-zero and this test
        // would have reported the DUT as wrong). A flat temporary plus an
        // explicit copy, the same pattern tb_conv1_top.sv uses for wbank_tmp,
        // is the form XSim actually honors.
        for (r = 0; r < ROWS; r = r + 1) begin
            $readmemh($sformatf("../vectors/c1_wbank%0d.mem", r), wtmp);
            for (a = 0; a < K_LEN; a = a + 1)
                golden[r][a] = wtmp[a];
        end

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // Single tile, tile_idx=0: addr(bank=r, tile=0, k) = k, i.e. bank r
        // address k holds golden[r][k] directly (ADR-011 addr formula with
        // t=0).
        while (!ready)
            @(negedge clk);
        @(negedge clk);
        tile_idx = '0;
        k_len    = K_LEN[K_W-1:0];
        start    = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start = 1'b0;

        weight_ready = 1'b1;
        beat = 0;
        while (!done && beat < K_LEN + 10) begin
            @(posedge clk);
            if (weight_valid && weight_ready) begin
                if (beat >= K_LEN) begin
                    fail("extra accepted beat beyond K_LEN");
                end else begin
                    for (r = 0; r < ROWS; r = r + 1) begin
                        logic [7:0] got;
                        got = weight_data[r*DATA_WIDTH +: DATA_WIDTH];
                        if (got !== golden[r][beat]) begin
                            $display("FAIL T_WF_INIT bank=%0d addr=%0d got=%02h exp=%02h (from c1_wbank%0d.mem)",
                                     r, beat, got, golden[r][beat], r);
                            errors = errors + 1;
                        end
                    end
                    beat = beat + 1;
                end
            end
            @(negedge clk);
        end

        if (beat != K_LEN)
            fail($sformatf("streamed %0d beats, expected %0d", beat, K_LEN));
        if (cfg_error)
            fail("cfg_error asserted on valid geometry");
        if (!done)
            fail("done never asserted");

        if (errors == 0)
            $display("PASS tb_weight_feeder_init");
        else
            $display("FAIL tb_weight_feeder_init: %0d errors", errors);
        $finish;
    end

    initial begin
        repeat (WATCHDOG) @(posedge clk);
        $display("FAIL tb_weight_feeder_init watchdog timeout");
        $finish;
    end
endmodule
