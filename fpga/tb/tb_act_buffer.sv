`timescale 1ns/1ps

// act_buffer unit test (faz4 contract, section 3).
//
// Producer view: a write pass carries one tile plane in raster order; byte
// lane r of the word for tile t at (h,w) is channel 8t+r.  Reference view:
// the expected read stream is built from an HWC byte array with
// c_phys = 8*T, hwc[(h*W+w)*C + c], cut into 64-bit words.  The two views
// share only the byte value function val(), so a read in tile-major order
// (the K1 defect) or any other permutation fails word by word.
//
// Coverage: multi-tile writes in scrambled tile order, cfg inputs changed
// right after wr_start (sampling), swap, three replays, LFSR-random wr_valid
// and rd_ready, rd_ready=1 throughput, a write of the next layer during a
// read, tiles=1 and a 48x48x2 layer filling DEPTH exactly, busy-command and
// configuration errors, soft_reset in the middle of a read and of a write.
// Layer completeness: swap without any write, with a tile missing, after an
// aborted pass, mixed geometry inside a layer, tile rewrite; rd_geom_* after
// every swap and unchanged by rejected swaps and soft_reset.
// The vectors under ../vectors are not used: the reference is in this file.
module tb_act_buffer;
    localparam int MAXW = 4608;
    logic clk=0;
    always #5 clk=~clk;
    logic rst_n=0, soft_reset=0;
    logic wr_start=0, wr_valid=0, wr_ready, wr_done;
    logic [5:0] cfg_wr_h=0, cfg_wr_w=0;
    logic [4:0] cfg_wr_tile=0, cfg_wr_tiles=0;
    logic [63:0] wr_data=0;
    logic layer_swap=0, rd_start=0, rd_valid, rd_ready=0, rd_last;
    logic [63:0] rd_data;
    logic rd_busy, wr_busy, buf_sel, seq_error, ovf_error;
    logic [31:0] frame_count;
    logic rd_geom_valid;
    logic [5:0] rd_geom_h, rd_geom_w;
    logic [4:0] rd_geom_tiles;
    // Expected rd_geom_*: what the last accepted swap handed over.
    logic g_v=0;
    integer g_h=0, g_w=0, g_t=0;

    act_buffer dut (.*);

    logic [7:0] hwc [0:MAXW*8-1];
    logic [63:0] exp_words [0:MAXW-1];
    logic [15:0] wlfsr=16'hACE1, rlfsr=16'h1D0B;
    integer errors=0, cyc=0, rd_idx=0, exp_n=0, chk_en=0, rd_mode=0;
    integer first_hs=0, last_hs=0, start_cyc=0, wr_done_cnt=0, passes=0;
    logic stall_v=0, stall_l;
    logic [63:0] stall_d;

    initial begin
        #5000000;
        $fatal(1,"tb_act_buffer timeout");
    end

    function automatic logic [7:0] val(input integer layer, input integer c,
                                       input integer h, input integer w);
        val = 8'(layer*113 + c*37 + h*59 + w*17 + (c*h + c*w)*3 + 5) ^ 8'(layer<<5);
    endfunction

    function automatic logic [63:0] tile_word(input integer layer, input integer t,
                                              input integer h, input integer w);
        integer r;
        for (r=0;r<8;r=r+1) tile_word[r*8 +: 8] = val(layer,8*t+r,h,w);
    endfunction

    function automatic logic [15:0] step(input logic [15:0] s);
        step = {s[14:0], s[15]^s[13]^s[12]^s[10]};
    endfunction

    // rd_ready: mode 0 always 1, mode 1 LFSR ~50%, mode 2 LFSR ~25%.
    always @(negedge clk) begin
        rlfsr = step(rlfsr);
        rd_ready = (rd_mode==0) ? 1'b1 : (rd_mode==1) ? rlfsr[0] : (rlfsr[0] & rlfsr[3]);
    end

    // Read scoreboard and AXI-stream stability.  Sampled at the edge, before
    // the DUT's nonblocking updates.  A word held under backpressure must not
    // change; every handshake is checked in order against exp_words, so a
    // lost, duplicated or reordered word is a mismatch.
    always @(posedge clk) begin
        if (rst_n && stall_v && (!rd_valid || rd_data !== stall_d || rd_last !== stall_l)) begin
            $display("MISMATCH: read beat changed under backpressure at cycle %0d",cyc);
            errors = errors + 1;
        end
        stall_v = rst_n && !soft_reset && rd_valid && !rd_ready;
        stall_d = rd_data;
        stall_l = rd_last;
        if (rst_n && rd_start) start_cyc = cyc;
        if (rst_n && rd_valid && rd_ready) begin
            if (!chk_en) begin
                $display("MISMATCH: unexpected read word %h at cycle %0d",rd_data,cyc);
                errors = errors + 1;
            end else if (rd_idx >= exp_n) begin
                $display("MISMATCH: extra read word %0d (stream has %0d)",rd_idx,exp_n);
                errors = errors + 1;
            end else begin
                if (rd_data !== exp_words[rd_idx]) begin
                    $display("MISMATCH: read word %0d got %h expected %h",
                             rd_idx,rd_data,exp_words[rd_idx]);
                    errors = errors + 1;
                end
                if (rd_last !== (rd_idx == exp_n-1)) begin
                    $display("MISMATCH: rd_last=%b at word %0d of %0d",rd_last,rd_idx,exp_n);
                    errors = errors + 1;
                end
            end
            if (rd_idx == 0) first_hs = cyc;
            last_hs = cyc;
            rd_idx = rd_idx + 1;
        end
        if (rst_n && wr_done) wr_done_cnt = wr_done_cnt + 1;
        cyc = cyc + 1;
    end

    task automatic fail(input string msg);
        $display("MISMATCH: %s",msg);
        errors = errors + 1;
    endtask

    // Expected HWC stream of a stored layer, from the byte-level definition.
    task automatic build_expected(input integer layer, input integer H,
                                  input integer W, input integer T);
        integer h, w, c, j, r;
        for (h=0;h<H;h=h+1)
            for (w=0;w<W;w=w+1)
                for (c=0;c<8*T;c=c+1)
                    hwc[(h*W+w)*8*T + c] = val(layer,c,h,w);
        for (j=0;j<H*W*T;j=j+1)
            for (r=0;r<8;r=r+1)
                exp_words[j][r*8 +: 8] = hwc[8*j+r];
        exp_n = H*W*T;
    endtask

    task automatic pulse(ref logic sig);
        @(negedge clk); sig = 1;
        @(negedge clk); sig = 0;
    endtask

    task automatic do_soft_reset;
        pulse(soft_reset);
        if (seq_error !== 0 || ovf_error !== 0 || wr_busy !== 0 || rd_busy !== 0)
            fail("soft_reset did not clear errors / busy");
    endtask

    // One tile pass.  rnd selects LFSR-paced wr_valid (held until accepted).
    // The cfg inputs are scrambled right after wr_start to prove sampling.
    task automatic write_pass(input integer layer, input integer H, input integer W,
                              input integer tile, input integer T, input bit rnd);
        integer i, h, w, done0, guard;
        bit fire;
        done0 = wr_done_cnt;
        @(negedge clk);
        cfg_wr_h = H; cfg_wr_w = W; cfg_wr_tile = tile; cfg_wr_tiles = T;
        wr_start = 1;
        @(negedge clk);
        wr_start = 0;
        cfg_wr_h = 0; cfg_wr_w = 63; cfg_wr_tile = 31; cfg_wr_tiles = 0;
        if (wr_ready !== 0 || wr_busy !== 1) fail("wr_ready high / wr_busy low in write setup");
        i = 0; h = 0; w = 0; guard = 0;
        while (i < H*W && guard < H*W*20+100) begin
            guard = guard + 1;
            if (!wr_valid) begin
                wlfsr = step(wlfsr);
                if (!rnd || wlfsr[0]) begin
                    wr_valid = 1;
                    wr_data = tile_word(layer,tile,h,w);
                end
            end
            @(posedge clk);
            fire = wr_valid && wr_ready;
            @(negedge clk);
            if (fire) begin
                wr_valid = 0;
                wr_data = 'x;
                i = i + 1;
                if (w == W-1) begin w = 0; h = h + 1; end
                else w = w + 1;
            end
        end
        wr_valid = 0;
        if (i != H*W) fail($sformatf("write pass L%0d t%0d stalled after %0d words",layer,tile,i));
        // wr_done is the cycle right after the h*w-th word.
        if (wr_done !== 1 || wr_busy !== 0 || wr_ready !== 0)
            fail($sformatf("wr_done/idle after pass L%0d t%0d",layer,tile));
        @(negedge clk);
        if (wr_done !== 0 || wr_done_cnt != done0+1)
            fail($sformatf("wr_done not a single pulse L%0d t%0d",layer,tile));
        passes = passes + 1;
    endtask

    task automatic write_layer(input integer layer, input integer H, input integer W,
                               input integer T, input integer order [],
                               input bit rnd);
        integer k;
        for (k=0;k<T;k=k+1) write_pass(layer,H,W,order[k],T,rnd);
    endtask

    task automatic check_geom(input string tag);
        if (rd_geom_valid !== g_v || rd_geom_h !== g_h[5:0] || rd_geom_w !== g_w[5:0] ||
            rd_geom_tiles !== g_t[4:0])
            fail($sformatf("%s: rd_geom v=%b %0d x %0d x %0d, expected v=%b %0d x %0d x %0d",
                           tag,rd_geom_valid,rd_geom_h,rd_geom_w,rd_geom_tiles,g_v,g_h,g_w,g_t));
    endtask

    task automatic swap(input logic want_sel, input integer want_fc,
                        input integer H, input integer W, input integer T);
        pulse(layer_swap);
        if (buf_sel !== want_sel || frame_count !== want_fc || seq_error !== 0)
            fail($sformatf("swap: buf_sel=%b frame_count=%0d",buf_sel,frame_count));
        g_v = 1; g_h = H; g_w = W; g_t = T;
        check_geom("after swap");
    endtask

    // layer_swap while one side is busy: rejected, seq_error, then cleared.
    task automatic swap_rejected(input string tag);
        logic s;
        integer f;
        s = buf_sel; f = frame_count;
        pulse(layer_swap);
        if (seq_error !== 1 || buf_sel !== s || frame_count !== f)
            fail($sformatf("layer_swap while %s not rejected",tag));
        check_geom({"rejected swap, ",tag});
    endtask

    // Read the whole stored layer (exp_words must hold its stream).
    task automatic read_layer(input integer mode, input string tag);
        integer guard;
        rd_idx = 0; chk_en = 1; rd_mode = mode;
        pulse(rd_start);
        guard = 0;
        while (rd_idx < exp_n && guard < exp_n*20+100) begin
            @(negedge clk); guard = guard + 1;
        end
        repeat (3) @(negedge clk);
        if (rd_idx != exp_n || rd_busy !== 0 || rd_valid !== 0)
            fail($sformatf("%s: read %0d of %0d words, busy=%b",tag,rd_idx,exp_n,rd_busy));
        if (mode == 0)
            $display("THROUGHPUT %s: %0d words in %0d cycles at rd_ready=1, rd_start to first word %0d cycles",
                     tag,exp_n,last_hs-first_hs+1,first_hs-start_cyc);
        if (mode == 0 && last_hs-first_hs+1 != exp_n)
            fail($sformatf("%s: not full rate at rd_ready=1",tag));
        chk_en = 0; rd_mode = 1;
    endtask

    // A rejected wr_start: no wr_ready while a beat is offered, flags as given.
    task automatic bad_write(input integer H, input integer W, input integer tile,
                             input integer T, input bit want_seq, input bit want_ovf,
                             input string tag);
        integer k;
        @(negedge clk);
        cfg_wr_h = H; cfg_wr_w = W; cfg_wr_tile = tile; cfg_wr_tiles = T;
        wr_start = 1; wr_valid = 1; wr_data = 64'hDEAD_BEEF_DEAD_BEEF;
        @(negedge clk);
        wr_start = 0;
        for (k=0;k<8;k=k+1) begin
            if (wr_ready !== 0) fail($sformatf("%s: wr_ready asserted",tag));
            @(negedge clk);
        end
        wr_valid = 0;
        if (seq_error !== want_seq || ovf_error !== want_ovf || wr_busy !== 0)
            fail($sformatf("%s: seq=%b ovf=%b busy=%b",tag,seq_error,ovf_error,wr_busy));
        do_soft_reset();
    endtask

    integer o3 [] = '{0,2,1};
    integer o4 [] = '{3,1,0,2};
    integer o1 [] = '{0};
    integer o2 [] = '{1,0};
    integer o2b [] = '{0,1};
    integer k;

    // A pass started and killed by soft_reset after some words: sets no mask bit.
    task automatic abort_pass(input integer H, input integer W, input integer tile,
                              input integer T);
        @(negedge clk);
        cfg_wr_h = H; cfg_wr_w = W; cfg_wr_tile = tile; cfg_wr_tiles = T;
        wr_start = 1;
        @(negedge clk);
        wr_start = 0; wr_valid = 1; wr_data = 64'h1111_2222_3333_4444;
        repeat (5) @(negedge clk);
        wr_valid = 0;
        do_soft_reset();
    endtask

    initial begin
        repeat (3) @(negedge clk);
        rst_n = 1;
        rd_mode = 1;

        // No layer swapped in yet.
        check_geom("after reset");
        pulse(rd_start);
        @(negedge clk);
        if (seq_error !== 1 || rd_busy !== 0 || rd_valid !== 0) fail("rd_start with no layer");
        do_soft_reset();

        // Swap with nothing written: rejected, nothing swapped in.
        pulse(layer_swap);
        if (seq_error !== 1 || frame_count !== 0 || buf_sel !== 0) fail("swap without any write");
        check_geom("swap without any write");
        do_soft_reset();

        // L0: 3 tiles of 5x7 written in order 0,2,1; swap; three replays.
        write_layer(0,5,7,3,o3,1);
        swap(1,1,5,7,3);
        build_expected(0,5,7,3);
        read_layer(1,"L0 replay 1");
        read_layer(0,"L0 replay 2");

        // Replay 3 of L0 while L1 (3x3, 4 tiles, order 3,1,0,2) is written.
        fork
            read_layer(2,"L0 replay 3");
            write_layer(1,3,3,4,o4,1);
        join
        swap(0,2,3,3,4);
        build_expected(1,3,3,4);
        fork
            read_layer(1,"L1");
            write_layer(2,6,4,1,o1,1);
        join
        swap(1,3,6,4,1);
        build_expected(2,6,4,1);
        read_layer(1,"L2 tiles=1");
        read_layer(0,"L2 tiles=1");

        // 48x48x2 fills DEPTH=4608 exactly.
        write_layer(3,48,48,2,o2,0);
        swap(0,4,48,48,2);
        build_expected(3,48,48,2);
        read_layer(0,"L3 48x48x2");

        // Commands while busy, during a read of L3 (4608 words) and the first
        // pass of L4 (36 words): the swap is rejected, the extra rd_start does
        // not restart the read (scoreboard) and the extra wr_start does not
        // disturb the write (L4 read back below).
        fork
            read_layer(1,"L3 busy");
            write_layer(4,6,6,2,o2b,1);
            begin
                wait (wr_ready === 1);
                swap_rejected("both sides busy");
                pulse(wr_start);
                pulse(rd_start);
            end
        join
        if (seq_error !== 1 || ovf_error !== 0) fail("busy commands: flags");
        do_soft_reset();
        if (buf_sel !== 0 || frame_count !== 4) fail("soft_reset changed buf_sel/frame_count");
        swap(1,5,6,6,2);
        build_expected(4,6,6,2);
        // Only the read side busy (write idle): the swap is still rejected.
        fork
            read_layer(1,"L4 after ignored wr_start");
            begin
                wait (rd_idx >= 5);
                if (wr_busy !== 0) fail("write side not idle for read-only swap test");
                swap_rejected("read side busy");
            end
        join
        do_soft_reset();

        // Configuration errors from idle.
        bad_write(48,48,0,3,0,1,"footprint 48x48x3");
        bad_write(48,48,2,2,1,0,"tile >= tiles");
        bad_write(0,5,0,1,1,0,"h=0");
        bad_write(5,49,0,1,1,0,"w=49");
        bad_write(5,5,0,0,1,0,"tiles=0");
        bad_write(1,1,0,17,1,0,"tiles=17");
        write_pass(5,1,1,15,16,0);
        if (seq_error !== 0 || ovf_error !== 0) fail("tiles=C_TILE_MAX rejected");
        // Tile 15 of 16 alone is not a layer.
        swap_rejected("tiles 0..14 missing");
        do_soft_reset();

        // soft_reset in the middle of a read: flush, then replay intact.
        rd_idx = 0; chk_en = 1; rd_mode = 1;
        pulse(rd_start);
        wait (rd_idx >= 10);
        @(negedge clk);
        do_soft_reset();
        @(negedge clk);
        if (rd_valid !== 0) fail("soft_reset did not flush the read FIFO");
        chk_en = 0;
        read_layer(1,"L4 after soft_reset");

        // L5: 16 tiles (C_TILE_MAX) of 1x1; tile 15 was written above, the
        // mask survived soft_reset, so tiles 0..14 complete the layer.
        for (k=0;k<15;k=k+1) write_pass(5,1,1,k,16,0);
        swap(0,6,1,1,16);
        build_expected(5,1,1,16);
        read_layer(0,"L5 16 tiles");

        // soft_reset in the middle of a write, then a full layer still works.
        @(negedge clk);
        cfg_wr_h = 5; cfg_wr_w = 5; cfg_wr_tile = 0; cfg_wr_tiles = 1;
        wr_start = 1;
        @(negedge clk);
        wr_start = 0; wr_valid = 1; wr_data = 64'h0123_4567_89AB_CDEF;
        repeat (6) @(negedge clk);
        wr_valid = 0;
        k = wr_done_cnt;
        do_soft_reset();
        repeat (2) @(negedge clk);
        if (wr_ready !== 0 || wr_done_cnt != k) fail("soft_reset mid-write");
        // Only the write side busy (read idle): the swap is rejected.
        fork
            write_layer(6,2,3,2,o2,1);
            begin
                wait (wr_ready === 1);
                if (rd_busy !== 0) fail("read side not idle for write-only swap test");
                swap_rejected("write side busy");
            end
        join
        do_soft_reset();
        swap(1,7,2,3,2);
        build_expected(6,2,3,2);
        read_layer(1,"L6 after soft_reset");
        read_layer(0,"L6");

        // Swap with no new write since the last swap: rejected, geometry kept.
        pulse(layer_swap);
        if (seq_error !== 1 || frame_count !== 7 || buf_sel !== 1) fail("swap without new write");
        check_geom("swap without new write");
        do_soft_reset();
        check_geom("after soft_reset");

        // L7: tile 1 of 3 missing; tile rewrite is allowed.
        write_pass(7,4,4,0,3,0);
        write_pass(7,4,4,2,3,0);
        swap_rejected("tile 1 of 3 missing");
        do_soft_reset();
        write_pass(7,4,4,0,3,1);
        swap_rejected("tile 1 of 3 still missing");
        do_soft_reset();
        write_pass(7,4,4,1,3,1);
        swap(0,8,4,4,3);
        build_expected(7,4,4,3);
        read_layer(1,"L7 completed, tile rewritten");

        // L8: a second pass with another h, w or tiles is rejected at wr_start
        // (seq_error, nothing written) and does not touch the mask.
        write_pass(8,3,3,0,2,0);
        bad_write(3,4,1,2,1,0,"mixed w in layer");
        bad_write(4,3,1,2,1,0,"mixed h in layer");
        bad_write(3,3,1,3,1,0,"mixed tiles in layer");
        swap_rejected("tile 1 of 2 missing after rejected passes");
        do_soft_reset();
        write_pass(8,3,3,1,2,0);
        swap(1,9,3,3,2);
        build_expected(8,3,3,2);
        read_layer(0,"L8 after rejected mixed passes");
        // The first pass of the next layer may have any geometry again.
        write_pass(9,2,2,0,1,0);
        swap(0,10,2,2,1);
        build_expected(9,2,2,1);
        read_layer(1,"L9 geometry free after swap");

        // L10: a pass aborted by soft_reset sets no bit.
        write_pass(10,2,2,0,2,0);
        abort_pass(2,2,1,2);
        swap_rejected("aborted pass");
        do_soft_reset();
        write_pass(10,2,2,1,2,0);
        swap(1,11,2,2,2);
        build_expected(10,2,2,2);
        read_layer(1,"L10 after aborted pass");

        if (wr_done_cnt != passes) fail($sformatf("wr_done pulses %0d for %0d passes",wr_done_cnt,passes));
        if (errors==0)
            $display("PASS: act_buffer HWC read of 11 layers, %0d write passes, replay, concurrent write, LFSR backpressure, errors, soft_reset, swap completeness, mixed geometry, rd_geom",passes);
        else $display("FAIL: tb_act_buffer errors=%0d",errors);
        $finish;
    end
endmodule
