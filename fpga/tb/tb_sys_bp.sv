`timescale 1ns/1ps
// T_AXI_BP_001: input/output backpressure at accel_top level.
// One 10x10x8 3x3 pad1 layer (100 s_* beats in; 100 m_* words, or 25 with
// pool) runs under a matrix of s_valid / m_ready stall profiles, all LFSR or
// counter driven (no seeded $urandom):
//   0 always ready/valid      1 LFSR 50%        2 LFSR 25% pass
//   3 LFSR 75% pass           4 bursts (s: 300 idle cycles after every 25
//   beats; m: 400 blocked cycles at beat 5, 25, 45, ... i.e. in the middle of a
//   row burst of outputs)
//   5 (m only) ready held low until m_valid has been up for 64 cycles, then 50%
// Every pass must be bit-exact against model/gen_sys_vectors.py (sys_bp_*),
// carry exactly one m_last, take exactly 100 s_* beats, end with ERROR and
// ERR_DETAIL clear, and STALL_IN / STALL_OUT must count the testbench's own
// s_valid&&!s_ready / m_valid&&!m_ready cycles.  Continuous checks: while
// m_valid && !m_ready every m_* payload bit holds until the handshake, m_valid
// does not drop, and no output carries X.
module tb_sys_bp;
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

    logic [63:0] frame_mem [0:99];
    logic [63:0] y_full [0:99];
    logic [63:0] y_pool [0:24];
    logic [63:0] expm [0:99];
    logic [7:0] wb2 [0:127];
    logic [31:0] bias [0:7];
    logic [17:0] m0 [0:7];
    logic [5:0] shift [0:7];
    logic relu [0:7];
    logic [31:0] tb_bias [0:127];
    logic [17:0] tb_m0 [0:127];
    logic [5:0] tb_shift [0:127];
    logic tb_relu [0:127];
    string path;

    int errors = 0;
    int exp_n = 0, seen = 0, last_seen = 0, bad_beats = 0;
    int s_mode = 0, m_mode = 0;
    int s_cnt = 0, tb_s_stall = 0, tb_m_stall = 0;
    int stability_bad = 0, x_bad = 0;
    int m_gap = 0, last_gap_seen = -1, hold_cnt = 0;
    logic [15:0] lfsr_s = 16'hACE1, lfsr_m = 16'h1D2B;
    logic [31:0] value;

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

    // m_ready driver per profile.
    always @(negedge clk) begin
        if (m_mode == 4 && seen != last_gap_seen && seen % 20 == 5 && seen < exp_n) begin
            m_gap = 400; last_gap_seen = seen;
        end
        case (m_mode)
            0: m_ready = rst_n;
            1: m_ready = rst_n && lfsr_m[0];
            2: m_ready = rst_n && (lfsr_m[1:0] == 2'b00);
            3: m_ready = rst_n && (lfsr_m[1:0] != 2'b00);
            4: begin
                m_ready = rst_n && (m_gap == 0);
                if (m_gap > 0) m_gap--;
            end
            default: begin
                if (m_valid && hold_cnt < 64) hold_cnt++;
                m_ready = rst_n && (hold_cnt >= 64) && lfsr_m[0];
            end
        endcase
    end

    // m_* scoreboard.
    always @(posedge clk) if (rst_n && m_valid && m_ready) begin
        if (seen >= exp_n) begin
            bad_beats++;
        end else begin
            if (m_y_flat !== expm[seen]) begin
                if (bad_beats < 5)
                    $display("SYS-FAIL: m beat %0d = %016h expected %016h", seen, m_y_flat, expm[seen]);
                bad_beats++;
            end
            if (m_last !== (seen == exp_n - 1)) bad_beats++;
        end
        if (m_last) last_seen++;
        seen++;
    end

    // Stall counters of the testbench, and the continuous protocol checks.
    logic pv_q = 0, pr_q = 0;
    logic [63:0] py_q;
    logic [7:0] plv_q, psat_q, povf_q;
    logic [3:0] pcol_q;
    logic plast_q;
    always @(posedge clk) begin
        if (s_valid && !s_ready) tb_s_stall++;
        if (s_valid && s_ready) s_cnt++;
        if (m_valid && !m_ready) tb_m_stall++;
        if (rst_n) begin
            if (m_valid && (^{m_y_flat, m_last, m_col, m_lane_valid} === 1'bx)) x_bad++;
            if (pv_q && !pr_q) begin
                if (!m_valid || m_y_flat !== py_q || m_last !== plast_q || m_col !== pcol_q ||
                    m_lane_valid !== plv_q || m_sat_flat !== psat_q || m_ovf_flat !== povf_q)
                    stability_bad++;
            end
        end
        pv_q <= m_valid; pr_q <= m_ready; py_q <= m_y_flat; plast_q <= m_last;
        pcol_q <= m_col; plv_q <= m_lane_valid; psat_q <= m_sat_flat; povf_q <= m_ovf_flat;
    end

    // s_* feeder per profile: valid is raised, then held (data stable) until accepted.
    task automatic feed_frame;
        int b = 0;
        bit hs = 0;
        bit allow;
        while (b < 100) begin
            @(negedge clk);
            if (hs) begin s_valid = 0; hs = 0; end
            if (s_mode == 4 && b > 0 && b % 25 == 0 && !s_valid && !hs) begin
                // burst gap once per 25-beat block
                repeat (300) @(negedge clk);
            end
            case (s_mode)
                0: allow = 1;
                1: allow = lfsr_s[0];
                2: allow = (lfsr_s[1:0] == 2'b00);
                3: allow = (lfsr_s[1:0] != 2'b00);
                default: allow = 1;
            endcase
            if (!s_valid && allow) begin
                s_valid = 1; s_data = frame_mem[b]; s_last = (b == 99);
            end
            @(posedge clk);
            if (s_valid && s_ready) begin
                b++; hs = 1;
            end
        end
        @(negedge clk); s_valid = 0; s_last = 0;
    endtask

    task automatic cfg_pass(input bit pool);
        axi_write(12'h010, {1'b0, 6'd10, 6'd10, 2'd1, 2'd1, 3'd3, 3'd3, 9'd8});
        axi_write(12'h018, 32'd8);
        axi_write(12'h01C, 32'd0);
        axi_write(12'h014, {10'b0, 4'd0, 2'b0, 8'd1, 8'd0});
        axi_write(12'h020, {29'b0, 1'b1, pool, 1'b0});   // s_* -> (pool) -> m_*
        for (int r = 0; r < 8; r++) begin
            axi_write(12'(12'h040 + 16*r), bias[r]);
            axi_write(12'(12'h044 + 16*r), {14'b0, m0[r]});
            axi_write(12'(12'h048 + 16*r), {23'b0, relu[r], 2'b0, shift[r]});
        end
        axi_write(12'h0C0, 1);
    endtask

    task automatic run_profile(input string name, input int sm, mm, input bit pool);
        logic [31:0] st, e, d, si0, so0, si1, so1;
        int ts0, tm0, mark;
        mark = errors;
        s_mode = sm; m_mode = mm;
        for (int i = 0; i < 100; i++) expm[i] = pool ? ((i < 25) ? y_pool[i] : 64'h0) : y_full[i];
        exp_n = pool ? 25 : 100;
        seen = 0; last_seen = 0; bad_beats = 0; m_gap = 0; last_gap_seen = -1; hold_cnt = 0;
        stability_bad = 0; x_bad = 0; s_cnt = 0;
        cfg_pass(pool);
        axi_read(12'h104, si0); axi_read(12'h108, so0);
        ts0 = tb_s_stall; tm0 = tb_m_stall;
        axi_write(12'h004, 1);
        fork feed_frame(); join_none
        begin
            int n = 0;
            do begin axi_read(12'h008, st); n++; end while (!st[2] && !st[3] && n < 100000);
        end
        check(st[2] && !st[3] && !st[5], $sformatf("%s: STATUS=%08h (want DONE, no ERROR/ABORTED)", name, st));
        axi_write(12'h008, 4);
        repeat (20) @(negedge clk);
        axi_read(12'h104, si1); axi_read(12'h108, so1);
        axi_read(12'h00C, e); axi_read(12'h024, d);
        check(seen == exp_n && last_seen == 1 && bad_beats == 0,
              $sformatf("%s: beats=%0d/%0d m_last=%0d bad=%0d", name, seen, exp_n, last_seen, bad_beats));
        check(s_cnt == 100, $sformatf("%s: s_* beats taken=%0d (want 100)", name, s_cnt));
        check(e[7:0] == 0 && d[15:0] == 0, $sformatf("%s: ERROR=%02h ERR_DETAIL=%04h", name, e[7:0], d[15:0]));
        check(stability_bad == 0, $sformatf("%s: m_* payload moved or m_valid dropped under stall %0d times", name, stability_bad));
        check(x_bad == 0, $sformatf("%s: m_* carried X %0d times", name, x_bad));
        if (mm != 0)
            check(tb_m_stall - tm0 > 0, $sformatf("%s: the profile never stalled m_valid", name));
        check(si1 - si0 == 32'(tb_s_stall - ts0),
              $sformatf("%s: STALL_IN +%0d, testbench saw %0d", name, si1 - si0, tb_s_stall - ts0));
        check(so1 - so0 == 32'(tb_m_stall - tm0),
              $sformatf("%s: STALL_OUT +%0d, testbench saw %0d", name, so1 - so0, tb_m_stall - tm0));
        $display("%s %s: s_mode=%0d m_mode=%0d pool=%0d s_stall=%0d m_stall=%0d", (errors == mark) ? "ok" : "FAIL",
                 name, sm, mm, pool, tb_s_stall - ts0, tb_m_stall - tm0);
    endtask

    initial begin
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0;
        bready = 0; araddr = 0; arvalid = 0; rready = 0;
        s_valid = 0; s_data = 0; s_last = 0; m_ready = 0;
        w_wr_en = 0; w_wr_bank = 0; w_wr_addr = 0; w_wr_data = 0;
        $readmemh("../vectors/sys_bp_frame.mem", frame_mem);
        $readmemh("../vectors/sys_bp_y.mem", y_full);
        $readmemh("../vectors/sys_bp_yp.mem", y_pool);
        $readmemh("../vectors/sys_bp_bias.mem", tb_bias);
        $readmemh("../vectors/sys_bp_m0.mem", tb_m0);
        $readmemh("../vectors/sys_bp_shift.mem", tb_shift);
        $readmemh("../vectors/sys_bp_relu.mem", tb_relu);
        for (int c = 0; c < 8; c++) begin
            bias[c] = tb_bias[c]; m0[c] = tb_m0[c]; shift[c] = tb_shift[c]; relu[c] = tb_relu[c];
        end
        repeat (4) @(negedge clk); rst_n = 1;
        for (int r = 0; r < 8; r++) begin
            path = $sformatf("../vectors/sys_bp_wbank%0d.mem", r);
            $readmemh(path, wb2);
            for (int a = 0; a < 128; a++) begin
                @(negedge clk);
                w_wr_en = 1; w_wr_bank = 3'(r); w_wr_addr = 13'(a); w_wr_data = wb2[a];
            end
        end
        @(negedge clk); w_wr_en = 0;

        run_profile("full rate",           0, 0, 1'b0);
        run_profile("LFSR 50% both",       1, 1, 1'b0);
        run_profile("slow input 25%",      2, 0, 1'b0);
        run_profile("slow output 25%",     0, 2, 1'b0);
        run_profile("75% both",            3, 3, 1'b0);
        run_profile("25% both",            2, 2, 1'b0);
        run_profile("bursty input",        4, 0, 1'b0);
        run_profile("bursty output",       0, 4, 1'b0);
        run_profile("bursty both",         4, 4, 1'b0);
        run_profile("hold from first beat",0, 5, 1'b0);
        run_profile("pool LFSR 50%",       1, 1, 1'b1);
        run_profile("pool 25% both",       2, 2, 1'b1);
        run_profile("pool hold from first",0, 5, 1'b1);

        if (errors == 0)
            $display("PASS T_AXI_BP_001: 13 stall profiles on s_valid/m_ready (LFSR 25/50/75%%, bursts, hold-from-first-beat, pooled), bit-exact, m_* stable under stall, one m_last, exact beat counts, STALL_IN/OUT match");
        else
            $display("SYS-FAIL: tb_sys_bp errors=%0d", errors);
        $finish;
    end
    initial begin #500000000; $display("SYS-FAIL: tb_sys_bp global timeout"); $finish; end
endmodule
