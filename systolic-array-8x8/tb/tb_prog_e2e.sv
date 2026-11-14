`timescale 1ns/1ps

// Contract-section-6 interpreter.  It deliberately knows only program
// operations and the compact metadata file; it has no layer or geometry table.
module prog_replay_env #(
    parameter string PRIMARY = "np_v3",
    parameter string OPTIONAL = "",
    parameter string PASS_TAG = "tb_prog_e2e",
    parameter string PASS_DETAIL = ""
);
    localparam int MAX_WORDS = 8192;
    localparam int MAX_IMAGES = 32;
    localparam int POLL_LIMIT = 500000;

    logic aclk = 1'b0, aresetn = 1'b0;
    always #5 aclk = ~aclk;

    logic [11:0] s_axi_awaddr, s_axi_araddr;
    logic [2:0] s_axi_awprot, s_axi_arprot;
    logic s_axi_awvalid, s_axi_awready, s_axi_wvalid, s_axi_wready;
    logic [31:0] s_axi_wdata, s_axi_rdata;
    logic [3:0] s_axi_wstrb;
    logic [1:0] s_axi_bresp, s_axi_rresp;
    logic s_axi_bvalid, s_axi_bready, s_axi_arvalid, s_axi_arready;
    logic s_axi_rvalid, s_axi_rready;
    logic [63:0] s_axis_tdata, m_axis_tdata;
    logic [7:0] s_axis_tkeep, m_axis_tkeep;
    logic s_axis_tlast, s_axis_tvalid, s_axis_tready;
    logic m_axis_tlast, m_axis_tvalid, m_axis_tready;
    logic irq;

    logic [63:0] in_mem [0:MAX_WORDS-1];
    logic [63:0] exp_mem [0:MAX_WORDS-1];
    logic [63:0] got_mem [0:MAX_WORDS-1];
    logic [31:0] meta_mem [0:4*MAX_IMAGES+2];
    int meta_offset [0:MAX_IMAGES-1];
    int meta_nbeats [0:MAX_IMAGES-1];
    int meta_count [0:MAX_IMAGES-1];
    int meta_pred [0:MAX_IMAGES-1];

    logic [15:0] lfsr_s, lfsr_m;
    bit s_pending, m_pending, s_active, m_active, watch_output, leftover_reported;
    int errors, total_images, total_passes, total_beats;
    string predictions;

    accel_axis dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready), .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot), .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .s_axis_tdata(s_axis_tdata), .s_axis_tkeep(s_axis_tkeep),
        .s_axis_tlast(s_axis_tlast), .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .m_axis_tdata(m_axis_tdata), .m_axis_tkeep(m_axis_tkeep),
        .m_axis_tlast(m_axis_tlast), .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready), .irq(irq)
    );

    function automatic logic [15:0] lfsr_next(input logic [15:0] v);
        return {v[14:0], v[15] ^ v[13] ^ v[12] ^ v[10]};
    endfunction

    always @(posedge aclk) begin
        if (!aresetn) begin
            lfsr_s <= 16'hBEEF;
            lfsr_m <= 16'hACE1;
        end else begin
            lfsr_s <= lfsr_next(lfsr_s);
            lfsr_m <= lfsr_next(lfsr_m);
        end
    end

    task automatic fail(input string why);
        begin
            $display("FAIL %s: %s", PASS_TAG, why);
            errors++;
        end
    endtask

    always @(posedge aclk) begin
        if (aresetn && watch_output && m_axis_tvalid && !m_active && !leftover_reported) begin
            leftover_reported = 1'b1;
            fail($sformatf("unsolicited/leftover m_axis beat data=%016h last=%0b",
                           m_axis_tdata, m_axis_tlast));
        end
    end

    task automatic init_ports;
        begin
            s_axi_awaddr = '0; s_axi_awprot = '0; s_axi_awvalid = 1'b0;
            s_axi_wdata = '0; s_axi_wstrb = 4'h0; s_axi_wvalid = 1'b0;
            s_axi_bready = 1'b0; s_axi_araddr = '0; s_axi_arprot = '0;
            s_axi_arvalid = 1'b0; s_axi_rready = 1'b0;
            s_axis_tdata = '0; s_axis_tkeep = 8'hFF;
            s_axis_tlast = 1'b0; s_axis_tvalid = 1'b0;
            m_axis_tready = 1'b0;
            s_pending = 1'b0; m_pending = 1'b0;
            s_active = 1'b0; m_active = 1'b0; watch_output = 1'b0;
            leftover_reported = 1'b0;
        end
    endtask

    task automatic reset_dut;
        begin
            watch_output = 1'b0;
            aresetn = 1'b0;
            init_ports();
            repeat (6) @(negedge aclk);
            aresetn = 1'b1;
            repeat (2) @(negedge aclk);
            watch_output = 1'b1;
        end
    endtask

    task automatic axi_write(input logic [11:0] addr, input logic [31:0] data);
        int timeout;
        begin
            @(negedge aclk);
            s_axi_awaddr = addr; s_axi_awvalid = 1'b1;
            s_axi_wdata = data; s_axi_wstrb = 4'hF; s_axi_wvalid = 1'b1;
            s_axi_bready = 1'b0; timeout = 0;
            while (!(s_axi_awready && s_axi_wready) && timeout < 1000) begin
                @(posedge aclk); timeout++;
            end
            if (timeout == 1000) fail($sformatf("AXI write address timeout at %03h", addr));
            @(negedge aclk);
            s_axi_awvalid = 1'b0; s_axi_wvalid = 1'b0; s_axi_bready = 1'b1;
            timeout = 0;
            while (!s_axi_bvalid && timeout < 1000) begin
                @(posedge aclk); timeout++;
            end
            if (timeout == 1000) fail($sformatf("AXI write response timeout at %03h", addr));
            else if (s_axi_bresp != 2'b00)
                fail($sformatf("AXI BRESP=%0b at %03h", s_axi_bresp, addr));
            @(negedge aclk); s_axi_bready = 1'b0;
        end
    endtask

    task automatic axi_read(input logic [11:0] addr, output logic [31:0] data);
        int timeout;
        begin
            @(negedge aclk);
            s_axi_araddr = addr; s_axi_arvalid = 1'b1; s_axi_rready = 1'b0;
            timeout = 0;
            while (!s_axi_arready && timeout < 1000) begin
                @(posedge aclk); timeout++;
            end
            if (timeout == 1000) fail($sformatf("AXI read address timeout at %03h", addr));
            @(negedge aclk); s_axi_arvalid = 1'b0; s_axi_rready = 1'b1;
            timeout = 0;
            while (!s_axi_rvalid && timeout < 1000) begin
                @(posedge aclk); timeout++;
            end
            data = s_axi_rdata;
            if (timeout == 1000) fail($sformatf("AXI read response timeout at %03h", addr));
            else if (s_axi_rresp != 2'b00)
                fail($sformatf("AXI RRESP=%0b at %03h", s_axi_rresp, addr));
            @(negedge aclk); s_axi_rready = 1'b0;
        end
    endtask

    task automatic send_transfer(input int offset, input int nbeats);
        int beat;
        bit accepted;
        begin
            s_active = 1'b1; beat = 0; accepted = 1'b0;
            while (beat < nbeats) begin
                @(negedge aclk);
                if (accepted) begin s_axis_tvalid = 1'b0; accepted = 1'b0; end
                if (!s_axis_tvalid && lfsr_s[2:0] != 3'b000) begin
                    s_axis_tvalid = 1'b1;
                    s_axis_tdata = in_mem[offset + beat];
                    s_axis_tkeep = 8'hFF;
                    s_axis_tlast = (beat == nbeats - 1);
                end
                @(posedge aclk);
                if (s_axis_tvalid && s_axis_tready) begin beat++; accepted = 1'b1; end
            end
            @(negedge aclk);
            s_axis_tvalid = 1'b0; s_axis_tlast = 1'b0;
            s_active = 1'b0; s_pending = 1'b0;
        end
    endtask

    task automatic receive_transfer(input int offset, input int nbeats);
        int beat;
        begin
            m_active = 1'b1; leftover_reported = 1'b0; beat = 0;
            while (beat < nbeats) begin
                @(negedge aclk);
                m_axis_tready = (lfsr_m[2:0] != 3'b000);
                @(posedge aclk);
                if (m_axis_tvalid && m_axis_tready) begin
                    if (m_axis_tkeep !== 8'hFF)
                        fail($sformatf("M offset %0d beat %0d TKEEP=%02h", offset, beat, m_axis_tkeep));
                    if (m_axis_tlast !== (beat == nbeats - 1))
                        fail($sformatf("M offset %0d beat %0d TLAST=%0b expected=%0b",
                                       offset, beat, m_axis_tlast, beat == nbeats - 1));
                    got_mem[offset + beat] = m_axis_tdata;
                    if (m_axis_tdata !== exp_mem[offset + beat])
                        fail($sformatf("M offset %0d beat %0d data=%016h expected=%016h",
                                       offset, beat, m_axis_tdata, exp_mem[offset + beat]));
                    beat++; total_beats++;
                end
            end
            @(negedge aclk); m_axis_tready = 1'b0;
            m_active = 1'b0; m_pending = 1'b0;
        end
    endtask

    task automatic join_transfers;
        int timeout;
        begin
            timeout = 0;
            while ((s_pending || m_pending || s_active || m_active) && timeout < 2000000) begin
                @(negedge aclk); timeout++;
            end
            if (timeout == 2000000) fail("J transfer timeout");
            repeat (2) @(negedge aclk);
            if (s_axis_tvalid) fail("J left s_axis transfer active");
            if (m_axis_tvalid) fail("J found leftover m_axis transfer");
        end
    endtask

    function automatic int signed lane8(input logic [63:0] word, input int lane);
        logic signed [7:0] byte_value;
        begin byte_value = word[8*lane +: 8]; return int'(byte_value); end
    endfunction

    task automatic run_program(input string name);
        string base, line, op;
        integer fd, rc, fields, image_count, class_count;
        integer i, cidx, pred, best, value, polls;
        logic [31:0] a, b, c, read_value;
        begin
            base = {"../vectors/", name};
            $readmemh({base, "_in.mem"}, in_mem);
            $readmemh({base, "_exp.mem"}, exp_mem);
            $readmemh({base, "_meta.mem"}, meta_mem);
            if (meta_mem[0] !== 32'h4E504D31) begin
                fail({name, " bad metadata magic"});
                image_count = 0; class_count = 0;
            end else begin
                image_count = meta_mem[1]; class_count = meta_mem[2];
            end
            if (image_count < 1 || image_count > MAX_IMAGES || class_count < 1)
                fail($sformatf("%s invalid metadata images=%0d classes=%0d",
                               name, image_count, class_count));
            for (i = 0; i < image_count; i++) begin
                meta_offset[i] = meta_mem[3 + 4*i];
                meta_nbeats[i] = meta_mem[4 + 4*i];
                meta_count[i] = meta_mem[5 + 4*i];
                meta_pred[i] = meta_mem[6 + 4*i];
                for (cidx = 0; cidx < meta_nbeats[i]; cidx++)
                    got_mem[meta_offset[i] + cidx] = 'x;
            end

            fd = $fopen({base, ".prog"}, "r");
            if (fd == 0) begin
                fail({"cannot open ", base, ".prog"});
            end else begin
                while (!$feof(fd)) begin
                    line = ""; op = ""; a = '0; b = '0; c = '0;
                    rc = $fgets(line, fd);
                    fields = $sscanf(line, "%s %h %h %h", op, a, b, c);
                    if (fields > 0 && op.substr(0,0) != "#") begin
                        case (op)
                            "W": begin
                                if (fields != 3) fail({name, " malformed W: ", line});
                                else begin
                                    axi_write(a[11:0], b);
                                    if (a[11:0] == 12'h004 && b[0]) total_passes++;
                                end
                            end
                            "R": begin
                                if (fields != 4) fail({name, " malformed R: ", line});
                                else begin
                                    axi_read(a[11:0], read_value);
                                    if ((read_value & b) !== c)
                                        fail($sformatf("%s R %03h read=%08h mask=%08h expected=%08h",
                                                       name, a[11:0], read_value, b, c));
                                end
                            end
                            "P": begin
                                if (fields != 4) fail({name, " malformed P: ", line});
                                else begin
                                    polls = 0; read_value = '0;
                                    while (((read_value & b) !== c) && polls < POLL_LIMIT) begin
                                        axi_read(a[11:0], read_value); polls++;
                                    end
                                    if (polls == POLL_LIMIT)
                                        fail($sformatf("%s P timeout addr=%03h last=%08h mask=%08h expected=%08h",
                                                       name, a[11:0], read_value, b, c));
                                end
                            end
                            "S": begin
                                if (fields != 3 || b == 0) fail({name, " malformed S: ", line});
                                else if (s_pending || s_active) fail({name, " overlapping S transfer"});
                                else begin
                                    s_pending = 1'b1;
                                    fork send_transfer(int'(a), int'(b)); join_none
                                    // Let the child copy automatic arguments before
                                    // this parser reuses a/b for the next line.
                                    @(negedge aclk);
                                end
                            end
                            "M": begin
                                if (fields != 3 || b == 0) fail({name, " malformed M: ", line});
                                else if (m_pending || m_active) fail({name, " overlapping M transfer"});
                                else begin
                                    m_pending = 1'b1;
                                    fork receive_transfer(int'(a), int'(b)); join_none
                                    @(negedge aclk);
                                end
                            end
                            "J": begin
                                if (fields != 1) fail({name, " malformed J: ", line});
                                join_transfers();
                            end
                            default: fail({name, " unknown operation: ", line});
                        endcase
                    end
                end
                $fclose(fd);
            end
            join_transfers();

            for (i = 0; i < image_count; i++) begin
                if (meta_nbeats[i] != (meta_count[i] + 7) / 8) begin
                    fail($sformatf("%s image %0d inconsistent logit metadata", name, i));
                end else begin
                    pred = 0; best = lane8(got_mem[meta_offset[i]], 0);
                    for (cidx = 1; cidx < meta_count[i]; cidx++) begin
                        value = lane8(got_mem[meta_offset[i] + cidx/8], cidx%8);
                        if (value > best) begin best = value; pred = cidx; end
                    end
                    if (pred != meta_pred[i])
                        fail($sformatf("%s image %0d predicted=%0d expected=%0d",
                                       name, i, pred, meta_pred[i]));
                    predictions = {predictions, (total_images == 0 ? "" : ","),
                                   $sformatf("%0d", pred)};
                    total_images++;
                end
            end
        end
    endtask

    initial begin
        integer optional_fd;
        errors = 0; total_images = 0; total_passes = 0; total_beats = 0;
        predictions = "";
        init_ports();
        reset_dut();
        run_program(PRIMARY);
        if (OPTIONAL != "") begin
            optional_fd = $fopen({"../vectors/", OPTIONAL, ".prog"}, "r");
            if (optional_fd != 0) begin
                $fclose(optional_fd);
                reset_dut();
                run_program(OPTIONAL);
            end
        end
        watch_output = 1'b0;
        if (errors == 0)
            $display("PASS %s: images=%0d passes=%0d beats compared=%0d predicted classes=%s%s",
                     PASS_TAG, total_images, total_passes, total_beats, predictions, PASS_DETAIL);
        else
            $display("FAIL %s: errors=%0d", PASS_TAG, errors);
        $finish;
    end

    initial begin
        #5000000000;
        $display("FAIL %s: global timeout", PASS_TAG);
        $finish;
    end
endmodule

module tb_prog_e2e;
    // np_lenet is replayed when present; the DUT is reset before that program.
    prog_replay_env #(.PRIMARY("np_v3"), .OPTIONAL("np_lenet"),
                      .PASS_TAG("tb_prog_e2e")) env();
endmodule
