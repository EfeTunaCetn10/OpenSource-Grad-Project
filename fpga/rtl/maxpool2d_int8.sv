`timescale 1ns/1ps
// 2x2 stride-2 signed INT8 max selection. Both streams are [c_tile][H][W][8].
// Whole eight-channel planes only; even H/W >=2. No scale, rounding or bias.
// POC s_last/m_last mark the complete tensor, not individual compute tiles.
module maxpool2d_int8 #(
    parameter int CHANNELS=16, HEIGHT=32, WIDTH=32
)(
    input logic clk,rst_n,restart,
    input logic s_valid, output logic s_ready,
    input logic [63:0] s_data, input logic s_last,
    output logic m_valid, input logic m_ready,
    output logic [63:0] m_data, output logic m_last,
    output logic done, output logic error
);
    localparam int TILES=CHANNELS/8;
    localparam int RW=(HEIGHT>1)?$clog2(HEIGHT):1;
    localparam int CW=(WIDTH>1)?$clog2(WIDTH):1;
    localparam int TW=(TILES>1)?$clog2(TILES):1;
    generate if(CHANNELS<8 || CHANNELS%8!=0 || HEIGHT<2 || WIDTH<2 ||
                HEIGHT%2!=0 || WIDTH%2!=0) begin : bad_geometry
        invalid_maxpool2d_int8_geometry invalid_configuration();
    end endgenerate
    logic [RW-1:0] row;
    logic [CW-1:0] col;
    logic [TW-1:0] tile;
    logic started,input_done,restart_ok,last_input;
    logic [63:0] left_word,top_pair;
    // WIDTH/2 words, reused for each row pair and each channel tile.
    (* ram_style="distributed" *) logic [63:0] row_pairs [0:WIDTH/2-1];
    function automatic [63:0] max_lanes(input logic [63:0] a,b);
        for(int lane=0;lane<8;lane++)
            max_lanes[lane*8+:8]=($signed(a[lane*8+:8]) >= $signed(b[lane*8+:8]))
                                  ? a[lane*8+:8] : b[lane*8+:8];
    endfunction
    assign last_input=(tile==TILES-1 && row==HEIGHT-1 && col==WIDTH-1);
    assign restart_ok=restart && (done || !started);
    assign s_ready=rst_n && !restart && !input_done && (!m_valid || m_ready);
    // On an odd row, the first pixel's handshake reads the preceding row's
    // horizontal maximum. It is available before the second pixel can arrive.
    always_ff @(posedge clk) begin
        if(s_valid && s_ready) begin
            if(!row[0] && col[0]) row_pairs[col>>1] <= max_lanes(left_word,s_data);
            if(row[0] && !col[0]) top_pair <= row_pairs[col>>1];
        end
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            row<=0; col<=0; tile<=0; started<=0; input_done<=0;
            left_word<=0; m_valid<=0; m_data<=0; m_last<=0; done<=0; error<=0;
        end else if(restart_ok) begin
            row<=0; col<=0; tile<=0; started<=0; input_done<=0;
            left_word<=0; m_valid<=0; m_data<=0; m_last<=0; done<=0;
        end else begin
            if(restart) error<=1;
            if(m_valid && m_ready) begin
                m_valid<=0;
                if(m_last) done<=1;
            end
            if(s_valid && s_ready) begin
                started<=1;
                if(s_last!=last_input) error<=1;
                if(!col[0]) left_word<=s_data;
                if(row[0] && col[0]) begin
                    m_data<=max_lanes(top_pair,max_lanes(left_word,s_data));
                    m_valid<=1; m_last<=last_input;
                end
                if(last_input) input_done<=1;
                else if(col==WIDTH-1) begin
                    col<=0;
                    if(row==HEIGHT-1) begin row<=0; tile<=tile+1'b1; end
                    else row<=row+1'b1;
                end else col<=col+1'b1;
            end
        end
    end
`ifndef SYNTHESIS
    assert property(@(posedge clk) disable iff(!rst_n)
        m_valid && !m_ready |=> m_valid && $stable({m_data,m_last}))
        else $fatal(1,"pool changed stalled output");
`endif
endmodule
