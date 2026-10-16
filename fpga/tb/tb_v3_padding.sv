`timescale 1ns/1ps
// Directed asymmetric 8x8 RGB fixture; checks every window byte including
// four corners, four edges, and center under two deterministic stall patterns.
module tb_v3_padding;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0, restart=0, restart_error;
    logic s_valid=0,s_ready,s_last=0,m_valid,m_ready=0,done,first,last;
    logic [63:0] s_data=0,m_data;
    logic [3:0] active;
    logic [31:0] k,row,x;
    int seen=0,cycles=0,pattern=0;
    int coverage_count[0:8];
    logic [15:0] lfsr=16'hACE1;
    window_gen #(.K_H(3),.K_W(3),.C_LOGICAL(3),.IN_H(8),.IN_W(8),.PAD(1)) dut(
        .clk(clk),.rst_n(rst_n),.restart(restart),.restart_error(restart_error),
        .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_last(s_last),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_active_cols(active),
        .m_k(k),.m_tile_row(row),.m_tile_x(x),.m_tile_start(first),.m_tile_last(last),.done(done));
    function automatic logic [7:0] pixel(input int h,w,c);
        return ((h*37+w*13+c*53+11)%251)-125;
    endfunction
    always @(negedge clk) begin
        cycles++;
        lfsr={lfsr[14:0],lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
        m_ready= rst_n && ((pattern==0) ? (cycles%9>=4) : (lfsr[2:0]>2));
    end
    always @(posedge clk) begin : scoreboard
        int ci,kh,kw,h,w,region;
        logic [7:0] expected;
        if(rst_n && m_valid && m_ready) begin
            if(seen>=216 || row !== 32'(seen/27) || x!==0 || k !== 32'(seen%27)
               || active!==8 || first!==(k==0) || last!==(k==26))
                $fatal(1,"padding metadata/order at beat %0d",seen);
            ci=k/9; kh=(k/3)%3; kw=k%3;
            for(int lane=0;lane<8;lane++) begin
                h=int'(row)+kh-1; w=lane+kw-1;
                expected=(h<0 || h>=8 || w<0 || w>=8) ? 8'h00 : pixel(h,w,ci);
                if(m_data[lane*8+:8] !== expected)
                    $fatal(1,"padding byte row%0d col%0d k%0d got%h expected%h",row,lane,k,m_data[lane*8+:8],expected);
                if(k==26) begin
                    region=(row==0 ? 0 : (row==7 ? 2 : 1))*3+(lane==0 ? 0 : (lane==7 ? 2 : 1));
                    coverage_count[region]++;
                end
            end
            seen++;
        end
    end
    property stable_stall;
        @(posedge clk) disable iff(!rst_n)
        m_valid && !m_ready |=> m_valid && $stable({m_data,k,row,x,active,first,last});
    endproperty
    assert property(stable_stall) else $fatal(1,"padding output changed under stall");
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        for(int p=0;p<2;p++) begin
            pattern=p; seen=0;
            for(int i=0;i<9;i++) coverage_count[i]=0;
            if(p!=0) begin
                @(negedge clk); restart=1;
                @(negedge clk); restart=0;
            end
            for(int b=0;b<24;b++) begin
                @(negedge clk);
                for(int lane=0;lane<8;lane++)
                    s_data[lane*8+:8]=pixel((b*8+lane)/24,((b*8+lane)/3)%8,(b*8+lane)%3);
                s_valid=1; s_last=(b==23);
                @(posedge clk); while(!s_ready) @(posedge clk);
                @(negedge clk); s_valid=0; s_last=0;
            end
            wait(done);
            repeat(10) @(negedge clk);
            if(seen!=216 || restart_error) $fatal(1,"padding missing/extra outputs");
            for(int i=0;i<9;i++) if(coverage_count[i]==0) $fatal(1,"missing region %0d",i);
            $display("padding pattern%0d: all corners/edges/center, 216 beats / 1728 bytes exact",p);
        end
        $display("PASS tb_v3_padding"); $finish;
    end
    initial begin
        #2000000; $fatal(1,"padding timeout (bottom row must complete)");
    end
endmodule
