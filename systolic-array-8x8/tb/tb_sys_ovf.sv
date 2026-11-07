`timescale 1ns/1ps
// T_NUM_OVF_001: accumulator/bias overflow at the 2^31 boundary, through
// accel_top.  Semantics (ADR-003, ADR-014 S0): a = wrap32(acc + bias); the
// wrapped value is requantized; out_ovf flags a signed overflow of that sum;
// accel_top ORs it into ERROR[2] (flag only: no abort, no ERR_DETAIL bit) and
// shows it per lane on m_ovf_flat (zero when pool is on).
// 4x4x3 input of a constant value, 3x3 pad0, 2x2 outputs: every pixel has
// acc_r = 27*X*w_r exactly, so lane r's bias can sit exactly on either side
// of the boundary (model/gen_sys_vectors.py gen_ovf: +2^31-1 / +2^31 on the
// positive side, -2^31 / -2^31-1 on the negative side, acc=0, large weights,
// and one ordinary lane).
//   pass 1  no-overflow biases      : ERROR clear, m_ovf_flat 0, golden words
//   pass 2  boundary biases         : golden words and per-beat {sat, ovf} flags
//                                     (lanes 1,3,5,6 overflow), ERROR == 0x04,
//                                     ERR_DETAIL == 0, DONE and not ABORTED
//   pass 3  pass 2 again with pool  : ERROR[2] set again, golden word, m_ovf 0
//   pass 4  no-overflow biases      : the flag does not stay stuck after W1C
module tb_sys_ovf;
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

    logic [63:0] frame_mem [0:5];
    logic [63:0] y_ovf [0:3], y_ok [0:3];
    logic [15:0] fl_ovf [0:3], fl_ok [0:3];
    logic [7:0] wb2 [0:127];
    logic [31:0] bias_ovf [0:127], bias_ok [0:127];
    logic [31:0] bias_cur [0:7];
    logic [17:0] m0 [0:127];
    logic [5:0] shift [0:127];
    logic relu [0:127];
    string path;

    int errors = 0;
    int exp_n = 0, seen = 0, last_seen = 0, bad_beats = 0;
    bit exp_flags = 0, exp_pool = 0, use_ovf_set = 0;
    logic [15:0] lfsr_s = 16'hACE1, lfsr_m = 16'h1D2B;

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

    // m_* scoreboard: words, lane mask, and (no pool) the per-lane flags.
    always @(posedge clk) if (rst_n && m_valid && m_ready) begin
        if (seen >= exp_n) begin
            bad_beats++;
        end else begin
            if (m_y_flat !== (use_ovf_set ? y_ovf[seen] : y_ok[seen]) || m_lane_valid !== 8'hFF) begin
                if (bad_beats < 5)
                    $display("SYS-FAIL: m beat %0d = %016h lanes %02h expected %016h", seen, m_y_flat,
                             m_lane_valid, use_ovf_set ? y_ovf[seen] : y_ok[seen]);
                bad_beats++;
            end
            if (exp_pool) begin
                if (m_ovf_flat !== 8'h00 || m_sat_flat !== 8'h00) bad_beats++;
            end else if ({m_sat_flat, m_ovf_flat} !== (use_ovf_set ? fl_ovf[seen] : fl_ok[seen])) begin
                if (bad_beats < 5)
                    $display("SYS-FAIL: m beat %0d sat/ovf = %02h/%02h expected %04h", seen,
                             m_sat_flat, m_ovf_flat, use_ovf_set ? fl_ovf[seen] : fl_ok[seen]);
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
        while (b < 6) begin
            @(negedge clk);
            if (hs) begin s_valid = 0; hs = 0; end
            if (!s_valid && (lfsr_s[1:0] != 2'b00)) begin
                s_valid = 1; s_data = frame_mem[b]; s_last = (b == 5);
            end
            @(posedge clk);
            if (s_valid && s_ready) begin b++; hs = 1; end
        end
        @(negedge clk); s_valid = 0; s_last = 0;
    endtask

    task automatic cfg_pass(input bit pool, input bit ovf_set);
        axi_write(12'h010, {1'b0, 6'd2, 6'd2, 2'd0, 2'd1, 3'd3, 3'd3, 9'd3});   // 4x4x3, pad 0 -> 2x2
        axi_write(12'h018, 32'd3);
        axi_write(12'h01C, 32'd0);
        axi_write(12'h014, {10'b0, 4'd0, 2'b0, 8'd1, 8'd0});
        axi_write(12'h020, {29'b0, 1'b1, pool, 1'b0});   // s_* -> (pool) -> m_*
        for (int r = 0; r < 8; r++) begin
            axi_write(12'(12'h040 + 16*r), ovf_set ? bias_ovf[r] : bias_ok[r]);
            axi_write(12'(12'h044 + 16*r), {14'b0, m0[r]});
            axi_write(12'(12'h048 + 16*r), {23'b0, relu[r], 2'b0, shift[r]});
        end
        axi_write(12'h0C0, 1);
    endtask

    // Runs one pass and checks STATUS/ERROR: want_err is the exact ERROR byte.
    task automatic run_case(input string name, input bit pool, input bit ovf_set,
                            input logic [7:0] want_err);
        logic [31:0] st, e, d;
        int n = 0, mark = errors;
        use_ovf_set = ovf_set; exp_pool = pool; exp_n = pool ? 1 : 4;
        seen = 0; last_seen = 0; bad_beats = 0;
        cfg_pass(pool, ovf_set);
        axi_write(12'h004, 1);
        fork feed_frame(); join_none
        do begin axi_read(12'h008, st); n++; end while (!st[2] && n < 20000);
        check(st[2] && !st[1] && !st[5], $sformatf("%s: STATUS=%08h (want DONE, not ABORTED)", name, st));
        repeat (10) @(negedge clk);
        axi_read(12'h00C, e); axi_read(12'h024, d);
        check(seen == exp_n && last_seen == 1 && bad_beats == 0,
              $sformatf("%s: beats=%0d/%0d m_last=%0d bad=%0d", name, seen, exp_n, last_seen, bad_beats));
        check(e[7:0] == want_err, $sformatf("%s: ERROR=%02h want %02h", name, e[7:0], want_err));
        check(d[15:0] == 0, $sformatf("%s: ERR_DETAIL=%04h (an overflow flag has no detail bit)", name, d[15:0]));
        axi_write(12'h008, 4);
        axi_write(12'h00C, 32'hFF);
        $display("%s %s: ERROR=%02h", (errors == mark) ? "ok" : "FAIL", name, e[7:0]);
    endtask

    initial begin
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0;
        bready = 0; araddr = 0; arvalid = 0; rready = 0;
        s_valid = 0; s_data = 0; s_last = 0; m_ready = 0;
        w_wr_en = 0; w_wr_bank = 0; w_wr_addr = 0; w_wr_data = 0;
        $readmemh("../vectors/sys_ovf_frame.mem", frame_mem);
        $readmemh("../vectors/sys_ovf_y.mem", y_ovf);
        $readmemh("../vectors/sys_ovfn_y.mem", y_ok);
        $readmemh("../vectors/sys_ovf_flags.mem", fl_ovf);
        $readmemh("../vectors/sys_ovfn_flags.mem", fl_ok);
        $readmemh("../vectors/sys_ovf_bias.mem", bias_ovf);
        $readmemh("../vectors/sys_ovfn_bias.mem", bias_ok);
        $readmemh("../vectors/sys_ovf_m0.mem", m0);
        $readmemh("../vectors/sys_ovf_shift.mem", shift);
        $readmemh("../vectors/sys_ovf_relu.mem", relu);
        repeat (4) @(negedge clk); rst_n = 1;
        for (int r = 0; r < 8; r++) begin
            path = $sformatf("../vectors/sys_ovf_wbank%0d.mem", r);
            $readmemh(path, wb2);
            for (int a = 0; a < 128; a++) begin
                @(negedge clk);
                w_wr_en = 1; w_wr_bank = 3'(r); w_wr_addr = 13'(a); w_wr_data = wb2[a];
            end
        end
        @(negedge clk); w_wr_en = 0;

        run_case("no overflow",                 1'b0, 1'b0, 8'h00);
        run_case("boundary biases",             1'b0, 1'b1, 8'h04);
        run_case("boundary biases, pool on",    1'b1, 1'b1, 8'h04);
        run_case("no overflow after W1C",       1'b0, 1'b0, 8'h00);

        if (errors == 0)
            $display("PASS T_NUM_OVF_001: acc+bias at +/-2^31 (+-1), wrap32 then requant bit-exact, per-lane m_ovf_flat/m_sat_flat match the model, ERROR[2] flag only (no abort, no detail bit), set with pool on, clear when no lane overflows");
        else
            $display("SYS-FAIL: tb_sys_ovf errors=%0d", errors);
        $finish;
    end
    initial begin #200000000; $display("SYS-FAIL: tb_sys_ovf global timeout"); $finish; end
endmodule
