`timescale 1ns/1ps
// Real v3 Conv1: existing oracle vectors, two channel passes, two stall patterns.
module tb_v3_conv1_poc;
    localparam int ROWS       = 8;
    localparam int COLS       = 8;
    localparam int DATA_WIDTH = 8;
    localparam int ACC_WIDTH  = 32;
    localparam int M0_W       = 18;

    localparam int KERN_H = 3;
    localparam int KERN_W = 3;
    localparam int C_IN   = 3;
    localparam int IN_H   = 32;
    localparam int IN_W   = 32;
    localparam int C_OUT  = 8; // physical lanes per pass, 16 logical channels

    localparam int K_LEN       = C_IN * KERN_H * KERN_W;   // 27
    localparam int OUT_H       = IN_H;        // 32
    localparam int OUT_W       = IN_W;        // 32
    localparam int TILES_PER_ROW = (OUT_W + COLS - 1) / COLS;  // 4
    localparam int TILES       = OUT_H * TILES_PER_ROW;    // 128
    localparam int OUT_BEATS   = OUT_H * OUT_W;            // 1024
    localparam int FRAME_BEATS = (IN_H * IN_W * C_IN) / 8; // 384

    localparam int K_MAX    = 1024;
    localparam int TILE_MAX = 16;
    localparam int W_DEPTH  = 8192;

    localparam int ROW_W  = $clog2(ROWS+1);
    localparam int COL_W  = $clog2(COLS+1);
    localparam int K_W    = $clog2(K_MAX+1);
    localparam int TILE_W = $clog2(TILE_MAX);

    localparam int TIMEOUT_CYCLES = 500_000;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    always #5 clk = ~clk;

    // -- vectors ----------------------------------------------------------
    logic [63:0] frame_mem [0:FRAME_BEATS-1];
    logic [63:0] y_mem     [0:OUT_BEATS-1];
    logic [31:0] acc_mem   [0:OUT_BEATS*ROWS-1];
    logic [7:0]  tile_cols [0:TILES-1];
    logic [31:0] biased_mem [0:OUT_BEATS*ROWS-1];
    string vector_dir = "../../../cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_conv1_poc";
    int channel_tile;
    int bias_beats [0:7];
    logic restart, restart_error;

    logic signed [ACC_WIDTH-1:0] cfg_bias_q  [0:ROWS-1];
    logic signed [M0_W-1:0]      cfg_m0      [0:ROWS-1];
    logic        [5:0]           cfg_shift_n [0:ROWS-1];
    logic                        cfg_relu    [0:ROWS-1];
    logic                        cfg_bypass;

    logic [7:0] wbank_tmp [0:W_DEPTH-1];

    // -- dut interface ----------------------------------------------------
    logic        s_valid;
    logic        s_ready;
    logic [63:0] s_data;
    logic        s_last;

    logic                        w_wr_en;
    logic [$clog2(ROWS)-1:0]     w_wr_bank;
    logic [$clog2(W_DEPTH)-1:0]  w_wr_addr;
    logic [DATA_WIDTH-1:0]       w_wr_data;

    logic              frame_start;
    logic [ROW_W-1:0]  cfg_active_rows;
    logic [K_W-1:0]    cfg_k_len;
    logic [TILE_W-1:0] cfg_tile_idx;

    logic             m_valid;
    logic             m_ready;
    logic [ROWS*8-1:0] m_y_flat;
    logic [ROWS-1:0]  m_lane_valid;
    logic [COL_W-1:0] m_col;
    logic             m_last;
    logic [ROWS-1:0]  m_sat_flat;
    logic [ROWS-1:0]  m_ovf_flat;

    logic        busy;
    logic        layer_done;
    logic        window_done;
    logic [31:0] tile_count;
    logic [7:0]  error_flags;
    logic        lockstep_error;
    logic        drain_stall;
    logic [31:0] engine_cycle_count;

    conv1_top #(
        .ROWS       (ROWS),
        .COLS       (COLS),
        .DATA_WIDTH (DATA_WIDTH),
        .ACC_WIDTH  (ACC_WIDTH),
        .M0_W       (M0_W),
        .KERN_H     (KERN_H),
        .KERN_W     (KERN_W),
        .C_IN       (C_IN),
        .IN_H       (IN_H),
        .IN_W       (IN_W),
        .STRIDE     (1),
        .PAD        (1),
        .K_MAX      (K_MAX),
        .TILE_MAX   (TILE_MAX),
        .W_DEPTH    (W_DEPTH)
    ) dut (
        .clk                (clk),
        .rst_n              (rst_n),
        .restart(restart), .restart_error(restart_error),
        .s_valid            (s_valid),
        .s_ready            (s_ready),
        .s_data             (s_data),
        .s_last             (s_last),
        .w_wr_en            (w_wr_en),
        .w_wr_bank          (w_wr_bank),
        .w_wr_addr          (w_wr_addr),
        .w_wr_data          (w_wr_data),
        .frame_start        (frame_start),
        .cfg_active_rows    (cfg_active_rows),
        .cfg_k_len          (cfg_k_len),
        .cfg_tile_idx       (cfg_tile_idx),
        .cfg_bias_q         (cfg_bias_q),
        .cfg_m0             (cfg_m0),
        .cfg_shift_n        (cfg_shift_n),
        .cfg_relu           (cfg_relu),
        .cfg_bypass         (cfg_bypass),
        .m_valid            (m_valid),
        .m_ready            (m_ready),
        .m_y_flat           (m_y_flat),
        .m_lane_valid       (m_lane_valid),
        .m_col              (m_col),
        .m_last             (m_last),
        .m_sat_flat         (m_sat_flat),
        .m_ovf_flat         (m_ovf_flat),
        .busy               (busy),
        .layer_done         (layer_done),
        .window_done        (window_done),
        .tile_count         (tile_count),
        .error_flags        (error_flags),
        .lockstep_error     (lockstep_error),
        .drain_stall        (drain_stall),
        .engine_cycle_count (engine_cycle_count)
    );

    // -- scoreboard state -------------------------------------------------
    // Each monitor keeps its own counter so a failure says which seam broke,
    // and the totals are summed at the end.  The monitors below are plain
    // clocked always blocks, not always_ff: always_ff allows only one
    // procedural driver per variable, and the stimulus thread also writes
    // these counters and the beat indices.
    int err_seq;      // the stimulus thread and the per-frame checks
    int err_out;      // requantized output beat scoreboard
    int err_acc;      // engine/requant seam scoreboard
    int err_status;   // sticky status/error flag monitor
    int out_beats_seen;
    int acc_beats_seen;
    int tile_index;        // which tile the next output beat belongs to
    int col_in_tile;       // expected m_col for the next output beat
    bit checking;          // scoreboard armed only while a frame is running

    // XSim has no seeded $urandom, so stalls come from an explicit LFSR: the
    // stall pattern is part of the test, and it has to be reproducible.
    logic [15:0] lfsr_out;
    logic [15:0] lfsr_in;

    function automatic logic [15:0] lfsr_next(logic [15:0] v);
        return {v[14:0], v[15] ^ v[13] ^ v[12] ^ v[10]};
    endfunction

    // -- helpers ----------------------------------------------------------
    task automatic load_vectors;
        string path;
        begin
            $readmemh({vector_dir,"/frame.mem"}, frame_mem);
            for (int r=0; r<8; r++) begin
                path=$sformatf("%s/wbank%0d.mem",vector_dir,r);
                $readmemh(path,wbank_tmp,0,2*K_LEN-1);
                for (int a=0; a<2*K_LEN; a++) begin
                    @(negedge clk);
                    w_wr_en=1; w_wr_bank=r; w_wr_addr=a; w_wr_data=wbank_tmp[a];
                    @(posedge clk);
                end
            end
            @(negedge clk); w_wr_en=0;
            for (int t=0;t<TILES;t++) tile_cols[t]=8;
        end
    endtask

    task automatic load_pass(input int ct);
        logic [31:0] biases [0:15];
        logic [17:0] multipliers [0:15];
        logic [5:0] shifts [0:15];
        begin
            channel_tile=ct;
            $readmemh({vector_dir,"/bias_q.mem"},biases);
            $readmemh({vector_dir,"/M0.mem"},multipliers);
            $readmemh({vector_dir,"/n.mem"},shifts);
            for(int r=0;r<8;r++) begin
                cfg_bias_q[r]=biases[ct*8+r];
                cfg_m0[r]=multipliers[ct*8+r];
                cfg_shift_n[r]=shifts[ct*8+r];
                cfg_relu[r]=1;
                bias_beats[r]=0;
            end
            $readmemh($sformatf("%s/t%0d_y.mem",vector_dir,ct),y_mem);
            $readmemh($sformatf("%s/t%0d_acc.mem",vector_dir,ct),acc_mem);
            $readmemh($sformatf("%s/t%0d_biased.mem",vector_dir,ct),biased_mem);
        end
    endtask

    task automatic do_reset;
        begin
            @(negedge clk);
            rst_n       = 1'b0;
            restart = 0;
            w_wr_en     = 1'b0;
            w_wr_bank   = '0;
            w_wr_addr   = '0;
            w_wr_data   = '0;
            s_valid     = 1'b0;
            s_data      = '0;
            s_last      = 1'b0;
            frame_start = 1'b0;
            repeat (4) @(negedge clk);
            rst_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    // Feed the whole 384-beat frame.  `gap_mode` 0 is full rate, 1 inserts
    // pseudo-random gaps so the generator's input side is starved too.
    task automatic feed_frame(input int gap_mode);
        begin
            lfsr_in = 16'hBEEF;
            for (int b = 0; b < FRAME_BEATS; b++) begin
                if (gap_mode != 0) begin
                    lfsr_in = lfsr_next(lfsr_in);
                    if (lfsr_in[2:0] == 3'b000) begin
                        @(negedge clk);
                        s_valid = 1'b0;
                        repeat (1 + lfsr_in[5:4]) @(posedge clk);
                    end
                end
                @(negedge clk);
                s_valid = 1'b1;
                s_data  = frame_mem[b];
                s_last  = (b == FRAME_BEATS-1);
                // The beat is accepted at the first posedge where s_ready is
                // high; valid and data stay stable until then.
                @(posedge clk);
                while (!s_ready) @(posedge clk);
                @(negedge clk);
                s_valid = 1'b0;
                s_last  = 1'b0;
            end
        end
    endtask

    // -- output consumer with backpressure --------------------------------
    // ready_mode 1: deterministic LFSR stalls; 2: periodic four-cycle stalls.
    int ready_mode;

    int ready_cycle;
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ready_cycle <= 0;
            m_ready  <= 1'b0;
            lfsr_out <= 16'hACE1;
        end else if (!checking) begin
            m_ready <= 1'b0;
        end else if (ready_mode == 0) begin
            m_ready <= 1'b1;
        end else if (ready_mode == 2) begin
            ready_cycle <= ready_cycle+1;
            m_ready <= ((ready_cycle % 11) >= 4);
        end else begin
            lfsr_out <= lfsr_next(lfsr_out);
            m_ready  <= (lfsr_out[3:0] != 4'h0);
        end
    end

    // -- scoreboard: requantized output beats -----------------------------
    always @(posedge clk) begin
        if (rst_n && checking && m_valid && m_ready) begin
            if (out_beats_seen >= OUT_BEATS) begin
                $display("FAIL: extra output beat %0d (expected %0d in total)",
                         out_beats_seen, OUT_BEATS);
                err_out++;
            end else begin
                if (m_y_flat !== y_mem[out_beats_seen]) begin
                    $display("FAIL: beat %0d (tile %0d col %0d) y=%016h expected %016h",
                             out_beats_seen, tile_index, col_in_tile,
                             m_y_flat, y_mem[out_beats_seen]);
                    err_out++;
                end
                if (m_lane_valid !== 8'((1 << C_OUT) - 1)) begin
                    $display("FAIL: beat %0d lane_valid %02h expected %02h",
                             out_beats_seen, m_lane_valid,
                             8'((1 << C_OUT) - 1));
                    err_out++;
                end
                if (m_col !== COL_W'(col_in_tile)) begin
                    $display("FAIL: beat %0d col %0d expected %0d",
                             out_beats_seen, m_col, col_in_tile);
                    err_out++;
                end
                if (m_last !== (col_in_tile == int'(tile_cols[tile_index]) - 1)) begin
                    $display("FAIL: beat %0d last=%0b at col %0d of %0d",
                             out_beats_seen, m_last, col_in_tile,
                             tile_cols[tile_index]);
                    err_out++;
                end
                // Saturation is expected on this fixture; an overflow flag is
                // not -- the bias add must not wrap at any point.
                if ((m_ovf_flat & m_lane_valid) != '0) begin
                    $display("FAIL: beat %0d raised overflow %02h",
                             out_beats_seen, m_ovf_flat);
                    err_out++;
                end

                out_beats_seen++;
                if (col_in_tile == int'(tile_cols[tile_index]) - 1) begin
                    col_in_tile = 0;
                    tile_index++;
                end else begin
                    col_in_tile++;
                end
            end
        end
    end

    // -- scoreboard: engine/requant seam (INT32 accumulators) -------------
    always @(posedge clk) begin
        if (rst_n && checking && dut.acc_valid && dut.acc_ready) begin
            if (acc_beats_seen >= OUT_BEATS) begin
                $display("FAIL: extra accumulator beat %0d", acc_beats_seen);
                err_acc++;
            end else begin
                for (int lane = 0; lane < ROWS; lane++) begin
                    if (dut.acc_lane_valid[lane] &&
                        dut.acc_flat[lane*ACC_WIDTH +: ACC_WIDTH] !==
                        acc_mem[acc_beats_seen*ROWS + lane]) begin
                        $display("FAIL: acc beat %0d lane %0d = %08h expected %08h",
                                 acc_beats_seen, lane,
                                 dut.acc_flat[lane*ACC_WIDTH +: ACC_WIDTH],
                                 acc_mem[acc_beats_seen*ROWS + lane]);
                        err_acc++;
                    end
                end
                acc_beats_seen++;
            end
        end
    end

    generate for(genvar lane=0;lane<8;lane++) begin : bias_score
        always @(posedge clk) begin
            if(rst_n && checking && dut.u_requant.g_lane[lane].u_req.in_valid &&
               dut.u_requant.g_lane[lane].u_req.in_ready) begin
                if(bias_beats[lane]>=OUT_BEATS) $fatal(1,"extra biased value");
                if(dut.u_requant.g_lane[lane].u_req.s0_a_comb !==
                   biased_mem[bias_beats[lane]*8+lane])
                    $fatal(1,"biased mismatch tile %0d lane %0d beat %0d",channel_tile,lane,bias_beats[lane]);
                bias_beats[lane]++;
            end
        end
    end endgenerate

    // Output payload must remain stable across backpressure, not just match
    // at handshakes. This also checks sideband stability.
    property p_stable_output;
        @(posedge clk) disable iff(!rst_n)
        m_valid && !m_ready |=> m_valid && $stable({m_y_flat,m_lane_valid,m_col,m_last,m_sat_flat,m_ovf_flat});
    endproperty
    assert property(p_stable_output) else $fatal(1,"stalled output changed");

    // layer_done is a one-cycle pulse, and it is raised when the engine drains
    // the last tile -- that is several cycles BEFORE the final requantized beat
    // emerges from the requant pipeline.  It has to be latched, not polled.
    bit layer_done_seen;

    always @(posedge clk) begin
        if (!rst_n || restart)
            layer_done_seen <= 1'b0;
        else if (layer_done)
            layer_done_seen <= 1'b1;
    end

    // -- status monitors ---------------------------------------------------
    // Both of these are sticky in the DUT, so they are reported once rather
    // than once per cycle -- otherwise one real fault buries the log.
    bit flags_reported;
    bit lockstep_reported;

    always @(posedge clk) begin
        if (!rst_n) begin
            flags_reported    <= 1'b0;
            lockstep_reported <= 1'b0;
        end else begin
            if ((error_flags != 8'h00) && !flags_reported) begin
                $display("FAIL: layer_ctrl error_flags %02h", error_flags);
                err_status++;
                flags_reported <= 1'b1;
            end
            if (lockstep_error && !lockstep_reported) begin
                $display("FAIL: requant lockstep_error");
                err_status++;
                lockstep_reported <= 1'b1;
            end
        end
    end

    task automatic run_frame(input int gap_mode, input int rdy_mode,
                             input string label);
        int guard;
        begin
            ready_mode     = rdy_mode;
            out_beats_seen = 0;
            acc_beats_seen = 0;
            tile_index     = 0;
            col_in_tile    = 0;
            checking       = 1'b1;

            cfg_active_rows = ROW_W'(C_OUT);
            cfg_k_len       = K_W'(K_LEN);
            cfg_tile_idx    = TILE_W'(channel_tile);

            @(negedge clk);
            frame_start = 1'b1;
            @(posedge clk);
            @(negedge clk);
            frame_start = 1'b0;

            fork
                feed_frame(gap_mode);
            join_none

            guard = 0;
            while (out_beats_seen < OUT_BEATS && guard < TIMEOUT_CYCLES) begin
                @(posedge clk);
                guard++;
            end

            if (guard >= TIMEOUT_CYCLES) begin
                $display("FAIL: %s timed out after %0d cycles with %0d/%0d beats",
                         label, guard, out_beats_seen, OUT_BEATS);
                err_seq++;
            end

            // Give the controller a bounded window to close out the frame in
            // case layer_done trails the last beat on some future revision.
            guard = 0;
            while (!layer_done_seen && guard < 1000) begin
                @(posedge clk);
                guard++;
            end
            if (!layer_done_seen) begin
                $display("FAIL: %s produced every beat but never asserted layer_done",
                         label);
                err_seq++;
            end

            if (tile_count != TILES) begin
                $display("FAIL: %s ran %0d tiles, expected %0d",
                         label, tile_count, TILES);
                err_seq++;
            end
            if (acc_beats_seen != OUT_BEATS) begin
                $display("FAIL: %s saw %0d accumulator beats, expected %0d",
                         label, acc_beats_seen, OUT_BEATS);
                err_seq++;
            end
            if (!window_done) begin
                $display("FAIL: %s finished without window_gen done", label);
                err_seq++;
            end

            // Keep monitors armed beyond the expected last beat to catch extras.
            repeat (20) @(negedge clk);
            for (int r=0;r<8;r++)
                if (bias_beats[r] != OUT_BEATS) $fatal(1,"bias count lane %0d",r);
            if (restart_error) $fatal(1,"restart rejected");
            checking = 1'b0;
            $display("[%s] %0d output beats, %0d accumulator beats, %0d tiles, engine cycles %0d",
                     label, out_beats_seen, acc_beats_seen, tile_count,
                     engine_cycle_count);
        end
    endtask

    initial begin
        err_seq    = 0;
        err_out    = 0;
        err_acc    = 0;
        err_status = 0;
        checking   = 1'b0;
        ready_mode = 0;
        cfg_bypass = 1'b0;

        do_reset();
        load_vectors();

        // TB supplies the outer channel loop. No full-network controller claim.
        for (int pattern=1;pattern<=2;pattern++) begin
            for (int ct=0;ct<2;ct++) begin
                if (pattern!=1 || ct!=0) begin
                    @(negedge clk); restart=1;
                    @(negedge clk); restart=0;
                    repeat(3) @(negedge clk);
                end
                load_pass(ct);
                run_frame(1,pattern,$sformatf("pattern%0d channels%0d..%0d",pattern,ct*8,ct*8+7));
            end
        end

        if (err_seq + err_out + err_acc + err_status == 0)
            $display("PASS tb_v3_conv1_poc: 16384 INT8 + MAC + biased values per pattern; two patterns; %0d tiles/pass, %0d beats/pass",
                     TILES, OUT_BEATS);
        else
            $display("FAIL tb_v3_conv1_poc: %0d errors (seq %0d, out %0d, acc %0d, status %0d)",
                     err_seq + err_out + err_acc + err_status,
                     err_seq, err_out, err_acc, err_status);
        $finish;
    end

    // Hard stop: a deadlock in the paired handshake would otherwise hang the
    // regression instead of reporting a failure.
    initial begin
        #(20 * TIMEOUT_CYCLES * 2);
        $display("FAIL tb_v3_conv1_poc: global timeout");
        $finish;
    end
endmodule
