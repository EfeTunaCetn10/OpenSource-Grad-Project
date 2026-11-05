`timescale 1ns/1ps

// T_ACCEL_CTRL_001: AXI configuration through a bit-exact conv1 frame.
// faz4: register writes while busy only touch the shadow image, a second
// START after SOFT_RESET reruns the frame bit-exact, and geometry/tile
// changes act only after COMMIT.
module tb_accel_top;
    localparam int FRAME_BEATS = 384;
    localparam int OUT_BEATS = 784;
    localparam int K_LEN = 75;
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
    logic [63:0] y_mem [0:OUT_BEATS-1];
    logic [31:0] bias_mem [0:7];
    logic [17:0] m0_mem [0:7];
    logic [5:0] shift_mem [0:7];
    logic relu_mem [0:7];
    logic [7:0] weight_mem [0:K_LEN-1];
    int errors = 0, out_seen = 0, cyc = 0, exact_frames = 0;
    int expected_stall_in = 0, expected_stall_out = 0;
    bit checking = 0, busy_seen = 0, done_seen = 0;
    string path;
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
        if (!ok) begin $display("FAIL tb_accel_top: %s", why); errors++; end
    endtask

    task automatic axi_write(input logic [11:0] addr, input logic [31:0] data);
        begin
            @(negedge clk);
            awaddr = addr; awvalid = 1; wdata = data; wstrb = 4'hF; wvalid = 1;
            bready = 0;
            do @(posedge clk); while (!(awready && wready));
            @(negedge clk); awvalid = 0; wvalid = 0; bready = 1;
            do @(posedge clk); while (!bvalid);
            check(bresp == 0, "AXI write BRESP");
            @(negedge clk); bready = 0;
        end
    endtask

    task automatic axi_read(input logic [11:0] addr, output logic [31:0] data);
        begin
            @(negedge clk); araddr = addr; arvalid = 1; rready = 0;
            do @(posedge clk); while (!arready);
            @(negedge clk); arvalid = 0; rready = 1;
            do @(posedge clk); while (!rvalid);
            data = rdata;
            check(rresp == 0, "AXI read RRESP");
            @(negedge clk); rready = 0;
        end
    endtask

    // Plain always: the stimulus initializes scoreboard state.
    always @(posedge clk) begin
        if (rst_n) begin
            if (s_valid && !s_ready) expected_stall_in++;
            if (m_valid && !m_ready) expected_stall_out++;
            if (dut.busy) busy_seen = 1;
            if (dut.pass_done) done_seen = 1;
            if (checking && m_valid && m_ready) begin
                if (out_seen >= OUT_BEATS) begin
                    check(0, "extra output beat");
                end else begin
                    if (m_y_flat !== y_mem[out_seen]) begin
                        $display("FAIL tb_accel_top: output %0d = %016h expected %016h",
                                 out_seen, m_y_flat, y_mem[out_seen]);
                        errors++;
                    end
                    check(m_lane_valid == 8'h3F, "lane mask");
                    check(m_last == (out_seen == OUT_BEATS-1), "m_last position");
                    check((m_ovf_flat & m_lane_valid) == 0, "overflow");
                    out_seen++;
                end
            end
        end
    end
    // Deliberate output backpressure during the frame.
    always @(negedge clk) begin
        if (!rst_n || !checking) m_ready = 0;
        else begin
            cyc++;
            m_ready = (cyc[1:0] != 0);
        end
    end

    task automatic load_weights;
        for (int r = 0; r < 8; r++) begin
            path = $sformatf("../vectors/c1_wbank%0d.mem", r);
            $readmemh(path, weight_mem);
            for (int a = 0; a < K_LEN; a++) begin
                @(negedge clk);
                w_wr_en = 1; w_wr_bank = 3'(r); w_wr_addr = 13'(a);
                w_wr_data = weight_mem[a];
            end
        end
        @(negedge clk); w_wr_en = 0;
    endtask

    task automatic write_params;
        for (int r = 0; r < 8; r++) begin
            axi_write(12'(12'h040 + 16*r), bias_mem[r]);
            axi_write(12'(12'h044 + 16*r), {14'b0,m0_mem[r]});
            axi_write(12'(12'h048 + 16*r), {23'b0,relu_mem[r],2'b0,shift_mem[r]});
        end
    endtask

    task automatic feed_frame;
        for (int b = 0; b < FRAME_BEATS; b++) begin
            @(negedge clk); s_valid = 1; s_data = frame_mem[b];
            s_last = (b == FRAME_BEATS-1);
            do @(posedge clk); while (!s_ready);
        end
        @(negedge clk); s_valid = 0; s_last = 0;
    endtask

    initial begin
        awaddr = 0; awvalid = 0; wdata = 0; wstrb = 0; wvalid = 0;
        bready = 0; araddr = 0; arvalid = 0; rready = 0;
        s_valid = 0; s_data = 0; s_last = 0;
        w_wr_en = 0; w_wr_bank = 0; w_wr_addr = 0; w_wr_data = 0;
        $readmemh("../vectors/c1_frame.mem", frame_mem);
        $readmemh("../vectors/c1_y.mem", y_mem);
        $readmemh("../vectors/c1_cfg_bias.mem", bias_mem);
        $readmemh("../vectors/c1_cfg_m0.mem", m0_mem);
        $readmemh("../vectors/c1_cfg_shift.mem", shift_mem);
        $readmemh("../vectors/c1_cfg_relu.mem", relu_mem);
        repeat (4) @(negedge clk); rst_n = 1;

        // c_in=3, kH=kW=5, stride=1, pad=0, out_H=out_W=28.
        axi_write(12'h010, 32'h38E0_DA03);
        axi_read(12'h010, value);
        check(value == 32'h38E0_DA03, "LAYER_CFG readback");
        axi_write(12'h018, 32'h0000_0003); // c_phys=3
        axi_write(12'h01C, 32'h0000_0000); // weight-bank base=0
        // tile_idx=0, tile_count=1, last_rows=6
        axi_write(12'h014, 32'h0018_0100);
        axi_write(12'h020, 32'h0000_0004); // DP_CFG: s_* -> no pool -> m_*
        write_params();
        axi_read(12'h0C4, value);
        check(value[23:0] == 24'hFFFFFF && !value[24], "written_mask before commit");
        axi_write(12'h0C0, 1);
        axi_read(12'h0C4, value);
        check(value[23:0] == 0 && value[24], "commit status");
        check(dut.cfg_k_len == K_LEN, "registered k_len");
        check(dut.cfg_in_h == 32 && dut.cfg_in_w == 32,
              "registered input geometry");
        check(dut.cfg_active_rows == 6, "last-tile active rows");
        load_weights();

        // Frame 1.  While it runs, rewrite every shadow register the pass
        // depends on (W_BASE=1 would read undefined weight words) and try a
        // COMMIT and a LAYER_SWAP: the running pass must stay bit-exact.
        checking = 1;
        axi_write(12'h004, 1);
        fork
            feed_frame();
        join_none
        wait (out_seen >= 100);
        axi_write(12'h010, 32'h36E0_DA03);
        axi_write(12'h014, 32'h0008_0201);
        axi_write(12'h01C, 32'h0000_0001);
        axi_write(12'h020, 32'h0000_0003);
        write_params();
        axi_write(12'h0C0, 1);
        axi_write(12'h004, 8);
        check(dut.cfg_out_w == 28 && dut.cfg_w_base == 0 && dut.cfg_dst_sel &&
              !dut.cfg_src_sel && dut.cfg_active_rows == 6,
              "busy shadow writes changed the active image");
        axi_read(12'h00C, value);
        check(value[7:0] == 8'h08, "busy COMMIT/LAYER_SWAP sets ERROR[3] only");
        axi_read(12'h01C, value);
        check(value == 1, "W_BASE readback is the shadow");
        check(out_seen < OUT_BEATS, "busy writes finished after the frame");
        for (int guard = 0; guard < 500000 && out_seen < OUT_BEATS; guard++)
            @(negedge clk);
        repeat (20) @(negedge clk);
        check(out_seen == OUT_BEATS, "frame output timeout");
        check(busy_seen, "BUSY never rose");
        check(done_seen, "pass_done pulse missing");
        if (out_seen == OUT_BEATS) exact_frames++;
        checking = 0;
        axi_write(12'h00C, 32'hFF);
        axi_read(12'h008, value);
        check(!value[1] && value[2] && !value[4], "BUSY/DONE/TABLE_VALID status");
        axi_write(12'h008, 4);
        axi_read(12'h008, value);
        check(!value[2], "DONE W1C");
        axi_read(12'h100, value); check(value > 0, "CYCLE_COUNT");
        axi_read(12'h104, value);
        check(value == expected_stall_in && value > 0, "STALL_IN exact count");
        axi_read(12'h108, value);
        check(value == expected_stall_out && value > 0, "STALL_OUT exact count");
        axi_read(12'h10C, value); check(value == 1, "FRAME_COUNT");
        axi_write(12'h004, 2);
        axi_read(12'h100, value); check(value == 0, "CYCLE_COUNT clear");
        axi_read(12'h104, value); check(value == 0, "STALL_IN clear");
        axi_read(12'h108, value); check(value == 0, "STALL_OUT clear");
        axi_read(12'h10C, value); check(value == 0, "FRAME_COUNT clear");

        // Frames 2 and 3: same active image, no new COMMIT; frame 2 follows
        // SOFT_RESET, frame 3 follows frame 2 directly, so only the restart
        // pulse can take the window generator out of its done state.
        for (int f = 2; f <= 3; f++) begin
            out_seen = 0; busy_seen = 0; done_seen = 0;
            checking = 1;
            axi_write(12'h004, 1);
            fork
                feed_frame();
            join_none
            for (int guard = 0; guard < 500000 && out_seen < OUT_BEATS; guard++)
                @(negedge clk);
            repeat (20) @(negedge clk);
            check(out_seen == OUT_BEATS, $sformatf("frame %0d output timeout", f));
            check(busy_seen && done_seen, $sformatf("frame %0d BUSY/DONE", f));
            checking = 0;
            if (out_seen == OUT_BEATS) exact_frames++;
            axi_read(12'h10C, value);
            check(value == f - 1, $sformatf("FRAME_COUNT after frame %0d", f));
            axi_read(12'h00C, value);
            check(value[7:0] == 8'h00, $sformatf("frame %0d ERROR", f));
        end

        // Shadow writes without COMMIT leave the active geometry alone.
        out_seen = 0;
        axi_write(12'h010, 32'h36E0_DA03);
        axi_read(12'h010, value);
        check(value == 32'h36E0_DA03, "LAYER_CFG shadow readback");
        check(dut.cfg_out_w == 28 && dut.cfg_in_w == 32,
              "uncommitted LAYER_CFG changed the active geometry");

        // A committed out_H=0, and kh=1 with pad=1, are rejected at START
        // (window_gen parity) before they reach the generator.
        axi_write(12'h010, 32'h3800_DA03); // out_H=0
        write_params();
        axi_write(12'h0C0, 1);
        axi_write(12'h004, 1);
        repeat (4) @(negedge clk);
        axi_read(12'h00C, value);
        check(value[7:0] == 8'h80, "out_H=0 ERROR[7] only");
        axi_read(12'h008, value);
        check(!value[1], "out_H=0 started a frame");
        axi_write(12'h00C, 32'hFF);
        axi_write(12'h010, 32'h0822_B203); // kh=1, kw=3, pad=1, out 4x4
        write_params();
        axi_write(12'h0C0, 1);
        axi_write(12'h004, 1);
        repeat (4) @(negedge clk);
        axi_read(12'h00C, value);
        check(value[7:0] == 8'h80, "pad>=kh ERROR[7] only");
        axi_read(12'h008, value);
        check(!value[1], "pad>=kh started a frame");
        check(out_seen == 0, "rejected geometry emitted output");

        // last_rows=2 makes a 10-channel layer expressible as tiles 8+2.
        // TILE_CFG acts only after COMMIT.  The active tile is still the
        // final-tile image written while busy and committed above (2 rows).
        axi_write(12'h014, 32'h0008_0200); // first of two tiles
        check(dut.cfg_active_rows == 2, "uncommitted TILE_CFG changed active rows");
        write_params();
        axi_write(12'h0C0, 1);
        check(dut.cfg_active_rows == 8, "non-final tile active rows");
        axi_write(12'h014, 32'h0008_0201); // final tile
        write_params();
        axi_write(12'h0C0, 1);
        check(dut.cfg_active_rows == 2, "final tile active rows");

        if (errors == 0) $display("PASS tb_accel_top: %0d bit-exact frames of %0d beats",
                                    exact_frames, OUT_BEATS);
        else $display("FAIL tb_accel_top: %0d errors", errors);
        $finish;
    end
    initial begin
        #10000000;
        $display("FAIL tb_accel_top: global timeout");
        $finish;
    end
endmodule
