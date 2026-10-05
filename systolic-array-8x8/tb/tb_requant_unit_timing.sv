`timescale 1ns/1ps

// T_REQ_TIMING_001: handshake, stall, reset, and conservation checks.
module tb_requant_unit_timing;
    // requant_unit is five physical stages since the 2026-10-05 re-pipelining
    // (S0 bias add, S1 multiply, S2 rounding add, S3 shift, S4 clamp).  ADR-014
    // fixes the contract as a knowable latency, not a particular number, and the
    // checks below are written against this parameter rather than a constant.
    localparam int LAT = 5;
    localparam int MAX_EVENTS = 4096;

    logic clk = 0;
    logic rst_n = 0;
    logic signed [31:0] cfg_bias_q = 0;
    logic signed [17:0] cfg_m0 = 18'sd98765;
    logic [5:0] cfg_shift_n = 6'd20;
    logic cfg_relu = 0, cfg_bypass = 0;
    logic in_valid = 0, in_ready;
    logic signed [31:0] in_acc = 0;
    logic in_k_last = 0, in_last = 0;
    logic out_valid, out_ready = 0;
    logic signed [7:0] out_y;
    logic signed [63:0] out_y_raw;
    logic out_last, out_sat, out_ovf;

    integer cycle_count;
    integer accepted_total, dropped_total, produced_total, live_total;
    integer errors;
    integer source_id;
    integer holding_input;
    integer reset_phase;
    integer output_queue_last [0:MAX_EVENTS-1];
    integer output_queue_cycle [0:MAX_EVENTS-1];
    integer queue_head, queue_tail;
    integer accept_cycle;
    integer expected_cycle;
    integer lfsr;
    integer i;
    logic input_handshake;
    logic ready_at_negedge;

    always #5 clk = ~clk;

    requant_unit #(.LAT(LAT)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_bias_q(cfg_bias_q), .cfg_m0(cfg_m0),
        .cfg_shift_n(cfg_shift_n), .cfg_relu(cfg_relu),
        .cfg_bypass(cfg_bypass),
        .in_valid(in_valid), .in_ready(in_ready), .in_acc(in_acc),
        .in_k_last(in_k_last), .in_last(in_last),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_y(out_y), .out_y_raw(out_y_raw), .out_last(out_last),
        .out_sat(out_sat), .out_ovf(out_ovf)
    );

    // ADR-014 assertion list.
    property p_hold_input;
        @(posedge clk) disable iff (!rst_n)
            in_valid && !in_ready |=> in_valid && $stable(in_acc) &&
            $stable(in_k_last) && $stable(in_last);
    endproperty
    assert property (p_hold_input)
        else begin $display("FAIL tb_requant_unit_timing: input changed while not ready"); errors = errors + 1; end

    property p_hold_output;
        @(posedge clk) disable iff (!rst_n)
            out_valid && !out_ready |=> out_valid && $stable(out_y) &&
            $stable(out_y_raw) && $stable(out_last) && $stable(out_sat) &&
            $stable(out_ovf);
    endproperty
    assert property (p_hold_output)
        else begin $display("FAIL tb_requant_unit_timing: output changed while stalled"); errors = errors + 1; end

    // A no-stall pipeline has the accepted word in the result register on the
    // LAT'th pipeline cycle. The scoreboard below checks that exact LAT-slot
    // history while out_ready is continuously high.
    integer no_stall_accept_hist [0:LAT-1];
    integer no_stall_hist_valid [0:LAT-1];

    // Handshakes are sampled before the DUT's nonblocking assignments at the
    // active edge. This is the value that a real synchronous endpoint sees.
    always @(posedge clk) begin
        input_handshake = 1'b0;
        if (!rst_n) begin
            accepted_total = 0;
            dropped_total = 0;
            produced_total = 0;
            live_total = 0;
            queue_head = 0;
            queue_tail = 0;
            input_handshake = 1'b0;
        end else begin
            input_handshake = in_valid && in_ready;
            if (in_valid && in_ready) begin
                accepted_total = accepted_total + 1;
                if (!in_k_last) begin
                    dropped_total = dropped_total + 1;
                end else begin
                    live_total = live_total + 1;
                    output_queue_last[queue_tail] = in_last;
                    output_queue_cycle[queue_tail] = cycle_count;
                    queue_tail = queue_tail + 1;
                end
            end
            if (out_valid && out_ready) begin
                produced_total = produced_total + 1;
                if (queue_head >= queue_tail) begin
                    $display("FAIL tb_requant_unit_timing: output for dropped/unaccepted sample");
                    errors = errors + 1;
                end else begin
                    if (out_last !== output_queue_last[queue_head]) begin
                        $display("FAIL tb_requant_unit_timing: out_last ordering error cycle=%0d head=%0d got=%b exp=%b exp_cycle=%0d",
                                 cycle_count, queue_head, out_last,
                                 output_queue_last[queue_head],
                                 output_queue_cycle[queue_head]);
                        errors = errors + 1;
                    end
                    if (out_ready && cycle_count < 60 && !reset_phase) begin
                        accept_cycle = output_queue_cycle[queue_head];
                        expected_cycle = cycle_count - accept_cycle;
                        if (expected_cycle != LAT) begin
                            $display("FAIL tb_requant_unit_timing: no-stall latency got %0d expected %0d",
                                     expected_cycle, LAT);
                            errors = errors + 1;
                        end
                    end
                    queue_head = queue_head + 1;
                    live_total = live_total - 1;
                end
            end

            if (accepted_total !== produced_total + live_total + dropped_total) begin
                $display("FAIL tb_requant_unit_timing: conservation %0d != %0d + %0d + %0d",
                         accepted_total, produced_total, live_total, dropped_total);
                errors = errors + 1;
            end
        end
    end

    // Reset is synchronous inside the DUT, so check the post-edge state.
    always @(posedge clk) begin
        #1;
        if (!rst_n) begin
            if (out_valid !== 1'b0 || in_ready !== 1'b1) begin
                $display("FAIL tb_requant_unit_timing: reset did not produce idle state");
                errors = errors + 1;
            end
        end
    end

    always @(negedge clk) begin
        if (rst_n) begin
            ready_at_negedge = in_ready;
            #1;
            assert (in_ready === ready_at_negedge)
                else begin
                    $display("FAIL tb_requant_unit_timing: in_ready changed combinationally");
                    errors = errors + 1;
                end
        end
    end

    initial begin
        assert (dut.LAT == LAT)
            else begin
                $display("FAIL tb_requant_unit_timing: DUT LAT parameter mismatch");
                $finish(1);
            end
        cycle_count = 0;
        accepted_total = 0;
        dropped_total = 0;
        produced_total = 0;
        live_total = 0;
        errors = 0;
        source_id = 0;
        holding_input = 0;
        reset_phase = 1;
        queue_head = 0;
        queue_tail = 0;
        lfsr = 32'h1ACE_B00C;
        input_handshake = 0;
        ready_at_negedge = 1;
        in_valid = 0;
        out_ready = 0;

        repeat (3) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;
        reset_phase = 0;

        // Directed illegal-input case: in_last on a sample that is not the end
        // of a K reduction. The DUT's a_last_requires_k_last assertion owns
        // reporting it, so it is switched off for exactly this window rather
        // than being counted through a hook inside the DUT -- ADR-014 rejects
        // hierarchical testbench state in the module under test.
        //
        // What is checked here is therefore the behaviour, not the assertion:
        // the sample must be consumed (in_ready stays high, so the upstream
        // reducer cannot deadlock) and must produce no output beat at all --
        // in particular no out_last, which is the failure that would otherwise
        // strand a DMA transfer waiting for a TLAST that never arrives.
        $assertoff(0, dut.a_last_requires_k_last);
        @(negedge clk);
        out_ready = 1'b1;
        cfg_bias_q = 0;
        cfg_m0 = 18'sd98765;
        cfg_shift_n = 6'd20;
        cfg_relu = 1'b0;
        cfg_bypass = 1'b0;
        in_acc = 32'sd17;
        in_valid = 1'b1;
        in_k_last = 1'b0;
        in_last = 1'b1;
        if (!in_ready) begin
            $display("FAIL tb_requant_unit_timing: illegal sample was not accepted (deadlock risk)");
            errors = errors + 1;
        end
        @(posedge clk);
        @(negedge clk);
        in_valid = 1'b0;
        in_k_last = 1'b0;
        in_last = 1'b0;
        // LAT cycles is the window in which a wrongly-propagated in_last would
        // surface. Nothing may come out.
        repeat (LAT + 2) begin
            @(posedge clk);
            #1;
            if (out_valid) begin
                $display("FAIL tb_requant_unit_timing: dropped sample produced an output (out_last=%b)",
                         out_last);
                errors = errors + 1;
            end
        end
        $asserton(0, dut.a_last_requires_k_last);

        // Randomized stream. The first burst is intentionally full-rate with
        // no stalls; later windows include long stalls, one-cycle gaps, and
        // back-to-back ready bursts.
        for (cycle_count = 0; cycle_count < 900; cycle_count = cycle_count + 1) begin
            @(negedge clk);

            if (cycle_count == 300) begin
                rst_n = 1'b0;
                in_valid = 1'b0;
                holding_input = 0;
                out_ready = 1'b0;
                reset_phase = 1;
            end else if (cycle_count == 304) begin
                rst_n = 1'b1;
                reset_phase = 0;
                out_ready = 1'b1;
            end else if (!rst_n) begin
                out_ready = 1'b0;
                in_valid = 1'b0;
            end else begin
                if (cycle_count < 60)
                    out_ready = 1'b1;
                else if (cycle_count < 80)
                    out_ready = 1'b0;
                else if (cycle_count < 100)
                    out_ready = ((cycle_count - 80) % 2) == 0;
                else if (cycle_count < 140)
                    out_ready = 1'b1;
                else begin
                    lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                    out_ready = lfsr[0] | lfsr[3];
                end

                if (!holding_input) begin
                    lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                    in_valid = (cycle_count < 60) ? 1'b1 : (lfsr[0] | lfsr[2]);
                    if (in_valid) begin
                        in_acc = source_id * 97 - 10000;
                        cfg_bias_q = (source_id % 9 == 0) ? 32'sd123 : -32'sd7;
                        cfg_m0 = (source_id % 3 == 0) ? 18'sd98765 : 18'sd131071;
                        cfg_shift_n = (source_id % 4 == 0) ? 6'd0 : 6'd20;
                        cfg_relu = source_id[0];
                        cfg_bypass = (source_id % 11 == 0);
                        in_k_last = (source_id % 7 != 0);
                        // Random traffic remains legal: a frame marker can
                        // only accompany a completed K reduction.
                        in_last = (source_id % 13 == 0) &&
                                  (source_id % 7 != 0);
                        holding_input = 1;
                        source_id = source_id + 1;
                    end
                end
            end

            @(posedge clk);
            #1;
            if (rst_n && holding_input && input_handshake)
                holding_input = 0;
        end

        @(negedge clk);
        in_valid = 0;
        holding_input = 0;
        out_ready = 1;
        for (i = 0; i < 100; i = i + 1) begin
            @(posedge clk);
            #1;
        end

        if (live_total != 0 || out_valid) begin
            $display("FAIL tb_requant_unit_timing: stream did not drain (live=%0d out_valid=%b)",
                     live_total, out_valid);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("PASS tb_requant_unit_timing");
        else
            $display("FAIL tb_requant_unit_timing: %0d errors", errors);
        $finish;
    end
endmodule
