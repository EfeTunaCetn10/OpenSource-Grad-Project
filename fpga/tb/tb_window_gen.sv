`timescale 1ns/1ps

module tb_window_gen;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n;

    // ------------------------------------------------------------------
    // Four real parameter sets plus the FC-as-1x1 case:
    //   u_c1   conv1 input, 32x32, C_LOGICAL = C_PHYS_STRIDE = 3
    //   u_c2   conv2 input stored DENSE, 14x14, 6/6
    //   u_c2p  conv2 input stored PADDED tile-major, 14x14, 6/8
    //          -> T_CONV2_REPLAY_001 (ADR-018 Decision 2)
    //   u_fc1  FC1 as a 1x1 convolution, C_LOGICAL = 400
    // u_c2 and u_c2p share one geometry and one logical channel count and must
    // therefore emit the SAME 3000-beat stream from two different byte
    // layouts.  That is the whole point of the C_LOGICAL/C_PHYS_STRIDE split.
    // ------------------------------------------------------------------
    logic c1_sv, c1_sr, c1_sl;
    logic c1_mr_manual;
    logic [63:0] c1_sd, c1_md;
    logic c1_mv, c1_mr, c1_done, c1_start, c1_last, c1_rerr;
    logic [3:0] c1_ac;
    logic [31:0] c1_k, c1_row, c1_x;

    logic c2_sv, c2_sr, c2_sl;
    logic [63:0] c2_sd, c2_md;
    logic c2_mv, c2_mr, c2_done, c2_start, c2_last, c2_rerr;
    logic [3:0] c2_ac;
    logic [31:0] c2_k, c2_row, c2_x;

    logic c2p_sv, c2p_sr, c2p_sl;
    logic [63:0] c2p_sd, c2p_md;
    logic c2p_mv, c2p_mr, c2p_done, c2p_start, c2p_last;
    logic c2p_restart, c2p_rerr;
    logic [3:0] c2p_ac;
    logic [31:0] c2p_k, c2p_row, c2p_x;

    logic fc_sv, fc_sr, fc_sl;
    logic [63:0] fc_sd, fc_md;
    logic fc_mv, fc_mr, fc_done, fc_start, fc_last, fc_rerr;
    logic [3:0] fc_ac;
    logic [31:0] fc_k, fc_row, fc_x;

    window_gen #(.K_H(5), .K_W(5), .C_LOGICAL(3), .IN_W(32), .IN_H(32), .STRIDE(1)) u_c1 (
        .clk(clk), .rst_n(rst_n), .restart(1'b0), .restart_error(c1_rerr),
        .s_valid(c1_sv), .s_ready(c1_sr), .s_data(c1_sd), .s_last(c1_sl),
        .m_valid(c1_mv), .m_ready(c1_mr), .m_data(c1_md), .m_active_cols(c1_ac), .m_k(c1_k),
        .m_tile_row(c1_row), .m_tile_x(c1_x), .m_tile_start(c1_start), .m_tile_last(c1_last), .done(c1_done));
    window_gen #(.K_H(5), .K_W(5), .C_LOGICAL(6), .IN_W(14), .IN_H(14), .STRIDE(1)) u_c2 (
        .clk(clk), .rst_n(rst_n), .restart(1'b0), .restart_error(c2_rerr),
        .s_valid(c2_sv), .s_ready(c2_sr), .s_data(c2_sd), .s_last(c2_sl),
        .m_valid(c2_mv), .m_ready(c2_mr), .m_data(c2_md), .m_active_cols(c2_ac), .m_k(c2_k),
        .m_tile_row(c2_row), .m_tile_x(c2_x), .m_tile_start(c2_start), .m_tile_last(c2_last), .done(c2_done));
    window_gen #(.K_H(5), .K_W(5), .C_LOGICAL(6), .C_PHYS_STRIDE(8),
                 .IN_W(14), .IN_H(14), .STRIDE(1)) u_c2p (
        .clk(clk), .rst_n(rst_n), .restart(c2p_restart), .restart_error(c2p_rerr),
        .s_valid(c2p_sv), .s_ready(c2p_sr), .s_data(c2p_sd), .s_last(c2p_sl),
        .m_valid(c2p_mv), .m_ready(c2p_mr), .m_data(c2p_md), .m_active_cols(c2p_ac), .m_k(c2p_k),
        .m_tile_row(c2p_row), .m_tile_x(c2p_x), .m_tile_start(c2p_start), .m_tile_last(c2p_last), .done(c2p_done));
    window_gen #(.K_H(1), .K_W(1), .C_LOGICAL(400), .IN_W(1), .IN_H(1), .STRIDE(1)) u_fc1 (
        .clk(clk), .rst_n(rst_n), .restart(1'b0), .restart_error(fc_rerr),
        .s_valid(fc_sv), .s_ready(fc_sr), .s_data(fc_sd), .s_last(fc_sl),
        .m_valid(fc_mv), .m_ready(fc_mr), .m_data(fc_md), .m_active_cols(fc_ac), .m_k(fc_k),
        .m_tile_row(fc_row), .m_tile_x(fc_x), .m_tile_start(fc_start), .m_tile_last(fc_last), .done(fc_done));

    logic [7:0] frame1 [0:3071];
    logic [7:0] frame2 [0:1175];
    logic [7:0] frame2p [0:1567];   // 14*14*8 physical bytes
    logic [7:0] frame3 [0:399];

    // Nonzero padding sentinels.  ADR-018 requires these to be nonzero: with
    // zero padding a physical/logical confusion is invisible, because the
    // wrongly fetched byte lands in the accumulator as a harmless zero.
    localparam logic [7:0] PAD_SENTINEL_A = 8'hAA;
    localparam logic [7:0] PAD_SENTINEL_B = 8'hBB;

    // Printed by `python model/window_ref.py`.  Ties this testbench to the
    // Python golden model by a number rather than by two independently
    // written coordinate functions.
    localparam logic [31:0] CONV2_PHYS_CHECKSUM = 32'h9AF4F8F4;

    localparam int C2P_BEATS = 3000;   // 10 output rows * 2 tiles * K=150
    localparam int C2P_K_LEN = 150;    // C_LOGICAL*5*5, NOT C_PHYS_STRIDE*5*5

    integer errors;
    integer prng;
    integer i;
    integer ih, iw, ic;

    // ------------------------------------------------------------------
    // Expected HWC byte functions.  The index and lane construction is
    // deliberately explicit so a $readmemh-style byte reversal or a CHW
    // transpose cannot pass this test.
    // ------------------------------------------------------------------
    function automatic [7:0] c1_expected(input integer oy, input integer tx,
                                           input integer kk, input integer lane);
        integer ci, kh, kw, h, w, active;
        begin
            active = 28 - tx;
            if (active > 8) active = 8;
            ci = kk / 25;
            kh = (kk / 5) % 5;
            kw = kk % 5;
            h = oy + kh;
            w = tx + lane + kw;
            if (lane >= active)
                c1_expected = 8'h00;
            else
                c1_expected = frame1[(h*32 + w)*3 + ci];
        end
    endfunction

    function automatic [7:0] c2_expected(input integer oy, input integer tx,
                                           input integer kk, input integer lane);
        integer ci, kh, kw, h, w, active;
        begin
            active = 10 - tx;
            if (active > 8) active = 8;
            ci = kk / 25;
            kh = (kk / 5) % 5;
            kw = kk % 5;
            h = oy + kh;
            w = tx + lane + kw;
            if (lane >= active)
                c2_expected = 8'h00;
            else
                c2_expected = frame2[(h*14 + w)*6 + ci];
        end
    endfunction

    // Same logical coordinate, PHYSICAL byte offset: the column step is 8, not
    // 6, and ci still only ever runs 0..5.  If the RTL used the physical
    // stride for the channel range instead, ci would reach 7 and the sentinel
    // bytes would appear in m_data.
    function automatic [7:0] c2p_expected(input integer oy, input integer tx,
                                            input integer kk, input integer lane);
        integer ci, kh, kw, h, w, active;
        begin
            active = 10 - tx;
            if (active > 8) active = 8;
            ci = kk / 25;
            kh = (kk / 5) % 5;
            kw = kk % 5;
            h = oy + kh;
            w = tx + lane + kw;
            if (lane >= active)
                c2p_expected = 8'h00;
            else
                c2p_expected = frame2p[(h*14 + w)*8 + ci];
        end
    endfunction

    function automatic [7:0] fc_expected(input integer kk);
        fc_expected = frame3[kk];
    endfunction

    function automatic integer weight_value(input integer r, input integer kk);
        weight_value = (r + 1) * ((kk % 7) - 3);
    endfunction

    function automatic integer c1_acc_expected(input integer r, input integer col);
        integer kk, ci, kh, kw, h, w, value, total;
        begin
            total = 0;
            for (kk = 0; kk < 75; kk = kk + 1) begin
                ci = kk / 25;
                kh = (kk / 5) % 5;
                kw = kk % 5;
                h = kh;
                w = col + kw;
                value = $signed(c1_expected(0, 0, kk, col));
                total = total + weight_value(r, kk) * value;
            end
            c1_acc_expected = total;
        end
    endfunction

    task automatic reset_all;
        begin
            rst_n = 1'b0;
            c1_sv = 0; c1_sd = 0; c1_sl = 0; c1_mr_manual = 0;
            c2_sv = 0; c2_sd = 0; c2_sl = 0; c2_mr = 0;
            c2p_sv = 0; c2p_sd = 0; c2p_sl = 0; c2p_mr = 0; c2p_restart = 0;
            fc_sv = 0; fc_sd = 0; fc_sl = 0; fc_mr = 0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
        end
    endtask

    // ------------------------------------------------------------------
    // Sentinel monitor.  The padding bytes must never be visible on the
    // activation edge in ANY cycle, not merely in accepted beats, so this is
    // a continuous monitor rather than a check inside the stimulus task.
    //
    // It owns its own counter: `errors` is driven by the stimulus process and
    // XSim wants a single procedural driver per variable.  The count is folded
    // into `errors` once, at the end, by that process.
    // ------------------------------------------------------------------
    integer sentinel_hits = 0;
    integer mon_lane;
    always @(negedge clk) begin
        if (rst_n === 1'b1 && c2p_mv === 1'b1) begin
            for (mon_lane = 0; mon_lane < 8; mon_lane = mon_lane + 1)
                if ((c2p_md[mon_lane*8 +: 8] === PAD_SENTINEL_A) ||
                    (c2p_md[mon_lane*8 +: 8] === PAD_SENTINEL_B)) begin
                    $display("FAIL c2p padding sentinel reached the engine: row=%0d x=%0d k=%0d lane=%0d data=%h",
                             c2p_row, c2p_x, c2p_k, mon_lane, c2p_md);
                    sentinel_hits = sentinel_hits + 1;
                end
        end
    end

    // c1 is run twice: once as an unstalled baseline and once with both
    // randomly gapped input and randomly stalled output.  The second pass is
    // compared to the recorded first pass as well as to the coordinate model.
    logic [63:0] c1_baseline [0:8399];
    logic [3:0]  c1_baseline_ac [0:8399];
    integer c1_baseline_n;

    task automatic run_conv1(input integer randomized, input integer compare_baseline);
        integer beat, out_n, cycles, b, lane;
        begin
            beat = 0; out_n = 0; cycles = 0; c1_baseline_n = 0;
            c1_sv = 0; c1_sl = 0; c1_mr_manual = 0;
            while ((out_n < 8400) && (cycles < 300000)) begin
                @(negedge clk);
                cycles = cycles + 1;
                prng = prng * 1103515245 + 12345;
                c1_mr_manual = randomized ? ((prng & 16'h0007) != 0) : 1'b1;
                #1;

                if (c1_mv && c1_mr) begin
                    if (c1_ac != ((c1_x >= 24) ? 4'd4 : 4'd8)) begin
                        $display("FAIL c1 active_cols row=%0d x=%0d got=%0d", c1_row, c1_x, c1_ac);
                        errors = errors + 1;
                    end
                    for (lane = 0; lane < 8; lane = lane + 1)
                        if (c1_md[lane*8 +: 8] !== c1_expected(c1_row, c1_x, c1_k, lane)) begin
                            $display("FAIL c1 byte row=%0d x=%0d k=%0d lane=%0d got=%h exp=%h",
                                     c1_row, c1_x, c1_k, lane, c1_md[lane*8 +: 8],
                                     c1_expected(c1_row, c1_x, c1_k, lane));
                            errors = errors + 1;
                        end
                    if (!compare_baseline) begin
                        c1_baseline[out_n] = c1_md;
                        c1_baseline_ac[out_n] = c1_ac;
                    end else if ((c1_md !== c1_baseline[out_n]) || (c1_ac !== c1_baseline_ac[out_n])) begin
                        $display("FAIL c1 stall sequence mismatch beat=%0d", out_n);
                        errors = errors + 1;
                    end
                    out_n = out_n + 1;
                end

                if (c1_sv && c1_sr) begin
                    c1_sv = 1'b0;
                    beat = beat + 1;
                end
                if (!c1_sv && (beat < 384)) begin
                    prng = prng * 1103515245 + 12345;
                    if (!randomized || ((prng & 16'h0003) != 0)) begin
                        c1_sd = 64'b0;
                        for (b = 0; b < 8; b = b + 1)
                            c1_sd[b*8 +: 8] = frame1[beat*8+b];
                        c1_sl = (beat == 383);
                        c1_sv = 1'b1;
                    end
                end
            end
            while (!c1_done && cycles < 300010) @(negedge clk);
            if (out_n != 8400 || !c1_done) begin
                $display("FAIL c1 timeout/out count=%0d done=%b", out_n, c1_done);
                errors = errors + 1;
            end
        end
    endtask

    task automatic run_conv2;
        integer beat, out_n, cycles, b, lane;
        begin
            beat = 0; out_n = 0; cycles = 0;
            c2_sv = 0; c2_sl = 0; c2_mr = 0;
            while ((out_n < 3000) && (cycles < 200000)) begin
                @(negedge clk);
                cycles = cycles + 1;
                prng = prng * 1103515245 + 12345;
                c2_mr = ((prng & 16'h000f) != 0);
                #1;
                if (c2_mv && c2_mr) begin
                    if (c2_ac != ((c2_x >= 8) ? 4'd2 : 4'd8)) begin
                        $display("FAIL c2 active_cols row=%0d x=%0d got=%0d", c2_row, c2_x, c2_ac);
                        errors = errors + 1;
                    end
                    for (lane = 0; lane < 8; lane = lane + 1)
                        if (c2_md[lane*8 +: 8] !== c2_expected(c2_row, c2_x, c2_k, lane)) begin
                            $display("FAIL c2 byte row=%0d x=%0d k=%0d lane=%0d got=%h exp=%h", c2_row, c2_x, c2_k, lane,
                                     c2_md[lane*8 +: 8], c2_expected(c2_row, c2_x, c2_k, lane));
                            if (c2_row == 0 && c2_k == 0 && lane == 0)
                                $display("DEBUG c2 bytes bank0 addr0=%h bank5 addr3=%h", u_c2.u_line_buffer.g_bank[0].bank_mem[0], u_c2.u_line_buffer.g_bank[5].bank_mem[3]);
                            errors = errors + 1;
                        end
                    out_n = out_n + 1;
                end
                if (c2_sv && c2_sr) begin c2_sv = 0; beat = beat + 1; end
                if (!c2_sv && beat < 147) begin
                    prng = prng * 1103515245 + 12345;
                    if ((prng & 16'h0003) != 0) begin
                        c2_sd = 0;
                        for (b = 0; b < 8; b = b + 1)
                            c2_sd[b*8 +: 8] = frame2[beat*8+b];
                        c2_sl = (beat == 146);
                        c2_sv = 1;
                    end
                end
            end
            while (!c2_done && cycles < 200010) @(negedge clk);
            if (out_n != 3000 || !c2_done) begin
                $display("FAIL c2 timeout/out count=%0d done=%b", out_n, c2_done);
                errors = errors + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // T_CONV2_REPLAY_001 -- padded tile-major conv2 input.
    //
    // 196 input beats (1568 physical bytes, 112-byte rows, a 560-byte ring),
    // 20 tiles of exactly 150 beats.  `slot` records the beat sequence for the
    // replay comparison; `restart_at` injects a one-cycle restart pulse once
    // that many beats have been accepted, which is mid-frame and must be
    // REFUSED.  `pattern` selects the m_ready behaviour.
    // ------------------------------------------------------------------
    logic [63:0] c2p_seq [0:1][0:C2P_BEATS-1];
    logic [3:0]  c2p_seq_ac [0:1][0:C2P_BEATS-1];
    logic [31:0] c2p_seq_k [0:1][0:C2P_BEATS-1];

    // Correct AXIS acceptance detection, and it has to be correct here.
    //
    // The older tasks in this file infer acceptance from "s_ready went high
    // again", which works only because they never restart: after the final
    // beat of a frame the line buffer raises frame_done and holds s_ready low
    // forever, so that idiom never sees the last beat land and leaves s_valid
    // asserted.  A restart clears frame_done, s_ready rises, and the generator
    // then legitimately consumes that leftover 197th beat as beat 0 of the
    // next frame -- which is a master-side frame-contract violation, not an
    // RTL defect, but it silently corrupts the replay comparison.  Sampling
    // the handshake on the clock instead removes the stale beat entirely.
    logic c2p_accept;
    always_ff @(posedge clk) begin
        if (!rst_n)
            c2p_accept <= 1'b0;
        else
            c2p_accept <= c2p_sv && c2p_sr;
    end

    task automatic run_conv2_phys(input integer pattern, input integer slot,
                                  input integer restart_at);
        integer beat, out_n, cycles, b, lane, exp_k, tile_beats, tiles, injected;
        logic [31:0] chk;
        begin
            beat = 0; out_n = 0; cycles = 0; exp_k = 0; tile_beats = 0;
            tiles = 0; injected = 0; chk = 32'h0;
            c2p_sv = 0; c2p_sl = 0; c2p_mr = 0; c2p_restart = 0;
            while ((out_n < C2P_BEATS) && (cycles < 400000)) begin
                @(negedge clk);
                cycles = cycles + 1;
                prng = prng * 1103515245 + 12345;
                case (pattern)
                    0: c2p_mr = 1'b1;
                    1: c2p_mr = ((prng & 16'h0007) != 0);
                    default: c2p_mr = ((prng & 16'h0003) == 0);
                endcase

                // One-cycle restart pulse, driven off the clock edge like all
                // the other stimulus here.
                if (injected == 1) begin
                    c2p_restart = 1'b0;
                    injected = 2;
                end else if ((restart_at > 0) && (out_n >= restart_at) && (injected == 0)) begin
                    c2p_restart = 1'b1;
                    injected = 1;
                end
                #1;

                if (c2p_mv && c2p_mr) begin
                    if (c2p_k !== exp_k) begin
                        $display("FAIL c2p k order beat=%0d got=%0d exp=%0d", out_n, c2p_k, exp_k);
                        errors = errors + 1;
                    end
                    if (c2p_ac != ((c2p_x >= 8) ? 4'd2 : 4'd8)) begin
                        $display("FAIL c2p active_cols row=%0d x=%0d got=%0d", c2p_row, c2p_x, c2p_ac);
                        errors = errors + 1;
                    end
                    if (c2p_start !== (exp_k == 0)) begin
                        $display("FAIL c2p tile_start k=%0d start=%b", c2p_k, c2p_start);
                        errors = errors + 1;
                    end
                    if (c2p_last !== (exp_k == C2P_K_LEN-1)) begin
                        $display("FAIL c2p tile_last k=%0d last=%b", c2p_k, c2p_last);
                        errors = errors + 1;
                    end
                    for (lane = 0; lane < 8; lane = lane + 1)
                        if (c2p_md[lane*8 +: 8] !== c2p_expected(c2p_row, c2p_x, c2p_k, lane)) begin
                            $display("FAIL c2p byte row=%0d x=%0d k=%0d lane=%0d got=%h exp=%h",
                                     c2p_row, c2p_x, c2p_k, lane, c2p_md[lane*8 +: 8],
                                     c2p_expected(c2p_row, c2p_x, c2p_k, lane));
                            errors = errors + 1;
                        end

                    chk = chk * 32'd31 + c2p_k;
                    chk = chk * 32'd31 + {28'b0, c2p_ac};
                    for (lane = 0; lane < 8; lane = lane + 1)
                        chk = chk * 32'd31 + {24'b0, c2p_md[lane*8 +: 8]};

                    c2p_seq[slot][out_n] = c2p_md;
                    c2p_seq_ac[slot][out_n] = c2p_ac;
                    c2p_seq_k[slot][out_n] = c2p_k;

                    tile_beats = tile_beats + 1;
                    if (exp_k == C2P_K_LEN-1) begin
                        // The explicit 150-not-200 assertion ADR-018 asks for.
                        if (tile_beats != C2P_K_LEN) begin
                            $display("FAIL c2p tile %0d carried %0d beats, expected %0d",
                                     tiles, tile_beats, C2P_K_LEN);
                            errors = errors + 1;
                        end
                        tile_beats = 0;
                        tiles = tiles + 1;
                        exp_k = 0;
                    end else begin
                        exp_k = exp_k + 1;
                    end
                    out_n = out_n + 1;
                end

                if (c2p_accept) begin c2p_sv = 0; beat = beat + 1; end
                if (!c2p_sv && beat < 196) begin
                    prng = prng * 1103515245 + 12345;
                    if ((pattern == 0) || ((prng & 16'h0003) != 0)) begin
                        c2p_sd = 0;
                        for (b = 0; b < 8; b = b + 1)
                            c2p_sd[b*8 +: 8] = frame2p[beat*8+b];
                        c2p_sl = (beat == 195);
                        c2p_sv = 1;
                    end
                end
            end
            while (!c2p_done && cycles < 400010) begin
                @(negedge clk);
                cycles = cycles + 1;
            end
            if (out_n != C2P_BEATS || !c2p_done) begin
                $display("FAIL c2p timeout/out count=%0d done=%b", out_n, c2p_done);
                errors = errors + 1;
            end
            // Exactly 196 beats, no more: a 197th offered beat would be a
            // frame-contract violation and is what the leftover-s_valid bug
            // above looked like from the outside.
            if (beat != 196) begin
                $display("FAIL c2p input beats accepted=%0d expected=196", beat);
                errors = errors + 1;
            end
            if (c2p_sv) begin
                $display("FAIL c2p left s_valid asserted after the frame");
                errors = errors + 1;
            end
            $display("INFO c2p pattern=%0d slot=%0d restart_at=%0d: %0d beats, %0d tiles of %0d, %0d input beats, checksum %08h, restart_error=%b",
                     pattern, slot, restart_at, out_n, tiles, C2P_K_LEN, beat, chk, c2p_rerr);
            if (tiles != C2P_BEATS/C2P_K_LEN) begin
                $display("FAIL c2p tile count=%0d expected=%0d", tiles, C2P_BEATS/C2P_K_LEN);
                errors = errors + 1;
            end
            if (chk !== CONV2_PHYS_CHECKSUM) begin
                $display("FAIL c2p stream checksum got=%08h exp=%08h (model/window_ref.py)",
                         chk, CONV2_PHYS_CHECKSUM);
                errors = errors + 1;
            end
            if (restart_at == 0) begin
                if (c2p_rerr) begin
                    $display("FAIL c2p restart_error raised with no restart injected");
                    errors = errors + 1;
                end
            end else begin
                if (!c2p_rerr) begin
                    $display("FAIL c2p mid-frame restart was not flagged (restart_error low)");
                    errors = errors + 1;
                end
            end
        end
    endtask

    task automatic pulse_restart;
        begin
            @(negedge clk);
            c2p_restart = 1'b1;
            @(negedge clk);
            c2p_restart = 1'b0;
            @(negedge clk);
        end
    endtask

    task automatic compare_c2p_slots(input integer slot_a, input integer slot_b,
                                     input string label);
        integer n, bad;
        begin
            bad = 0;
            for (n = 0; n < C2P_BEATS; n = n + 1)
                if ((c2p_seq[slot_a][n] !== c2p_seq[slot_b][n]) ||
                    (c2p_seq_ac[slot_a][n] !== c2p_seq_ac[slot_b][n]) ||
                    (c2p_seq_k[slot_a][n] !== c2p_seq_k[slot_b][n])) begin
                    if (bad < 4)
                        $display("FAIL %s beat %0d: %h/%0d/%0d vs %h/%0d/%0d", label, n,
                                 c2p_seq[slot_a][n], c2p_seq_ac[slot_a][n], c2p_seq_k[slot_a][n],
                                 c2p_seq[slot_b][n], c2p_seq_ac[slot_b][n], c2p_seq_k[slot_b][n]);
                    bad = bad + 1;
                end
            if (bad != 0) begin
                $display("FAIL %s: %0d of %0d beats differ", label, bad, C2P_BEATS);
                errors = errors + 1;
            end else begin
                $display("INFO %s: all %0d beats identical", label, C2P_BEATS);
            end
        end
    endtask

    // Frame-done -> restart -> re-stream the SAME frame.  The second pass must
    // be beat-for-beat identical to the first.  This is not a ring replay:
    // line_buffer holds K_H rows, so the frame really is streamed in again.
    task automatic run_restart_replay(input integer pat_a, input integer pat_b);
        begin
            run_conv2_phys(pat_a, 0, 0);
            if (!c2p_done) begin
                $display("FAIL restart replay: generator not done before restart");
                errors = errors + 1;
            end
            pulse_restart();
            if (c2p_done) begin
                $display("FAIL restart replay: still done one cycle after restart");
                errors = errors + 1;
            end
            if (c2p_rerr) begin
                $display("FAIL restart replay: accepted restart raised restart_error");
                errors = errors + 1;
            end
            run_conv2_phys(pat_b, 1, 0);
            compare_c2p_slots(0, 1, "restart replay");
        end
    endtask

    // Mid-frame restart: inject at beat 1200 of a 3000-beat frame, let the
    // frame finish, and compare it with the clean reference in slot 0.  A
    // restart that was partially honoured would corrupt the stream from that
    // point on; one that was fully honoured would restart the beat count and
    // time the run out.  Either way the comparison catches it.
    task automatic run_conv2_phys_midframe_check(input integer pattern);
        begin
            reset_all();
            run_conv2_phys(pattern, 1, 1200);
            compare_c2p_slots(0, 1, "mid-frame restart refused");
            if (!c2p_rerr) begin
                $display("FAIL mid-frame restart: restart_error not sticky after the frame");
                errors = errors + 1;
            end
        end
    endtask

    task automatic run_fc1;
        integer beat, out_n, cycles, b, lane;
        begin
            beat = 0; out_n = 0; cycles = 0;
            fc_sv = 0; fc_sl = 0; fc_mr = 0;
            while ((out_n < 400) && (cycles < 50000)) begin
                @(negedge clk);
                cycles = cycles + 1;
                prng = prng * 1103515245 + 12345;
                fc_mr = ((prng & 16'h0007) != 0);
                #1;
                if (fc_mv && fc_mr) begin
                    if (fc_ac != 1 || fc_md[63:8] !== 56'b0) begin
                        $display("FAIL fc1 active/inactive lanes got ac=%0d data=%h", fc_ac, fc_md);
                        errors = errors + 1;
                    end
                    if (fc_md[7:0] !== fc_expected(fc_k)) begin
                        $display("FAIL fc1 k=%0d got=%h exp=%h", fc_k, fc_md[7:0], fc_expected(fc_k));
                        errors = errors + 1;
                    end
                    out_n = out_n + 1;
                end
                if (fc_sv && fc_sr) begin fc_sv = 0; beat = beat + 1; end
                if (!fc_sv && beat < 50) begin
                    prng = prng * 1103515245 + 12345;
                    if ((prng & 16'h0003) != 0) begin
                        fc_sd = 0;
                        for (b = 0; b < 8; b = b + 1)
                            fc_sd[b*8 +: 8] = frame3[beat*8+b];
                        fc_sl = (beat == 49);
                        fc_sv = 1;
                    end
                end
            end
            while (!fc_done && cycles < 50010) @(negedge clk);
            if (out_n != 400 || !fc_done) begin
                $display("FAIL fc1 timeout/out count=%0d done=%b", out_n, fc_done);
                errors = errors + 1;
            end
        end
    endtask

    // ------------------------------------------------------------------
    // Integration: first conv1 output tile, with a real compute_engine on
    // the activation edge.  Six output-channel rows use distinct signed
    // weights, and every accumulated column is checked against a golden sum.
    // ------------------------------------------------------------------
    logic integration_mode, integration_started;
    logic ce_start, ce_start_ready, ce_weight_valid, ce_weight_ready;
    logic ce_activation_valid, ce_activation_ready;
    logic [7:0] ce_weight_data [0:7];
    logic [63:0] ce_weight_flat;
    logic ce_busy, ce_done, ce_config_error;
    logic ce_out_valid, ce_out_ready;
    logic [8*32-1:0] ce_out_acc_flat;
    logic [7:0] ce_out_lane_valid;
    logic [3:0] ce_out_col;
    logic ce_out_k_last, ce_out_last, ce_drain_stall;
    logic [31:0] ce_cycle_count;
    logic [63:0] ce_mac_fire_flat;
    logic [3:0] ce_active_rows, ce_active_cols;
    logic [8:0] ce_k_len;

    assign ce_weight_flat = {ce_weight_data[7], ce_weight_data[6], ce_weight_data[5], ce_weight_data[4],
                             ce_weight_data[3], ce_weight_data[2], ce_weight_data[1], ce_weight_data[0]};
    assign ce_start = integration_mode && c1_mv && c1_start && ce_start_ready && !integration_started;
    assign ce_activation_valid = integration_mode && integration_started && c1_mv;
    assign ce_weight_valid = ce_activation_valid;
    assign ce_weight_data[0] = weight_value(0, c1_k);
    assign ce_weight_data[1] = weight_value(1, c1_k);
    assign ce_weight_data[2] = weight_value(2, c1_k);
    assign ce_weight_data[3] = weight_value(3, c1_k);
    assign ce_weight_data[4] = weight_value(4, c1_k);
    assign ce_weight_data[5] = weight_value(5, c1_k);
    assign ce_weight_data[6] = 8'h00;
    assign ce_weight_data[7] = 8'h00;
    assign c1_mr = integration_mode ? ce_activation_ready : c1_mr_manual;
    assign ce_out_ready = integration_mode;

    always_ff @(posedge clk) begin
        if (!rst_n)
            integration_started <= 1'b0;
        else if (!integration_mode)
            integration_started <= 1'b0;
        else if (ce_start)
            integration_started <= 1'b1;
    end

    compute_engine #(.K_MAX(400)) u_engine (
        .clk(clk), .rst_n(rst_n), .start(ce_start), .start_ready(ce_start_ready),
        .active_rows(ce_active_rows), .active_cols(ce_active_cols), .k_len(ce_k_len),
        .weight_valid(ce_weight_valid), .weight_ready(ce_weight_ready), .weight_data(ce_weight_flat),
        .activation_valid(ce_activation_valid), .activation_ready(ce_activation_ready), .activation_data(c1_md),
        .busy(ce_busy), .done(ce_done), .config_error(ce_config_error),
        .out_valid(ce_out_valid), .out_ready(ce_out_ready), .out_acc_flat(ce_out_acc_flat),
        .out_lane_valid(ce_out_lane_valid), .out_col(ce_out_col), .out_k_last(ce_out_k_last),
        .out_last(ce_out_last), .drain_stall(ce_drain_stall), .cycle_count(ce_cycle_count),
        .mac_fire_flat(ce_mac_fire_flat)
    );

    task automatic run_integration;
        integer beat, cycles, b, r, c, got;
        integer exp;
        begin
            integration_mode = 1;
            c1_sv = 0; c1_sl = 0; c1_mr_manual = 0;
            beat = 0; cycles = 0; got = 0;
            ce_active_rows = 6; ce_active_cols = 8; ce_k_len = 75;
            while ((got < 8 || !ce_done) && (cycles < 200000)) begin
                @(negedge clk);
                cycles = cycles + 1;
                if (ce_out_valid && ce_out_ready) begin
                    for (r = 0; r < 6; r = r + 1) begin
                        exp = c1_acc_expected(r, ce_out_col);
                        if ($signed(ce_out_acc_flat[r*32 +: 32]) !== exp) begin
                            $display("FAIL integration row=%0d col=%0d got=%0d exp=%0d",
                                     r, ce_out_col, $signed(ce_out_acc_flat[r*32 +: 32]), exp);
                            errors = errors + 1;
                        end
                    end
                    got = got + 1;
                end
                if (c1_sv && c1_sr) begin c1_sv = 0; beat = beat + 1; end
                if (!c1_sv && beat < 384) begin
                    c1_sd = 0;
                    for (b = 0; b < 8; b = b + 1)
                        c1_sd[b*8 +: 8] = frame1[beat*8+b];
                    c1_sl = (beat == 383);
                    c1_sv = 1;
                end
                if (ce_done)
                    integration_mode = 0;
            end
            if (got != 8 || !ce_done || ce_config_error) begin
                $display("FAIL integration count=%0d done=%b config_error=%b", got, ce_done, ce_config_error);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        errors = 0;
        prng = 32'h1234567;
        integration_mode = 0;
        c1_mr_manual = 0;
        c2p_restart = 0;
        ce_active_rows = 0; ce_active_cols = 0; ce_k_len = 0;
        for (i = 0; i < 3072; i = i + 1) frame1[i] = (i*37 + 11) & 8'hff;
        for (i = 0; i < 1176; i = i + 1) frame2[i] = (i*53 + 19) & 8'hff;
        for (i = 0; i < 400; i = i + 1) frame3[i] = (i*29 + 7) & 8'hff;

        // Padded tile-major conv2 frame.  Real bytes stay in 0..159 so neither
        // sentinel can occur as data; the sentinels therefore prove something.
        // Same formula as model/window_ref.py's _conv2_physical_check.
        for (ih = 0; ih < 14; ih = ih + 1)
            for (iw = 0; iw < 14; iw = iw + 1)
                for (ic = 0; ic < 8; ic = ic + 1) begin
                    if (ic < 6)
                        frame2p[(ih*14 + iw)*8 + ic] =
                            ((((ih*14 + iw)*6 + ic) * 53 + 19) % 160);
                    else if (ic == 6)
                        frame2p[(ih*14 + iw)*8 + ic] = PAD_SENTINEL_A;
                    else
                        frame2p[(ih*14 + iw)*8 + ic] = PAD_SENTINEL_B;
                end
        // The sentinel assertion is only meaningful if the sentinel values
        // appear nowhere else in the frame.  Prove it rather than assume it.
        for (i = 0; i < 1568; i = i + 1)
            if (((frame2p[i] === PAD_SENTINEL_A) || (frame2p[i] === PAD_SENTINEL_B)) &&
                ((i % 8) < 6)) begin
                $display("FAIL frame2p sentinel value collides with real data at byte %0d", i);
                errors = errors + 1;
            end

        reset_all();
        run_conv1(0, 0);
        reset_all();
        run_conv1(1, 1);

        reset_all();
        run_conv2();
        reset_all();
        run_fc1();

        // T_CONV2_REPLAY_001: padded layout, two m_ready patterns.  The first
        // run also covers a restart issued while the generator is still idle
        // after reset: that is accepted, so it must be a silent no-op and the
        // frame that follows it must still be perfect.
        reset_all();
        pulse_restart();
        if (c2p_rerr) begin
            $display("FAIL idle restart after reset raised restart_error");
            errors = errors + 1;
        end
        run_conv2_phys(0, 0, 0);
        reset_all();
        run_conv2_phys(1, 1, 0);
        compare_c2p_slots(0, 1, "c2p backpressure invariance");

        // Frame restart after done, twice with different m_ready patterns.
        reset_all();
        run_restart_replay(0, 1);
        reset_all();
        run_restart_replay(2, 0);

        // Mid-frame restart must be refused, must latch restart_error, and
        // must not disturb the stream.  Slot 0 still holds the clean pass
        // recorded by the replay run above, so it is the reference.
        reset_all();
        run_conv2_phys(0, 0, 0);
        run_conv2_phys_midframe_check(0);
        run_conv2_phys_midframe_check(1);

        reset_all();
        if (c2p_rerr) begin
            $display("FAIL restart_error survived a reset");
            errors = errors + 1;
        end

        reset_all();
        run_integration();

        if (sentinel_hits != 0)
            errors = errors + sentinel_hits;

        if (errors == 0)
            $display("PASS tb_window_gen");
        else
            $display("FAIL tb_window_gen: %0d errors", errors);
        $finish;
    end

    initial begin
        repeat (3000000) @(posedge clk);
        $display("FAIL tb_window_gen watchdog timeout");
        $finish;
    end
endmodule
