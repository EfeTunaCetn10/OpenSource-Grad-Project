`timescale 1ns/1ps

// Integration-level testbench for requant_array.
//
// The arithmetic of a single lane is not retested here: tb_requant_unit_num
// already scores the INT32 -> INT8 path against the 60k Python vector set,
// and repeating it eight times over would only restate that result.  What is
// new at this level, and what this testbench is built to break, is the
// wiring:
//
//   T_REQA_MAP      lane r really uses cfg_*[r].  Every lane gets a visibly
//                   different bias/m0/shift/relu, so a swapped or shared
//                   configuration index cannot produce a matching output.
//   T_REQA_BP       the same stimulus under random input gaps and random
//                   out_ready.  Values, order, and metadata must be
//                   unchanged from the full-rate run.
//   T_REQA_PARTIAL  a partial tile (active_rows < LANES).  Lanes outside the
//                   mask must read zero and never set sat/ovf.
//   T_REQA_SATOVF   saturation and bias overflow on chosen lanes, to confirm
//                   the status bits are per lane and masked, not merged.
//   T_REQA_BYPASS   cfg_bypass is a single shared bit; clamping still
//                   applies in bypass while sat is forced low.
//   T_REQA_PARTIALK beats with in_k_last low are swallowed by the units and
//                   must consume no metadata slot.  If the FIFO pushed on
//                   them, every later beat would carry the wrong column.
//   T_REQA_MIXMASK  back-to-back tiles with different active_rows under harsh
//                   backpressure.  This is what makes the lanes' in_ready
//                   diverge, and it is the only phase that can fail when the
//                   lockstep gate on u_in_valid is removed -- a uniform mask
//                   gives every lane identical timing and hides the bug.
//
// The golden model below re-derives the ADR-003 arithmetic independently of
// the RTL expression forms, following requant_ref.py: floor (arithmetic)
// shift, half-ULP rounding for n > 0, clamp before the bypass sat override.
module tb_requant_array;
    localparam int LANES  = 8;
    localparam int ACC_W  = 32;
    localparam int M0_W   = 18;
    localparam int PROD_W = 64;
    localparam int COL_W  = 4;
    localparam int MAXB   = 64;
    localparam int PHASE_MAX = 20000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic signed [ACC_W-1:0] cfg_bias_q  [0:LANES-1];
    logic signed [M0_W-1:0]  cfg_m0      [0:LANES-1];
    logic        [5:0]       cfg_shift_n [0:LANES-1];
    logic                    cfg_relu    [0:LANES-1];
    logic                    cfg_bypass = 1'b0;

    logic                   in_valid = 1'b0;
    logic                   in_ready;
    logic [LANES*ACC_W-1:0] in_acc_flat = '0;
    logic [LANES-1:0]       in_lane_valid = '0;
    logic [COL_W-1:0]       in_col = '0;
    logic                   in_k_last = 1'b0;
    logic                   in_last = 1'b0;

    logic                   out_valid;
    logic                   out_ready = 1'b1;
    logic [LANES*8-1:0]     out_y_flat;
    logic [LANES-1:0]       out_lane_valid;
    logic [COL_W-1:0]       out_col;
    logic                   out_last;
    logic [LANES-1:0]       out_sat_flat;
    logic [LANES-1:0]       out_ovf_flat;
    logic                   lockstep_error;

    // Stimulus, filled per phase.
    logic signed [ACC_W-1:0] stim_acc  [0:MAXB-1][0:LANES-1];
    logic [LANES-1:0]        stim_mask [0:MAXB-1];
    logic [COL_W-1:0]        stim_col  [0:MAXB-1];
    logic                    stim_kl   [0:MAXB-1];
    logic                    stim_last [0:MAXB-1];
    integer n_beats = 0;

    // Scoreboard, pushed at the input handshake so it captures the
    // configuration actually in force when the beat was accepted.
    logic signed [7:0] exp_y    [0:MAXB-1][0:LANES-1];
    logic [LANES-1:0]  exp_mask [0:MAXB-1];
    logic [COL_W-1:0]  exp_col  [0:MAXB-1];
    logic              exp_last [0:MAXB-1];
    logic [LANES-1:0]  exp_sat  [0:MAXB-1];
    logic [LANES-1:0]  exp_ovf  [0:MAXB-1];

    integer send_i = 0;
    integer recv_i = 0;
    integer exp_n = 0;
    integer drv_gap = 0;
    integer errors = 0;
    integer phase_errors = 0;
    integer guard = 0;
    integer i, b;
    string  phase;

    // Deterministic pseudo-random source.  XSim rejects a seeded $urandom,
    // and leaning on a simulator-specific RNG would make a failing
    // backpressure pattern impossible to replay on another tool.  An explicit
    // LFSR keeps every run of this testbench bit-identical.
    logic [31:0] lfsr = 32'h00C0_FFEE;

    always #5 clk = ~clk;

    function automatic logic [31:0] lfsr_next();
        begin
            // x^32 + x^22 + x^2 + x + 1
            lfsr = {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            lfsr_next = lfsr;
        end
    endfunction

    function automatic integer rnd_mod(input integer m);
        logic [31:0] v;
        begin
            v = lfsr_next();
            rnd_mod = v[30:0] % m;
        end
    endfunction

    requant_array #(
        .LANES  (LANES),
        .ACC_W  (ACC_W),
        .M0_W   (M0_W),
        .PROD_W (PROD_W),
        .COL_W  (COL_W),
        .DEPTH  (8)
    ) dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .cfg_bias_q     (cfg_bias_q),
        .cfg_m0         (cfg_m0),
        .cfg_shift_n    (cfg_shift_n),
        .cfg_relu       (cfg_relu),
        .cfg_bypass     (cfg_bypass),
        .in_valid       (in_valid),
        .in_ready       (in_ready),
        .in_acc_flat    (in_acc_flat),
        .in_lane_valid  (in_lane_valid),
        .in_col         (in_col),
        .in_k_last      (in_k_last),
        .in_last        (in_last),
        .out_valid      (out_valid),
        .out_ready      (out_ready),
        .out_y_flat     (out_y_flat),
        .out_lane_valid (out_lane_valid),
        .out_col        (out_col),
        .out_last       (out_last),
        .out_sat_flat   (out_sat_flat),
        .out_ovf_flat   (out_ovf_flat),
        .lockstep_error (lockstep_error)
    );

    // ---------------------------------------------------------------------
    // Golden model (ADR-003 / requant_ref.py)
    // ---------------------------------------------------------------------
    function automatic void req_golden(
        input  logic signed [ACC_W-1:0] acc,
        input  logic signed [ACC_W-1:0] bias,
        input  logic signed [M0_W-1:0]  m0,
        input  logic        [5:0]       shift_n,
        input  logic                    relu,
        input  logic                    bypass,
        output logic signed [7:0]       y,
        output logic                    sat,
        output logic                    ovf
    );
        logic signed [ACC_W:0]    sum_ext;
        logic signed [ACC_W-1:0]  a;
        logic signed [PROD_W-1:0] a_ext, m0_ext, prod, half, raw, lo, clamped;
        begin
            sum_ext = $signed({acc[ACC_W-1], acc}) + $signed({bias[ACC_W-1], bias});
            a = sum_ext[ACC_W-1:0];
            ovf = (acc[ACC_W-1] == bias[ACC_W-1]) && (a[ACC_W-1] != acc[ACC_W-1]);

            a_ext = a;
            m0_ext = m0;
            prod = a_ext * m0_ext;

            half = '0;
            if (shift_n != 0) begin
                half[0] = 1'b1;
                half = half <<< (shift_n - 1'b1);
            end

            raw = bypass ? a_ext : ((prod + half) >>> shift_n);
            lo  = relu ? '0 : -128;

            if (raw > $signed(127)) begin
                clamped = $signed(127);
                sat = 1'b1;
            end else if (raw < lo) begin
                clamped = lo;
                sat = 1'b1;
            end else begin
                clamped = raw;
                sat = 1'b0;
            end
            // Bypass is a debug read-through, not a quantization, so it never
            // reports saturation -- but the output byte is still the clamped
            // value, exactly as the RTL computes it.
            if (bypass)
                sat = 1'b0;
            y = clamped[7:0];
        end
    endfunction

    // ---------------------------------------------------------------------
    // Driver / monitor helpers
    // ---------------------------------------------------------------------
    task automatic drive_stim(input integer idx);
        integer l;
        begin
            for (l = 0; l < LANES; l = l + 1)
                in_acc_flat[l*ACC_W +: ACC_W] = stim_acc[idx][l];
            in_lane_valid = stim_mask[idx];
            in_col        = stim_col[idx];
            in_k_last     = stim_kl[idx];
            in_last       = stim_last[idx];
        end
    endtask

    task automatic push_expected(input integer idx);
        integer l;
        logic signed [7:0] y;
        logic s, o;
        begin
            // A beat without k_last is dropped by every unit, so it must not
            // claim a scoreboard entry either.
            if (!stim_kl[idx])
                return;

            exp_mask[exp_n] = stim_mask[idx];
            exp_col[exp_n]  = stim_col[idx];
            exp_last[exp_n] = stim_last[idx];
            exp_sat[exp_n]  = '0;
            exp_ovf[exp_n]  = '0;
            for (l = 0; l < LANES; l = l + 1) begin
                if (stim_mask[idx][l]) begin
                    req_golden(stim_acc[idx][l], cfg_bias_q[l], cfg_m0[l],
                               cfg_shift_n[l], cfg_relu[l], cfg_bypass,
                               y, s, o);
                    exp_y[exp_n][l]   = y;
                    exp_sat[exp_n][l] = s;
                    exp_ovf[exp_n][l] = o;
                end else begin
                    exp_y[exp_n][l] = 8'sd0;
                end
            end
            exp_n = exp_n + 1;
        end
    endtask

    task automatic check_pop();
        integer l;
        logic signed [7:0] got;
        begin
            if (recv_i >= exp_n) begin
                $display("FAIL %s: extra output beat %0d (expected %0d total)",
                         phase, recv_i, exp_n);
                phase_errors = phase_errors + 1;
                recv_i = recv_i + 1;
                return;
            end
            if (out_lane_valid !== exp_mask[recv_i]) begin
                $display("FAIL %s beat %0d: lane mask %02h, expected %02h",
                         phase, recv_i, out_lane_valid, exp_mask[recv_i]);
                phase_errors = phase_errors + 1;
            end
            if (out_col !== exp_col[recv_i]) begin
                $display("FAIL %s beat %0d: col %0d, expected %0d",
                         phase, recv_i, out_col, exp_col[recv_i]);
                phase_errors = phase_errors + 1;
            end
            if (out_last !== exp_last[recv_i]) begin
                $display("FAIL %s beat %0d: last %0b, expected %0b",
                         phase, recv_i, out_last, exp_last[recv_i]);
                phase_errors = phase_errors + 1;
            end
            if (out_sat_flat !== exp_sat[recv_i]) begin
                $display("FAIL %s beat %0d: sat %02h, expected %02h",
                         phase, recv_i, out_sat_flat, exp_sat[recv_i]);
                phase_errors = phase_errors + 1;
            end
            if (out_ovf_flat !== exp_ovf[recv_i]) begin
                $display("FAIL %s beat %0d: ovf %02h, expected %02h",
                         phase, recv_i, out_ovf_flat, exp_ovf[recv_i]);
                phase_errors = phase_errors + 1;
            end
            for (l = 0; l < LANES; l = l + 1) begin
                got = out_y_flat[l*8 +: 8];
                if (got !== exp_y[recv_i][l]) begin
                    $display("FAIL %s beat %0d lane %0d: y %0d, expected %0d",
                             phase, recv_i, l, got, exp_y[recv_i][l]);
                    phase_errors = phase_errors + 1;
                end
            end
            recv_i = recv_i + 1;
        end
    endtask

    // One negedge-synchronous process drives both sides.  Sampling in_ready
    // and out_valid at the negedge is unambiguous: both are produced from
    // registered state, so mid-cycle they already hold the value that governs
    // the handshake at the coming posedge.
    task automatic run_phase(input integer gaps, input integer bp);
        begin
            send_i = 0;
            recv_i = 0;
            exp_n  = 0;
            drv_gap = 0;
            guard  = 0;
            phase_errors = 0;

            while (!(send_i == n_beats && recv_i == exp_n)) begin
                @(negedge clk);
                guard = guard + 1;
                if (guard > PHASE_MAX) begin
                    $display("FAIL %s: phase did not complete (sent %0d/%0d, got %0d/%0d)",
                             phase, send_i, n_beats, recv_i, exp_n);
                    phase_errors = phase_errors + 1;
                    in_valid = 1'b0;
                    out_ready = 1'b1;
                    errors = errors + phase_errors;
                    return;
                end

                // bp: 0 = never stall, 1 = stall half the time, 2 = accept
                // one beat in four, which is harsh enough to fill a unit's
                // three result slots and drive its in_ready low.
                case (bp)
                    0:       out_ready = 1'b1;
                    1:       out_ready = (rnd_mod(2) == 1);
                    default: out_ready = (rnd_mod(4) == 0);
                endcase

                if (send_i < n_beats && drv_gap == 0) begin
                    drive_stim(send_i);
                    in_valid = 1'b1;
                end else begin
                    in_valid = 1'b0;
                    if (drv_gap > 0)
                        drv_gap = drv_gap - 1;
                end

                if (out_valid && out_ready)
                    check_pop();
                if (in_valid && in_ready) begin
                    push_expected(send_i);
                    send_i = send_i + 1;
                    if (gaps != 0)
                        drv_gap = rnd_mod(3);
                end

                @(posedge clk);
            end

            @(negedge clk);
            in_valid  = 1'b0;
            out_ready = 1'b1;

            // The flag is sticky, so a single check at the end of the phase
            // covers every cycle of it.
            if (lockstep_error !== 1'b0) begin
                $display("FAIL %s: lockstep_error asserted", phase);
                phase_errors = phase_errors + 1;
            end

            if (phase_errors == 0)
                $display("  %s ok (%0d beats)", phase, exp_n);
            errors = errors + phase_errors;
        end
    endtask

    // ---------------------------------------------------------------------
    // Configuration presets
    // ---------------------------------------------------------------------
    // Every lane differs in bias, multiplier, shift and ReLU, so an index
    // mix-up in the configuration fan-out cannot go unnoticed.
    task automatic cfg_distinct();
        integer l;
        begin
            for (l = 0; l < LANES; l = l + 1) begin
                cfg_bias_q[l]  = (l % 2 == 0) ? (100 * (l + 1)) : -(50 * (l + 1));
                cfg_m0[l]      = 18'sd65536 + 18'sd4096 * l;  // in [2**16, 2**17)
                cfg_shift_n[l] = 6'd16 + l[2:0];
                cfg_relu[l]    = (l >= 4);
            end
            cfg_bypass = 1'b0;
        end
    endtask

    task automatic build_tile(input integer beats, input logic [LANES-1:0] mask);
        integer l;
        begin
            n_beats = beats;
            for (b = 0; b < beats; b = b + 1) begin
                stim_mask[b] = mask;
                stim_col[b]  = b[COL_W-1:0];
                stim_kl[b]   = 1'b1;
                stim_last[b] = (b == beats - 1);
                for (l = 0; l < LANES; l = l + 1)
                    stim_acc[b][l] = $signed(1000 * (b + 1)) * ((l % 3 == 1) ? -1 : 1)
                                     + $signed(37 * l);
            end
        end
    endtask

    // Back-to-back tiles whose active_rows differ.  This is the only shape
    // that makes the lanes' in_ready signals diverge: a lane outside the
    // narrow mask is fed on fewer beats, so its result queue drains while the
    // low lanes' queues are still full.  Without the lockstep gate on
    // u_in_valid, the idle lanes would accept a beat the busy lanes refused
    // and run ahead of the metadata.  A uniform mask cannot expose that --
    // every lane then sees identical timing and the gate is a no-op.
    task automatic build_tiles_mixed(input integer tiles, input integer per_tile);
        integer l, t, idx;
        logic [LANES-1:0] masks [0:3];
        begin
            masks[0] = 8'hFF;
            masks[1] = 8'h0F;
            masks[2] = 8'h03;
            masks[3] = 8'h01;
            n_beats = tiles * per_tile;
            for (t = 0; t < tiles; t = t + 1) begin
                for (i = 0; i < per_tile; i = i + 1) begin
                    idx = t * per_tile + i;
                    stim_mask[idx] = masks[t % 4];
                    stim_col[idx]  = i[COL_W-1:0];
                    stim_kl[idx]   = 1'b1;
                    stim_last[idx] = (i == per_tile - 1);
                    for (l = 0; l < LANES; l = l + 1)
                        stim_acc[idx][l] = $signed(300 * (idx + 1))
                                           * ((l % 3 == 1) ? -1 : 1)
                                           + $signed(53 * l);
                end
            end
        end
    endtask

    initial begin
        cfg_distinct();

        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        // --- T_REQA_MAP ------------------------------------------------
        phase = "T_REQA_MAP";
        build_tile(8, 8'hFF);
        run_phase(0, 0);

        // --- T_REQA_BP -------------------------------------------------
        phase = "T_REQA_BP";
        build_tile(8, 8'hFF);
        run_phase(1, 1);

        // --- T_REQA_PARTIAL --------------------------------------------
        phase = "T_REQA_PARTIAL";
        build_tile(5, 8'h07);
        run_phase(1, 1);

        // --- T_REQA_SATOVF ---------------------------------------------
        // Lane 0: acc near INT32_MAX with a positive bias -> wrap, ovf set.
        // Lane 1: large positive accumulator -> saturates high.
        // Lane 2: large negative with relu off -> saturates at -128.
        // Lane 5: large negative with relu on  -> clamps to 0, sat set.
        // Lane 3/4/6/7 stay in range, so the status vectors must be sparse.
        phase = "T_REQA_SATOVF";
        n_beats = 2;
        for (b = 0; b < 2; b = b + 1) begin
            stim_mask[b] = 8'hFF;
            stim_col[b]  = b[COL_W-1:0];
            stim_kl[b]   = 1'b1;
            stim_last[b] = (b == 1);
            for (i = 0; i < LANES; i = i + 1)
                stim_acc[b][i] = 32'sd500;
            stim_acc[b][0] = 32'sh7FFF_FFFF;
            stim_acc[b][1] = 32'sd400_000_000;
            stim_acc[b][2] = -32'sd400_000_000;
            stim_acc[b][5] = -32'sd400_000_000;
        end
        run_phase(1, 1);

        // --- T_REQA_BYPASS ---------------------------------------------
        phase = "T_REQA_BYPASS";
        cfg_bypass = 1'b1;
        build_tile(6, 8'hFF);
        run_phase(1, 1);
        cfg_bypass = 1'b0;

        // --- T_REQA_PARTIALK -------------------------------------------
        // Interleave partial-K beats, which the units accept and drop.  The
        // columns of the surviving beats are deliberately non-consecutive so
        // a FIFO that pushed on a dropped beat would report the wrong one.
        phase = "T_REQA_PARTIALK";
        n_beats = 9;
        for (b = 0; b < 9; b = b + 1) begin
            stim_mask[b] = 8'hFF;
            stim_col[b]  = b[COL_W-1:0];
            stim_kl[b]   = (b % 3 == 2);
            stim_last[b] = (b == 8);
            for (i = 0; i < LANES; i = i + 1)
                stim_acc[b][i] = $signed(700 * (b + 2)) + $signed(11 * i);
        end
        run_phase(1, 1);
        if (exp_n != 3) begin
            $display("FAIL T_REQA_PARTIALK: %0d beats reached the output, expected 3", exp_n);
            errors = errors + 1;
        end

        // --- T_REQA_MIXMASK --------------------------------------------
        phase = "T_REQA_MIXMASK";
        build_tiles_mixed(8, 4);
        run_phase(1, 2);

        if (errors == 0)
            $display("PASS tb_requant_array");
        else
            $display("FAIL tb_requant_array: %0d errors", errors);
        $finish;
    end

    initial begin
        repeat (400000) @(posedge clk);
        $display("FAIL tb_requant_array watchdog timeout");
        $finish;
    end
endmodule
