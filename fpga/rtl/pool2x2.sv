`timescale 1ns/1ps

// One 64-bit beat is one pixel's TILE signed INT8 channels. Tiles are
// serialized: all pixels of tile 0, then all pixels of tile 1, etc.
module pool2x2 #(
    parameter int IN_H_MAX = 48,
    parameter int IN_W_MAX = 48,
    parameter int C_TILE_MAX = 4,
    parameter int TILE = 8
) (
    input  logic             clk,
    input  logic             rst_n,
    input  logic [$clog2(IN_H_MAX+1)-1:0] cfg_in_h,
    input  logic [$clog2(IN_W_MAX+1)-1:0] cfg_in_w,
    input  logic [$clog2(C_TILE_MAX+1)-1:0] cfg_c_tiles,
    input  logic             s_valid,
    output logic             s_ready,
    input  logic [TILE*8-1:0] s_data,
    input  logic             s_last = 1'b0,
    output logic             m_valid,
    input  logic             m_ready,
    output logic [TILE*8-1:0] m_data,
    output logic             m_last,
    output logic             cfg_error
);
    localparam int H_W = $clog2(IN_H_MAX+1);
    localparam int W_W = $clog2(IN_W_MAX+1);
    localparam int CT_W = $clog2(C_TILE_MAX+1);
    localparam int HALF_W_MAX = (IN_W_MAX+1)/2;

    generate
        if (IN_H_MAX < 2 || IN_W_MAX < 2 || C_TILE_MAX < 1 || TILE != 8) begin : g_bad_envelope
            illegal_pool2x2_parameters u_guard ();
        end
    endgenerate
`ifndef SYNTHESIS
    initial begin
        if (IN_H_MAX < 2 || IN_W_MAX < 2 || C_TILE_MAX < 1 || TILE != 8)
            $fatal(1, "pool2x2: envelope requires H/W >= 2, tiles >= 1, and TILE=8");
    end
`endif

    logic [H_W-1:0] cfg_in_h_q;
    logic [W_W-1:0] cfg_in_w_q;
    logic [CT_W-1:0] cfg_c_tiles_q;
    logic cfg_loaded, cfg_valid, cfg_matches, frame_active;
    logic [H_W-1:0] in_row;
    logic [W_W-1:0] in_col;
    logic [CT_W-1:0] in_tile;
    logic [TILE*8-1:0] even_word;
    logic [TILE*8-1:0] row_max [0:HALF_W_MAX-1];
    logic [TILE*8-1:0] horizontal_max, pooled_word;
    logic accept;

    function automatic logic [TILE*8-1:0] lane_max(
        input logic [TILE*8-1:0] a,
        input logic [TILE*8-1:0] b
    );
        integer lane;
        begin
            for (lane=0; lane<TILE; lane=lane+1)
                lane_max[lane*8 +: 8] =
                    ($signed(a[lane*8 +: 8]) >= $signed(b[lane*8 +: 8]))
                    ? a[lane*8 +: 8] : b[lane*8 +: 8];
        end
    endfunction

    always_comb begin
        cfg_valid = (cfg_in_h != 0) && (cfg_in_w != 0) &&
                    !cfg_in_h[0] && !cfg_in_w[0] &&
                    (cfg_in_h <= IN_H_MAX) && (cfg_in_w <= IN_W_MAX) &&
                    (cfg_c_tiles != 0) && (cfg_c_tiles <= C_TILE_MAX);
        cfg_matches = (cfg_in_h_q == cfg_in_h) &&
                      (cfg_in_w_q == cfg_in_w) &&
                      (cfg_c_tiles_q == cfg_c_tiles);
        horizontal_max = lane_max(even_word, s_data);
        pooled_word = lane_max(row_max[in_col >> 1], horizontal_max);
    end

    // A changed idle configuration is sampled for one cycle before ready.
    // During a frame only the registered geometry participates in control.
    assign s_ready = !cfg_error && cfg_loaded &&
                     (frame_active || (cfg_valid && cfg_matches)) &&
                     (frame_active || !m_valid) && (!m_valid || m_ready);
    assign accept = s_valid && s_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cfg_in_h_q <= '0;
            cfg_in_w_q <= '0;
            cfg_c_tiles_q <= '0;
            cfg_loaded <= 1'b0;
            cfg_error <= 1'b0;
            frame_active <= 1'b0;
            in_row <= '0;
            in_col <= '0;
            in_tile <= '0;
            even_word <= '0;
            m_valid <= 1'b0;
            m_data <= '0;
            m_last <= 1'b0;
        end else begin
            if (!frame_active && !m_valid) begin
                cfg_in_h_q <= cfg_in_h;
                cfg_in_w_q <= cfg_in_w;
                cfg_c_tiles_q <= cfg_c_tiles;
                cfg_loaded <= 1'b1;
                cfg_error <= !cfg_valid;
            end

            if (m_valid && m_ready) begin
                m_valid <= 1'b0;
                m_last <= 1'b0;
            end

            if (accept) begin
                if (!frame_active) frame_active <= 1'b1;

                if (!in_col[0]) begin
                    even_word <= s_data;
                end else if (!in_row[0]) begin
                    row_max[in_col >> 1] <= horizontal_max;
                end else begin
                    m_data <= pooled_word;
                    m_valid <= 1'b1;
                    m_last <= (in_tile == cfg_c_tiles_q-1'b1) &&
                              (in_row == cfg_in_h_q-1'b1) &&
                              (in_col == cfg_in_w_q-1'b1);
                end

                if (in_col == cfg_in_w_q-1'b1) begin
                    in_col <= '0;
                    if (in_row == cfg_in_h_q-1'b1) begin
                        in_row <= '0;
                        if (in_tile == cfg_c_tiles_q-1'b1) begin
                            in_tile <= '0;
                            frame_active <= 1'b0;
                        end else begin
                            in_tile <= in_tile + 1'b1;
                        end
                    end else begin
                        in_row <= in_row + 1'b1;
                    end
                end else begin
                    in_col <= in_col + 1'b1;
                end
            end
        end
    end

    // Fixed eight-byte beats have no TKEEP; geometry is the byte-count
    // contract. Keep s_last in the interface for the DMA wrapper.
    logic unused_s_last;
    always_comb unused_s_last = s_last;
endmodule
