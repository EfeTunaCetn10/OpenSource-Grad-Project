`timescale 1ns/1ps
// System regression, chain part (adapted from smoke S1-S3, S5, S6; the smoke
// itself stays in smoke/).  Drives accel_top only through AXI-Lite, the s_* /
// m_* streams and the weight load port, against the pure-Python chain in
// model/gen_sys_vectors.py (vectors sim/vectors/sys_*.mem).
//   S1: v3 conv1 (s_*, 2 tiles, pool) -> SWAP -> conv2 (act_buffer, 3 tiles,
//       pool) -> SWAP -> conv3 (act_buffer, 4 tiles, no pool) -> m_*;
//       the stored banks are compared word by word.
//   S2: two more STARTs with no COMMIT in between, both full and exact.
//   S3: shadow writes (LAYER_CFG/TILE_CFG/W_BASE/DP_CFG) mid-pass.
//   S5: LeNet chain conv1(32x32x3, 5x5, 6 ch padded to 8) -> conv2 (c_in 6,
//       c_phys 8) -> fc1 (400, flatten h,w,c) -> fc2 -> fc3 -> m_*.
//   S6: v3 tail conv4 -> conv5 -> fc1 (288) -> fc2 (64, last_rows 2) -> m_*.
// Contract IDs covered here (each has its own PASS line):
//   T_NUM_CONV_001      every conv/fc pass bit-exact against the golden chain
//   T_MEM_PINGPONG_001  buf_sel moves only on an accepted LAYER_SWAP, an early
//                       swap (layer incomplete) is refused, and the read bank
//                       keeps the previous layer while the next one is written
// s_* / m_* pacing comes from LFSRs (no seeded $urandom).
module tb_sys_chain;
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
    int feed_n = 864;

    int errors = 0;
    int exp_base = 0, exp_n = 0, seen = 0, last_seen = 0, bad_beats = 0;
    logic [15:0] lfsr_s = 16'hACE1, lfsr_m = 16'h1D2B;
    logic [31:0] value;
    string path;

    accel_top dut (
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
    always @(negedge clk) m_ready = rst_n && (lfsr_m[1:0] != 2'b00);

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

    // T_MEM_PINGPONG_001 monitor: the bank select may only move in the cycle
    // after act_buffer accepted a layer_swap.
    logic sel_q = 0, swap_ok_q = 0;
    int pp_toggles = 0, pp_bad = 0;
    always @(posedge clk) begin
        sel_q <= dut.u_act.buf_sel;
        swap_ok_q <= dut.u_act.swap_ok;
        if (rst_n && dut.u_act.buf_sel !== sel_q) begin
            pp_toggles++;
            if (!swap_ok_q) pp_bad++;
        end
    end

    task automatic feed_frame;
        int b = 0;
        bit hs = 0;
        while (b < feed_n) begin
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

    // The just-written layer sits tile-major in the write bank (rd=0) or the
    // previous layer in the read bank (rd=1).
    task automatic check_bank2(input string tag, input int n, input string fname,
                               input bit rd);
        int bad = 0;
        logic [63:0] got;
        $readmemh(fname, etmp);
        for (int i = 0; i < n; i++) begin
            got = (dut.u_act.buf_sel ^ rd) ? dut.u_act.g_buffer[1].mem[i]
                                           : dut.u_act.g_buffer[0].mem[i];
            if (got !== etmp[i]) begin
                if (bad < 3) $display("SYS-FAIL: %s word %0d = %016h expected %016h",
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

    task automatic swap_layer;
        axi_write(12'h004, 8);   // LAYER_SWAP
    endtask

    task automatic expect_sel(input string tag, input bit sel);
        check(dut.u_act.buf_sel === sel, $sformatf("%s: buf_sel=%0b want %0b", tag,
                                                    dut.u_act.buf_sel, sel));
    endtask

    task automatic check_clean(input string tag);
        logic [31:0] e, d, ss;
        axi_read(12'h00C, e); axi_read(12'h024, d); axi_read(12'h008, ss);
        check(e[7:0] == 0 && d[15:0] == 0 && !ss[1] && !ss[2] && !ss[3] && !ss[5],
              $sformatf("%s: ERROR=%02h ERR_DETAIL=%04h STATUS=%08h (want clean idle)",
                        tag, e[7:0], d[15:0], ss));
    endtask

    logic [31:0] st, st_e, st_d;
    int e1, e2, e3, e5, e6, e_pp;

    initial begin
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0;
        bready = 0; araddr = 0; arvalid = 0; rready = 0;
        s_valid = 0; s_data = 0; s_last = 0;
        w_wr_en = 0; w_wr_bank = 0; w_wr_addr = 0; w_wr_data = 0;
        repeat (4) @(negedge clk); rst_n = 1;

        // ---------------- S1 ----------------
        load_weights_pfx("../vectors/sys_s1", 2048);
        load_gp("../vectors/sys_s1", 0, "l1"); load_gp("../vectors/sys_s1", 1, "l2");
        load_gp("../vectors/sys_s1", 2, "l3");
        $readmemh("../vectors/sys_s1_frame.mem", frame_mem);
        $readmemh("../vectors/sys_s1_l3_y.mem", expm);
        feed_n = 864;   // 48*48*3 / 8
        expect_sel("S1 start", 1'b0);
        for (int t = 0; t < 2; t++) begin
            cfg2(0, 3, 3, 3, 3, 1, 48, 48, 0, t, 2, 0, 1'b0, 1'b1, 1'b0);
            run_pass($sformatf("S1 L1 tile %0d", t), 1'b1, st);
        end
        expect_sel("S1 L1 written (no swap yet)", 1'b0);
        check_bank2("S1 L1 bank", 1152, "../vectors/sys_s1_l1_y.mem", 1'b0);
        swap_layer();
        expect_sel("S1 after swap 1", 1'b1);
        for (int t = 0; t < 3; t++) begin
            cfg2(1, 16, 16, 3, 3, 1, 24, 24, 64, t, 3, 0, 1'b1, 1'b1, 1'b0);
            run_pass($sformatf("S1 L2 tile %0d", t), 1'b0, st);
            if (t == 0) begin
                // T_MEM_PINGPONG_001: 1 of 3 tiles written -> a swap is refused,
                // the banks stay put and ERR_DETAIL[8] (act_buffer seq) flags it.
                swap_layer();
                repeat (10) @(negedge clk);
                expect_sel("S1 early swap refused", 1'b1);
                axi_read(12'h024, st_d); axi_read(12'h00C, st_e);
                check(st_d[8] && st_e[7],
                      $sformatf("S1 early swap: ERROR=%02h ERR_DETAIL=%04h (want [7], [8])",
                                st_e[7:0], st_d[15:0]));
                axi_write(12'h00C, 32'hFF); axi_write(12'h024, 32'hFFFF);
            end
        end
        check_bank2("S1 L2 bank", 432, "../vectors/sys_s1_l2_y.mem", 1'b0);
        // The read bank still holds layer 1 after three tiles of layer 2 were written.
        check_bank2("S1 L1 intact in read bank", 1152, "../vectors/sys_s1_l1_y.mem", 1'b1);
        swap_layer();
        expect_sel("S1 after swap 2", 1'b0);
        for (int t = 0; t < 4; t++) begin
            cfg2(2, 24, 24, 3, 3, 1, 12, 12, 512, t, 4, 0, 1'b1, 1'b0, 1'b1);
            expect_m(144*t, 144);
            run_pass($sformatf("S1 L3 tile %0d", t), 1'b0, st);
            check_m($sformatf("S1 L3 tile %0d", t));
        end
        check_bank2("S1 L2 intact in read bank", 432, "../vectors/sys_s1_l2_y.mem", 1'b1);
        axi_read(12'h00C, st);
        check(st[7:0] == 0, $sformatf("S1 ERROR=%02h", st[7:0]));
        e1 = errors;
        $display("%s S1: conv1(2 tiles,pool)->swap->conv2(3 tiles,pool)->swap->conv3(4 tiles)->m_*, 576 words, errors=%0d",
                 (e1 == 0) ? "ok" : "FAIL", e1);

        // ---------------- S2 ----------------
        for (int k = 0; k < 2; k++) begin
            expect_m(144*3, 144);
            run_pass($sformatf("S2 START %0d", k), 1'b0, st);
            check_m($sformatf("S2 START %0d", k));
        end
        e2 = errors - e1;
        $display("%s S2: two further STARTs, no COMMIT, conv3 tile 3 replayed exact twice, errors=%0d",
                 (e2 == 0) ? "ok" : "FAIL", e2);

        // ---------------- S3 ----------------
        cfg2(2, 24, 24, 3, 3, 1, 12, 12, 512, 1, 4, 0, 1'b1, 1'b0, 1'b1);
        expect_m(144*1, 144);
        axi_write(12'h004, 1);
        wait (seen >= 40);
        axi_write(12'h010, {1'b0, 6'd24, 6'd24, 2'd1, 2'd1, 3'd3, 3'd3, 9'd16});
        axi_write(12'h018, 32'd16);
        axi_write(12'h01C, 32'd64);
        axi_write(12'h014, {10'b0, 4'd0, 2'b0, 8'd3, 8'd2});
        axi_write(12'h020, 32'd3);
        check(seen < 144, "S3 shadow writes landed after the pass");
        wait_pass(400000, st);
        check(st[2] && !st[3], $sformatf("S3: STATUS=%08h", st));
        check_m("S3");
        axi_read(12'h01C, st); check(st == 64, "S3 W_BASE shadow readback");
        e3 = errors - e1 - e2;
        $display("%s S3: LAYER_CFG/TILE_CFG/W_BASE/DP_CFG written mid-pass, pass exact, errors=%0d",
                 (e3 == 0) ? "ok" : "FAIL", e3);

        // ---------------- S5 ----------------
        load_weights_pfx("../vectors/sys_s5", 8192);
        load_gp("../vectors/sys_s5", 0, "c1"); load_gp("../vectors/sys_s5", 1, "c2");
        load_gp("../vectors/sys_s5", 2, "f1"); load_gp("../vectors/sys_s5", 3, "f2");
        load_gp("../vectors/sys_s5", 4, "f3");
        $readmemh("../vectors/sys_s5_frame.mem", frame_mem);
        feed_n = 384;   // 32*32*3 / 8
        run_layer("S5 conv1", 0, 3, 3, 5, 5, 0, 28, 28, 0, 1, 6, 1'b0, 1'b1, 1'b0, 0);
        check_bank2("S5 conv1 bank", 196, "../vectors/sys_s5_c1_y.mem", 1'b0);
        swap_layer();
        run_layer("S5 conv2", 1, 6, 8, 5, 5, 0, 10, 10, 75, 2, 0, 1'b1, 1'b1, 1'b0, 0);
        check_bank2("S5 conv2 bank", 50, "../vectors/sys_s5_c2_y.mem", 1'b0);
        check_bank2("S5 conv1 intact in read bank", 196, "../vectors/sys_s5_c1_y.mem", 1'b1);
        swap_layer();
        run_layer("S5 fc1", 2, 400, 400, 1, 1, 0, 1, 1, 375, 15, 0, 1'b1, 1'b0, 1'b0, 0);
        check_bank2("S5 fc1 bank", 15, "../vectors/sys_s5_f1_y.mem", 1'b0);
        swap_layer();
        run_layer("S5 fc2", 3, 120, 120, 1, 1, 0, 1, 1, 6375, 11, 4, 1'b1, 1'b0, 1'b0, 0);
        check_bank2("S5 fc2 bank", 11, "../vectors/sys_s5_f2_y.mem", 1'b0);
        swap_layer();
        $readmemh("../vectors/sys_s5_f3_y.mem", expm);
        run_layer("S5 fc3", 4, 84, 88, 1, 1, 0, 1, 1, 7695, 2, 2, 1'b1, 1'b0, 1'b1, 1);
        axi_read(12'h00C, st); axi_read(12'h024, value);
        check(st[7:0] == 0 && value[15:0] == 0,
              $sformatf("S5 ERROR=%02h ERR_DETAIL=%04h", st[7:0], value[15:0]));
        e5 = errors - e1 - e2 - e3;
        $display("%s S5: LeNet conv1(6ch padded to 8)->pool->conv2(c_in6,c_phys8)->pool->fc1(400,15 tiles)->fc2(11 tiles)->fc3(2 tiles)->m_*, bit-exact, errors=%0d",
                 (e5 == 0) ? "ok" : "FAIL", e5);

        // ---------------- S6 ----------------
        load_weights_pfx("../vectors/sys_s6", 8192);
        load_gp("../vectors/sys_s6", 0, "c4"); load_gp("../vectors/sys_s6", 1, "c5");
        load_gp("../vectors/sys_s6", 2, "f1"); load_gp("../vectors/sys_s6", 3, "f2");
        $readmemh("../vectors/sys_s6_frame.mem", frame_mem);
        feed_n = 576;   // 12*12*32 / 8
        run_layer("S6 conv4", 0, 32, 32, 3, 3, 1, 12, 12, 0, 4, 0, 1'b0, 1'b1, 1'b0, 0);
        check_bank2("S6 conv4 bank", 144, "../vectors/sys_s6_c4_y.mem", 1'b0);
        swap_layer();
        run_layer("S6 conv5", 1, 32, 32, 3, 3, 1, 6, 6, 1152, 4, 0, 1'b1, 1'b1, 1'b0, 0);
        check_bank2("S6 conv5 bank", 36, "../vectors/sys_s6_c5_y.mem", 1'b0);
        check_bank2("S6 conv4 intact in read bank", 144, "../vectors/sys_s6_c4_y.mem", 1'b1);
        swap_layer();
        run_layer("S6 fc1", 2, 288, 288, 1, 1, 0, 1, 1, 2304, 8, 0, 1'b1, 1'b0, 1'b0, 0);
        check_bank2("S6 fc1 bank", 8, "../vectors/sys_s6_f1_y.mem", 1'b0);
        swap_layer();
        $readmemh("../vectors/sys_s6_f2_y.mem", expm);
        run_layer("S6 fc2", 3, 64, 64, 1, 1, 0, 1, 1, 4608, 2, 2, 1'b1, 1'b0, 1'b1, 1);
        check_clean("S6 end");
        e6 = errors - e1 - e2 - e3 - e5;
        $display("%s S6: v3 tail conv4(4 tiles)->pool->conv5->pool->fc1(288,8 tiles)->fc2(64,2 tiles,last_rows 2)->m_*, bit-exact, errors=%0d",
                 (e6 == 0) ? "ok" : "FAIL", e6);

        // ---------------- T_MEM_PINGPONG_001 verdict ----------------
        // Accepted swaps issued: S1 2, S5 4, S6 3.
        check(pp_toggles == 9 && pp_bad == 0,
              $sformatf("buf_sel toggles=%0d (want 9) outside an accepted swap=%0d", pp_toggles, pp_bad));
        e_pp = pp_bad + ((pp_toggles == 9) ? 0 : 1);

        if (e_pp == 0)
            $display("PASS T_MEM_PINGPONG_001: buf_sel moved only on the 9 accepted swaps, early swap refused (ERROR[7]/detail[8], banks unchanged), read bank kept layer N-1 while layer N was written (S1, S5, S6)");
        if (e1 + e2 + e3 + e5 + e6 == 0)
            $display("PASS T_NUM_CONV_001: 3x3 pad1 48/24/12/6 maps, 5x5 LeNet convs and FC flattens, every pass bit-exact against the Python chain");
        axi_read(12'h10C, value);
        if (errors == 0)
            $display("PASS tb_sys_chain: S1 S2 S3 S5 S6, FRAME_COUNT=%0d", value);
        else
            $display("SYS-FAIL: tb_sys_chain errors=%0d", errors);
        $finish;
    end
    initial begin #2000000000; $display("SYS-FAIL: tb_sys_chain global timeout"); $finish; end
endmodule
