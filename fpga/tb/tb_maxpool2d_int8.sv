`timescale 1ns/1ps
module pool_case #(
    parameter int C=16,H=32,W=32,STAGE=1,REAL_FIXTURE=1
)(output logic complete=0);
    localparam int NI=C/8*H*W, OH=H/2, OW=W/2, NO=NI/4;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,restart=0,sv=0,sr,sl=0,mv,mr=0,ml,done,error;
    logic [63:0] sd=0,md;
    logic [63:0] inputs[0:NI-1],expected[0:NO-1];
    logic [15:0] lfsr=16'hACE1;
    int seen=0,pattern=0,cycle=0,accepted=0,stalls=0;
    int coverage_count[0:7];
    string vectors="../../../cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_pool_poc";
    maxpool2d_int8 #(.CHANNELS(C),.HEIGHT(H),.WIDTH(W)) dut(
        .clk(clk),.rst_n(rst_n),.restart(restart),.s_valid(sv),.s_ready(sr),.s_data(sd),.s_last(sl),
        .m_valid(mv),.m_ready(mr),.m_data(md),.m_last(ml),.done(done),.error(error));
    function automatic int kind(input int c,h,w);
        return (c+(h/2)*OW+w/2+pattern)%8;
    endfunction
    function automatic logic[7:0] directed_pixel(input int c,h,w);
        int k,pos;
        k=kind(c,h,w);pos=(h%2)*2+w%2;
        if(k<4) return pos==k ? -1-c : -100+pos;
        if(k==4) return -17-c; // equal negative maxima
        if(k==5) begin // mixed signs: unsigned max would incorrectly select -1
            case(pos) 0:return -128; 1:return 0; 2:return 127; 3:return -1; endcase
        end
        if(k==6) return -128; // all INT8 minimum
        return 127;          // all INT8 maximum
    endfunction
    function automatic logic[7:0] directed_expected(input int c,oy,ox);
        int k;
        k=(c+oy*OW+ox+pattern)%8;
        if(k<4) return -1-c;
        if(k==4) return -17-c;
        if(k==6) return -128;
        return 127;
    endfunction
    always @(negedge clk) begin
        cycle++;
        lfsr={lfsr[14:0],lfsr[15]^lfsr[13]^lfsr[12]^lfsr[10]};
        mr=rst_n && (pattern==0 ? (cycle%13>=6) : (lfsr[2:0]>3));
    end
    always @(posedge clk) if(rst_n) begin
        if(sv && sr) accepted++;
        if(mv && !mr) stalls++;
        if(mv && mr) begin
            if(seen>=NO || ml!==(seen==NO-1)) $fatal(1,"pool stage%0d count/last beat%0d",STAGE,seen);
            if(REAL_FIXTURE) begin
                if(md!==expected[seen]) $fatal(1,"pool%0d beat%0d got%h expected%h",STAGE,seen,md,expected[seen]);
            end else begin
                for(int lane=0;lane<8;lane++) begin
                    if(md[lane*8+:8] !== directed_expected((seen/(OH*OW))*8+lane,(seen/OW)%OH,seen%OW))
                        $fatal(1,"signed/order stage%0d beat%0d lane%0d",STAGE,seen,lane);
                    coverage_count[((seen/(OH*OW))*8+lane+(seen/OW)%OH*OW+seen%OW+pattern)%8]++;
                end
            end
            seen++;
        end
    end
    initial begin
        if(REAL_FIXTURE) begin
            $readmemh($sformatf("%s/pool%0d_input.mem",vectors,STAGE),inputs);
            $readmemh($sformatf("%s/pool%0d_expected.mem",vectors,STAGE),expected);
        end
        repeat(4) @(negedge clk); rst_n=1;
        for(int p=0;p<2;p++) begin
            pattern=p; seen=0; accepted=0; stalls=0;
            for(int j=0;j<8;j++) coverage_count[j]=0;
            if(p!=0) begin @(negedge clk);restart=1;@(negedge clk);restart=0;end
            for(int b=0;b<NI;b++) begin
                if(b%11==0) repeat(2) @(negedge clk);
                @(negedge clk);sv=1;sl=(b==NI-1);
                if(REAL_FIXTURE) sd=inputs[b];
                else for(int lane=0;lane<8;lane++) sd[lane*8+:8]=directed_pixel((b/(H*W))*8+lane,(b/W)%H,b%W);
                @(posedge clk);while(!sr) @(posedge clk);
                @(negedge clk);sv=0;sl=0;
            end
            wait(done); repeat(20) @(negedge clk);
            if(seen!=NO || accepted!=NI || error || sr) $fatal(1,"pool completion/replay error stage%0d",STAGE);
            if(REAL_FIXTURE && stalls==0) $fatal(1,"no exercised output stalls");
            if(!REAL_FIXTURE) for(int j=0;j<8;j++) if(!coverage_count[j]) $fatal(1,"missing signed/max-position case%0d",j);
            $display("pool case%0d real%0d pattern%0d: %0d inputs, %0d outputs (%0d INT8), %0d stalled cycles exact",STAGE,REAL_FIXTURE,p,accepted,seen,seen*8,stalls);
        end
        complete=1;
    end
endmodule
module tb_v3_pool_poc;
    wire a,b,c;
    pool_case #(.C(16),.H(32),.W(32),.STAGE(1)) p1(a);
    pool_case #(.C(24),.H(16),.W(16),.STAGE(2)) p2(b);
    pool_case #(.C(32),.H(8),.W(8),.STAGE(3)) p3(c);
    initial begin wait(a&&b&&c);$display("PASS tb_v3_pool_poc: 4096+1536+512=6144 INT8 values per pattern; both patterns exact");$finish;end
    initial begin #2000000;$fatal(1,"pool real timeout");end
endmodule
module tb_maxpool2d_directed;
    wire a,b;
    pool_case #(.C(24),.H(4),.W(6),.REAL_FIXTURE(0),.STAGE(4)) wide(a);
    pool_case #(.C(8),.H(2),.W(2),.REAL_FIXTURE(0),.STAGE(5)) minimum(b);
    initial begin wait(a&&b);$display("PASS tb_maxpool2d_directed: signed/ties/four positions/c7-8/c15-16/first-last/replay");$finish;end
    initial begin #2000000;$fatal(1,"pool directed timeout");end
endmodule
