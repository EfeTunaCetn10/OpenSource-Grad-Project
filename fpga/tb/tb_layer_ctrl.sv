`timescale 1ns/1ps

// Self-checking layer_ctrl test with the real compute_engine and a
// cycle-accurate behavioural weight source.  The main frame sends two K=75
// tiles (active_cols 8 then 4), first at full rate and then with deterministic
// activation/weight starvation plus a twelve-cycle output stall.
module tb_layer_ctrl;
    localparam int ROWS   = 8;
    localparam int COLS   = 8;
    localparam int K_MAX  = 1024;
    localparam int ROW_W  = $clog2(ROWS+1);
    localparam int COL_W  = $clog2(COLS+1);
    localparam int K_W    = $clog2(K_MAX+1);
    localparam int TILE_W = $clog2(16);

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic frame_start;
    logic [ROW_W-1:0] cfg_active_rows;
    logic [K_W-1:0] cfg_k_len;
    logic [TILE_W-1:0] cfg_tile_idx;
    logic busy, layer_done;

    logic w_valid, w_ready;
    logic [63:0] w_data;
    logic [3:0] w_active_cols;
    logic [31:0] w_k;
    logic w_tile_start, w_tile_last, w_done;

    logic eng_start, ctrl_eng_start_ready, eng_start_ready_raw;
    logic [ROW_W-1:0] eng_active_rows;
    logic [COL_W-1:0] eng_active_cols;
    logic [K_W-1:0] eng_k_len;
    logic eng_activation_valid;
    logic ctrl_eng_activation_ready, eng_activation_ready_raw;
    logic [63:0] eng_activation_data;
    logic eng_done, eng_config_error;

    logic wf_start, wf_ready;
    logic [TILE_W-1:0] wf_tile_idx;
    logic [K_W-1:0] wf_k_len;
    logic wf_done, wf_cfg_error;

    logic [31:0] tile_count;
    logic [7:0] error_flags;

    logic engine_weight_valid, engine_weight_ready;
    logic [63:0] engine_weight_data;
    logic engine_busy;
    logic engine_out_valid, engine_out_ready;
    logic [ROWS*32-1:0] engine_out_acc_flat;
    logic [ROWS-1:0] engine_out_lane_valid;
    logic [COL_W-1:0] engine_out_col;
    logic engine_out_k_last, engine_out_last, engine_drain_stall;
    logic [31:0] engine_cycle_count;
    logic [ROWS*COLS-1:0] engine_mac_fire_flat;

    logic eng_ready_allow;
    logic inject_bad_activation_ready;
    logic inject_wf_cfg_error;

    assign ctrl_eng_start_ready = eng_start_ready_raw && eng_ready_allow;
    assign ctrl_eng_activation_ready = inject_bad_activation_ready ?
                                       1'b1 : eng_activation_ready_raw;
    assign wf_cfg_error = inject_wf_cfg_error;

    layer_ctrl dut (
        .clk(clk), .rst_n(rst_n),
        .frame_start(frame_start), .cfg_active_rows(cfg_active_rows),
        .cfg_k_len(cfg_k_len), .cfg_tile_idx(cfg_tile_idx),
        .busy(busy), .layer_done(layer_done),
        .w_valid(w_valid), .w_ready(w_ready), .w_data(w_data),
        .w_active_cols(w_active_cols), .w_k(w_k),
        .w_tile_start(w_tile_start), .w_tile_last(w_tile_last),
        .w_done(w_done),
        .eng_start(eng_start), .eng_start_ready(ctrl_eng_start_ready),
        .eng_active_rows(eng_active_rows), .eng_active_cols(eng_active_cols),
        .eng_k_len(eng_k_len),
        .eng_activation_valid(eng_activation_valid),
        .eng_activation_ready(ctrl_eng_activation_ready),
        .eng_activation_data(eng_activation_data),
        .eng_done(eng_done), .eng_config_error(eng_config_error),
        .wf_start(wf_start), .wf_ready(wf_ready),
        .wf_tile_idx(wf_tile_idx), .wf_k_len(wf_k_len),
        .wf_done(wf_done), .wf_cfg_error(wf_cfg_error),
        .tile_count(tile_count), .error_flags(error_flags)
    );

    compute_engine #(
        .ROWS(ROWS), .COLS(COLS), .K_MAX(K_MAX)
    ) u_engine (
        .clk(clk), .rst_n(rst_n),
        .start(eng_start), .start_ready(eng_start_ready_raw),
        .active_rows(eng_active_rows), .active_cols(eng_active_cols),
        .k_len(eng_k_len),
        .weight_valid(engine_weight_valid), .weight_ready(engine_weight_ready),
        .weight_data(engine_weight_data),
        .activation_valid(eng_activation_valid),
        .activation_ready(eng_activation_ready_raw),
        .activation_data(eng_activation_data),
        .busy(engine_busy), .done(eng_done), .config_error(eng_config_error),
        .out_valid(engine_out_valid), .out_ready(engine_out_ready),
        .out_acc_flat(engine_out_acc_flat),
        .out_lane_valid(engine_out_lane_valid), .out_col(engine_out_col),
        .out_k_last(engine_out_k_last), .out_last(engine_out_last),
        .drain_stall(engine_drain_stall), .cycle_count(engine_cycle_count),
        .mac_fire_flat(engine_mac_fire_flat)
    );

    integer errors = 0;
    string phase = "reset";

    task automatic fail(input string message);
        begin
            $display("FAIL %s: %s", phase, message);
            errors = errors + 1;
        end
    endtask

    // ------------------------------------------------------------------
    // Behavioural window source
    // ------------------------------------------------------------------
    logic producer_enable;
    logic producer_started;
    integer producer_tiles;
    integer producer_tile;
    integer producer_k;
    integer producer_gap;
    logic producer_gap_second;
    logic producer_bad_last;
    logic producer_bad_cols;
    logic producer_early_done;
    logic [31:0] producer_lfsr;
    integer source_gap_cycles;
    integer source_accepts [0:3];

    task automatic load_window_beat(input integer tile_no, input integer k_no);
        begin
            w_data        <= {16'(tile_no), 16'(k_no), 32'h5A00_0000 ^ k_no};
            w_active_cols <= (tile_no == 0) ? 4'd8 : 4'd4;
            if (producer_bad_cols && (k_no >= 2))
                w_active_cols <= 4'd7;
            w_k          <= k_no;
            w_tile_start <= (k_no == 0);
            w_tile_last  <= (k_no == (int'(cfg_k_len) - 1));
            if (producer_bad_last && (k_no == 1))
                w_tile_last <= 1'b1;
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            w_valid          <= 1'b0;
            w_data           <= '0;
            w_active_cols    <= '0;
            w_k              <= '0;
            w_tile_start     <= 1'b0;
            w_tile_last      <= 1'b0;
            w_done           <= 1'b0;
            producer_started <= 1'b0;
            producer_tile    <= 0;
            producer_k       <= 0;
            producer_gap     <= 0;
            producer_lfsr    <= 32'h19C0_FFEE;
            source_gap_cycles <= 0;
            source_accepts[0] <= 0;
            source_accepts[1] <= 0;
            source_accepts[2] <= 0;
            source_accepts[3] <= 0;
        end else if (!producer_enable) begin
            w_valid          <= 1'b0;
            w_done           <= 1'b0;
            w_tile_start     <= 1'b0;
            w_tile_last      <= 1'b0;
            producer_started <= 1'b0;
            producer_tile    <= 0;
            producer_k       <= 0;
            producer_gap     <= 0;
        end else if (!producer_started) begin
            producer_started <= 1'b1;
            producer_tile    <= 0;
            producer_k       <= 0;
            w_valid          <= 1'b1;
            w_done           <= 1'b0;
            load_window_beat(0, 0);
        end else begin
            producer_lfsr <= {producer_lfsr[30:0],
                              producer_lfsr[31] ^ producer_lfsr[21] ^
                              producer_lfsr[1] ^ producer_lfsr[0]};

            if (producer_early_done && (producer_tile == 0) &&
                (producer_k >= 2))
                w_done <= 1'b1;

            if (!w_valid && (producer_gap > 0)) begin
                producer_gap <= producer_gap - 1;
                source_gap_cycles <= source_gap_cycles + 1;
            end else if (!w_valid && (producer_gap == 0) && !w_done) begin
                w_valid <= 1'b1;
                load_window_beat(producer_tile, producer_k);
            end

            if (w_valid && w_ready) begin
                source_accepts[producer_tile] <=
                    source_accepts[producer_tile] + 1;
                if (producer_k == (int'(cfg_k_len) - 1)) begin
                    if (producer_tile == (producer_tiles - 1)) begin
                        w_valid <= 1'b0;
                        w_done  <= 1'b1;
                    end else begin
                        producer_tile <= producer_tile + 1;
                        producer_k    <= 0;
                        w_valid       <= 1'b1;
                        load_window_beat(producer_tile + 1, 0);
                    end
                end else begin
                    producer_k <= producer_k + 1;
                    if (producer_gap_second && (producer_tile == 1) &&
                        (((producer_k + 1) % 9) == 0)) begin
                        // One- and two-cycle gaps alternate deterministically.
                        producer_gap <= producer_lfsr[0] ? 1 : 2;
                        w_valid      <= 1'b0;
                    end else begin
                        w_valid <= 1'b1;
                        load_window_beat(producer_tile, producer_k + 1);
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Behavioural feeder: synchronous command, stable valid/data, and
    // deterministic 1/2/7-cycle starvation on the second main-frame tile.
    // ------------------------------------------------------------------
    logic feeder_active;
    logic feeder_ready_allow;
    integer feeder_k;
    integer feeder_k_len;
    integer feeder_tile_no;
    integer feeder_stall;
    integer feeder_stall_cycles;
    integer feeder_launches;
    integer feeder_beats [0:3];
    integer feeder_lane;

    assign wf_ready = feeder_ready_allow && !feeder_active;
    assign engine_weight_valid = feeder_active && (feeder_stall == 0);

    always_comb begin
        engine_weight_data = '0;
        for (feeder_lane = 0; feeder_lane < ROWS; feeder_lane = feeder_lane + 1)
            engine_weight_data[feeder_lane*8 +: 8] =
                8'((feeder_lane + 1) * 3 + feeder_k);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            feeder_active       <= 1'b0;
            feeder_k            <= 0;
            feeder_k_len        <= 0;
            feeder_tile_no      <= 0;
            feeder_stall        <= 0;
            feeder_stall_cycles <= 0;
            feeder_launches     <= 0;
            feeder_beats[0]     <= 0;
            feeder_beats[1]     <= 0;
            feeder_beats[2]     <= 0;
            feeder_beats[3]     <= 0;
            wf_done             <= 1'b0;
        end else begin
            wf_done <= 1'b0;
            if (!busy) begin
                feeder_active <= 1'b0;
                feeder_stall  <= 0;
            end
            if (wf_start && wf_ready) begin
                feeder_active  <= 1'b1;
                feeder_k       <= 0;
                feeder_k_len   <= wf_k_len;
                feeder_tile_no <= feeder_launches;
                feeder_launches <= feeder_launches + 1;
            end
            if (feeder_stall > 0) begin
                feeder_stall <= feeder_stall - 1;
                feeder_stall_cycles <= feeder_stall_cycles + 1;
            end
            if (engine_weight_valid && engine_weight_ready) begin
                feeder_beats[feeder_tile_no] <=
                    feeder_beats[feeder_tile_no] + 1;
                if (feeder_k == (feeder_k_len - 1)) begin
                    feeder_active <= 1'b0;
                    wf_done       <= 1'b1;
                end else begin
                    feeder_k <= feeder_k + 1;
                    if (feeder_tile_no == 1) begin
                        case (feeder_k + 1)
                            5:  feeder_stall <= 1;
                            15: feeder_stall <= 2;
                            25: feeder_stall <= 7;
                            default: feeder_stall <= feeder_stall;
                        endcase
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Scoreboard and output backpressure
    // ------------------------------------------------------------------
    integer starts_seen;
    integer active_beats [0:3];
    integer output_beats [0:3];
    integer current_engine_tile;
    integer full_rate_bubbles;
    logic full_rate_started;
    logic clear_guard;
    logic bp_second_tile;
    integer drain_stall_cycles;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            starts_seen        <= 0;
            active_beats[0]    <= 0;
            active_beats[1]    <= 0;
            active_beats[2]    <= 0;
            active_beats[3]    <= 0;
            output_beats[0]    <= 0;
            output_beats[1]    <= 0;
            output_beats[2]    <= 0;
            output_beats[3]    <= 0;
            current_engine_tile <= 0;
            full_rate_bubbles  <= 0;
            full_rate_started  <= 1'b0;
            clear_guard        <= 1'b0;
            engine_out_ready   <= 1'b1;
            drain_stall_cycles <= 0;
        end else begin
            if (eng_start) begin
                current_engine_tile <= starts_seen;
                if (!ctrl_eng_start_ready)
                    fail("eng_start was asserted while its controller-side ready was low");
                if (eng_active_rows != cfg_active_rows)
                    fail("active_rows did not reach the engine command");
                if (eng_k_len != cfg_k_len)
                    fail("k_len did not reach the engine command");
                if ((starts_seen == 0) && (eng_active_cols != 8))
                    fail("first tile did not launch with active_cols=8");
                if ((starts_seen == 1) && (producer_tiles > 1) &&
                    (eng_active_cols != 4))
                    fail("right-edge tile did not launch with active_cols=4");
                starts_seen <= starts_seen + 1;
                clear_guard <= 1'b1;
                if (bp_second_tile && (starts_seen == 1))
                    engine_out_ready <= 1'b0;
            end else if (clear_guard) begin
                // During the one cycle after accepted start, the real engine
                // is in CLEAR and the layer gate must still be closed.
                if (eng_activation_valid)
                    fail("activation gate opened during engine CLEAR");
                clear_guard <= 1'b0;
            end

            if (wf_start) begin
                if ((wf_tile_idx != cfg_tile_idx) || (wf_k_len != cfg_k_len))
                    fail("weight-feeder command geometry mismatch");
            end

            if (eng_activation_valid && eng_activation_ready_raw) begin
                active_beats[current_engine_tile] <=
                    active_beats[current_engine_tile] + 1;
                if (current_engine_tile == 0)
                    full_rate_started <= 1'b1;
            end else if (full_rate_started && (current_engine_tile == 0) &&
                         (active_beats[0] < int'(cfg_k_len))) begin
                full_rate_bubbles <= full_rate_bubbles + 1;
            end

            if (engine_out_valid && engine_out_ready)
                output_beats[current_engine_tile] <=
                    output_beats[current_engine_tile] + 1;

            if (engine_out_valid && !engine_out_ready) begin
                drain_stall_cycles <= drain_stall_cycles + 1;
                if (drain_stall_cycles >= 11)
                    engine_out_ready <= 1'b1;
            end
        end
    end

    task automatic reset_all;
        begin
            producer_enable             = 1'b0;
            producer_tiles              = 1;
            producer_gap_second         = 1'b0;
            producer_bad_last           = 1'b0;
            producer_bad_cols           = 1'b0;
            producer_early_done         = 1'b0;
            frame_start                 = 1'b0;
            cfg_active_rows             = 6;
            cfg_k_len                   = 75;
            cfg_tile_idx                = 0;
            eng_ready_allow             = 1'b1;
            feeder_ready_allow          = 1'b1;
            inject_bad_activation_ready = 1'b0;
            inject_wf_cfg_error         = 1'b0;
            bp_second_tile              = 1'b0;
            rst_n                       = 1'b0;
            repeat (4) @(posedge clk);
            @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    task automatic launch_frame;
        begin
            @(negedge clk);
            producer_enable = 1'b1;
            frame_start     = 1'b1;
            @(negedge clk);
            frame_start     = 1'b0;
        end
    endtask

    task automatic wait_for_layer_done(input integer limit);
        integer cycles;
        begin
            cycles = 0;
            while (!layer_done && (cycles < limit)) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (!layer_done)
                fail("timeout waiting for layer_done");
            @(posedge clk);
            if (layer_done)
                fail("layer_done was wider than one cycle");
        end
    endtask

    task automatic check_sticky(input logic [7:0] expected);
        integer hold;
        begin
            for (hold = 0; hold < 5; hold = hold + 1) begin
                @(posedge clk);
                if (error_flags !== expected)
                    fail("error_flags were not sticky or had an unexpected bit");
            end
        end
    endtask

    initial begin
        // --- T_LC_MAIN -------------------------------------------------
        phase = "T_LC_MAIN";
        reset_all();
        producer_tiles      = 2;
        producer_gap_second = 1'b1;
        bp_second_tile      = 1'b1;
        eng_ready_allow     = 1'b0;
        launch_frame();

        wait (w_valid && w_tile_start);
        repeat (3) begin
            @(posedge clk);
            if (eng_start)
                fail("engine start ignored controller-side backpressure");
        end
        @(negedge clk);
        eng_ready_allow = 1'b1;
        wait_for_layer_done(20000);

        if (error_flags !== 8'h00)
            fail("clean frame raised error_flags");
        if ((starts_seen != 2) || (feeder_launches != 2) || (tile_count != 2))
            fail("tile/engine/feeder launch counts were not all two");
        if ((source_accepts[0] != 75) || (source_accepts[1] != 75) ||
            (active_beats[0] != 75) || (active_beats[1] != 75) ||
            (feeder_beats[0] != 75) || (feeder_beats[1] != 75))
            fail("a main-frame tile did not deliver exactly K=75 paired beats");
        if ((output_beats[0] != 8) || (output_beats[1] != 4))
            fail("engine drain counts did not match active_cols 8 then 4");
        if (full_rate_bubbles != 0)
            fail("full-rate first tile contained an activation bubble");
        if (source_gap_cycles == 0)
            fail("generator-gap phase did not create any valid gaps");
        if (feeder_stall_cycles < 10)
            fail("weight starvation did not cover 1/2/many-cycle stalls");
        if (drain_stall_cycles < 12)
            fail("consumer backpressure did not stretch engine DRAIN");

        // --- T_LC_FLAGS_2_TO_6 ----------------------------------------
        phase = "T_LC_FLAGS_2_TO_6";
        reset_all();
        cfg_k_len           = 6;
        producer_bad_last   = 1'b1;
        producer_bad_cols   = 1'b1;
        producer_early_done = 1'b1;
        eng_ready_allow     = 1'b0;
        launch_frame();
        wait (busy && w_valid);

        // Rejected frame command: clears old status and sets bit 5.
        @(negedge clk);
        frame_start = 1'b1;
        @(negedge clk);
        frame_start = 1'b0;

        // A substituted/broken engine claims a transfer while the gate is
        // closed.  The beat remains unaccepted because w_ready is still low.
        inject_bad_activation_ready = 1'b1;
        @(posedge clk);
        @(negedge clk);
        inject_bad_activation_ready = 1'b0;
        eng_ready_allow = 1'b1;
        wait_for_layer_done(5000);
        if (error_flags !== 8'h7C)
            fail("bits 2..6 were not all raised by their directed faults");
        check_sticky(8'h7C);

        // --- T_LC_ENGINE_CFG_ERROR ------------------------------------
        phase = "T_LC_ENGINE_CFG_ERROR";
        reset_all();
        cfg_active_rows = 0;
        cfg_k_len       = 6;
        launch_frame();
        wait (busy);
        wait (!busy);
        @(posedge clk);
        if (error_flags !== 8'h01)
            fail("engine config_error did not set bit 0 only");
        check_sticky(8'h01);

        // --- T_LC_FEEDER_CFG_ERROR ------------------------------------
        phase = "T_LC_FEEDER_CFG_ERROR";
        reset_all();
        cfg_k_len       = 6;
        eng_ready_allow = 1'b0;
        launch_frame();
        wait (wf_start);
        @(negedge clk);
        inject_wf_cfg_error = 1'b1;
        @(negedge clk);
        inject_wf_cfg_error = 1'b0;
        wait (!busy);
        @(posedge clk);
        if (error_flags !== 8'h02)
            fail("weight-feeder cfg_error did not set bit 1 only");
        check_sticky(8'h02);

        if (error_flags[7] !== 1'b0)
            fail("reserved error flag bit 7 was not tied low");

        if (errors == 0)
            $display("PASS tb_layer_ctrl");
        else
            $display("FAIL tb_layer_ctrl: %0d errors", errors);
        $finish;
    end

    initial begin
        repeat (200000) @(posedge clk);
        $display("FAIL tb_layer_ctrl watchdog timeout");
        $finish;
    end
endmodule
