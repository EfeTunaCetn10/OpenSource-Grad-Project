`timescale 1ns/1ps

// T_REG_PARAM_001: register map, AXI channel independence, and the
// shadow/commit protocol.
module tb_axi_lite_regs;
    localparam int AW = 12;

    logic clk = 1'b0;
    logic rst_n = 1'b0;

    logic [AW-1:0] awaddr;
    logic awvalid, awready;
    logic [31:0] wdata;
    logic [3:0] wstrb;
    logic wvalid, wready;
    logic [1:0] bresp;
    logic bvalid, bready;
    logic [AW-1:0] araddr;
    logic arvalid, arready;
    logic [31:0] rdata;
    logic [1:0] rresp;
    logic rvalid, rready;

    logic busy, done, table_valid;
    logic [31:0] cycle_count, stall_in, stall_out, frame_count;
    logic [7:0] hw_error_set;
    logic start, soft_reset, counter_clear;
    logic signed [31:0] cfg_bias_q [0:7];
    logic signed [17:0] cfg_m0 [0:7];
    logic [5:0] cfg_shift_n [0:7];
    logic cfg_relu [0:7];
    logic cfg_bypass;
    logic [8:0] cfg_c_in;
    logic [2:0] cfg_kh, cfg_kw;
    logic [1:0] cfg_stride, cfg_pad;
    logic [5:0] cfg_out_h, cfg_out_w;
    logic [7:0] cfg_tile_idx, cfg_tile_count;
    logic cfg_param_src;
    logic [15:0] cfg_k_len;

    integer errors = 0;
    integer start_seen = 0;
    integer soft_seen = 0;
    integer clear_seen = 0;
    integer i;

    always #5 clk = ~clk;

    axi_lite_regs dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
        .s_axi_rready(rready),
        .busy(busy), .done(done),
        .cycle_count(cycle_count), .stall_in(stall_in),
        .stall_out(stall_out), .frame_count(frame_count),
        .table_valid(table_valid), .hw_error_set(hw_error_set),
        .start(start), .soft_reset(soft_reset), .counter_clear(counter_clear),
        .cfg_bias_q(cfg_bias_q), .cfg_m0(cfg_m0),
        .cfg_shift_n(cfg_shift_n), .cfg_relu(cfg_relu),
        .cfg_bypass(cfg_bypass), .cfg_c_in(cfg_c_in), .cfg_kh(cfg_kh),
        .cfg_kw(cfg_kw), .cfg_stride(cfg_stride), .cfg_pad(cfg_pad),
        .cfg_out_h(cfg_out_h), .cfg_out_w(cfg_out_w),
        .cfg_tile_idx(cfg_tile_idx), .cfg_tile_count(cfg_tile_count),
        .cfg_param_src(cfg_param_src), .cfg_k_len(cfg_k_len)
    );

    always @(posedge clk) begin
        if (rst_n) begin
            if (start) start_seen = start_seen + 1;
            if (soft_reset) soft_seen = soft_seen + 1;
            if (counter_clear) clear_seen = clear_seen + 1;
        end
    end

    task automatic check(input logic condition, input string message);
        begin
            if (!condition) begin
                $display("FAIL tb_axi_lite_regs: %s", message);
                errors = errors + 1;
            end
        end
    endtask

    task automatic axi_write(
        input logic [AW-1:0] addr,
        input logic [31:0] data,
        input logic [3:0] strb,
        input bit aw_first,
        input integer gap_cycles,
        input integer b_delay
    );
        begin
            awvalid = 1'b0;
            wvalid = 1'b0;
            bready = 1'b0;
            if (aw_first) begin
                @(negedge clk);
                awaddr = addr;
                awvalid = 1'b1;
                do @(posedge clk); while (!awready);
                @(negedge clk);
                awvalid = 1'b0;
                repeat (gap_cycles) @(negedge clk);
                wdata = data;
                wstrb = strb;
                wvalid = 1'b1;
                do @(posedge clk); while (!wready);
                @(negedge clk);
                wvalid = 1'b0;
            end else begin
                @(negedge clk);
                wdata = data;
                wstrb = strb;
                wvalid = 1'b1;
                do @(posedge clk); while (!wready);
                @(negedge clk);
                wvalid = 1'b0;
                repeat (gap_cycles) @(negedge clk);
                awaddr = addr;
                awvalid = 1'b1;
                do @(posedge clk); while (!awready);
                @(negedge clk);
                awvalid = 1'b0;
            end
            repeat (b_delay) @(negedge clk);
            bready = 1'b1;
            do @(posedge clk); while (!bvalid);
            check(bresp == 2'b00, "write response was not OKAY");
            @(negedge clk);
            bready = 1'b0;
        end
    endtask

    task automatic axi_read(
        input logic [AW-1:0] addr,
        input integer r_delay,
        output logic [31:0] data
    );
        begin
            araddr = addr;
            arvalid = 1'b1;
            rready = 1'b0;
            do @(posedge clk); while (!arready);
            @(negedge clk);
            arvalid = 1'b0;
            repeat (r_delay) @(negedge clk);
            rready = 1'b1;
            do @(posedge clk); while (!rvalid);
            data = rdata;
            check(rresp == 2'b00, "read response was not OKAY");
            @(negedge clk);
            rready = 1'b0;
        end
    endtask

    task automatic check_error_bit(input int bit_index, input string label);
        logic [31:0] value;
        begin
            axi_read(12'h00C, 1, value);
            check(value[bit_index], label);
        end
    endtask

    task automatic clear_errors;
        begin
            axi_write(12'h00C, 32'h0000_00FF, 4'h1, 1'b0, 2, 1);
        end
    endtask

    task automatic write_shadow_set(input bit aw_first, input integer gap);
        integer b;
        begin
            for (b = 0; b < 8; b = b + 1) begin
                axi_write(12'h040 + b*16, 32'h1000_0000 + b, 4'hF,
                          aw_first, gap, 0);
                axi_write(12'h044 + b*16, 32'h0001_0000 + b, 4'hF,
                          !aw_first, gap, 0);
                axi_write(12'h048 + b*16, {23'h0, (b[0]), 2'b0, (b+1)},
                          4'hF, aw_first, gap, 0);
            end
        end
    endtask

    initial begin
        logic [31:0] value;
        logic [31:0] old_value;

        awaddr = '0;
        awvalid = 1'b0;
        wdata = '0;
        wstrb = 4'h0;
        wvalid = 1'b0;
        bready = 1'b0;
        araddr = '0;
        arvalid = 1'b0;
        rready = 1'b0;
        busy = 1'b0;
        done = 1'b0;
        table_valid = 1'b0;
        cycle_count = 32'd123;
        stall_in = 32'd7;
        stall_out = 32'd9;
        frame_count = 32'd11;
        hw_error_set = 8'h0;

        repeat (2) @(posedge clk);
        #1;
        check(awready && wready && arready, "reset did not leave channels ready");
        rst_n = 1'b1;

        axi_read(12'h000, 2, value);
        check(value == 32'h0001_0001, "VERSION mismatch");
        axi_read(12'h008, 1, value);
        check(value[0] && !value[1] && !value[2] && !value[3],
              "reset STATUS mismatch");
        axi_write(12'h010, 32'hB8E0_DA03, 4'hF, 1'b1, 0, 0);
        axi_read(12'h010, 0, value);
        check(value == 32'h38E0_DA03, "LAYER_CFG reserved bit was not masked");
        check(cfg_c_in == 3 && cfg_kh == 5 && cfg_kw == 5 &&
              cfg_stride == 1 && cfg_pad == 0 &&
              cfg_out_h == 28 && cfg_out_w == 28,
              "LAYER_CFG decoded fields mismatch");
        check(cfg_k_len == 0, "k_len changed before commit");
        axi_write(12'h014, 32'h0002_0103, 4'hF, 1'b1, 0, 0);
        check(cfg_tile_idx == 3 && cfg_tile_count == 1 && cfg_param_src,
              "TILE_CFG decoded fields mismatch");
        axi_write(12'h014, 32'h0, 4'hF, 1'b1, 0, 0);

        // START is rejected before the first commit and is self-clearing.
        axi_write(12'h004, 32'h1, 4'h1, 1'b1, 3, 2);
        check(start_seen == 0, "incomplete START was emitted");
        check_error_bit(7, "START without COMMITTED did not set ERR_PARAM_INCOMPLETE");
        axi_read(12'h004, 1, value);
        check(value[1:0] == 2'b00, "START/SOFT_RESET did not self-clear");
        clear_errors();

        // Missing one word: no active register may change.
        for (i = 0; i < 8; i = i + 1) begin
            axi_write(12'h040 + i*16, 32'h2000_0000 + i, 4'hF, 1'b1, 1, 0);
            axi_write(12'h044 + i*16, 32'h0001_0000 + i, 4'hF, 1'b0, 2, 1);
            if (i != 3)
                axi_write(12'h048 + i*16,
                          (i[0] ? 32'h0000_0100 : 32'h0) | (i + 1),
                          4'hF, 1'b1, 0, 0);
        end
        axi_write(12'h0C0, 32'h1, 4'h1, 1'b0, 1, 0);
        check_error_bit(7, "missing-word commit did not set ERR_PARAM_INCOMPLETE");
        for (i = 0; i < 8; i = i + 1) begin
            axi_read(12'h040 + i*16, 1, value);
            check(value == 32'h0, "failed commit changed active BIAS_Q");
            axi_read(12'h044 + i*16, 0, value);
            check(value == 32'h0, "failed commit changed active M0");
            axi_read(12'h048 + i*16, 1, value);
            check(value == 32'h0, "failed commit changed active SHIFT");
        end
        clear_errors();

        // Fill the missing word, then make one M0 illegal.  Again, active
        // parameters must remain at the old image.
        axi_write(12'h048 + 3*16, 32'h0000_0103, 4'hF, 1'b0, 2, 0);
        axi_write(12'h044 + 3*16, 32'h0, 4'hF, 1'b1, 1, 1);
        axi_write(12'h0C0, 32'h1, 4'h1, 1'b1, 0, 0);
        check_error_bit(0, "M0=0 commit did not set ERR_CFG_M0");
        for (i = 0; i < 8; i = i + 1) begin
            axi_read(12'h040 + i*16, 0, value);
            check(value == 32'h0, "M0 failure changed active BIAS_Q");
        end
        clear_errors();

        // A complete shadow image can still be written while BUSY, but the
        // commit itself is refused.
        busy = 1'b1;
        axi_write(12'h040, 32'hCAFE_0000, 4'hF, 1'b1, 4, 2);
        axi_write(12'h0C0, 32'h1, 4'h1, 1'b0, 1, 1);
        check_error_bit(3, "BUSY commit did not set ERR_CFG_WR_BUSY");
        axi_read(12'h040, 1, value);
        check(value == 32'h0, "BUSY shadow write incorrectly changed active BIAS_Q");
        busy = 1'b0;
        clear_errors();

        // Repair the invalid M0 and commit.  Distinct values prove that the
        // active copy is per-bank rather than accidentally broadcast.
        axi_write(12'h044 + 3*16, 32'h0001_0003, 4'hF, 1'b1, 1, 0);
        axi_write(12'h0C0, 32'h1, 4'h1, 1'b0, 2, 1);
        axi_read(12'h0C4, 1, value);
        check(value[24] && value[23:0] == 24'h0, "valid commit status mismatch");
        check(cfg_k_len == 75, "registered k_len mismatch after commit");
        for (i = 0; i < 8; i = i + 1) begin
            axi_read(12'h040 + i*16, 0, value);
            if (i == 0)
                check(value == 32'hCAFE_0000, "BUSY shadow write was not retained");
            else
                check(value == 32'h2000_0000 + i, "active BIAS_Q bank mismatch");
            axi_read(12'h044 + i*16, 1, value);
            check(value[17:0] == 18'h10000 + i, "active M0 bank mismatch");
            axi_read(12'h048 + i*16, 0, value);
            check(value[5:0] == ((i == 3) ? 6'd3 : 6'd1 + i),
                  "active SHIFT bank mismatch");
            check(value[8] == i[0], "active ReLU bank mismatch");
            check(cfg_m0[i] == (18'h10000 + i), "cfg_m0 output mismatch");
            check(cfg_bias_q[i] == ((i == 0) ? 32'shCAFE_0000 :
                                    $signed(32'h2000_0000 + i)),
                  "cfg_bias_q output mismatch");
        end

        // START now succeeds, and both control pulses are one-cycle events.
        axi_write(12'h004, 32'h1, 4'h1, 1'b0, 1, 0);
        check(start_seen == 1, "valid START was not emitted");
        axi_read(12'h004, 0, value);
        check(value[1:0] == 2'b00, "valid START did not self-clear");
        axi_write(12'h004, 32'h2, 4'h1, 1'b1, 2, 1);
        check(soft_seen == 1 && clear_seen == 1, "SOFT_RESET/counter_clear pulse missing");
        axi_read(12'h004, 1, value);
        check(value[1:0] == 2'b00, "SOFT_RESET did not self-clear");

        // PARAM_SRC=1 has a separate table-valid guard.  STATUS[4] exposes
        // the condition, while the normative ERR_PARAM_INCOMPLETE bit is
        // reused for the refused start.
        axi_write(12'h014, 32'h0002_0000, 4'hF, 1'b1, 0, 0);
        axi_read(12'h008, 1, value);
        check(!value[4], "TABLE_VALID unexpectedly asserted");
        axi_write(12'h004, 32'h1, 4'h1, 1'b1, 1, 0);
        check(start_seen == 1, "table-invalid START was emitted");
        check_error_bit(7, "table-invalid START did not set ERR_PARAM_INCOMPLETE");
        clear_errors();
        axi_write(12'h014, 32'h0, 4'hF, 1'b0, 2, 1);

        // DONE and every ERROR bit are W1C.  Holding the hardware event high
        // through the write exercises the set-and-clear-same-cycle rule.
        done = 1'b1;
        hw_error_set = 8'hFF;
        axi_write(12'h008, 32'h4, 4'h1, 1'b0, 3, 2);
        hw_error_set = 8'h0;
        done = 1'b0;
        axi_read(12'h008, 1, value);
        check(value[2] && value[3], "hardware-set DONE/ERROR was lost to W1C");
        axi_read(12'h00C, 0, value);
        check(value[7:0] == 8'hFF, "set-and-clear ERROR race was resolved incorrectly");
        axi_write(12'h008, 32'h4, 4'h1, 1'b1, 0, 0);
        axi_write(12'h00C, 32'hFF, 4'h1, 1'b0, 1, 1);
        axi_read(12'h008, 0, value);
        check(!value[2] && !value[3], "DONE/ERROR W1C did not clear");
        axi_read(12'h00C, 1, value);
        check(value[7:0] == 8'h0, "all ERROR bits did not clear");

        // Unmapped reads complete and return zero even with delayed RREADY.
        axi_read(12'h018, 5, value);
        check(value == 32'h0, "unmapped read did not return zero");

        // Reset in the middle of an AW-only transaction must discard it and
        // leave the slave immediately reusable.
        @(negedge clk);
        awaddr = 12'h010;
        awvalid = 1'b1;
        @(posedge clk);
        @(negedge clk);
        awvalid = 1'b0;
        rst_n = 1'b0;
        @(posedge clk);
        #1;
        rst_n = 1'b1;
        axi_write(12'h010, 32'hA5A5_5A5A, 4'hF, 1'b1, 0, 0);
        axi_read(12'h010, 1, value);
        check(value == 32'h25A5_5A5A, "LAYER_CFG[31] RAZ/WI failed");

        // The counters are direct datapath inputs and counter_clear is the
        // SOFT_RESET contract to their owner.
        axi_read(12'h100, 0, value); check(value == 123, "CYCLE_COUNT read mismatch");
        axi_read(12'h104, 1, value); check(value == 7, "STALL_IN read mismatch");
        axi_read(12'h108, 0, value); check(value == 9, "STALL_OUT read mismatch");
        axi_read(12'h10C, 1, value); check(value == 11, "FRAME_COUNT read mismatch");

        if (errors == 0)
            $display("PASS tb_axi_lite_regs");
        else
            $display("FAIL tb_axi_lite_regs: %0d errors", errors);
        $finish;
    end
endmodule
