`timescale 1ns/1ps

// T_LAYOUT_ADDR_001. From addr=(((c>>3)*H+h)*W+w)*8+(c&7):
// (c=4,h=0,w=23,H=W=28) gives 23*8+4=188;
// (c=2,h=1,w=3,H=W=28) gives (28+3)*8+2=250.
module tb_act_buffer;
    logic clk=0;
    always #5 clk=~clk;
    logic rst_n=0;
    logic [4:0] cfg_out_h=28, cfg_out_w=28;
    logic [1:0] cfg_c_tile=0;
    logic in_valid=0, in_ready, in_last=0;
    logic [63:0] in_y_flat=0;
    logic [7:0] in_lane_valid=8'h3f;
    logic [3:0] in_col=0;
    logic rd_en=0, rd_valid;
    logic [9:0] rd_addr=0;
    logic [63:0] rd_data;
    logic buf_sel, seq_error, ovf_error;
    logic [31:0] frame_count;
    logic [63:0] expected0 [0:783], expected1 [0:783];
    integer errors=0, accepted=0, writes=0, setup_stalls=0;
    integer x, y, lane, held_stalls;
    logic [63:0] word_value;

    initial begin
        #200000;
        $fatal(1,"tb_act_buffer timeout");
    end

    act_buffer dut (.*);

    // A good accepted beat must issue exactly one write, to the active bank.
    // These counters have a plain procedural driver (XSim rejects a
    // scoreboard variable updated from always_ff plus a task).
    always @(posedge clk) if (rst_n) begin
        if (!in_ready) setup_stalls = setup_stalls + 1;
        if (in_valid && in_ready && !dut.bad_beat && dut.word_ptr < 784) begin
            accepted = accepted + 1;
            if (!dut.write_fire) begin
                $display("MISMATCH: accepted beat without word write");
                errors = errors + 1;
            end
        end
        if (dut.write_fire) begin
            writes = writes + 1;
            if (!(in_valid && in_ready)) begin
                $display("MISMATCH: write without handshake");
                errors = errors + 1;
            end
        end
    end

    task automatic reset_dut;
        @(negedge clk);
        rst_n=0; in_valid=0; rd_en=0; cfg_c_tile=0;
        repeat (3) @(negedge clk);
        rst_n=1;
    endtask

    task automatic send_beat(input integer frame, input integer h,
                             input integer w, input bit read_old);
        integer k;
        logic [63:0] value;
        bit ready_sample;
        begin
            value=0;
            for (k=0;k<8;k=k+1)
                value[k*8 +: 8]=(k*37+h*29+w*13+frame*71+1)&255;
            @(negedge clk);
            in_valid=1; in_y_flat=value; in_lane_valid=8'h3f;
            in_col=w%8; in_last=(h==27 && w==27);
            rd_en=read_old && ((w+h*28)%7 != 3);
            rd_addr=h*28+w;
            do begin
                @(posedge clk);
                ready_sample=in_ready;
                if (read_old && rd_en) begin
                    #1;
                    if (!rd_valid || rd_data !== expected0[h*28+w]) begin
                        $display("MISMATCH: ping-pong old frame at %0d,%0d: %h expected %h",
                                 h,w,rd_data,expected0[h*28+w]);
                        errors=errors+1;
                    end
                end
            end while (!ready_sample);
            @(negedge clk);
            in_valid=0; rd_en=0;
        end
    endtask

    task automatic send_frame(input integer frame, input bit read_old);
        integer h,w;
        begin
            for (h=0;h<28;h=h+1)
                for (w=0;w<28;w=w+1) begin
                    if ((frame==0 && w%5==0) || (frame==1 && w%3==0))
                        @(negedge clk);
                    send_beat(frame,h,w,read_old);
                end
        end
    endtask

    task automatic read_frame(input integer frame);
        integer addr;
        logic [63:0] want;
        begin
            for (addr=0;addr<784;addr=addr+1) begin
                if ((addr+frame)%11==0) @(negedge clk);
                @(negedge clk);
                rd_addr=addr; rd_en=1;
                @(posedge clk);
                #1;
                want=frame==0 ? expected0[addr] : expected1[addr];
                if (!rd_valid || rd_data !== want) begin
                    $display("MISMATCH: frame %0d word %0d got %h expected %h",
                             frame,addr,rd_data,want);
                    errors=errors+1;
                end
                if (rd_data[63:48] !== 16'b0) begin
                    $display("MISMATCH: masked lanes nonzero at %0d",addr);
                    errors=errors+1;
                end
                @(negedge clk); rd_en=0;
            end
        end
    endtask

    initial begin
        $readmemh("../vectors/actbuf_frame0.mem",expected0);
        $readmemh("../vectors/actbuf_frame1.mem",expected1);
        reset_dut();
        if (in_ready) begin
            $display("MISMATCH: ready asserted during frame setup"); errors=errors+1;
        end
        send_frame(0,0);
        if (frame_count !== 1 || buf_sel !== 1) begin
            $display("MISMATCH: first swap"); errors=errors+1;
        end
        read_frame(0);
        send_frame(1,1);
        if (frame_count !== 2 || buf_sel !== 0) begin
            $display("MISMATCH: second swap"); errors=errors+1;
        end
        read_frame(1);
        if (accepted != 1568 || writes != 1568 || setup_stalls < 2) begin
            $display("MISMATCH: accepted=%0d writes=%0d setup_stalls=%0d",
                     accepted,writes,setup_stalls); errors=errors+1;
        end

        // Keep a valid beat stable while the two setup stages deassert ready.
        // This exercises elastic backpressure separately from the two source
        // pacing / read-gap patterns used for the full frames above.
        reset_dut();
        cfg_out_h=1; cfg_out_w=1;
        in_valid=1; in_col=0; in_last=1;
        in_y_flat=expected0[0]; in_lane_valid=8'h3f;
        held_stalls=0;
        do begin
            @(posedge clk);
            if (!in_ready) held_stalls=held_stalls+1;
        end while (!in_ready);
        #1;
        if (held_stalls < 2 || frame_count != 1) begin
            $display("MISMATCH: elastic setup stall count=%0d frame_count=%0d",
                     held_stalls,frame_count); errors=errors+1;
        end
        @(negedge clk); in_valid=0; cfg_out_h=28; cfg_out_w=28;

        reset_dut();
        @(negedge clk); in_valid=1; in_col=1; in_last=0;
        do @(posedge clk); while (!in_ready);
        #1;
        if (!seq_error || dut.write_fire || frame_count != 0) begin
            $display("MISMATCH: sequence error handling"); errors=errors+1;
        end
        @(negedge clk); in_valid=0;
        if (in_ready) begin
            $display("MISMATCH: sequence error did not stop input"); errors=errors+1;
        end

        reset_dut();
        cfg_c_tile=1;
        @(negedge clk); in_valid=1; in_col=0; in_last=0;
        do @(posedge clk); while (!in_ready);
        #1;
        if (!ovf_error || frame_count != 0) begin
            $display("MISMATCH: overflow handling"); errors=errors+1;
        end
        @(negedge clk); in_valid=0;
        if (in_ready) begin
            $display("MISMATCH: overflow did not stop input"); errors=errors+1;
        end
        if (errors==0) $display("PASS: T_LAYOUT_ADDR_001, 2 frames, 1568 words, ping-pong, errors");
        else $display("FAIL: tb_act_buffer errors=%0d",errors);
        $finish;
    end
endmodule
