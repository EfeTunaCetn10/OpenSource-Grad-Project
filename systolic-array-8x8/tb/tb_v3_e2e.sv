`timescale 1ns/1ps
// Full frozen v3 network through accel_top, driven only the way a PS would:
// AXI-Lite registers, weight load port (idle), input frame on s_*, results on m_*.
//   conv1 3->16 (s_*, 2 tiles, pool) -> conv2 16->24 (3 tiles, pool) -> conv3 24->32
//   (4 tiles) -> conv4 32->32 (4 tiles, pool) -> conv5 32->32 (4 tiles, pool)
//   -> fc1 288->64 (1x1, c_phys 288, flatten (h,w,c), 8 tiles) -> fc2 64->10
//   (2 tiles, last tile 2 rows, no ReLU) -> m_*.
// Per layer, per output tile: LAYER_CFG/LAYER_CFG2/W_BASE/TILE_CFG/DP_CFG + 24 param
// words, COMMIT, START, poll STATUS.DONE (W1C); LAYER_SWAP after every layer.
// All layers' weights are resident at once (W_BASE offsets, 6086 bytes per bank).
// Compared against model/gen_v3_e2e_vectors.py (pure Python): every stored act_buffer
// layer word-by-word (hierarchical read), the logits on m_* beat by beat, and the
// predicted class (argmax, first index on ties, computed here from the m_* bytes).
// Stream pacing comes from LFSRs (no seeded $urandom).
module tb_v3_e2e;
    localparam int NIMG = 2;
    localparam int NL = 7;
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

    // ---- network table (index = layer) ----
    string  ltag    [NL] = '{"c1", "c2", "c3", "c4", "c5", "f1", "f2"};
    int     l_cin   [NL] = '{3, 16, 24, 32, 32, 288, 64};
    int     l_cphys [NL] = '{3, 16, 24, 32, 32, 288, 64};
    int     l_k     [NL] = '{3, 3, 3, 3, 3, 1, 1};
    int     l_pad   [NL] = '{1, 1, 1, 1, 1, 0, 0};
    int     l_ohw   [NL] = '{48, 24, 12, 12, 6, 1, 1};
    int     l_wbase [NL] = '{0, 54, 486, 1350, 2502, 3654, 5958};
    int     l_tiles [NL] = '{2, 3, 4, 4, 4, 8, 2};
    int     l_lrows [NL] = '{0, 0, 0, 0, 0, 0, 2};
    bit     l_pool  [NL] = '{1, 1, 0, 1, 1, 0, 0};
    int     l_words [NL] = '{1152, 432, 576, 144, 36, 8, 2};

    logic [63:0] frame_mem [0:FRAME_BEATS-1];
    logic [63:0] expm [0:1];       // logits reference
    logic [63:0] gotm [0:1];       // logits as seen on m_*
    logic [63:0] etmp [0:1151];
    logic [7:0] wb [0:8191];
    logic [7:0] pred_mem [0:0];
    logic [31:0] gbias [0:NL-1][0:127];
    logic [17:0] gm0 [0:NL-1][0:127];
    logic [5:0] gshift [0:NL-1][0:127];
    logic grelu [0:NL-1][0:127];
    logic [31:0] tb_bias [0:127];
    logic [17:0] tb_m0 [0:127];
    logic [5:0] tb_shift [0:127];
    logic tb_relu [0:127];

    int errors = 0;
    int exp_base = 0, exp_n = 0, seen = 0, last_seen = 0, bad_beats = 0;
    int words_checked = 0, passes = 0;
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
        if (!ok) begin $display("FAIL tb_v3_e2e: %s", why); errors++; end
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
            gotm[exp_base + seen] = m_y_flat;
            if (m_y_flat !== expm[exp_base + seen]) begin
                if (bad_beats < 5)
                    $display("FAIL tb_v3_e2e: m beat %0d = %016h expected %016h",
                             exp_base + seen, m_y_flat, expm[exp_base + seen]);
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
        while (b < FRAME_BEATS) begin
            @(negedge clk);
            if (hs) begin s_valid = 0; hs = 0; end
            if (!s_valid && (lfsr_s[1:0] != 2'b00)) begin
                s_valid = 1; s_data = frame_mem[b]; s_last = (b == FRAME_BEATS-1);
            end
            @(posedge clk);
            if (s_valid && s_ready) begin b++; hs = 1; end
        end
        @(negedge clk); s_valid = 0; s_last = 0;
    endtask

    task automatic load_weights;
        for (int r = 0; r < 8; r++) begin
            path = $sformatf("../vectors/v3e_wbank%0d.mem", r);
            $readmemh(path, wb);
            for (int a = 0; a < 8192; a++) begin
                @(negedge clk);
                w_wr_en = 1; w_wr_bank = 3'(r); w_wr_addr = 13'(a); w_wr_data = wb[a];
            end
        end
        @(negedge clk); w_wr_en = 0;
    endtask

    task automatic load_params;
        for (int L = 0; L < NL; L++) begin
            $readmemh($sformatf("../vectors/v3e_%s_bias.mem", ltag[L]), tb_bias);
            $readmemh($sformatf("../vectors/v3e_%s_m0.mem", ltag[L]), tb_m0);
            $readmemh($sformatf("../vectors/v3e_%s_shift.mem", ltag[L]), tb_shift);
            $readmemh($sformatf("../vectors/v3e_%s_relu.mem", ltag[L]), tb_relu);
            for (int c = 0; c < 128; c++) begin
                gbias[L][c] = tb_bias[c]; gm0[L][c] = tb_m0[c];
                gshift[L][c] = tb_shift[c]; grelu[L][c] = tb_relu[c];
            end
        end
    endtask

    // Full shadow image of one pass (layer L, output tile t), then COMMIT.
    task automatic configure(input int L, t, input bit src, dst);
        axi_write(12'h010, {1'b0, 6'(l_ohw[L]), 6'(l_ohw[L]), 2'(l_pad[L]), 2'd1,
                            3'(l_k[L]), 3'(l_k[L]), 9'(l_cin[L])});
        axi_write(12'h018, 32'(l_cphys[L]));
        axi_write(12'h01C, 32'(l_wbase[L]));
        axi_write(12'h014, {10'b0, 4'(l_lrows[L]), 2'b0, 8'(l_tiles[L]), 8'(t)});
        axi_write(12'h020, {29'b0, dst, l_pool[L], src});
        for (int r = 0; r < 8; r++) begin
            axi_write(12'(12'h040 + 16*r), gbias[L][8*t + r]);
            axi_write(12'(12'h044 + 16*r), {14'b0, gm0[L][8*t + r]});
            axi_write(12'(12'h048 + 16*r),
                      {23'b0, grelu[L][8*t + r], 2'b0, gshift[L][8*t + r]});
        end
        axi_write(12'h0C0, 1);
    endtask

    // Poll STATUS until DONE or ERROR; DONE is cleared (W1C).
    task automatic wait_pass(input int max_polls, output logic [31:0] st);
        int n = 0;
        do begin
            axi_read(12'h008, st);
            n++;
        end while (!st[2] && !st[3] && n < max_polls);
        if (st[2]) axi_write(12'h008, 4);
    endtask

    task automatic run_pass(input string tag, input bit feed);
        logic [31:0] st;
        axi_write(12'h004, 1);
        if (feed) fork feed_frame(); join_none
        wait_pass(400000, st);
        passes++;
        check(st[2] && !st[3] && !st[5], $sformatf("%s: STATUS=%08h (want DONE, no ERROR/ABORTED)", tag, st));
    endtask

    // Written layer, tile-major, in the current write bank of act_buffer.
    task automatic check_bank(input string tag, input int n, input string fname);
        int bad = 0;
        logic [63:0] got;
        $readmemh(fname, etmp);
        for (int i = 0; i < n; i++) begin
            got = dut.u_act.buf_sel ? dut.u_act.g_buffer[1].mem[i]
                                    : dut.u_act.g_buffer[0].mem[i];
            if (got !== etmp[i]) begin
                if (bad < 3) $display("FAIL tb_v3_e2e: %s word %0d = %016h expected %016h",
                                      tag, i, got, etmp[i]);
                bad++;
            end
        end
        words_checked += n;
        check(bad == 0, $sformatf("%s: %0d of %0d stored words differ", tag, bad, n));
    endtask

    task automatic check_clean(input string tag);
        logic [31:0] e, d;
        axi_read(12'h00C, e); axi_read(12'h024, d);
        check(e[7:0] == 0 && d[15:0] == 0,
              $sformatf("%s: ERROR=%02h ERR_DETAIL=%04h", tag, e[7:0], d[15:0]));
    endtask

    function automatic int signed lane8(input logic [63:0] w, input int lane);
        logic signed [7:0] b;
        b = w[8*lane +: 8];
        return int'(b);
    endfunction

    task automatic run_image(input int img);
        int pred, best, v;
        string pre;
        pre = $sformatf("../vectors/v3e_img%0d", img);
        $readmemh({pre, "_frame.mem"}, frame_mem);
        for (int L = 0; L < NL; L++) begin
            for (int t = 0; t < l_tiles[L]; t++) begin
                if (L == NL-1) begin
                    // logits: one word per tile on m_*
                    $readmemh({pre, "_f2_y.mem"}, expm);
                    expect_m(t, 1);
                end
                configure(L, t, L != 0, L == NL-1);
                run_pass($sformatf("img%0d %s tile %0d", img, ltag[L], t), L == 0);
                if (L == NL-1) check(seen == 1 && last_seen == 1 && bad_beats == 0,
                    $sformatf("img%0d f2 tile %0d: beats=%0d m_last=%0d bad=%0d", img, t, seen, last_seen, bad_beats));
            end
            check_clean($sformatf("img%0d %s", img, ltag[L]));
            if (L != NL-1) begin
                check_bank($sformatf("img%0d %s bank", img, ltag[L]), l_words[L],
                           {pre, "_", ltag[L], "_y.mem"});
                axi_write(12'h004, 8);   // LAYER_SWAP
            end
        end
        // argmax over the 10 INT8 logits seen on m_*, first index on ties
        pred = 0; best = lane8(gotm[0], 0);
        for (int c = 1; c < 10; c++) begin
            v = lane8(gotm[c / 8], c % 8);
            if (v > best) begin best = v; pred = c; end
        end
        $readmemh({pre, "_pred.mem"}, pred_mem);
        check(pred == int'(pred_mem[0]),
              $sformatf("img%0d predicted class %0d expected %0d", img, pred, pred_mem[0]));
        $display("img%0d: predicted class %0d (expected %0d), logits[pred]=%0d", img, pred, pred_mem[0], best);
    endtask

    task automatic expect_m(input int base, n);
        exp_base = base; exp_n = n; seen = 0; last_seen = 0; bad_beats = 0;
    endtask

    initial begin
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0;
        bready = 0; araddr = 0; arvalid = 0; rready = 0;
        s_valid = 0; s_data = 0; s_last = 0;
        w_wr_en = 0; w_wr_bank = 0; w_wr_addr = 0; w_wr_data = 0;
        load_params();
        repeat (4) @(negedge clk); rst_n = 1;
        load_weights();
        for (int i = 0; i < NIMG; i++) run_image(i);
        axi_read(12'h10C, value);
        if (errors == 0)
            $display("PASS tb_v3_e2e: %0d images, %0d passes, %0d act_buffer words + logits bit-exact, FRAME_COUNT=%0d",
                     NIMG, passes, words_checked, value);
        else
            $display("FAIL tb_v3_e2e: errors=%0d", errors);
        $finish;
    end
    initial begin #2000000000; $display("FAIL tb_v3_e2e: global timeout"); $finish; end
endmodule
