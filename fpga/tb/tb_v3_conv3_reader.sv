`timescale 1ns/1ps
// Independent coordinate oracle checks repacking and all Cin=24 padded windows.
module tb_v3_conv3_reader;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,restart=0,repack_error,repack_done,window_error;
    logic s_valid=0,s_ready,s_last=0,dv,dr,dl,m_valid,m_ready=0,done,first,last;
    logic [63:0] s_data=0,dd,m_data;
    logic [3:0] active;
    logic [31:0] k,row,x;
    int seen=0,dense_seen=0,cycles=0,pattern=0,boundary_bytes=0,boundary_upper=0;
    int coverage_count[0:8];
    logic [15:0] lfsr=16'hACE1;
    tile_major_repack #(.CHANNELS(24),.HEIGHT(8),.WIDTH(8)) adapter(.clk(clk),.rst_n(rst_n),.restart(restart),
        .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_last(s_last),
        .m_valid(dv),.m_ready(dr),.m_data(dd),.m_last(dl),.done(repack_done),.error(repack_error));
    window_gen #(.K_H(3),.K_W(3),.C_LOGICAL(24),.C_PHYS_STRIDE(24),
                 .IN_H(8),.IN_W(8),.PAD(1)) dut(
        .clk(clk),.rst_n(rst_n),.restart(restart),.restart_error(window_error),
        .s_valid(dv),.s_ready(dr),.s_data(dd),.s_last(dl),
        .m_valid(m_valid),.m_ready(m_ready),.m_data(m_data),.m_active_cols(active),
        .m_k(k),.m_tile_row(row),.m_tile_x(x),.m_tile_start(first),.m_tile_last(last),.done(done));
    function automatic logic [7:0] pixel(input int h,w,c);
        return ((h*37+w*13+c*53+11+pattern*71)%251)-125;
    endfunction
    always @(negedge clk) begin
        cycles++;
        lfsr={lfsr[14:0],lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
        m_ready=rst_n && ((pattern==0) ? (cycles%9>=4) : (lfsr[2:0]>2));
    end
    always @(posedge clk) begin : scoreboard
        int ci,kh,kw,h,w,region,col;
        logic [7:0] expected;
        if(rst_n && dv && dr) begin
            if(dense_seen>=192 || dl !== (dense_seen==191)) $fatal(1,"dense stream count/last");
            for(int lane=0;lane<8;lane++)
                if(dd[lane*8+:8] !== pixel(dense_seen/24,(dense_seen/3)%8,(dense_seen%3)*8+lane))
                    $fatal(1,"repack c7/8 ordering: dense beat%0d lane%0d",dense_seen,lane);
            dense_seen++;
        end
        if(rst_n && m_valid && m_ready) begin
            if(seen>=1728 || row !== 32'(seen/216) || x !== 0
               || k !== 32'(seen%216) || active!==8 || first!==(k==0) || last!==(k==215))
                $fatal(1,"window metadata/order at beat %0d",seen);
            ci=k/9; kh=(k/3)%3; kw=k%3;
            for(int lane=0;lane<8;lane++) begin
                col=int'(x)+lane; h=int'(row)+kh-1; w=col+kw-1;
                expected=(h<0 || h>=8 || w<0 || w>=8) ? 8'h00 : pixel(h,w,ci);
                if(m_data[lane*8+:8] !== expected)
                    $fatal(1,"reader row%0d col%0d ci%0d kh%0d kw%0d got%h expected%h",row,col,ci,kh,kw,m_data[lane*8+:8],expected);
                if(ci==7 || ci==8) boundary_bytes++;
                if(ci==15 || ci==16) boundary_upper++;
                if(k==215) begin
                    region=(row==0 ? 0 : (row==7 ? 2 : 1))*3+(col==0 ? 0 : (col==7 ? 2 : 1));
                    coverage_count[region]++;
                end
            end
            seen++;
        end
    end
    assert property(@(posedge clk) disable iff(!rst_n)
        m_valid && !m_ready |=> m_valid && $stable({m_data,k,row,x,active,first,last}))
        else $fatal(1,"window changed under stall");
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        for(int p=0;p<2;p++) begin
            pattern=p; seen=0; dense_seen=0; boundary_bytes=0; boundary_upper=0;
            for(int i=0;i<9;i++) coverage_count[i]=0;
            if(p!=0) begin
                @(negedge clk); restart=1;
                @(negedge clk); restart=0;
            end
            for(int b=0;b<192;b++) begin
                // Distinguish old/new frame and both input planes; input gaps.
                if(b%7==0) repeat(2) @(negedge clk);
                @(negedge clk);
                for(int lane=0;lane<8;lane++)
                    s_data[lane*8+:8]=pixel((b%64)/8,b%8,(b/64)*8+lane);
                s_valid=1; s_last=(b==191);
                @(posedge clk); while(!s_ready) @(posedge clk);
                @(negedge clk); s_valid=0; s_last=0;
            end
            wait(done);
            repeat(10) @(negedge clk);
            if(seen!=1728 || dense_seen!=192 || boundary_bytes!=1152 || boundary_upper!=1152 ||
               repack_error || window_error || !repack_done) $fatal(1,"reader completion/count/error");
            for(int i=0;i<9;i++) if(coverage_count[i]==0) $fatal(1,"missing border region %0d",i);
            $display("reader pattern%0d: 192 dense beats, 13824 window bytes, 1152 c7/8 + 1152 c15/16 bytes, all borders exact",p);
        end
        $display("PASS tb_v3_conv3_reader"); $finish;
    end
    initial begin #4000000; $fatal(1,"reader timeout"); end
endmodule
