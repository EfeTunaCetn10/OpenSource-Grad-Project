`timescale 1ns/1ps
// Full-frame tile-major [c_tile][H][W][8] to internal dense-HWC stream.
// One synchronous 64-bit RAM. Full reload after restart; no numerical changes.
// CHANNELS must be a positive multiple of 8; HEIGHT/WIDTH positive.
module tile_major_repack #(
    parameter int CHANNELS=16, HEIGHT=16, WIDTH=16
) (
    input logic clk, rst_n, restart,
    input logic s_valid, output logic s_ready,
    input logic [63:0] s_data, input logic s_last,
    output logic m_valid, input logic m_ready,
    output logic [63:0] m_data, output logic m_last,
    output logic done, output logic error
);
    localparam int TILES=CHANNELS/8;
    localparam int PIXELS=HEIGHT*WIDTH;
    localparam int WORDS=TILES*PIXELS;
    localparam int AW=(WORDS>1) ? $clog2(WORDS) : 1;
    localparam int PW=(PIXELS>1) ? $clog2(PIXELS) : 1;
    localparam int TW=(TILES>1) ? $clog2(TILES) : 1;
    // Only whole eight-channel planes are supported; no silent padding policy.
    generate if(CHANNELS<8 || CHANNELS%8!=0 || HEIGHT<1 || WIDTH<1) begin : bad_geometry
        invalid_tile_major_repack_geometry invalid_configuration();
    end endgenerate
    typedef enum logic [2:0] {LOAD, READ_WORD, WAIT_WORD, SEND, DONE} state_t;
    state_t state;
    (* ram_style = "block" *) logic [63:0] memory [0:WORDS-1];
    logic [AW-1:0] load_index, read_address;
    logic [PW-1:0] pixel_index;
    logic [TW-1:0] channel_tile;
    logic [63:0] read_data;
    logic restart_ok;
    // Separate tile/pixel counters work for 1, 2, 3, ... planes; no power-of-two
    // bit permutation, division or modulo in the runtime address datapath.
    assign read_address = AW'(channel_tile)*PIXELS + pixel_index;
    assign restart_ok = restart && ((state==DONE) || (state==LOAD && load_index==0));
    assign s_ready = rst_n && state==LOAD && !restart;
    assign m_valid = state==SEND;
    assign m_last = (pixel_index==PIXELS-1) && (channel_tile==TILES-1);
    assign done = state==DONE;
    // Synchronous BRAM read, explicitly separated from the output register.
    always_ff @(posedge clk) begin
        if(s_valid && s_ready) memory[load_index] <= s_data;
        if(state==READ_WORD) read_data <= memory[read_address];
    end
    always_ff @(posedge clk) begin
        if(!rst_n) begin
            state<=LOAD; load_index<=0; pixel_index<=0; channel_tile<=0; m_data<=0; error<=0;
        end else if(restart_ok) begin
            state<=LOAD; load_index<=0; pixel_index<=0; channel_tile<=0; m_data<=0;
        end else begin
            if(restart) error<=1;
            case(state)
                LOAD: if(s_valid && s_ready) begin
                    if(s_last != (load_index==WORDS-1)) error<=1;
                    if(load_index==WORDS-1) begin pixel_index<=0; channel_tile<=0; state<=READ_WORD; end
                    else load_index<=load_index+1'b1;
                end
                READ_WORD: state<=WAIT_WORD;
                WAIT_WORD: begin m_data<=read_data; state<=SEND; end
                SEND: if(m_ready) begin
                    if(m_last) state<=DONE;
                    else begin
                        if(channel_tile==TILES-1) begin
                            channel_tile<=0; pixel_index<=pixel_index+1'b1;
                        end else channel_tile<=channel_tile+1'b1;
                        state<=READ_WORD;
                    end
                end
                DONE: begin end
                default: begin error<=1; state<=LOAD; load_index<=0; end
            endcase
        end
    end
`ifndef SYNTHESIS
    assert property (@(posedge clk) disable iff(!rst_n)
        m_valid && !m_ready |=> m_valid && $stable({m_data,m_last}))
        else $fatal(1,"repack changed a stalled beat");
`endif
endmodule
