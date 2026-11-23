`timescale 1ns/1ps
// faz4 lane C system smoke (scratch, not committed).  Drives accel_top only
// through AXI-Lite + the s_* / m_* streams + the weight load port.
//   S1: v3 conv1 (s_*, 2 tiles, pool) -> SWAP -> conv2 (act_buffer, 3 tiles,
//       pool) -> SWAP -> conv3 (act_buffer, 4 tiles, no pool) -> m_*,
//       bit-exact against gen_smoke.py; act_buffer banks also compared.
//   S2: two more STARTs with no COMMIT in between, both full and exact.
//   S3: shadow writes (LAYER_CFG/LAYER_CFG2/TILE_CFG/W_BASE/DP_CFG) mid-pass.
//   S4: overflowing act_buffer pass -> abort (L3 semantics: BUSY falls,
//       DONE + ERROR[7] + STATUS.ABORTED, ERR_DETAIL[9]) -> no SOFT_RESET ->
//       COMMIT + START of a good pass, exact.  (Lane C version expected BUSY
//       held after the error and recovered with SOFT_RESET.)
//   S5: LeNet chain conv1(32x32x3, 5x5, 6 ch padded to 8) -> conv2 (c_in 6,
//       c_phys 8) -> fc1 (400, flatten h,w,c) -> fc2 -> fc3 -> m_*.
//   S6: v3 tail conv4 -> conv5 -> fc1 (288) -> fc2 (64, last_rows 2) -> m_*.
//   S7: faults: (a) stored layer != committed geometry -> START rejected,
//       (b) s_* short frame -> abort ERROR[4]/detail[13], (c) stalled m_ready
//       -> watchdog ERROR[6]/detail[15]; each followed by a good pass with no
//       SOFT_RESET.  WDOG_W is overridden to 13 (8191 idle cycles).
// Stream pacing comes from LFSRs (no seeded $urandom).
module tb_smoke_accel;
    localparam int FRAME_BEATS = 864;   // 48*48*3 bytes / 8
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    logic [11:0] awaddr, araddr;
    logic awvalid, awready, wvalid, wready, bvalid, bready;
    logic [31:0] wdata, rdata;
    logic [3:0] wstrb;
    logic [1:0] bresp, rresp;
    logic arvalid, arready, rvalid, rready;
    logic s_valid, s_ready, s_last;
    logic [63:0] s_data;
    logic w_wr_en;
    logic [2:0] w_wr_bank;
    logic [12:0] w_wr_addr;
    logic [7:0] w_wr_data;
    logic m_valid, m_ready, m_last;
    logic [63:0] m_y_flat;
    logic [7:0] m_lane_valid, m_sat_flat, m_ovf_flat;
    logic [3:0] m_col;
    logic soft_reset;

    logic [63:0] frame_mem [0:FRAME_BEATS-1];
    logic [63:0] l1_y [0:1151];
    logic [63:0] l2_y [0:431];
    logic [63:0] expm [0:1023];   // m_* scoreboard reference
    logic [63:0] etmp [0:4607];
    logic [7:0] wb2 [0:8191];
    logic [31:0] gbias [0:5][0:127];
    logic [17:0] gm0 [0:5][0:127];
    logic [5:0] gshift [0:5][0:127];
    logic grelu [0:5][0:127];
    logic [31:0] tb_bias [0:127];
    logic [17:0] tb_m0 [0:127];
    logic [5:0] tb_shift [0:127];
    logic tb_relu [0:127];
    int feed_n = FRAME_BEATS;
    bit m_stall = 0;
    logic [31:0] bias_t [0:31];
    logic [17:0] m0_t [0:31];
    logic [5:0] shift_t [0:31];
    logic relu_t [0:31];
    logic [31:0] bias_m [0:2][0:31];
    logic [17:0] m0_m [0:2][0:31];
    logic [5:0] shift_m [0:2][0:31];
    logic relu_m [0:2][0:31];
    logic [7:0] wbank [0:2047];

    int errors = 0;
    int exp_base = 0, exp_n = 0, seen = 0, last_seen = 0, bad_beats = 0;
    bit feed_abort = 0;
    logic [15:0] lfsr_s = 16'hACE1, lfsr_m = 16'h1D2B;
    logic [31:0] value;
    string path;

    accel_top #(.WDOG_W(13)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
        .s_axi_bready(bready), .s_axi_araddr(araddr), .s_axi_arvalid(arvalid),
        .s_axi_arready(arready), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data), .s_last(s_last),
        .w_wr_en(w_wr_en), .w_wr_bank(w_wr_bank), .w_wr_addr(w_wr_addr),
        .w_wr_data(w_wr_data), .m_valid(m_valid), .m_ready(m_ready),
        .m_y_flat(m_y_flat), .m_lane_valid(m_lane_valid), .m_col(m_col),
        .m_last(m_last), .m_sat_flat(m_sat_flat), .m_ovf_flat(m_ovf_flat),
        .soft_reset(soft_reset)
    );

    task automatic check(input bit ok, input string why);
        if (!ok) begin $display("SMOKE-FAIL: %s", why); errors++; end
    endtask

    function automatic logic [31:0] layer_cfg(input int c_in, kh, kw, pad, oh, ow);
        return {1'b0, 6'(ow), 6'(oh), 2'(pad), 2'd1, 3'(kw), 3'(kh), 9'(c_in)};
    endfunction

    task automatic axi_write(input logic [11:0] addr, input logic [31:0] data);
        @(negedge clk);
        awaddr = addr; awvalid = 1; wdata = data; wstrb = 4'hF; wvalid = 1; bready = 0;
        do @(posedge clk); while (!(awready && wready));
        @(negedge clk); awvalid = 0; wvalid = 0; bready = 1;
        do @(posedge clk); while (!bvalid);
        @(negedge clk); bready = 0;
    endtask

    task automatic axi_read(input logic [11:0] addr, output logic [31:0] data);
        @(negedge clk); araddr = addr; arvalid = 1; rready = 0;
        do @(posedge clk); while (!arready);
        @(negedge clk); arvalid = 0; rready = 1;
        do @(posedge clk); while (!rvalid);
        data = rdata;
        @(negedge clk); rready = 0;
    endtask

    always @(posedge clk) begin
        lfsr_s <= {lfsr_s[14:0], lfsr_s[15] ^ lfsr_s[13] ^ lfsr_s[12] ^ lfsr_s[10]};
        lfsr_m <= {lfsr_m[14:0], lfsr_m[15] ^ lfsr_m[13] ^ lfsr_m[12] ^ lfsr_m[10]};
    end
    always @(negedge clk) m_ready = rst_n && !m_stall && (lfsr_m[1:0] != 2'b00);

    // m_* scoreboard: the current pass expects l3_y[exp_base +: exp_n].
    always @(posedge clk) if (rst_n && m_valid && m_ready) begin
        if (seen >= exp_n) begin
            bad_beats++;
        end else begin
            if (m_y_flat !== expm[exp_base + seen]) begin
                if (bad_beats < 5)
                    $display("SMOKE-FAIL: m beat %0d = %016h expected %016h",
                             seen, m_y_flat, expm[exp_base + seen]);
                bad_beats++;
            end
            if (m_last !== (seen == exp_n - 1)) bad_beats++;
        end
        if (m_last) last_seen++;
        seen++;
    end

    task automatic feed_frame;
        int b = 0;
        bit hs = 0;
        while (b < feed_n && !feed_abort) begin
            @(negedge clk);
            if (hs) begin s_valid = 0; hs = 0; end
            if (!s_valid && (lfsr_s[1:0] != 2'b00)) begin
                s_valid = 1; s_data = frame_mem[b]; s_last = (b == feed_n-1);
            end
            @(posedge clk);
            if (s_valid && s_ready) begin b++; hs = 1; end
        end
        @(negedge clk); s_valid = 0; s_last = 0;
    endtask

    task automatic load_weights;
        for (int r = 0; r < 8; r++) begin
            path = $sformatf("../vec/wbank%0d.mem", r);
            $readmemh(path, wbank);
            for (int a = 0; a < 2048; a++) begin
                @(negedge clk);
                w_wr_en = 1; w_wr_bank = 3'(r); w_wr_addr = 13'(a); w_wr_data = wbank[a];
            end
        end
        @(negedge clk); w_wr_en = 0;
    endtask

    // Full shadow image of one pass, then COMMIT.
    task automatic configure(input int L, c_in, c_phys, in_hw, w_base, tile, tiles,
                             input bit src, pool, dst);
        axi_write(12'h010, layer_cfg(c_in, 3, 3, 1, in_hw, in_hw));
        axi_write(12'h018, 32'(c_phys));
        axi_write(12'h01C, 32'(w_base));
        axi_write(12'h014, {14'b0, 4'd0, 1'b0, 1'b0, 8'(tiles), 8'(tile)});
        axi_write(12'h020, {29'b0, dst, pool, src});
        for (int r = 0; r < 8; r++) begin
            axi_write(12'(12'h040 + 16*r), bias_m[L][8*tile + r]);
            axi_write(12'(12'h044 + 16*r), {14'b0, m0_m[L][8*tile + r]});
            axi_write(12'(12'h048 + 16*r),
                      {23'b0, relu_m[L][8*tile + r], 2'b0, shift_m[L][8*tile + r]});
        end
        axi_write(12'h0C0, 1);
    endtask

    // Poll STATUS until DONE or ERROR; returns STATUS, DONE cleared (W1C).
    task automatic wait_pass(input int max_polls, output logic [31:0] st);
        int n = 0;
        do begin
            axi_read(12'h008, st);
            n++;
        end while (!st[2] && !st[3] && n < max_polls);
        if (st[2]) axi_write(12'h008, 4);
    endtask

    task automatic expect_m(input int base, n);
        exp_base = base; exp_n = n; seen = 0; last_seen = 0; bad_beats = 0;
    endtask

    task automatic run_pass(input string tag, input bit feed, output logic [31:0] st);
        axi_write(12'h004, 1);
        if (feed) fork feed_frame(); join_none
        wait_pass(400000, st);
        check(st[2] && !st[3], $sformatf("%s: STATUS=%08h (want DONE, no ERROR)", tag, st));
    endtask

    task automatic check_m(input string tag);
        check(seen == exp_n && last_seen == 1 && bad_beats == 0,
              $sformatf("%s: beats=%0d/%0d m_last=%0d bad=%0d", tag, seen, exp_n,
                        last_seen, bad_beats));
    endtask

    // The just-written layer must sit tile-major in the current write bank.
    task automatic check_bank(input string tag, input int n, input int L);
        int bad = 0;
        logic [63:0] got, exp;
        for (int i = 0; i < n; i++) begin
            got = dut.u_act.buf_sel ? dut.u_act.g_buffer[1].mem[i]
                                    : dut.u_act.g_buffer[0].mem[i];
            exp = (L == 0) ? l1_y[i] : l2_y[i];
            if (got !== exp) begin
                if (bad < 3) $display("SMOKE-FAIL: %s word %0d = %016h expected %016h",
                                      tag, i, got, exp);
                bad++;
            end
        end
        check(bad == 0, $sformatf("%s: %0d of %0d stored words differ", tag, bad, n));
    endtask

    // ---- S5/S6/S7 helpers (generic geometry) ----
    task automatic load_weights_pfx(input string pfx);
        for (int r = 0; r < 8; r++) begin
            path = $sformatf("%s_wbank%0d.mem", pfx, r);
            $readmemh(path, wb2);
            for (int a = 0; a < 8192; a++) begin
                @(negedge clk);
                w_wr_en = 1; w_wr_bank = 3'(r); w_wr_addr = 13'(a); w_wr_data = wb2[a];
            end
        end
        @(negedge clk); w_wr_en = 0;
    endtask

    task automatic load_gp(input string pfx, input int L, input string tag);
        $readmemh($sformatf("%s_%s_bias.mem", pfx, tag), tb_bias);
        $readmemh($sformatf("%s_%s_m0.mem", pfx, tag), tb_m0);
        $readmemh($sformatf("%s_%s_shift.mem", pfx, tag), tb_shift);
        $readmemh($sformatf("%s_%s_relu.mem", pfx, tag), tb_relu);
        for (int c = 0; c < 128; c++) begin
            gbias[L][c] = tb_bias[c]; gm0[L][c] = tb_m0[c];
            gshift[L][c] = tb_shift[c]; grelu[L][c] = tb_relu[c];
        end
    endtask

    task automatic cfg2(input int L, c_in, c_phys, kh, kw, pad, oh, ow, w_base, tile, tiles,
                        last_rows, input bit src, pool, dst);
        axi_write(12'h010, {1'b0, 6'(ow), 6'(oh), 2'(pad), 2'd1, 3'(kw), 3'(kh), 9'(c_in)});
        axi_write(12'h018, 32'(c_phys));
        axi_write(12'h01C, 32'(w_base));
        axi_write(12'h014, {10'b0, 4'(last_rows), 2'b0, 8'(tiles), 8'(tile)});
        axi_write(12'h020, {29'b0, dst, pool, src});
        for (int r = 0; r < 8; r++) begin
            axi_write(12'(12'h040 + 16*r), gbias[L][8*tile + r]);
            axi_write(12'(12'h044 + 16*r), {14'b0, gm0[L][8*tile + r]});
            axi_write(12'(12'h048 + 16*r),
                      {23'b0, grelu[L][8*tile + r], 2'b0, gshift[L][8*tile + r]});
        end
        axi_write(12'h0C0, 1);
    endtask

    task automatic check_bank2(input string tag, input int n, input string fname);
        int bad = 0;
        logic [63:0] got;
        $readmemh(fname, etmp);
        for (int i = 0; i < n; i++) begin
            got = dut.u_act.buf_sel ? dut.u_act.g_buffer[1].mem[i]
                                    : dut.u_act.g_buffer[0].mem[i];
            if (got !== etmp[i]) begin
                if (bad < 3) $display("SMOKE-FAIL: %s word %0d = %016h expected %016h",
                                      tag, i, got, etmp[i]);
                bad++;
            end
        end
        check(bad == 0, $sformatf("%s: %0d of %0d stored words differ", tag, bad, n));
    endtask

    // All tiles of one layer.  dst=1: m_* words (wpt per tile) vs expm[t*wpt +:]
    // (loaded by the caller).  An s_* source re-sends the frame per tile.
    task automatic run_layer(input string tag, input int L, c_in, c_phys, kh, kw, pad, oh, ow,
                             w_base, tiles, last_rows, input bit src, pool, dst, input int wpt);
        logic [31:0] stl;
        for (int t = 0; t < tiles; t++) begin
            cfg2(L, c_in, c_phys, kh, kw, pad, oh, ow, w_base, t, tiles, last_rows, src, pool, dst);
            if (dst) expect_m(wpt*t, wpt);
            run_pass($sformatf("%s tile %0d", tag, t), !src, stl);
            if (dst) check_m($sformatf("%s tile %0d", tag, t));
        end
    endtask

    // Poll STATUS until DONE or ERROR, no W1C (the caller inspects it first).
    task automatic poll_stop(input int max_polls, output logic [31:0] stp);
        int n = 0;
        do begin axi_read(12'h008, stp); n++; end
        while (!stp[2] && !stp[3] && n < max_polls);
    endtask

    task automatic clear_all;
        axi_write(12'h00C, 32'hFF);
        axi_write(12'h024, 32'hFFFF);
        axi_write(12'h008, 4);
    endtask

    task automatic check_clean(input string tag);
        logic [31:0] e, d, ss;
        axi_read(12'h00C, e); axi_read(12'h024, d); axi_read(12'h008, ss);
        check(e[7:0] == 0 && d[15:0] == 0 && !ss[1] && !ss[2] && !ss[3] && !ss[5],
              $sformatf("%s: ERROR=%02h ERR_DETAIL=%04h STATUS=%08h (want clean idle)",
                        tag, e[7:0], d[15:0], ss));
    endtask

    // START with a committed geometry the stored layer cannot satisfy.
    task automatic bad_src_start(input string tag);
        logic [31:0] ss, e, d;
        axi_write(12'h004, 1);
        repeat (40) @(negedge clk);
        axi_read(12'h008, ss); axi_read(12'h00C, e); axi_read(12'h024, d);
        check(!ss[1] && !ss[2] && ss[3] && !ss[5] && e[7:0] == 8'h80 && d[15:0] == 16'h1000,
              $sformatf("%s: STATUS=%08h ERROR=%02h ERR_DETAIL=%04h (want idle, no DONE, ERROR 80, detail 1000)",
                        tag, ss, e[7:0], d[15:0]));
        clear_all();
    endtask

    logic [31:0] st;
    int err_s1, err_s2, err_s3, err_s4, err_s5, err_s6, err_s7, e7a, e7b, e7c;
    logic [31:0] st_e, st_d;
    logic [31:0] st4_det;

    initial begin
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0;
        bready = 0; araddr = 0; arvalid = 0; rready = 0;
        s_valid = 0; s_data = 0; s_last = 0;
        w_wr_en = 0; w_wr_bank = 0; w_wr_addr = 0; w_wr_data = 0;
        $readmemh("../vec/l1_frame.mem", frame_mem);
        $readmemh("../vec/l1_y.mem", l1_y);
        $readmemh("../vec/l2_y.mem", l2_y);
        $readmemh("../vec/l3_y.mem", expm);
        for (int L = 0; L < 3; L++) begin
            $readmemh($sformatf("../vec/l%0d_bias.mem", L+1), bias_t);
            $readmemh($sformatf("../vec/l%0d_m0.mem", L+1), m0_t);
            $readmemh($sformatf("../vec/l%0d_shift.mem", L+1), shift_t);
            $readmemh($sformatf("../vec/l%0d_relu.mem", L+1), relu_t);
            for (int c = 0; c < 32; c++) begin
                bias_m[L][c] = bias_t[c]; m0_m[L][c] = m0_t[c];
                shift_m[L][c] = shift_t[c]; relu_m[L][c] = relu_t[c];
            end
        end
        repeat (4) @(negedge clk); rst_n = 1;
        load_weights();

        // ---------------- S1 ----------------
        for (int t = 0; t < 2; t++) begin
            configure(0, 3, 3, 48, 0, t, 2, 1'b0, 1'b1, 1'b0);
            run_pass($sformatf("S1 L1 tile %0d", t), 1'b1, st);
        end
        check_bank("S1 L1 bank", 1152, 0);
        axi_write(12'h004, 8);  // LAYER_SWAP
        for (int t = 0; t < 3; t++) begin
            configure(1, 16, 16, 24, 64, t, 3, 1'b1, 1'b1, 1'b0);
            run_pass($sformatf("S1 L2 tile %0d", t), 1'b0, st);
        end
        check_bank("S1 L2 bank", 432, 1);
        axi_write(12'h004, 8);  // LAYER_SWAP
        for (int t = 0; t < 4; t++) begin
            configure(2, 24, 24, 12, 512, t, 4, 1'b1, 1'b0, 1'b1);
            expect_m(144*t, 144);
            run_pass($sformatf("S1 L3 tile %0d", t), 1'b0, st);
            check_m($sformatf("S1 L3 tile %0d", t));
        end
        axi_read(12'h00C, st);
        check(st[7:0] == 0, $sformatf("S1 ERROR=%02h", st[7:0]));
        err_s1 = errors;
        $display("S1 %s: conv1(2 tiles,pool)->swap->conv2(3 tiles,pool)->swap->conv3(4 tiles)->m_*, 576 words, errors=%0d",
                 (err_s1 == 0) ? "PASS" : "FAIL", err_s1);

        // ---------------- S2 ----------------
        for (int k = 0; k < 2; k++) begin
            expect_m(144*3, 144);
            run_pass($sformatf("S2 START %0d", k), 1'b0, st);
            check_m($sformatf("S2 START %0d", k));
        end
        err_s2 = errors - err_s1;
        $display("S2 %s: two further STARTs, no COMMIT, conv3 tile 3 replayed exact twice, errors=%0d",
                 (err_s2 == 0) ? "PASS" : "FAIL", err_s2);

        // ---------------- S3 ----------------
        configure(2, 24, 24, 12, 512, 1, 4, 1'b1, 1'b0, 1'b1);
        expect_m(144*1, 144);
        axi_write(12'h004, 1);
        wait (seen >= 40);
        axi_write(12'h010, layer_cfg(16, 3, 3, 1, 24, 24));
        axi_write(12'h018, 32'd16);
        axi_write(12'h01C, 32'd64);
        axi_write(12'h014, {14'b0, 4'd0, 1'b0, 1'b0, 8'd3, 8'd2});
        axi_write(12'h020, 32'd3);
        check(seen < 144, "S3 shadow writes landed after the pass");
        wait_pass(400000, st);
        check(st[2] && !st[3], $sformatf("S3: STATUS=%08h", st));
        check_m("S3");
        axi_read(12'h01C, st); check(st == 64, "S3 W_BASE shadow readback");
        err_s3 = errors - err_s1 - err_s2;
        $display("S3 %s: LAYER_CFG/LAYER_CFG2/TILE_CFG/W_BASE/DP_CFG written mid-pass, pass exact, errors=%0d",
                 (err_s3 == 0) ? "PASS" : "FAIL", err_s3);

        // ---------------- S4 ----------------
        // conv1 geometry without pool, 3 tiles, to act_buffer: 3*48*48 > 4608.
        configure(0, 3, 3, 48, 0, 0, 3, 1'b0, 1'b0, 1'b0);
        feed_abort = 0;
        axi_write(12'h004, 1);
        fork feed_frame(); join_none
        repeat (5000) @(negedge clk);
        axi_read(12'h008, st);
        check(!st[1] && st[2] && st[3] && st[5],
              $sformatf("S4 bad pass STATUS=%08h (want DONE+ERROR+ABORTED, not BUSY)", st));
        axi_read(12'h00C, value);
        check(value[7:0] == 8'h80, $sformatf("S4 bad pass ERROR=%02h (want 80)", value[7:0]));
        axi_read(12'h024, st4_det);
        check(st4_det[15:0] == 16'h0200,
              $sformatf("S4 bad pass ERR_DETAIL=%04h (want 0200)", st4_det[15:0]));
        $display("S4 bad pass: STATUS=%08h ERROR=%02h ERR_DETAIL=%04h", st, value[7:0],
                 st4_det[15:0]);
        // The aborted pass closed s_ready; stop the feeder.  No SOFT_RESET.
        feed_abort = 1;
        repeat (5) @(negedge clk);
        feed_abort = 0;
        axi_write(12'h00C, 32'hFF);
        axi_write(12'h024, 32'hFFFF);
        axi_write(12'h008, 4);
        axi_read(12'h008, st);
        check(!st[1] && !st[2] && !st[3] && !st[5],
              $sformatf("S4 after W1C STATUS=%08h (want idle, clean)", st));
        configure(2, 24, 24, 12, 512, 0, 4, 1'b1, 1'b0, 1'b1);
        expect_m(0, 144);
        run_pass("S4 good pass", 1'b0, st);
        check_m("S4 good pass");
        axi_read(12'h00C, value);
        check(value[7:0] == 0, $sformatf("S4 good pass ERROR=%02h", value[7:0]));
        axi_read(12'h024, value);
        check(value[15:0] == 0, $sformatf("S4 good pass ERR_DETAIL=%04h", value[15:0]));
        err_s4 = errors - err_s1 - err_s2 - err_s3;
        $display("S4 %s: overflow pass -> abort (DONE+ERROR[7]+ABORTED, ERR_DETAIL[9]), no SOFT_RESET -> COMMIT+START exact, errors=%0d",
                 (err_s4 == 0) ? "PASS" : "FAIL", err_s4);

        // ---------------- S5 ----------------
        load_weights_pfx("../vec/s5");
        load_gp("../vec/s5", 0, "c1"); load_gp("../vec/s5", 1, "c2");
        load_gp("../vec/s5", 2, "f1"); load_gp("../vec/s5", 3, "f2");
        load_gp("../vec/s5", 4, "f3");
        $readmemh("../vec/s5_frame.mem", frame_mem);
        feed_n = 384;   // 32*32*3 / 8
        run_layer("S5 conv1", 0, 3, 3, 5, 5, 0, 28, 28, 0, 1, 6, 1'b0, 1'b1, 1'b0, 0);
        check_bank2("S5 conv1 bank", 196, "../vec/s5_c1_y.mem");
        axi_write(12'h004, 8);
        run_layer("S5 conv2", 1, 6, 8, 5, 5, 0, 10, 10, 75, 2, 0, 1'b1, 1'b1, 1'b0, 0);
        check_bank2("S5 conv2 bank", 50, "../vec/s5_c2_y.mem");
        axi_write(12'h004, 8);
        run_layer("S5 fc1", 2, 400, 400, 1, 1, 0, 1, 1, 375, 15, 0, 1'b1, 1'b0, 1'b0, 0);
        check_bank2("S5 fc1 bank", 15, "../vec/s5_f1_y.mem");
        axi_write(12'h004, 8);
        run_layer("S5 fc2", 3, 120, 120, 1, 1, 0, 1, 1, 6375, 11, 4, 1'b1, 1'b0, 1'b0, 0);
        check_bank2("S5 fc2 bank", 11, "../vec/s5_f2_y.mem");
        axi_write(12'h004, 8);
        $readmemh("../vec/s5_f3_y.mem", expm);
        run_layer("S5 fc3", 4, 84, 88, 1, 1, 0, 1, 1, 7695, 2, 2, 1'b1, 1'b0, 1'b1, 1);
        axi_read(12'h00C, st); axi_read(12'h024, value);
        check(st[7:0] == 0 && value[15:0] == 0,
              $sformatf("S5 ERROR=%02h ERR_DETAIL=%04h", st[7:0], value[15:0]));
        err_s5 = errors - err_s1 - err_s2 - err_s3 - err_s4;
        $display("S5 %s: LeNet conv1(6ch padded to 8)->pool->conv2(c_in6,c_phys8)->pool->fc1(400,15 tiles)->fc2(11 tiles)->fc3(2 tiles)->m_*, bit-exact, errors=%0d",
                 (err_s5 == 0) ? "PASS" : "FAIL", err_s5);

        // ---------------- S6 ----------------
        load_weights_pfx("../vec/s6");
        load_gp("../vec/s6", 0, "c4"); load_gp("../vec/s6", 1, "c5");
        load_gp("../vec/s6", 2, "f1"); load_gp("../vec/s6", 3, "f2");
        $readmemh("../vec/s6_frame.mem", frame_mem);
        feed_n = 576;   // 12*12*32 / 8
        run_layer("S6 conv4", 0, 32, 32, 3, 3, 1, 12, 12, 0, 4, 0, 1'b0, 1'b1, 1'b0, 0);
        check_bank2("S6 conv4 bank", 144, "../vec/s6_c4_y.mem");
        axi_write(12'h004, 8);
        run_layer("S6 conv5", 1, 32, 32, 3, 3, 1, 6, 6, 1152, 4, 0, 1'b1, 1'b1, 1'b0, 0);
        check_bank2("S6 conv5 bank", 36, "../vec/s6_c5_y.mem");
        axi_write(12'h004, 8);
        run_layer("S6 fc1", 2, 288, 288, 1, 1, 0, 1, 1, 2304, 8, 0, 1'b1, 1'b0, 1'b0, 0);
        check_bank2("S6 fc1 bank", 8, "../vec/s6_f1_y.mem");
        axi_write(12'h004, 8);
        $readmemh("../vec/s6_f2_y.mem", expm);
        run_layer("S6 fc2", 3, 64, 64, 1, 1, 0, 1, 1, 4608, 2, 2, 1'b1, 1'b0, 1'b1, 1);
        axi_read(12'h00C, st); axi_read(12'h024, value);
        check(st[7:0] == 0 && value[15:0] == 0,
              $sformatf("S6 ERROR=%02h ERR_DETAIL=%04h", st[7:0], value[15:0]));
        err_s6 = errors - err_s1 - err_s2 - err_s3 - err_s4 - err_s5;
        $display("S6 %s: v3 tail conv4(4 tiles)->pool->conv5->pool->fc1(288,8 tiles)->fc2(64,2 tiles,last_rows 2)->m_*, bit-exact, errors=%0d",
                 (err_s6 == 0) ? "PASS" : "FAIL", err_s6);

        // ---------------- S7 (S6 weights/params resident) ----------------
        // (b) s_* short frame: s_last on beat 100 of 576 -> abort ERROR[4]/detail[13].
        cfg2(0, 32, 32, 3, 3, 1, 12, 12, 0, 0, 4, 0, 1'b0, 1'b1, 1'b0);
        feed_n = 100; feed_abort = 0;
        axi_write(12'h004, 1);
        fork feed_frame(); join_none
        poll_stop(20000, st);
        axi_read(12'h00C, st_e); axi_read(12'h024, st_d);
        $display("S7b short frame: STATUS=%08h ERROR=%02h ERR_DETAIL=%04h", st, st_e[7:0], st_d[15:0]);
        check(!st[1] && st[2] && st[3] && st[5] && st_e[7:0] == 8'h10 && st_d[15:0] == 16'h2000,
              $sformatf("S7b short frame STATUS=%08h ERROR=%02h ERR_DETAIL=%04h (want DONE+ERROR+ABORTED, 10, 2000)",
                        st, st_e[7:0], st_d[15:0]));
        clear_all();
        check_clean("S7b after W1C");
        feed_n = 576;
        run_pass("S7b good tile 0 (START only)", 1'b1, st);
        for (int t = 1; t < 4; t++) begin
            cfg2(0, 32, 32, 3, 3, 1, 12, 12, 0, t, 4, 0, 1'b0, 1'b1, 1'b0);
            run_pass($sformatf("S7b good tile %0d", t), 1'b1, st);
        end
        check_bank2("S7b conv4 bank", 144, "../vec/s6_c4_y.mem");
        check_clean("S7b after good pass");
        axi_write(12'h004, 8);
        e7b = errors - err_s1 - err_s2 - err_s3 - err_s4 - err_s5 - err_s6;
        $display("S7b %s: s_* short frame -> abort (DONE+ERROR[4]+ABORTED, detail[13]), then conv4 4 tiles exact without SOFT_RESET, errors=%0d",
                 (e7b == 0) ? "PASS" : "FAIL", e7b);

        // (a) stored 6x6x(4 tiles) layer vs committed geometries that want more.
        cfg2(1, 32, 32, 3, 3, 1, 8, 8, 1152, 0, 4, 0, 1'b1, 1'b1, 1'b0);   // 8x8 plane
        bad_src_start("S7a 8x8 vs stored 6x6");
        cfg2(1, 32, 40, 3, 3, 1, 6, 6, 1152, 0, 4, 0, 1'b1, 1'b1, 1'b0);   // 5 tiles vs 4
        bad_src_start("S7a c_phys 40 vs 4 tiles");
        cfg2(2, 288, 288, 1, 1, 0, 1, 1, 2304, 0, 8, 0, 1'b1, 1'b0, 1'b0); // flatten 288 vs 1152
        bad_src_start("S7a fc c_phys 288 vs flatten 1152");
        check_clean("S7a after rejects");
        run_layer("S7a good conv5", 1, 32, 32, 3, 3, 1, 6, 6, 1152, 4, 0, 1'b1, 1'b1, 1'b0, 0);
        check_bank2("S7a conv5 bank", 36, "../vec/s6_c5_y.mem");
        check_clean("S7a after good run");
        e7a = errors - err_s1 - err_s2 - err_s3 - err_s4 - err_s5 - err_s6 - e7b;
        $display("S7a %s: stored 6x6x4 layer vs 8x8 / c_phys 40 / flatten 288 -> START rejected (ERROR[7]+detail[12], idle, no DONE), then conv5 exact, errors=%0d",
                 (e7a == 0) ? "PASS" : "FAIL", e7a);

        // (c) watchdog: conv5 tile 0 from the stored conv4 layer to m_*, m_ready stalled.
        $readmemh("../vec/s6_c5_y.mem", expm);
        cfg2(1, 32, 32, 3, 3, 1, 6, 6, 1152, 0, 4, 0, 1'b1, 1'b1, 1'b1);
        expect_m(0, 9);
        m_stall = 1;
        axi_write(12'h004, 1);
        // The engine still delivers a burst every ~2900 cycles until the pool and
        // register slice back up, so the abort comes ~8191 cycles after that.
        poll_stop(40000, st);
        axi_read(12'h00C, st_e); axi_read(12'h024, st_d);
        $display("S7c watchdog: STATUS=%08h ERROR=%02h ERR_DETAIL=%04h m_beats=%0d", st,
                 st_e[7:0], st_d[15:0], seen);
        check(!st[1] && st[2] && st[3] && st[5] && st_e[7:0] == 8'h40 && st_d[15:0] == 16'h8000 && seen == 0,
              $sformatf("S7c watchdog STATUS=%08h ERROR=%02h ERR_DETAIL=%04h beats=%0d (want DONE+ERROR+ABORTED, 40, 8000, 0)",
                        st, st_e[7:0], st_d[15:0], seen));
        m_stall = 0;
        clear_all();
        check_clean("S7c after W1C");
        expect_m(0, 9);
        run_pass("S7c good pass", 1'b0, st);
        check_m("S7c good pass");
        check_clean("S7c after good pass");
        e7c = errors - err_s1 - err_s2 - err_s3 - err_s4 - err_s5 - err_s6 - e7b - e7a;
        $display("S7c %s: stalled m_ready (WDOG_W=13) -> abort (DONE+ERROR[6]+ABORTED, detail[15]), then the same pass exact without SOFT_RESET, errors=%0d",
                 (e7c == 0) ? "PASS" : "FAIL", e7c);
        err_s7 = e7a + e7b + e7c;
        $display("S7 %s: faults a/b/c, errors=%0d", (err_s7 == 0) ? "PASS" : "FAIL", err_s7);

        axi_read(12'h10C, value);
        $display("SMOKE %s: errors=%0d FRAME_COUNT=%0d act_buffer swaps=%0d",
                 (errors == 0) ? "PASS" : "FAIL", errors, value, dut.u_act.frame_count);
        $finish;
    end
    initial begin #2000000000; $display("SMOKE-FAIL: global timeout"); $finish; end
endmodule
