`timescale 1ns/1ps
// Counter-width and non-power-of-two geometry coverage beyond the real layers.
module repack_geometry_case #(parameter int C=24,H=3,W=5)(output logic complete=0);
    localparam int T=C/8, P=H*W, N=T*P;
    logic clk=0; always #5 clk=~clk;
    logic rst_n=0,restart=0,sv=0,sr,sl=0,mv,mr=0,ml,done,error;
    logic [63:0] sd=0,md;
    int seen=0,frame=0,ticks=0;
    tile_major_repack #(.CHANNELS(C),.HEIGHT(H),.WIDTH(W)) dut(
        .clk(clk),.rst_n(rst_n),.restart(restart),.s_valid(sv),.s_ready(sr),.s_data(sd),.s_last(sl),
        .m_valid(mv),.m_ready(mr),.m_data(md),.m_last(ml),.done(done),.error(error));
    function automatic logic[7:0] value(input int pixel,c);
        return (pixel*17+c*29+frame*61)%256;
    endfunction
    always @(negedge clk) begin ticks++; mr=(ticks%7>2); end
    always @(posedge clk) if(rst_n && mv && mr) begin
        if(seen>=N || ml!==(seen==N-1)) $fatal(1,"generic count/last C%0d H%0d W%0d",C,H,W);
        for(int lane=0;lane<8;lane++)
            if(md[lane*8+:8] !== value(seen/T,(seen%T)*8+lane))
                $fatal(1,"generic order C%0d H%0d W%0d beat%0d",C,H,W,seen);
        seen++;
    end
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        for(int f=0;f<2;f++) begin
            frame=f; seen=0;
            if(f!=0) begin @(negedge clk); restart=1; @(negedge clk); restart=0; end
            for(int b=0;b<N;b++) begin
                @(negedge clk); sv=1; sl=(b==N-1);
                for(int lane=0;lane<8;lane++) sd[lane*8+:8]=value(b%P,(b/P)*8+lane);
                @(posedge clk); while(!sr) @(posedge clk);
                @(negedge clk); sv=0; sl=0;
            end
            wait(done); repeat(10) @(negedge clk);
            if(seen!=N || error) $fatal(1,"generic completion");
        end
        complete=1;
    end
endmodule
module tb_tile_major_repack;
    wire a,b,c;
    repack_geometry_case #(.C(8),.H(1),.W(1)) single_word(a);
    repack_geometry_case #(.C(24),.H(3),.W(5)) three_planes(b);
    repack_geometry_case #(.C(32),.H(2),.W(3)) four_planes(c);
    initial begin wait(a && b && c); $display("PASS tb_tile_major_repack: 1/3/4 planes, non-power-of-two spatial sizes, two frames"); $finish; end
    initial begin #1000000; $fatal(1,"generic repack timeout"); end
endmodule
