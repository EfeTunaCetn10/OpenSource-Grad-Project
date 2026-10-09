`timescale 1ns/1ps

// FC1: 16*5*5 -> 120, one K=400 run per 8-output tile.
module tb_fc_layer;
    localparam int ROWS = 8;
    localparam int K = 400;
    localparam int TILES = 15;
    localparam int W_DEPTH = 8192;
    localparam int FRAME_BEATS = K/8;
    localparam int ROW_W = $clog2(ROWS+1);
    localparam int COL_W = $clog2(ROWS+1);
    localparam int K_W = $clog2(1024+1);
    localparam int TILE_W = $clog2(16);

    logic clk = 0;
    logic rst_n = 0;
    always #5 clk = ~clk;

    logic [63:0] frame_mem [0:FRAME_BEATS-1];
    logic [63:0] y_mem [0:TILES-1];
    logic [31:0] acc_mem [0:TILES*ROWS-1];
    logic [31:0] dims_mem [0:3];
    logic [7:0] wbank_tmp [0:TILES*K-1];
    logic signed [31:0] cfg_bias_q [0:ROWS-1];
    logic signed [17:0] cfg_m0 [0:ROWS-1];
    logic [5:0] cfg_shift_n [0:ROWS-1];
    logic cfg_relu [0:ROWS-1];

    logic s_valid, s_ready, s_last, restart, restart_error;
    logic [63:0] s_data;
    logic w_wr_en;
    logic [2:0] w_wr_bank;
    logic [$clog2(W_DEPTH)-1:0] w_wr_addr;
    logic [7:0] w_wr_data;
    logic frame_start;
    logic [ROW_W-1:0] cfg_active_rows;
    logic [K_W-1:0] cfg_k_len;
    logic [TILE_W-1:0] cfg_tile_idx;
    logic m_valid, m_ready, m_last;
    logic [63:0] m_y_flat;
    logic [7:0] m_lane_valid, m_sat_flat, m_ovf_flat;
    logic [COL_W-1:0] m_col;
    logic busy, layer_done, window_done, lockstep_error, drain_stall;
    logic [31:0] tile_count, engine_cycle_count;
    logic [7:0] error_flags;

    // K_MAX is intentionally left at conv1_top's 1024 default.
    conv1_top #(.C_IN(K), .KERN_H(1), .KERN_W(1), .IN_H(1),
                .IN_W(1)) dut (
        .clk(clk), .rst_n(rst_n), .s_valid(s_valid), .s_ready(s_ready),
        .s_data(s_data), .s_last(s_last), .restart(restart),
        .restart_error(restart_error), .w_wr_en(w_wr_en),
        .w_wr_bank(w_wr_bank), .w_wr_addr(w_wr_addr),
        .w_wr_data(w_wr_data), .frame_start(frame_start),
        .cfg_active_rows(cfg_active_rows), .cfg_k_len(cfg_k_len),
        .cfg_tile_idx(cfg_tile_idx), .cfg_bias_q(cfg_bias_q),
        .cfg_m0(cfg_m0), .cfg_shift_n(cfg_shift_n), .cfg_relu(cfg_relu),
        .cfg_bypass(1'b0), .m_valid(m_valid), .m_ready(m_ready),
        .m_y_flat(m_y_flat), .m_lane_valid(m_lane_valid),
        .m_col(m_col), .m_last(m_last), .m_sat_flat(m_sat_flat),
        .m_ovf_flat(m_ovf_flat), .busy(busy), .layer_done(layer_done),
        .window_done(window_done), .tile_count(tile_count),
        .error_flags(error_flags), .lockstep_error(lockstep_error),
        .drain_stall(drain_stall), .engine_cycle_count(engine_cycle_count)
    );

    int out_seen = 0;
    int acc_seen = 0;
    int done_seen = 0;
    int stall_seen = 0;
    bit checking = 0;
    bit mutate_y, mutate_acc, mutate_index;
    logic [15:0] lfsr = 16'hACE1;

    function automatic logic [15:0] lfsr_next(logic [15:0] v);
        return {v[14:0], v[15] ^ v[13] ^ v[12] ^ v[10]};
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            m_ready <= 0;
            lfsr <= 16'hACE1;
        end else begin
            lfsr <= lfsr_next(lfsr);
            m_ready <= (lfsr[2:0] != 3'b000);
            if (checking && m_valid && !m_ready) stall_seen++;
        end
    end

    always @(posedge clk) begin
        if (rst_n && checking) begin
            if (error_flags != 0 || lockstep_error || restart_error)
                $fatal(1, "FAIL FC status flags=%h lock=%b restart=%b",
                       error_flags, lockstep_error, restart_error);
            if (layer_done) done_seen++;
            if (dut.acc_valid && dut.acc_ready) begin
                if (acc_seen >= TILES || dut.acc_lane_valid !== 8'hff ||
                    dut.acc_col !== 0 || !dut.acc_last)
                    $fatal(1, "FAIL FC accumulator metadata beat=%0d lanes=%h col=%0d last=%b",
                           acc_seen, dut.acc_lane_valid, dut.acc_col, dut.acc_last);
                for (int r = 0; r < ROWS; r++) begin
                    if (dut.acc_flat[r*32 +: 32] !==
                        (acc_mem[acc_seen*ROWS+r] ^ ((mutate_acc && acc_seen == 0 && r == 0) ? 32'h1 : 32'h0)))
                        $fatal(1, "FAIL FC accumulator tile=%0d row=%0d got=%08h expected=%08h",
                               acc_seen, r, dut.acc_flat[r*32 +: 32],
                               acc_mem[acc_seen*ROWS+r] ^ ((mutate_acc && acc_seen == 0 && r == 0) ? 32'h1 : 32'h0));
                end
                acc_seen++;
            end
            if (m_valid && m_ready) begin
                if (out_seen >= TILES || m_lane_valid !== 8'hff ||
                    m_col !== 0 || !m_last || m_ovf_flat !== 0)
                    $fatal(1, "FAIL FC output metadata beat=%0d lanes=%h col=%0d last=%b ovf=%h",
                           out_seen, m_lane_valid, m_col, m_last, m_ovf_flat);
                if (m_y_flat !==
                    (y_mem[mutate_index ? ((out_seen+1) % TILES) : out_seen] ^
                     ((mutate_y && out_seen == 0) ? 64'h1 : 64'h0)))
                    $fatal(1, "FAIL FC output tile=%0d got=%016h expected=%016h",
                           out_seen, m_y_flat,
                           y_mem[mutate_index ? ((out_seen+1) % TILES) : out_seen] ^
                           ((mutate_y && out_seen == 0) ? 64'h1 : 64'h0));
                out_seen++;
            end
        end
    end

    task automatic load_vectors_and_weights;
        string path;
        $readmemh("../vectors/fc1_dims.mem", dims_mem);
        if (dims_mem[0] != K || dims_mem[1] != 120 ||
            dims_mem[2] != TILES || dims_mem[3] != FRAME_BEATS)
            $fatal(1, "FAIL FC vector geometry %0d,%0d,%0d,%0d",
                   dims_mem[0], dims_mem[1], dims_mem[2], dims_mem[3]);
        $readmemh("../vectors/fc1_frame.mem", frame_mem);
        $readmemh("../vectors/fc1_y.mem", y_mem);
        $readmemh("../vectors/fc1_acc.mem", acc_mem);
        $readmemh("../vectors/fc1_bias.mem", cfg_bias_q);
        $readmemh("../vectors/fc1_m0.mem", cfg_m0);
        $readmemh("../vectors/fc1_shift.mem", cfg_shift_n);
        $readmemh("../vectors/fc1_relu.mem", cfg_relu);
        for (int r = 0; r < ROWS; r++) begin
            path = $sformatf("../vectors/fc1_wbank%0d.mem", r);
            $readmemh(path, wbank_tmp);
            for (int a = 0; a < TILES*K; a++) begin
                @(negedge clk);
                w_wr_en = 1;
                w_wr_bank = 3'(r);
                w_wr_addr = 13'(a);
                w_wr_data = wbank_tmp[a];
            end
        end
        @(negedge clk);
        w_wr_en = 0;
    endtask

    task automatic feed_frame;
        for (int b = 0; b < FRAME_BEATS; b++) begin
            @(negedge clk);
            s_valid = 1;
            s_data = frame_mem[b];
            s_last = (b == FRAME_BEATS-1);
            @(posedge clk);
            while (!s_ready) @(posedge clk);
        end
        @(negedge clk);
        s_valid = 0;
        s_last = 0;
    endtask

    task automatic run_tile(input int t);
        int guard;
        if (t != 0) begin
            @(negedge clk);
            restart = 1;
            @(negedge clk);
            restart = 0;
        end
        cfg_tile_idx = TILE_W'(t);
        @(negedge clk);
        frame_start = 1;
        @(negedge clk);
        frame_start = 0;
        feed_frame();
        guard = 0;
        while ((out_seen <= t || done_seen <= t || !window_done) && guard < 100000) begin
            @(negedge clk);
            guard++;
        end
        if (guard == 100000 || out_seen != t+1 || acc_seen != t+1 ||
            done_seen != t+1 || tile_count != 1 || !window_done)
            $fatal(1, "FAIL FC tile=%0d out=%0d acc=%0d done=%0d count=%0d window=%b",
                   t, out_seen, acc_seen, done_seen, tile_count, window_done);
    endtask

    initial begin
        mutate_y = $test$plusargs("FC_MUTATE_Y");
        mutate_acc = $test$plusargs("FC_MUTATE_ACC");
        mutate_index = $test$plusargs("FC_MUTATE_INDEX");
        s_valid = 0; s_data = 0; s_last = 0; restart = 0;
        w_wr_en = 0; w_wr_bank = 0; w_wr_addr = 0; w_wr_data = 0;
        frame_start = 0; cfg_active_rows = ROW_W'(8);
        cfg_k_len = K_W'(K); cfg_tile_idx = 0;
        repeat (4) @(negedge clk);
        rst_n = 1;
        load_vectors_and_weights();
        checking = 1;
        for (int t = 0; t < TILES; t++) run_tile(t);
        if (out_seen != TILES || acc_seen != TILES ||
            done_seen != TILES || stall_seen == 0)
            $fatal(1, "FAIL FC totals out=%0d acc=%0d done=%0d stalls=%0d",
                   out_seen, acc_seen, done_seen, stall_seen);
        $display("PASS tb_fc_layer: 120 outputs, 15 K=400 runs, %0d output stalls", stall_seen);
        $finish;
    end

    initial begin
        #50000000;
        $fatal(1, "FAIL tb_fc_layer global timeout");
    end
endmodule
