`timescale 1ns/1ps

// Requant beat to padded [c_tile][h][w][lane] storage. Configuration is
// sampled during the two setup cycles before a frame; hold it through in_last.
module act_buffer #(
    parameter int LANES = 8,
    parameter int OUT_H_MAX = 28,
    parameter int OUT_W_MAX = 28,
    parameter int C_TILE_MAX = 2,
    parameter int DEPTH = 784,
    parameter int COL_W = 4
) (
    input  logic clk, rst_n,
    input  logic [$clog2(OUT_H_MAX+1)-1:0] cfg_out_h,
    input  logic [$clog2(OUT_W_MAX+1)-1:0] cfg_out_w,
    input  logic [$clog2(C_TILE_MAX+1)-1:0] cfg_c_tile,
    input  logic in_valid,
    output logic in_ready,
    input  logic [LANES*8-1:0] in_y_flat,
    input  logic [LANES-1:0] in_lane_valid,
    input  logic [COL_W-1:0] in_col,
    input  logic in_last,
    input  logic rd_en,
    input  logic [$clog2(DEPTH)-1:0] rd_addr,
    output logic rd_valid,
    output logic [LANES*8-1:0] rd_data,
    output logic buf_sel,
    output logic [31:0] frame_count,
    output logic seq_error,
    output logic ovf_error
);
    localparam int H_W = $clog2(OUT_H_MAX+1);
    localparam int W_W = $clog2(OUT_W_MAX+1);
    localparam int A_W = $clog2(C_TILE_MAX*OUT_H_MAX*OUT_W_MAX+1);
    typedef enum logic [1:0] {INIT_AREA, INIT_BASE, RUN} state_t;
    state_t state;
    logic [H_W-1:0] h;
    logic [W_W-1:0] tile_x;
    logic [COL_W-1:0] col;
    logic [A_W-1:0] plane_area, word_ptr;
    logic [LANES*8-1:0] write_word;
    logic accept, write_fire, last_position, bad_beat;
    logic [1:0] bank_read;
    logic [LANES*8-1:0] bank_q [0:1];
    logic [W_W:0] absolute_col;

    assign absolute_col = {1'b0,tile_x} + col;
    assign last_position = (h == cfg_out_h-1'b1) &&
                           (absolute_col == cfg_out_w-1'b1);
    assign in_ready = (state == RUN) && !seq_error && !ovf_error;
    assign accept = in_valid && in_ready;
    assign bad_beat = (in_col != col) || (in_last != last_position) ||
                      (cfg_out_h == 0) || (cfg_out_w == 0) ||
                      (cfg_out_h > OUT_H_MAX) || (cfg_out_w > OUT_W_MAX) ||
                      (cfg_c_tile >= C_TILE_MAX);
    assign write_fire = accept && !bad_beat && (word_ptr < DEPTH);

    genvar r;
    generate for (r=0; r<LANES; r=r+1) begin : g_mask
        assign write_word[r*8 +: 8] = in_lane_valid[r] ? in_y_flat[r*8 +: 8] : 8'b0;
    end endgenerate

    // Two independent one-dimensional arrays. Each 784x64 array uses block
    // RAM efficiently; line_buffer's 60-70-entry byte banks use LUTRAM instead.
    // Each array has one aligned 64-bit write and one synchronous read port.
    genvar b;
    generate for (b=0; b<2; b=b+1) begin : g_buffer
        (* ram_style = "block" *) logic [LANES*8-1:0] mem [0:DEPTH-1];
        always_ff @(posedge clk) begin
            if (write_fire && buf_sel == b[0]) mem[word_ptr] <= write_word;
            if (rd_en && buf_sel != b[0] && rd_addr < DEPTH)
                bank_q[b] <= mem[rd_addr];
        end
    end endgenerate

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= INIT_AREA;
            plane_area <= '0;
            word_ptr <= '0;
            h <= '0;
            tile_x <= '0;
            col <= '0;
            buf_sel <= 1'b0;
            frame_count <= '0;
            seq_error <= 1'b0;
            ovf_error <= 1'b0;
            rd_valid <= 1'b0;
            bank_read <= '0;
        end else begin
            rd_valid <= rd_en && (rd_addr < DEPTH);
            if (rd_en) bank_read <= {1'b0,~buf_sel};
            case (state)
                INIT_AREA: begin
                    plane_area <= cfg_out_h * cfg_out_w;
                    state <= INIT_BASE;
                end
                INIT_BASE: begin
                    word_ptr <= plane_area * cfg_c_tile;
                    h <= '0;
                    tile_x <= '0;
                    col <= '0;
                    state <= RUN;
                end
                RUN: if (accept) begin
                    if (bad_beat) seq_error <= 1'b1;
                    else if (word_ptr >= DEPTH) ovf_error <= 1'b1;
                    else begin
                        word_ptr <= word_ptr + 1'b1;
                        if (in_last) begin
                            buf_sel <= ~buf_sel;
                            frame_count <= frame_count + 1'b1;
                            state <= INIT_AREA;
                        end else if (absolute_col == cfg_out_w-1'b1) begin
                            h <= h + 1'b1;
                            tile_x <= '0;
                            col <= '0;
                        end else if (col == COL_W'(7)) begin
                            tile_x <= tile_x + W_W'(8);
                            col <= '0;
                        end else col <= col + 1'b1;
                    end
                end
                default: state <= INIT_AREA;
            endcase
        end
    end
    assign rd_data = bank_q[bank_read[0]];

    initial begin
        if (LANES != 8 || COL_W < 3 || DEPTH < 1)
            $error("act_buffer requires LANES=8, COL_W>=3, DEPTH>=1");
    end
endmodule
