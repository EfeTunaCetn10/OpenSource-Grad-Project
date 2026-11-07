`timescale 1ns/1ps
// System regression, fault part (adapted from smoke S4, S7a/b/c; the smoke
// itself stays in smoke/).  accel_top driven only through AXI-Lite, s_* / m_*
// and the weight port; WDOG_W is overridden to 13 (8191 idle cycles).  The
// S6 weights/params of model/gen_sys_vectors.py stay resident.  Every abort
// or reject is followed by a good pass that needs no SOFT_RESET.
//   S7b: s_last on beat 100 of 576 -> abort ERROR[4]/detail[13]; recover, then
//        conv4 (4 tiles) from s_*, swapped in as the stored layer.
//   S7d: s_last missing on the last expected beat -> flag ERROR[5]/detail[14],
//        pass completes exact, one extra beat is never accepted.
//   S4 : 48x48 3-tile layer routed to act_buffer overflows -> abort
//        ERROR[7]/detail[9]; COMMIT+START of a good pass is exact.
//   S7a: stored 6x6x4 layer vs committed 8x8 / c_phys 40 / flatten 288 ->
//        START rejected (ERROR[7]/detail[12], idle, no DONE).
//   S7c: m_ready held low -> watchdog abort ERROR[6]/detail[15].
//   T_RST_001 (soft reset / hard reset / abort recovery):
//        R1 SOFT_RESET in the middle of an act_buffer->m_* pass,
//        R2 SOFT_RESET in the middle of an s_* frame,
//        R3 rst_n low in the middle of an s_* -> m_* pass (the register image
//           is gone, START is refused until a COMMIT; weights survive),
//        plus S7b/S4/S7c/S7d above (abort and flag recovery).
// Pacing comes from LFSRs (no seeded $urandom).
module tb_sys_faults;
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

    logic [63:0] frame_mem [0:863];
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
    int feed_n = 576;
    bit m_stall = 0;
    bit feed_abort = 0, feed_nolast = 0, feed_extra = 0;
    int s_cnt = 0;

    int errors = 0;
    int exp_base = 0, exp_n = 0, seen = 0, last_seen = 0, bad_beats = 0;
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
        if (!ok) begin $display("SYS-FAIL: %s", why); errors++; end
    endtask

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

    // m_* scoreboard: the current pass expects expm[exp_base +: exp_n].
    always @(posedge clk) if (rst_n && m_valid && m_ready) begin
        if (seen >= exp_n) begin
            bad_beats++;
        end else begin
            if (m_y_flat !== expm[exp_base + seen]) begin
                if (bad_beats < 5)
                    $display("SYS-FAIL: m beat %0d = %016h expected %016h",
                             seen, m_y_flat, expm[exp_base + seen]);
                bad_beats++;
            end
            if (m_last !== (seen == exp_n - 1)) bad_beats++;
        end
        if (m_last) last_seen++;
        seen++;
    end
    always @(posedge clk) if (s_valid && s_ready) s_cnt++;

    // s_* feeder.  feed_nolast: s_last is never asserted.  feed_extra: after
    // the frame, one more beat (with s_last) is held valid until the caller
    // clears feed_extra.  feed_abort ends the frame early.
    task automatic feed_frame;
        int b = 0;
        bit hs = 0;
        while (b < feed_n && !feed_abort) begin
            @(negedge clk);
            if (hs) begin s_valid = 0; hs = 0; end
            if (!s_valid && (lfsr_s[1:0] != 2'b00)) begin
                s_valid = 1; s_data = frame_mem[b];
                s_last = !feed_nolast && (b == feed_n-1);
            end
            @(posedge clk);
            if (s_valid && s_ready) begin b++; hs = 1; end
        end
        @(negedge clk); s_valid = 0; s_last = 0;
        if (feed_extra && !feed_abort) begin
            s_valid = 1; s_data = frame_mem[0]; s_last = 1;
            while (feed_extra) @(negedge clk);
            s_valid = 0; s_last = 0;
        end
    endtask

    // Bounded waits on the beat counters (a missing pass must not hang the test).
    task automatic wait_seen(input int n);
        int c = 0;
        while (seen < n && c < 400000) begin @(negedge clk); c++; end
        check(seen >= n, $sformatf("timeout waiting for %0d m_* beats (seen %0d)", n, seen));
    endtask

    task automatic wait_scnt(input int n);
        int c = 0;
        while (s_cnt < n && c < 400000) begin @(negedge clk); c++; end
        check(s_cnt >= n, $sformatf("timeout waiting for %0d s_* beats (taken %0d)", n, s_cnt));
    endtask

    task automatic stop_feed;
        feed_abort = 1;
        repeat (4) @(negedge clk);
        feed_abort = 0;
    endtask

    task automatic load_weights_pfx(input string pfx, input int n);
        for (int r = 0; r < 8; r++) begin
            path = $sformatf("%s_wbank%0d.mem", pfx, r);
            $readmemh(path, wb2);
            for (int a = 0; a < n; a++) begin
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

    // Full shadow image of one pass, then COMMIT.
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

    // Poll STATUS until DONE or ERROR; returns STATUS, DONE cleared (W1C).
    task automatic wait_pass(input int max_polls, output logic [31:0] st);
        int n = 0;
        do begin
            axi_read(12'h008, st);
            n++;
        end while (!st[2] && !st[3] && n < max_polls);
        if (st[2]) axi_write(12'h008, 4);
    endtask

    // Poll STATUS until DONE or ERROR, no W1C (the caller inspects it first).
    task automatic poll_stop(input int max_polls, output logic [31:0] stp);
        int n = 0;
        do begin axi_read(12'h008, stp); n++; end
        while (!stp[2] && !stp[3] && n < max_polls);
    endtask

    // Poll STATUS until DONE only (a flag-only error does not stop the pass).
    task automatic poll_done(input int max_polls, output logic [31:0] stp);
        int n = 0;
        do begin axi_read(12'h008, stp); n++; end
        while (!stp[2] && n < max_polls);
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
    task automatic check_bank2(input string tag, input int n, input string fname);
        int bad = 0;
        logic [63:0] got;
        $readmemh(fname, etmp);
        for (int i = 0; i < n; i++) begin
            got = dut.u_act.buf_sel ? dut.u_act.g_buffer[1].mem[i]
                                    : dut.u_act.g_buffer[0].mem[i];
            if (got !== etmp[i]) begin
                if (bad < 3) $display("SYS-FAIL: %s word %0d = %016h expected %016h",
                                      tag, i, got, etmp[i]);
                bad++;
            end
        end
        check(bad == 0, $sformatf("%s: %0d of %0d stored words differ", tag, bad, n));
    endtask

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

    // After a reset the pass state is gone: idle, nothing pending, no stray beat.
    task automatic check_reset_idle(input string tag, input int beats_before);
        logic [31:0] ss, e, d, fc;
        repeat (3000) @(negedge clk);
        axi_read(12'h008, ss); axi_read(12'h00C, e); axi_read(12'h024, d);
        axi_read(12'h10C, fc);
        check(ss[0] && !ss[1] && !ss[2] && !ss[3] && !ss[5] && e[7:0] == 0 && d[15:0] == 0,
              $sformatf("%s: STATUS=%08h ERROR=%02h ERR_DETAIL=%04h (want idle, clean)",
                        tag, ss, e[7:0], d[15:0]));
        check(seen == beats_before, $sformatf("%s: m_* beats kept coming after reset (%0d -> %0d)",
                                              tag, beats_before, seen));
        check(fc == 0, $sformatf("%s: FRAME_COUNT=%0d after reset (want 0)", tag, fc));
    endtask

    logic [31:0] st, st_e, st_d;
    int mark, e7b, e7d, e4, e7a, e7c, er1, er2, er3, beats_b4;

    initial begin
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0;
        bready = 0; araddr = 0; arvalid = 0; rready = 0;
        s_valid = 0; s_data = 0; s_last = 0;
        w_wr_en = 0; w_wr_bank = 0; w_wr_addr = 0; w_wr_data = 0;
        repeat (4) @(negedge clk); rst_n = 1;
        load_weights_pfx("../vectors/sys_s6", 8192);
        load_gp("../vectors/sys_s6", 0, "c4"); load_gp("../vectors/sys_s6", 1, "c5");
        load_gp("../vectors/sys_s6", 2, "f1"); load_gp("../vectors/sys_s6", 3, "f2");
        $readmemh("../vectors/sys_s6_frame.mem", frame_mem);

        // ---------------- S7b ----------------
        mark = errors;
        cfg2(0, 32, 32, 3, 3, 1, 12, 12, 0, 0, 4, 0, 1'b0, 1'b1, 1'b0);
        feed_n = 100;
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
        check_bank2("S7b conv4 bank", 144, "../vectors/sys_s6_c4_y.mem");
        check_clean("S7b after good pass");
        axi_write(12'h004, 8);   // swap: conv4 is the stored layer from here on
        e7b = errors - mark;
        $display("%s S7b: s_* short frame -> abort (DONE+ERROR[4]+ABORTED, detail[13]), then conv4 4 tiles exact without SOFT_RESET, errors=%0d",
                 (e7b == 0) ? "ok" : "FAIL", e7b);

        // ---------------- S4: act_buffer overflow abort ----------------
        mark = errors;
        $readmemh("../vectors/sys_s1_frame.mem", frame_mem);   // 48*48*3 / 8 = 864 beats
        cfg2(0, 3, 3, 3, 3, 1, 48, 48, 0, 0, 3, 0, 1'b0, 1'b0, 1'b0);   // 3 tiles * 2304 > 4608
        feed_n = 864;
        axi_write(12'h004, 1);
        fork feed_frame(); join_none
        poll_stop(20000, st);
        axi_read(12'h00C, value); axi_read(12'h024, st_d);
        $display("S4 bad pass: STATUS=%08h ERROR=%02h ERR_DETAIL=%04h", st, value[7:0], st_d[15:0]);
        check(!st[1] && st[2] && st[3] && st[5],
              $sformatf("S4 bad pass STATUS=%08h (want DONE+ERROR+ABORTED, not BUSY)", st));
        check(value[7:0] == 8'h80, $sformatf("S4 bad pass ERROR=%02h (want 80)", value[7:0]));
        check(st_d[15:0] == 16'h0200, $sformatf("S4 bad pass ERR_DETAIL=%04h (want 0200)", st_d[15:0]));
        stop_feed();
        clear_all();
        check_clean("S4 after W1C");
        $readmemh("../vectors/sys_s6_frame.mem", frame_mem);
        $readmemh("../vectors/sys_s6_c5_y.mem", expm);
        cfg2(1, 32, 32, 3, 3, 1, 6, 6, 1152, 0, 4, 0, 1'b1, 1'b1, 1'b1);   // COMMIT+START, stored conv4
        expect_m(0, 9);
        run_pass("S4 good pass (stored layer survived the abort)", 1'b0, st);
        check_m("S4 good pass");
        check_clean("S4 after good pass");
        e4 = errors - mark;
        $display("%s S4: act_buffer overflow -> abort (DONE+ERROR[7]+ABORTED, detail[9]), no SOFT_RESET -> COMMIT+START exact from the stored layer, errors=%0d",
                 (e4 == 0) ? "ok" : "FAIL", e4);

        // ---------------- S7d: TLAST late ----------------
        mark = errors;
        cfg2(0, 32, 32, 3, 3, 1, 12, 12, 0, 0, 4, 0, 1'b0, 1'b1, 1'b0);
        feed_n = 576; feed_nolast = 1; feed_extra = 1; s_cnt = 0;
        axi_write(12'h004, 1);
        fork feed_frame(); join_none
        poll_done(400000, st);
        check(st[2] && !st[1] && !st[5], $sformatf("S7d STATUS=%08h (want DONE, not ABORTED)", st));
        axi_read(12'h00C, st_e); axi_read(12'h024, st_d);
        $display("S7d late TLAST: STATUS=%08h ERROR=%02h ERR_DETAIL=%04h s_beats=%0d", st,
                 st_e[7:0], st_d[15:0], s_cnt);
        check(st_e[7:0] == 8'h20 && st_d[15:0] == 16'h4000,
              $sformatf("S7d ERROR=%02h ERR_DETAIL=%04h (want 20, 4000)", st_e[7:0], st_d[15:0]));
        repeat (50) @(negedge clk);
        check(s_cnt == 576, $sformatf("S7d s_* beats taken=%0d (want 576, the extra beat refused)", s_cnt));
        feed_extra = 0; feed_nolast = 0;
        repeat (4) @(negedge clk);
        check_bank2("S7d conv4 tile 0 plane", 36, "../vectors/sys_s6_c4_y.mem");
        clear_all();
        check_clean("S7d after W1C");
        e7d = errors - mark;
        $display("%s S7d: last beat without s_last -> flag only (ERROR[5], detail[14]), pass exact, extra beat refused, errors=%0d",
                 (e7d == 0) ? "ok" : "FAIL", e7d);

        // ---------------- T_RST_001 R2: SOFT_RESET inside an s_* frame ----------------
        mark = errors;
        cfg2(0, 32, 32, 3, 3, 1, 12, 12, 0, 0, 4, 0, 1'b0, 1'b1, 1'b0);
        feed_n = 576; s_cnt = 0;
        axi_write(12'h004, 1);
        fork feed_frame(); join_none
        wait_scnt(200);
        axi_write(12'h004, 2);   // CONTROL.SOFT_RESET
        stop_feed();
        check_reset_idle("R2 soft reset in s_* frame", seen);
        s_cnt = 0;
        run_pass("R2 good pass (START only)", 1'b1, st);
        check(s_cnt == 576, $sformatf("R2 s_* beats taken=%0d (want 576)", s_cnt));
        check_bank2("R2 conv4 tile 0 plane", 36, "../vectors/sys_s6_c4_y.mem");
        check_clean("R2 after good pass");
        er2 = errors - mark;
        $display("%s R2: SOFT_RESET at s_* beat 200 of 576 -> idle, no DONE/ERROR, then START alone exact, errors=%0d",
                 (er2 == 0) ? "ok" : "FAIL", er2);

        // Finish the conv4 layer (tile 0 came from R2) so the write layer is
        // complete, compare it and swap it in as the stored layer again.
        feed_n = 576;
        for (int t = 1; t < 4; t++) begin
            cfg2(0, 32, 32, 3, 3, 1, 12, 12, 0, t, 4, 0, 1'b0, 1'b1, 1'b0);
            run_pass($sformatf("R2 conv4 tile %0d", t), 1'b1, st);
        end
        check_bank2("R2 conv4 bank", 144, "../vectors/sys_s6_c4_y.mem");
        axi_write(12'h004, 8);

        // ---------------- T_RST_001 R1: SOFT_RESET inside an act_buffer -> m_* pass ----------------
        mark = errors;
        cfg2(1, 32, 32, 3, 3, 1, 6, 6, 1152, 0, 4, 0, 1'b1, 1'b1, 1'b1);   // conv5 tile 0 -> m_*
        expect_m(0, 9);
        axi_write(12'h004, 1);
        wait_seen(3);
        axi_write(12'h004, 2);   // CONTROL.SOFT_RESET
        repeat (10) @(negedge clk);
        beats_b4 = seen;
        check_reset_idle("R1 soft reset in act_buffer pass", beats_b4);
        expect_m(0, 9);
        run_pass("R1 good pass (START only)", 1'b0, st);
        check_m("R1 good pass");
        check_clean("R1 after good pass");
        axi_read(12'h10C, value);
        check(value == 1, $sformatf("R1 FRAME_COUNT=%0d (want 1)", value));
        er1 = errors - mark;
        $display("%s R1: SOFT_RESET after 3 of 9 m_* beats -> idle, no DONE/ERROR, counters cleared, START alone exact from the stored layer, errors=%0d",
                 (er1 == 0) ? "ok" : "FAIL", er1);

        // ---------------- S7a ----------------
        mark = errors;
        cfg2(1, 32, 32, 3, 3, 1, 8, 8, 1152, 0, 4, 0, 1'b1, 1'b1, 1'b0);   // 8x8 plane
        bad_src_start("S7a 8x8 vs stored 6x6");
        cfg2(1, 32, 40, 3, 3, 1, 6, 6, 1152, 0, 4, 0, 1'b1, 1'b1, 1'b0);   // 5 tiles vs 4
        bad_src_start("S7a c_phys 40 vs 4 tiles");
        cfg2(2, 288, 288, 1, 1, 0, 1, 1, 2304, 0, 8, 0, 1'b1, 1'b0, 1'b0); // flatten 288 vs 1152
        bad_src_start("S7a fc c_phys 288 vs flatten 1152");
        check_clean("S7a after rejects");
        run_layer("S7a good conv5", 1, 32, 32, 3, 3, 1, 6, 6, 1152, 4, 0, 1'b1, 1'b1, 1'b0, 0);
        check_bank2("S7a conv5 bank", 36, "../vectors/sys_s6_c5_y.mem");
        check_clean("S7a after good run");
        e7a = errors - mark;
        $display("%s S7a: stored 6x6x4 layer vs 8x8 / c_phys 40 / flatten 288 -> START rejected (ERROR[7]+detail[12], idle, no DONE), then conv5 exact, errors=%0d",
                 (e7a == 0) ? "ok" : "FAIL", e7a);

        // ---------------- S7c ----------------
        mark = errors;
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
        e7c = errors - mark;
        $display("%s S7c: stalled m_ready (WDOG_W=13) -> abort (DONE+ERROR[6]+ABORTED, detail[15]), then the same pass exact without SOFT_RESET, errors=%0d",
                 (e7c == 0) ? "ok" : "FAIL", e7c);

        // ---------------- T_RST_001 R3: rst_n low inside an s_* -> m_* pass ----------------
        mark = errors;
        $readmemh("../vectors/sys_s6_c4_y.mem", expm);
        cfg2(0, 32, 32, 3, 3, 1, 12, 12, 0, 0, 4, 0, 1'b0, 1'b1, 1'b1);   // tile 0 -> 36 m_* words
        expect_m(0, 36);
        feed_n = 576; s_cnt = 0;
        axi_write(12'h004, 1);
        fork feed_frame(); join_none
        wait_seen(10);
        @(negedge clk); rst_n = 0;
        stop_feed();
        repeat (3) @(negedge clk);
        rst_n = 1;
        beats_b4 = seen;
        check_reset_idle("R3 hard reset in s_*->m_* pass", beats_b4);
        // Register image is gone: START without COMMIT does nothing.
        axi_read(12'h0C4, value);
        check(!value[24], $sformatf("R3 PARAM_STATUS=%08h: committed bit survived reset", value));
        axi_write(12'h004, 1);
        repeat (40) @(negedge clk);
        axi_read(12'h008, st); axi_read(12'h00C, st_e);
        check(st[0] && !st[1] && !st[2] && st_e[7:0] == 8'h80,
              $sformatf("R3 START without COMMIT: STATUS=%08h ERROR=%02h (want idle, no DONE, ERROR 80)",
                        st, st_e[7:0]));
        clear_all();
        // Weights (BRAM) survive: COMMIT + START, no reload.
        cfg2(0, 32, 32, 3, 3, 1, 12, 12, 0, 0, 4, 0, 1'b0, 1'b1, 1'b1);
        expect_m(0, 36);
        run_pass("R3 good pass after hard reset", 1'b1, st);
        check_m("R3 good pass");
        check_clean("R3 after good pass");
        axi_read(12'h10C, value);
        check(value == 1, $sformatf("R3 FRAME_COUNT=%0d (want 1)", value));
        er3 = errors - mark;
        $display("%s R3: rst_n low after 10 of 36 m_* beats -> idle, registers cleared, START refused until COMMIT, weights kept, next pass exact, errors=%0d",
                 (er3 == 0) ? "ok" : "FAIL", er3);

        if (er1 + er2 + er3 + e7b + e7d + e4 + e7c == 0)
            $display("PASS T_RST_001: SOFT_RESET mid act_buffer pass and mid s_* frame, rst_n mid pass (registers cleared, weights kept), abort/flag recovery without SOFT_RESET (S7b, S7d, S4, S7c)");
        if (errors == 0)
            $display("PASS tb_sys_faults: S7b S7d S4 S7a S7c R1 R2 R3");
        else
            $display("SYS-FAIL: tb_sys_faults errors=%0d", errors);
        $finish;
    end
    initial begin #2000000000; $display("SYS-FAIL: tb_sys_faults global timeout"); $finish; end
endmodule
