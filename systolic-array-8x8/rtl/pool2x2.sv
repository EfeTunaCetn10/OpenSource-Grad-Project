`timescale 1ns/1ps

// One 64-bit beat is one pixel's TILE signed INT8 channels. Tiles are
// serialized: all pixels of tile 0, then all pixels of tile 1, etc.
module pool2x2 #(
    parameter int IN_H = 28,
    parameter int IN_W = 28,
    parameter int C_LOGICAL = 6,
    parameter int TILE = 8
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic             s_valid,
    output logic             s_ready,
    input  logic [TILE*8-1:0] s_data,
    input  logic             s_last = 1'b0,
    output logic             m_valid,
    input  logic             m_ready,
    output logic [TILE*8-1:0] m_data,
    output logic             m_last
);
    localparam int N_TILES = (C_LOGICAL + TILE - 1) / TILE;
    localparam int TOTAL_H = IN_H * N_TILES;
    localparam int ROW_W = $clog2(TOTAL_H+1);
    localparam int COL_W = $clog2(IN_W+1);
    localparam int CH_W = $clog2(TILE+1);
    localparam int TOTAL_OUT = N_TILES * (IN_H/2) * (IN_W/2);
    localparam int COUNT_W = $clog2(TOTAL_OUT+1);

    generate
        if (IN_H <= 0 || IN_W <= 0 || IN_H % 2 != 0 || IN_W % 2 != 0 ||
            C_LOGICAL <= 0 || TILE != 8) begin : g_bad_geometry
            illegal_pool2x2_parameters u_guard ();
        end
    endgenerate
`ifndef SYNTHESIS
    initial begin
        if (IN_H <= 0 || IN_W <= 0 || IN_H % 2 != 0 || IN_W % 2 != 0 ||
            C_LOGICAL <= 0 || TILE != 8)
            $fatal(1, "pool2x2: geometry requires positive even H/W and TILE=8");
    end
`endif

    logic [ROW_W-1:0] rows_written;
    logic frame_done, rd_en, rd_valid;
    logic [ROW_W-1:0] rd_row;
    logic [COL_W-1:0] rd_col;
    logic [CH_W-1:0] rd_ch;
    logic [7:0] rd_byte;
    logic [ROW_W-1:0] pair_row;
    logic [COL_W-1:0] out_col;
    logic [CH_W-1:0] channel;
    logic [1:0] quadrant;
    logic signed [7:0] max_byte;
    logic [TILE*8-1:0] word_reg;
    logic [COUNT_W-1:0] out_count;
    logic write_busy;

    typedef enum logic [1:0] {WAIT_PAIR, ISSUE, CAPTURE, HOLD} state_t;
    state_t state;

    // The two rows belonging to the current output row remain resident until
    // every output beat has handshaken. K_H=3 avoids a power-of-two width
    // truncation in line_buffer's existing K_H_VALUE constant.
    line_buffer #(
        .K_H(3), .C_LOGICAL(TILE), .C_PHYS_STRIDE(TILE),
        .IN_W(IN_W), .IN_H(TOTAL_H), .DATA_WIDTH(8)
    ) u_rows (
        .clk(clk), .rst_n(rst_n), .clear(1'b0),
        .allow_input(rows_written < pair_row + ROW_W'(2)),
        .resume_write(1'b1), .s_valid(s_valid), .s_ready(s_ready),
        .s_data(s_data), .s_last(s_last), .write_busy(write_busy),
        .rows_written(rows_written), .frame_done(frame_done),
        .rd_en(rd_en), .rd_row(rd_row), .rd_col(rd_col), .rd_ch(rd_ch),
        .rd_valid(rd_valid), .rd_byte(rd_byte)
    );

    assign rd_en = state == ISSUE;
    assign rd_row = pair_row + ROW_W'(quadrant[1]);
    assign rd_col = COL_W'(2*out_col + quadrant[0]);
    assign rd_ch = channel;
    assign m_last = m_valid && out_count == COUNT_W'(TOTAL_OUT-1);

    logic signed [7:0] selected;
    logic [TILE*8-1:0] word_next;
    always_comb begin
        selected = (quadrant == 0 || $signed(rd_byte) > max_byte)
                 ? $signed(rd_byte) : max_byte;
        word_next = word_reg;
        word_next[channel*8 +: 8] = selected;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pair_row <= '0;
            out_col <= '0;
            channel <= '0;
            quadrant <= '0;
            max_byte <= '0;
            word_reg <= '0;
            m_data <= '0;
            m_valid <= 1'b0;
            out_count <= '0;
            state <= WAIT_PAIR;
        end else begin
            case (state)
                WAIT_PAIR: if (rows_written >= pair_row + ROW_W'(2) &&
                               out_count < COUNT_W'(TOTAL_OUT)) begin
                    channel <= '0;
                    quadrant <= '0;
                    state <= ISSUE;
                end
                ISSUE: state <= CAPTURE;
                CAPTURE: if (rd_valid) begin
                    max_byte <= selected;
                    if (quadrant != 2'd3) begin
                        quadrant <= quadrant + 1'b1;
                        state <= ISSUE;
                    end else begin
                        word_reg <= word_next;
                        quadrant <= '0;
                        if (channel != CH_W'(TILE-1)) begin
                            channel <= channel + 1'b1;
                            state <= ISSUE;
                        end else begin
                            m_data <= word_next;
                            m_valid <= 1'b1;
                            state <= HOLD;
                        end
                    end
                end
                HOLD: if (m_valid && m_ready) begin
                    m_valid <= 1'b0;
                    out_count <= out_count + 1'b1;
                    if (out_col == COL_W'(IN_W/2-1)) begin
                        out_col <= '0;
                        pair_row <= pair_row + ROW_W'(2);
                    end else begin
                        out_col <= out_col + 1'b1;
                    end
                    state <= WAIT_PAIR;
                end
                default: state <= WAIT_PAIR;
            endcase
        end
    end
endmodule
