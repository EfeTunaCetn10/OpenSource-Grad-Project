`timescale 1ns/1ps

// ADR-017 Kademe 1: the testbench is the PS layer sequencer.  One reusable
// driver instance per geometry runs conv1_top for every output-channel tile.
module lenet_e2e_stage #(
    parameter string NAME = "conv1",
    parameter int IN_H=32, IN_W=32, CI=3, PHYS=3,
    parameter int KH=5, KW=5, CO=6
) (
    input logic clk, rst_n,
    output logic finished
);
    localparam int ROWS=8, K=CI*KH*KW, OH=IN_H-KH+1, OW=IN_W-KW+1;
    localparam int NT=(CO+7)/8, FRAME_BYTES=IN_H*IN_W*PHYS;
    localparam int FRAME_BEATS=(FRAME_BYTES+7)/8, OUT_LEN=NT*OH*OW*8;
    localparam int WD=NT*K, KMAX=512, TILEMAX=16;
    localparam int TIMEOUT=1200000;

    logic [63:0] frame_mem [0:FRAME_BEATS-1];
    logic [7:0] golden [0:OUT_LEN-1];
    logic [7:0] actual [0:OUT_LEN-1];
    logic [7:0] bank [0:WD-1];
    logic signed [31:0] cfg_bias_q [0:7];
    logic signed [17:0] cfg_m0 [0:7];
    logic [5:0] cfg_shift_n [0:7];
    logic cfg_relu [0:7];
    logic s_valid,s_ready,s_last, restart, restart_error;
    logic [63:0] s_data;
    logic w_wr_en;
    logic [2:0] w_wr_bank;
    logic [$clog2(WD)-1:0] w_wr_addr;
    logic [7:0] w_wr_data;
    logic frame_start;
    logic [3:0] cfg_active_rows;
    logic [$clog2(KMAX+1)-1:0] cfg_k_len;
    logic [$clog2(TILEMAX)-1:0] cfg_tile_idx;
    logic m_valid,m_ready,m_last,busy,layer_done,window_done,lockstep_error,drain_stall;
    logic [63:0] m_y_flat;
    logic [7:0] m_lane_valid,m_sat_flat,m_ovf_flat,error_flags;
    logic [3:0] m_col;
    logic [31:0] tile_count,engine_cycle_count;
    logic [15:0] lfsr;
    int out_seen, current_tile, errors;
    bit checking,done_seen;
    string path;

    // One datapath for every layer: envelope defaults, geometry on cfg_*.
    conv1_top #(.ROWS(8),.COLS(8),
        .K_MAX(KMAX),.TILE_MAX(TILEMAX),.W_DEPTH(WD)) dut (
        .clk(clk),.rst_n(rst_n),.s_valid(s_valid),.s_ready(s_ready),
        .s_data(s_data),.s_last(s_last),.restart(restart),
        .restart_error(restart_error),.w_wr_en(w_wr_en),
        .w_wr_bank(w_wr_bank),.w_wr_addr(w_wr_addr),.w_wr_data(w_wr_data),
        .frame_start(frame_start),.cfg_active_rows(cfg_active_rows),
        .cfg_k_len(cfg_k_len),.cfg_tile_idx(cfg_tile_idx),
        .cfg_in_h(6'(IN_H)),.cfg_in_w(6'(IN_W)),.cfg_c_in(9'(CI)),
        .cfg_c_phys(9'(PHYS)),.cfg_kh(3'(KH)),.cfg_kw(3'(KW)),.cfg_pad(2'd0),
        .cfg_w_base('0),
        .cfg_bias_q(cfg_bias_q),.cfg_m0(cfg_m0),
        .cfg_shift_n(cfg_shift_n),.cfg_relu(cfg_relu),.cfg_bypass(1'b0),
        .m_valid(m_valid),.m_ready(m_ready),.m_y_flat(m_y_flat),
        .m_lane_valid(m_lane_valid),.m_col(m_col),.m_last(m_last),
        .m_sat_flat(m_sat_flat),.m_ovf_flat(m_ovf_flat),.busy(busy),
        .layer_done(layer_done),.window_done(window_done),
        .tile_count(tile_count),.error_flags(error_flags),
        .lockstep_error(lockstep_error),.drain_stall(drain_stall),
        .engine_cycle_count(engine_cycle_count)
    );

    function automatic logic [15:0] next_lfsr(logic [15:0] v);
        return {v[14:0],v[15]^v[13]^v[12]^v[10]};
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            m_ready <= 0;
            lfsr <= 16'hACE1;
            done_seen <= 0;
        end else begin
            lfsr <= next_lfsr(lfsr);
            m_ready <= checking && (lfsr[3:0] != 0);
            if (layer_done) done_seen <= 1;
            if (checking && m_valid && m_ready) begin
                if (out_seen >= OH*OW) begin
                    $display("FAIL %s tile %0d: extra output beat",NAME,current_tile);
                    errors++;
                end else begin
                    for (int r=0;r<8;r++) begin
                        int idx;
                        idx = (((current_tile*OH + out_seen/OW)*OW + out_seen%OW)*8+r);
                        actual[idx] = m_y_flat[r*8+:8];
                        if ((current_tile*8+r)<CO) begin
                            if (m_y_flat[r*8+:8] !== golden[idx]) begin
                                $display("FAIL %s boundary tile=%0d pos=%0d lane=%0d got=%02h expected=%02h",
                                    NAME,current_tile,out_seen,r,m_y_flat[r*8+:8],golden[idx]);
                                errors++;
                            end
                            if (!m_lane_valid[r]) begin
                                $display("FAIL %s missing valid lane %0d",NAME,r);
                                errors++;
                            end
                        end else actual[idx] = 0;
                    end
                    if (m_col !== 4'(out_seen%OW%8)) begin
                        $display("FAIL %s output column got %0d beat %0d",NAME,m_col,out_seen);
                        errors++;
                    end
                    if (m_ovf_flat & m_lane_valid) begin
                        $display("FAIL %s overflow flags %h",NAME,m_ovf_flat);
                        errors++;
                    end
                    out_seen++;
                end
            end
        end
    end

    task automatic load;
        path = $sformatf("../vectors/lenet_%s_y.mem",NAME);
        $readmemh(path,golden);
        path = $sformatf("../vectors/lenet_%s_bias_q.mem",NAME);
        $readmemh(path,cfg_bias_q);
        path = $sformatf("../vectors/lenet_%s_m0.mem",NAME);
        $readmemh(path,cfg_m0);
        path = $sformatf("../vectors/lenet_%s_shift_n.mem",NAME);
        $readmemh(path,cfg_shift_n);
        path = $sformatf("../vectors/lenet_%s_relu.mem",NAME);
        $readmemh(path,cfg_relu);
        for (int r=0;r<8;r++) begin
            path = $sformatf("../vectors/lenet_%s_wbank%0d.mem",NAME,r);
            $readmemh(path,bank);
            for (int a=0;a<WD;a++) begin
                @(negedge clk);
                w_wr_en=1; w_wr_bank=3'(r); w_wr_addr=$clog2(WD)'(a);
                w_wr_data=bank[a];
            end
        end
        @(negedge clk);
        w_wr_en=0;
    endtask

    task automatic feed;
        for (int b=0;b<FRAME_BEATS;b++) begin
            @(negedge clk);
            s_valid=1; s_data=frame_mem[b]; s_last=(b==FRAME_BEATS-1);
            @(posedge clk);
            while (!s_ready) @(posedge clk);
        end
        @(negedge clk);
        s_valid=0; s_last=0; s_data=0;
    endtask

    task automatic run;
        int guard;
        finished=0; errors=0; checking=0;
        s_valid=0; s_last=0; s_data=0; restart=0; frame_start=0;
        w_wr_en=0; w_wr_bank=0; w_wr_addr=0; w_wr_data=0;
        cfg_k_len=$clog2(KMAX+1)'(K);
        load();
        for (int tile=0;tile<NT;tile++) begin
            // Frame contract: never restart with a pending unaccepted beat.
            // feed() deasserts valid only after the last accepted beat.
            if (tile!=0) begin
                if (s_valid || !window_done || busy || m_valid)
                    $fatal(1,"FAIL %s unsafe restart before tile %0d",NAME,tile);
                @(negedge clk); restart=1;
                @(negedge clk); restart=0;
            end
            current_tile=tile; out_seen=0; done_seen=0;
            cfg_tile_idx=$clog2(TILEMAX)'(tile);
            cfg_active_rows=4'(((CO-tile*8)>8)?8:(CO-tile*8));
            checking=1;
            @(negedge clk); frame_start=1;
            @(negedge clk); frame_start=0;
            feed();
            guard=0;
            while ((out_seen<OH*OW || !done_seen) && guard<TIMEOUT) begin
                @(negedge clk); guard++;
            end
            if (guard>=TIMEOUT) $fatal(1,"FAIL %s tile %0d timeout out=%0d/%0d done=%0b",
                                      NAME,tile,out_seen,OH*OW,done_seen);
            repeat(3) @(negedge clk);
            checking=0;
            if (tile_count != OH*((OW+7)/8) || !window_done || restart_error ||
                error_flags || lockstep_error)
                $fatal(1,"FAIL %s tile %0d status tiles=%0d window=%b restart=%b flags=%h lock=%b",
                    NAME,tile,tile_count,window_done,restart_error,error_flags,lockstep_error);
        end
        if (errors) $fatal(1,"FAIL %s: %0d boundary mismatches",NAME,errors);
        $display("PASS %s RTL boundary: %0d logical outputs across %0d tile(s)",NAME,CO*OH*OW,NT);
        finished=1;
    endtask
endmodule

// The sequencer supplies each captured convolution tile as one pixel per
// beat.  Pool2's two tiles are serialized in frame_mem and by the pool DUT.
module lenet_e2e_pool #(
    parameter string NAME = "pool1",
    parameter int IN_H = 28, IN_W = 28, CO = 6
) (
    input logic clk, rst_n,
    output logic finished
);
    localparam int NT = (CO+7)/8;
    localparam int IN_BEATS = NT*IN_H*IN_W;
    localparam int OUT_BEATS = NT*(IN_H/2)*(IN_W/2);
    localparam int OUT_LEN = OUT_BEATS*8;
    localparam int TIMEOUT = 200000;

    logic [63:0] frame_mem [0:IN_BEATS-1];
    logic [7:0] golden [0:OUT_LEN-1];
    logic [7:0] actual [0:OUT_LEN-1];
    logic s_valid, s_ready, s_last, m_valid, m_ready, m_last, cfg_error;
    logic [63:0] s_data, m_data;
    logic [15:0] lfsr;
    logic was_stalled, stalled_last;
    logic [63:0] stalled_data;
    bit checking;
    int received, errors;
    string path;

    pool2x2 dut (
        .clk(clk), .rst_n(rst_n), .cfg_in_h(6'(IN_H)),
        .cfg_in_w(6'(IN_W)), .cfg_c_tiles(3'(NT)),
        .s_valid(s_valid), .s_ready(s_ready),
        .s_data(s_data), .s_last(s_last), .m_valid(m_valid),
        .m_ready(m_ready), .m_data(m_data), .m_last(m_last),
        .cfg_error(cfg_error)
    );

    function automatic logic [15:0] next_lfsr(logic [15:0] v);
        return {v[14:0],v[15]^v[13]^v[12]^v[10]};
    endfunction

    initial begin
        s_valid=0; s_last=0; s_data=0; checking=0; finished=0;
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= (CO == 6) ? 16'hACE1 : 16'hC00D;
            m_ready <= 0;
            was_stalled <= 0;
            stalled_data <= 0;
            stalled_last <= 0;
        end else begin
            lfsr <= next_lfsr(lfsr);
            m_ready <= checking && (lfsr[0] | lfsr[3]);
            if (checking) begin
                if (was_stalled && (!m_valid || m_data !== stalled_data ||
                                    m_last !== stalled_last))
                    $fatal(1,"FAIL %s output changed under stall",NAME);
                was_stalled <= m_valid && !m_ready;
                if (m_valid && !m_ready) begin
                    stalled_data <= m_data;
                    stalled_last <= m_last;
                end
                if (m_valid && m_ready) begin
                    if (received >= OUT_BEATS)
                        $fatal(1,"FAIL %s extra output beat=%0d data=%h",NAME,received,m_data);
                    if (m_last !== (received == OUT_BEATS-1))
                        $fatal(1,"FAIL %s beat=%0d last=%b expected_last=%b",
                               NAME,received,m_last,received == OUT_BEATS-1);
                    for (int lane=0;lane<8;lane++) begin
                        int idx;
                        idx=received*8+lane;
                        actual[idx]=m_data[lane*8+:8];
                        if (actual[idx] !== golden[idx]) begin
                            $display("FAIL %s RTL boundary index=%0d got=%02h expected=%02h",
                                     NAME,idx,actual[idx],golden[idx]);
                            errors++;
                        end
                    end
                    received++;
                end
            end
        end
    end

    task automatic feed;
        for (int b=0;b<IN_BEATS;b++) begin
            @(negedge clk);
            s_valid=1; s_data=frame_mem[b]; s_last=(b==IN_BEATS-1);
            @(posedge clk);
            while (!s_ready) @(posedge clk);
        end
        @(negedge clk);
        s_valid=0; s_last=0; s_data=0;
    endtask

    task automatic run;
        int guard;
        finished=0; received=0; errors=0;
        path=$sformatf("../vectors/lenet_%s_y.mem",NAME);
        $readmemh(path,golden);
        @(negedge clk);
        checking=1;
        feed();
        guard=0;
        while (received<OUT_BEATS && guard<TIMEOUT) begin
            @(negedge clk); guard++;
        end
        if (guard>=TIMEOUT)
            $fatal(1,"FAIL %s timeout received=%0d/%0d",NAME,received,OUT_BEATS);
        repeat (3) @(negedge clk);
        if (m_valid) $fatal(1,"FAIL %s extra valid after completion",NAME);
        if (cfg_error) $fatal(1,"FAIL %s unexpected pool config error",NAME);
        checking=0;
        if (errors) $fatal(1,"FAIL %s RTL boundary: %0d mismatches",NAME,errors);
        $display("PASS %s RTL boundary: %0d padded bytes across %0d tile(s)",
                 NAME,OUT_LEN,NT);
        finished=1;
    endtask
endmodule

module tb_lenet_e2e;
    logic clk=0,rst_n=0;
    always #5 clk=~clk;
    logic d1,d2,d3,d4,d5,dp1,dp2;
    lenet_e2e_stage #(.NAME("conv1"),.IN_H(32),.IN_W(32),.CI(3),.PHYS(3),.KH(5),.KW(5),.CO(6)) c1(clk,rst_n,d1);
    lenet_e2e_stage #(.NAME("conv2"),.IN_H(14),.IN_W(14),.CI(6),.PHYS(8),.KH(5),.KW(5),.CO(16)) c2(clk,rst_n,d2);
    lenet_e2e_stage #(.NAME("fc1"),.IN_H(1),.IN_W(1),.CI(400),.PHYS(400),.KH(1),.KW(1),.CO(120)) f1(clk,rst_n,d3);
    lenet_e2e_stage #(.NAME("fc2"),.IN_H(1),.IN_W(1),.CI(120),.PHYS(120),.KH(1),.KW(1),.CO(84)) f2(clk,rst_n,d4);
    lenet_e2e_stage #(.NAME("fc3"),.IN_H(1),.IN_W(1),.CI(84),.PHYS(84),.KH(1),.KW(1),.CO(10)) f3(clk,rst_n,d5);
    lenet_e2e_pool #(.NAME("pool1"),.IN_H(28),.IN_W(28),.CO(6)) p1(clk,rst_n,dp1);
    lenet_e2e_pool #(.NAME("pool2"),.IN_H(10),.IN_W(10),.CO(16)) p2(clk,rst_n,dp2);

    logic [7:0] pred_gold[0:0];

    initial begin
        $readmemh("../vectors/lenet_image_frame.mem",c1.frame_mem);
        $readmemh("../vectors/lenet_pred.mem",pred_gold);
        repeat(5) @(negedge clk); rst_n=1;
        c1.run();
        for(int i=0;i<784;i++) for(int j=0;j<8;j++)
            p1.frame_mem[i][j*8+:8]=c1.actual[i*8+j];
        p1.run();
        for(int i=0;i<196;i++) begin
            c2.frame_mem[i]=0;
            for(int j=0;j<8;j++) c2.frame_mem[i][j*8+:8]=p1.actual[i*8+j];
        end
        c2.run();
        for(int i=0;i<200;i++) for(int j=0;j<8;j++)
            p2.frame_mem[i][j*8+:8]=c2.actual[i*8+j];
        p2.run();
        for(int i=0;i<50;i++) begin
            f1.frame_mem[i]=0;
            for(int j=0;j<8;j++) f1.frame_mem[i][j*8+:8]=p2.actual[i*8+j];
        end
        f1.run();
        for(int i=0;i<15;i++) begin
            f2.frame_mem[i]=0;
            for(int j=0;j<8;j++) f2.frame_mem[i][j*8+:8]=f1.actual[i*8+j];
        end
        f2.run();
        for(int i=0;i<11;i++) begin
            f3.frame_mem[i]=0;
            for(int j=0;j<8;j++) if(i*8+j<84) f3.frame_mem[i][j*8+:8]=f2.actual[i*8+j];
        end
        f3.run();
        begin
            logic signed [7:0] best,v;
            int predicted;
            best=-128; predicted=0;
            for(int k=0;k<10;k++) begin
                v=f3.actual[(k/8)*8+k%8];
                if(v>best) begin best=v; predicted=k; end
            end
            if(predicted !== int'(pred_gold[0]))
                $fatal(1,"FAIL predicted class got=%0d expected=%0d",predicted,pred_gold[0]);
            $display("PASS tb_lenet_e2e: all 7 boundaries, predicted=%0d",predicted);
        end
        $finish;
    end
    initial begin
        #200000000;
        $fatal(1,"FAIL tb_lenet_e2e global timeout");
    end
endmodule
