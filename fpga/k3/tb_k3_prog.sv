`timescale 1ns/1ps

// Kademe-3 contract-section-6 interpreter.  This testbench knows the program
// operations and compact metadata only; it has no CNN layer/geometry table.
module tb_k3_prog;
    localparam logic [31:0] ACCEL_BASE = 32'h43C0_0000;
    localparam logic [31:0] DMA_BASE   = 32'h4040_0000;
    localparam logic [31:0] SRC_DDR    = 32'h1000_0000;
    localparam logic [31:0] DST_DDR    = 32'h1100_0000;

    localparam logic [31:0] MM2S_DMACR  = 32'h00;
    localparam logic [31:0] MM2S_DMASR  = 32'h04;
    localparam logic [31:0] MM2S_SA     = 32'h18;
    localparam logic [31:0] MM2S_LENGTH = 32'h28;
    localparam logic [31:0] S2MM_DMACR  = 32'h30;
    localparam logic [31:0] S2MM_DMASR  = 32'h34;
    localparam logic [31:0] S2MM_DA     = 32'h48;
    localparam logic [31:0] S2MM_LENGTH = 32'h58;

    localparam int MAX_WORDS = 8192;
    localparam int MAX_IMAGES = 32;
    localparam int REG_POLL_LIMIT = 500000;
    localparam int BRINGUP_POLL_LIMIT = 1000;
    localparam int DMA_POLL_LIMIT = 2000;

    // Mutation acceptance changes this line in a scratch testbench copy.
    localparam int K3_EXPECT_BIAS_BYTES = 0;

    logic [63:0] in_mem [0:MAX_WORDS-1];
    logic [63:0] exp_mem [0:MAX_WORDS-1];
    logic [63:0] got_mem [0:MAX_WORDS-1];
    logic [63:0] hp_capture_mem [0:MAX_WORDS-1];
    logic [31:0] meta_mem [0:4*MAX_IMAGES+2];
    int meta_offset [0:MAX_IMAGES-1];
    int meta_nbeats [0:MAX_IMAGES-1];
    int meta_count [0:MAX_IMAGES-1];
    int meta_pred [0:MAX_IMAGES-1];

    logic [1023:0] vip_data;
    logic [1023:0] trace_sparse0, trace_sparse1, trace_sparse2;
    logic [1:0] vip_resp;
    int errors, total_images, total_passes, total_beats;
    int s_offset, s_nbeats, m_offset, m_nbeats;
    bit s_pending, m_pending;
    bit bringup_only;
    logic [31:0] m_dst_addr;
    string predictions;
    string program_base;
    logic [31:0] hp_aw_addr [0:15];
    logic [7:0] hp_aw_beats_left [0:15];
    logic [2:0] hp_aw_size [0:15];
    logic [1:0] hp_aw_burst [0:15];
    int hp_aw_head, hp_aw_tail, hp_aw_count;
    int hp_capture_bytes;
    integer hp_lane, hp_cap_index;
    logic [31:0] hp_beat_addr, hp_byte_addr;

    logic ps_porb_drv = 1'b0;
    logic ps_srstb_drv = 1'b0;
    wire ps_porb;
    wire ps_srstb;
    assign ps_porb = ps_porb_drv;
    assign ps_srstb = ps_srstb_drv;

    accel_bd_wrapper dut(
        .FIXED_IO_ps_porb(ps_porb),
        .FIXED_IO_ps_srstb(ps_srstb)
    );

    `define PS7 dut.accel_bd_i.processing_system7_0.inst

    task automatic fail(input string why);
        begin
            $display("K3-ERROR: %s", why);
            errors++;
        end
    endtask

    task automatic gp_write(input logic [31:0] address,
                            input logic [31:0] value);
        begin
            vip_data = '0;
            vip_data[31:0] = value;
            `PS7.write_data(address, 4, vip_data, vip_resp);
            if (vip_resp !== 2'b00)
                fail($sformatf("GP0 write address=%08h data=%08h response=%0h",
                               address, value, vip_resp));
        end
    endtask

    task automatic gp_read(input logic [31:0] address,
                           output logic [31:0] value);
        begin
            vip_data = '0;
            `PS7.read_data(address, 4, vip_data, vip_resp);
            value = vip_data[31:0];
            if (vip_resp !== 2'b00)
                fail($sformatf("GP0 read address=%08h response=%0h", address, vip_resp));
        end
    endtask

    task automatic accel_write(input logic [31:0] offset,
                               input logic [31:0] value);
        gp_write(ACCEL_BASE + offset, value);
    endtask

    task automatic accel_read(input logic [31:0] offset,
                              output logic [31:0] value);
        gp_read(ACCEL_BASE + offset, value);
    endtask

    task automatic dma_write(input logic [31:0] offset,
                             input logic [31:0] value);
        gp_write(DMA_BASE + offset, value);
    endtask

    task automatic dma_read(input logic [31:0] offset,
                            output logic [31:0] value);
        gp_read(DMA_BASE + offset, value);
    endtask

    task automatic ddr_write_word(input logic [31:0] address,
                                  input logic [63:0] value);
        begin
            vip_data = '0;
            vip_data[63:0] = value;
            `PS7.write_mem(vip_data, address, 8);
        end
    endtask

    task automatic ddr_read_word(input logic [31:0] address,
                                 output logic [63:0] value);
        logic [1023:0] read_data;
        begin
            read_data = 'x;
            // Public PS7 VIP API order is address, byte count, output data.
            `PS7.read_mem(address, 8, read_data);
            value = read_data[63:0];
        end
    endtask

    task automatic pl_reset;
        begin
            `PS7.fpga_soft_reset(32'h0000_0001);
            #200;
            `PS7.fpga_soft_reset(32'h0000_0000);
            #1000;
        end
    endtask

    task automatic start_mm2s(input int offset, input int nbeats);
        int beat;
        begin
            if (s_pending) begin
                fail("overlapping S transfer");
            end else begin
                for (beat = 0; beat < nbeats; beat++)
                    ddr_write_word(SRC_DDR + 8*beat, in_mem[offset + beat]);
                dma_write(MM2S_DMASR, 32'h0000_1000);
                dma_write(MM2S_DMACR, 32'h0000_1001);
                dma_write(MM2S_SA, SRC_DDR);
                dma_write(MM2S_LENGTH, 8*nbeats);
                s_offset = offset;
                s_nbeats = nbeats;
                s_pending = 1'b1;
            end
        end
    endtask

    task automatic start_s2mm(input int offset, input int nbeats,
                              input logic [31:0] destination);
        int beat;
        begin
            if (m_pending) begin
                fail("overlapping M transfer");
            end else begin
                if (hp_aw_count != 0)
                    fail($sformatf("HP0 capture has %0d unfinished bursts", hp_aw_count));
                for (beat = 0; beat < nbeats; beat++)
                    hp_capture_mem[beat] = 'x;
                hp_capture_bytes = 0;
                dma_write(S2MM_DMASR, 32'h0000_1000);
                dma_write(S2MM_DMACR, 32'h0000_1001);
                dma_write(S2MM_DA, destination);
                dma_write(S2MM_LENGTH, 8*nbeats);
                m_offset = offset;
                m_nbeats = nbeats;
                m_dst_addr = destination;
                m_pending = 1'b1;
            end
        end
    endtask

    task automatic wait_dma_channel(input bit is_s2mm,
                                    output logic [31:0] status);
        int polls;
        logic [31:0] status_offset;
        begin
            status_offset = is_s2mm ? S2MM_DMASR : MM2S_DMASR;
            status = '0;
            polls = 0;
            while (!status[1] && polls < DMA_POLL_LIMIT) begin
                dma_read(status_offset, status);
                polls++;
            end
            if (!status[1])
                fail($sformatf("%s DMA timeout/hang status=%08h polls=%0d",
                               is_s2mm ? "S2MM" : "MM2S", status, polls));
            if ((status & 32'h0000_0770) != 0)
                fail($sformatf("%s DMA error status=%08h",
                               is_s2mm ? "S2MM" : "MM2S", status));
            if (!status[12])
                fail($sformatf("%s DMA completed without IOC status=%08h",
                               is_s2mm ? "S2MM" : "MM2S", status));
        end
    endtask

    task automatic join_transfers;
        logic [31:0] status, received_bytes;
        logic [63:0] word;
        int beat, expected_bytes;
        begin
            if (s_pending) begin
                wait_dma_channel(1'b0, status);
                s_pending = 1'b0;
            end
            if (m_pending) begin
                wait_dma_channel(1'b1, status);
                dma_read(S2MM_LENGTH, received_bytes);
                expected_bytes = 8*m_nbeats + K3_EXPECT_BIAS_BYTES;
                $display("K3_S2MM_BYTES: offset=%0d expected=%0d received=%0d status=%08h",
                         m_offset, expected_bytes, received_bytes, status);
                if (received_bytes != expected_bytes)
                    fail($sformatf("S2MM length offset=%0d received=%0d expected=%0d",
                                   m_offset, received_bytes, expected_bytes));
                if (hp_capture_bytes != 8*m_nbeats)
                    fail($sformatf("HP0 capture bytes offset=%0d received=%0d expected=%0d",
                                   m_offset, hp_capture_bytes, 8*m_nbeats));
                for (beat = 0; beat < m_nbeats; beat++) begin
                    word = hp_capture_mem[beat];
                    got_mem[m_offset + beat] = word;
                    if (word !== exp_mem[m_offset + beat])
                        fail($sformatf("M offset=%0d beat=%0d data=%016h expected=%016h",
                                       m_offset, beat, word, exp_mem[m_offset + beat]));
                    total_beats++;
                end
                m_pending = 1'b0;
            end
        end
    endtask

    // Permanent transport pre-check: 1x1 convolution, C_IN=8, one input beat,
    // one output beat.  Lane 0 has weight 1 and identity requantization;
    // inactive output lanes are masked to zero by LAST_ROWS=1.
    task automatic dma_accel_bringup(input int trial,
                                     input logic [31:0] destination,
                                     input logic [63:0] input_word);
        logic [31:0] value;
        logic [63:0] ddr_word;
        int bank, k, polls;
        begin
            $display("K3_BRINGUP: trial=%0d starting addr=%08h data=%016h",
                     trial, destination, input_word);
            accel_read(32'h000, value);
            if (value !== 32'h0001_0005)
                fail($sformatf("bring-up VERSION=%08h expected=00010005", value));
            for (bank = 0; bank < 8; bank++) begin
                accel_write(32'h028, bank << 16);
                for (k = 0; k < 8; k++)
                    accel_write(32'h02C, (bank == 0 && k == 0) ? 1 : 0);
            end
            accel_write(32'h010, 32'h0208_9208); // W=H=1, stride=1, K=1x1, C_IN=8
            accel_write(32'h018, 32'd8);
            accel_write(32'h01C, 32'd0);
            accel_write(32'h014, 32'h0004_0100); // tile 0/1, LAST_ROWS=1
            accel_write(32'h020, 32'h0000_0004); // external source, stream destination
            for (bank = 0; bank < 8; bank++) begin
                accel_write(32'h040 + 16*bank, 32'd0);
                accel_write(32'h044 + 16*bank, 32'd65536);
                accel_write(32'h048 + 16*bank, 32'd16);
            end
            accel_write(32'h0C0, 32'd1);
            in_mem[trial] = input_word;
            exp_mem[trial] = input_word;
            start_s2mm(trial, 1, destination);
            start_mm2s(trial, 1);
            accel_write(32'h004, 32'd1);
            value = '0;
            polls = 0;
            while (!value[2] && !value[3] && !value[5] &&
                   polls < BRINGUP_POLL_LIMIT) begin
                accel_read(32'h008, value);
                polls++;
            end
            if (!value[2] || value[3] || value[5]) begin
                fail($sformatf("bring-up accelerator STATUS=%08h polls=%0d", value, polls));
                accel_read(32'h00C, value);
                $display("K3_BRINGUP_DIAG: ERROR=%08h", value);
                accel_read(32'h024, value);
                $display("K3_BRINGUP_DIAG: ERR_DETAIL=%08h", value);
                dma_read(MM2S_DMASR, value);
                $display("K3_BRINGUP_DIAG: MM2S_DMASR=%08h", value);
                dma_read(S2MM_DMASR, value);
                $display("K3_BRINGUP_DIAG: S2MM_DMASR=%08h", value);
            end
            join_transfers();
            if (bringup_only) begin
                ddr_read_word(destination, ddr_word);
                $display("K3_DDR_READ: trial=%0d time=%0t addr=%08h data=%016h expected=%016h",
                         trial, $time, destination, ddr_word, input_word);
            end
            accel_read(32'h00C, value);
            if (value[7:0] != 0)
                fail($sformatf("bring-up accelerator ERROR=%08h", value));
            if (got_mem[trial] !== input_word)
                fail($sformatf("bring-up trial=%0d result=%016h expected=%016h",
                               trial, got_mem[trial], input_word));
            if (errors == 0)
                $display("K3_BRINGUP: PASS trial=%0d bytes=8 data=%016h",
                         trial, got_mem[trial]);
            accel_write(32'h008, 32'd4);
        end
    endtask

    function automatic int signed lane8(input logic [63:0] word, input int lane);
        logic signed [7:0] byte_value;
        begin
            byte_value = word[8*lane +: 8];
            return int'(byte_value);
        end
    endfunction

    task automatic run_program;
        string line, op;
        integer fd, rc, fields, image_count, class_count;
        integer i, cidx, pred, best, sample, polls;
        logic [31:0] a, b, c, read_value;
        begin
            $readmemh({program_base, "_in.mem"}, in_mem);
            $readmemh({program_base, "_exp.mem"}, exp_mem);
            $readmemh({program_base, "_meta.mem"}, meta_mem);
            if (meta_mem[0] !== 32'h4E504D31) begin
                fail("bad metadata magic");
                image_count = 0;
                class_count = 0;
            end else begin
                image_count = meta_mem[1];
                class_count = meta_mem[2];
            end
            if (image_count < 1 || image_count > MAX_IMAGES || class_count < 1)
                fail($sformatf("invalid metadata images=%0d classes=%0d",
                               image_count, class_count));
            for (i = 0; i < image_count; i++) begin
                meta_offset[i] = meta_mem[3 + 4*i];
                meta_nbeats[i] = meta_mem[4 + 4*i];
                meta_count[i] = meta_mem[5 + 4*i];
                meta_pred[i] = meta_mem[6 + 4*i];
                for (cidx = 0; cidx < meta_nbeats[i]; cidx++)
                    got_mem[meta_offset[i] + cidx] = 'x;
            end

            fd = $fopen({program_base, ".prog"}, "r");
            if (fd == 0) begin
                fail({"cannot open ", program_base, ".prog"});
            end else begin
                while (!$feof(fd)) begin
                    line = "";
                    op = "";
                    a = '0;
                    b = '0;
                    c = '0;
                    rc = $fgets(line, fd);
                    fields = $sscanf(line, "%s %h %h %h", op, a, b, c);
                    if (fields > 0 && op.substr(0,0) != "#") begin
                        case (op)
                            "W": begin
                                if (fields != 3) fail({"malformed W: ", line});
                                else begin
                                    accel_write(a, b);
                                    if (a == 32'h004 && b[0]) total_passes++;
                                end
                            end
                            "R": begin
                                if (fields != 4) fail({"malformed R: ", line});
                                else begin
                                    accel_read(a, read_value);
                                    if ((read_value & b) !== c)
                                        fail($sformatf("R %03h read=%08h mask=%08h expected=%08h",
                                                       a, read_value, b, c));
                                end
                            end
                            "P": begin
                                if (fields != 4) fail({"malformed P: ", line});
                                else begin
                                    polls = 0;
                                    read_value = '0;
                                    while (((read_value & b) !== c) && polls < REG_POLL_LIMIT) begin
                                        accel_read(a, read_value);
                                        polls++;
                                    end
                                    if (polls == REG_POLL_LIMIT)
                                        fail($sformatf("P timeout addr=%03h last=%08h mask=%08h expected=%08h",
                                                       a, read_value, b, c));
                                end
                            end
                            "S": begin
                                if (fields != 3 || b == 0) fail({"malformed S: ", line});
                                else start_mm2s(int'(a), int'(b));
                            end
                            "M": begin
                                if (fields != 3 || b == 0) fail({"malformed M: ", line});
                                else start_s2mm(int'(a), int'(b), DST_DDR);
                            end
                            "J": begin
                                if (fields != 1) fail({"malformed J: ", line});
                                join_transfers();
                            end
                            default: fail({"unknown operation: ", line});
                        endcase
                    end
                end
                $fclose(fd);
            end
            join_transfers();

            for (i = 0; i < image_count; i++) begin
                if (meta_nbeats[i] != (meta_count[i] + 7) / 8) begin
                    fail($sformatf("image %0d inconsistent logit metadata", i));
                end else begin
                    pred = 0;
                    best = lane8(got_mem[meta_offset[i]], 0);
                    for (cidx = 1; cidx < meta_count[i]; cidx++) begin
                        sample = lane8(got_mem[meta_offset[i] + cidx/8], cidx%8);
                        if (sample > best) begin
                            best = sample;
                            pred = cidx;
                        end
                    end
                    if (pred != meta_pred[i])
                        fail($sformatf("image %0d predicted=%0d expected=%0d",
                                       i, pred, meta_pred[i]));
                    predictions = {predictions, (total_images == 0 ? "" : ","),
                                   $sformatf("%0d", pred)};
                    total_images++;
                end
            end
        end
    endtask

    initial begin
        errors = 0;
        total_images = 0;
        total_passes = 0;
        total_beats = 0;
        s_pending = 1'b0;
        m_pending = 1'b0;
        hp_aw_head = 0;
        hp_aw_tail = 0;
        hp_aw_count = 0;
        hp_capture_bytes = 0;
        m_dst_addr = DST_DDR;
        predictions = "";
        bringup_only = $test$plusargs("K3_BRINGUP_ONLY");
        if (!$value$plusargs("PROG_BASE=%s", program_base))
            program_base = "k3_program";

        `PS7.set_debug_level_info(1'b0);
        `PS7.set_slave_profile("S_AXI_HP0", 2'b00);
        force dut.accel_bd_i.rst_ps7_0_100M_peripheral_aresetn = 1'b0;
        // FIXED_IO POR/SRSTB drive the PS7 VIP's GP0/HP0 transaction-state
        // resets; fpga_soft_reset alone only resets the PL-facing fabric.
        `PS7.fpga_soft_reset(32'h0000_0001);
        #500;
        ps_porb_drv = 1'b1;
        ps_srstb_drv = 1'b1;
        #500;
        `PS7.fpga_soft_reset(32'h0000_0000);
        #500;
        release dut.accel_bd_i.rst_ps7_0_100M_peripheral_aresetn;
        #500;
        if (bringup_only) begin
            // Three distinct values to one location, followed by writes to two
            // distinct locations.  This isolates any one-transaction commit lag.
            dma_accel_bringup(0, DST_DDR,      64'h0000_0000_0000_0011);
            dma_accel_bringup(1, DST_DDR,      64'h0000_0000_0000_0022);
            dma_accel_bringup(2, DST_DDR,      64'h0000_0000_0000_0033);
            dma_accel_bringup(3, DST_DDR + 8,  64'h0000_0000_0000_0044);
            dma_accel_bringup(4, DST_DDR + 16, 64'h0000_0000_0000_0055);
        end else begin
            dma_accel_bringup(0, DST_DDR, 64'h0000_0000_0000_0005);
            pl_reset();
            s_pending = 1'b0;
            m_pending = 1'b0;
            run_program();
        end

        if (errors == 0 && bringup_only)
            $display("PASS tb_k3_prog: bringup transfers=5 beats compared=%0d",
                     total_beats);
        else if (errors == 0)
            $display("PASS tb_k3_prog: images=%0d passes=%0d beats compared=%0d predicted classes=%s",
                     total_images, total_passes, total_beats, predictions);
        else
            $display("FAIL tb_k3_prog: errors=%0d", errors);
        $finish;
    end

    initial begin
        #(64'd5000000000);
        $display("FAIL tb_k3_prog: global timeout");
        $finish;
    end

    always @(posedge dut.accel_bd_i.processing_system7_0_FCLK_CLK0) begin
        if (dut.accel_bd_i.axi_mem_ic_M00_AXI_AWVALID &&
            dut.accel_bd_i.axi_mem_ic_M00_AXI_AWREADY) begin
            $display("K3_HP_WRITE: AW addr=%08h len=%0d size=%0d id=%0h",
                     dut.accel_bd_i.axi_mem_ic_M00_AXI_AWADDR,
                     dut.accel_bd_i.axi_mem_ic_M00_AXI_AWLEN,
                     dut.accel_bd_i.axi_mem_ic_M00_AXI_AWSIZE,
                     dut.accel_bd_i.axi_mem_ic_M00_AXI_AWID);
            if (hp_aw_count == 16) begin
                fail("HP0 capture AW queue overflow");
            end else begin
                hp_aw_addr[hp_aw_tail] = dut.accel_bd_i.axi_mem_ic_M00_AXI_AWADDR;
                hp_aw_beats_left[hp_aw_tail] = dut.accel_bd_i.axi_mem_ic_M00_AXI_AWLEN;
                hp_aw_size[hp_aw_tail] = dut.accel_bd_i.axi_mem_ic_M00_AXI_AWSIZE;
                hp_aw_burst[hp_aw_tail] = dut.accel_bd_i.axi_mem_ic_M00_AXI_AWBURST;
                hp_aw_tail = (hp_aw_tail + 1) % 16;
                hp_aw_count = hp_aw_count + 1;
            end
        end
        if (dut.accel_bd_i.axi_mem_ic_M00_AXI_WVALID &&
            dut.accel_bd_i.axi_mem_ic_M00_AXI_WREADY) begin
            $display("K3_HP_WRITE: W data=%016h strb=%02h last=%b id=%0h",
                     dut.accel_bd_i.axi_mem_ic_M00_AXI_WDATA,
                     dut.accel_bd_i.axi_mem_ic_M00_AXI_WSTRB,
                     dut.accel_bd_i.axi_mem_ic_M00_AXI_WLAST,
                     dut.accel_bd_i.axi_mem_ic_M00_AXI_WID);
            if (hp_aw_count == 0) begin
                fail("HP0 capture saw W without AW");
            end else begin
                hp_beat_addr = hp_aw_addr[hp_aw_head];
                if (dut.accel_bd_i.axi_mem_ic_M00_AXI_WLAST !==
                    (hp_aw_beats_left[hp_aw_head] == 0))
                    fail($sformatf("HP0 WLAST mismatch addr=%08h beats_left=%0d last=%b",
                                   hp_beat_addr, hp_aw_beats_left[hp_aw_head],
                                   dut.accel_bd_i.axi_mem_ic_M00_AXI_WLAST));
                for (hp_lane = 0; hp_lane < 8; hp_lane = hp_lane + 1) begin
                    if (dut.accel_bd_i.axi_mem_ic_M00_AXI_WSTRB[hp_lane]) begin
                        // AXI byte lanes are relative to the aligned bus word;
                        // WSTRB controls exactly which captured bytes change.
                        hp_byte_addr = {hp_beat_addr[31:3], 3'b000} + hp_lane;
                        if (hp_byte_addr >= m_dst_addr &&
                            hp_byte_addr < m_dst_addr + 8*MAX_WORDS) begin
                            hp_cap_index = (hp_byte_addr - m_dst_addr) >> 3;
                            hp_capture_mem[hp_cap_index]
                                [8*hp_byte_addr[2:0] +: 8] =
                                dut.accel_bd_i.axi_mem_ic_M00_AXI_WDATA
                                [8*hp_lane +: 8];
                            hp_capture_bytes = hp_capture_bytes + 1;
                        end
                    end
                end
                if (hp_aw_beats_left[hp_aw_head] == 0) begin
                    hp_aw_head = (hp_aw_head + 1) % 16;
                    hp_aw_count = hp_aw_count - 1;
                end else begin
                    hp_aw_beats_left[hp_aw_head] =
                        hp_aw_beats_left[hp_aw_head] - 1;
                    case (hp_aw_burst[hp_aw_head])
                        2'b00: hp_aw_addr[hp_aw_head] = hp_aw_addr[hp_aw_head];
                        2'b01: hp_aw_addr[hp_aw_head] = hp_aw_addr[hp_aw_head]
                                                      + (1 << hp_aw_size[hp_aw_head]);
                        default: fail($sformatf("HP0 unsupported AWBURST=%0b",
                                                hp_aw_burst[hp_aw_head]));
                    endcase
                end
            end
        end
        if (bringup_only &&
            dut.accel_bd_i.axi_mem_ic_M00_AXI_BVALID &&
            dut.accel_bd_i.axi_mem_ic_M00_AXI_BREADY)
            $display("K3_HP_WRITE: B time=%0t resp=%0h id=%0h",
                     $time, dut.accel_bd_i.axi_mem_ic_M00_AXI_BRESP,
                     dut.accel_bd_i.axi_mem_ic_M00_AXI_BID);
    end

    // Instrument the real PS7 VIP path.  HP0 is routed through DDR arbiter
    // port 1; the final probe watches the exact sparse-memory words read by
    // the public read_mem API.
    always @(posedge `PS7.net_wr_dv_ddr_hp0)
        if (bringup_only)
            $display("K3_VIP_HP_FIFO: time=%0t addr=%08h bytes=%0d data=%016h strb=%02h",
                     $time, `PS7.net_wr_addr_hp0, `PS7.net_wr_bytes_hp0,
                     `PS7.net_wr_data_hp0[63:0], `PS7.net_wr_strb_hp0[7:0]);

    always @(`PS7.ddr_wr_dv_port1)
        if (bringup_only)
            $display("K3_VIP_AFI_PORT1: time=%0t valid=%b addr=%08h bytes=%0d data=%016h strb=%02h",
                     $time, `PS7.ddr_wr_dv_port1, `PS7.ddr_wr_addr_port1,
                     `PS7.ddr_wr_bytes_port1, `PS7.ddr_wr_data_port1[63:0],
                     `PS7.ddr_wr_strb_port1[7:0]);

    always @(posedge `PS7.ddrc.wr_req)
        if (bringup_only)
            $display("K3_VIP_DDR_REQ: time=%0t addr=%08h bytes=%0d data=%016h strb=%02h",
                     $time, `PS7.ddrc.wr_addr, `PS7.ddrc.wr_bytes,
                     `PS7.ddrc.wr_data[63:0], `PS7.ddrc.wr_strb[7:0]);

    always @(posedge `PS7.ddrc.wr_ack) begin
        if (bringup_only) begin
            // wr_ack is assigned after the blocking sparse write_mem call.
            // One time unit avoids the active/NBA-region ambiguity of the ack.
            #1;
            trace_sparse0 = 'x;
            trace_sparse1 = 'x;
            trace_sparse2 = 'x;
            `PS7.ddrc.ddr.read_mem(trace_sparse0, DST_DDR, 8);
            `PS7.ddrc.ddr.read_mem(trace_sparse1, DST_DDR + 8, 8);
            `PS7.ddrc.ddr.read_mem(trace_sparse2, DST_DDR + 16, 8);
            $display("K3_VIP_SPARSE_POST_ACK: time=%0t d0=%016h d8=%016h d10=%016h",
                     $time, trace_sparse0[63:0], trace_sparse1[63:0],
                     trace_sparse2[63:0]);
        end
    end

endmodule
