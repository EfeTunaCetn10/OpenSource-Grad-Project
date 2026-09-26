`timescale 1ns/1ps

// Parametric valid-convolution window generator.
//
// The output order is output-row, eight-column tile, then
//   k = ci*(K_H*K_W) + kh*K_W + kw.
// Each output beat contains eight positions at the same k, exactly matching
// compute_engine's B-top activation edge.  The final tile of a row reports
// only its real columns in m_active_cols and zeroes all inactive lanes.
//
// A gather takes eight line-buffer reads (one pixel per cycle), then presents
// one 64-bit activation beat.  The line buffer has eight banks with one read
// port each; the gather therefore needs one read port per cycle, never more
// than two per memory.  It also means overlapping adjacent windows share the
// same K_H-row ring and do not require eight independent windows.
//
// PAD is retained as a parameter and zero padding is generated for coordinates
// outside the input frame.  The Stage-1 contract is PAD=0; a production
// non-zero-padding design would additionally need an explicit border policy
// in the DMA/frame contract and verification vectors.
module window_gen #(
    parameter int K_H        = 5,
    parameter int K_W        = 5,
    parameter int C_IN       = 3,
    parameter int IN_W       = 32,
    parameter int IN_H       = 32,
    parameter int STRIDE     = 1,
    parameter int PAD        = 0,
    parameter int DATA_WIDTH = 8
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        s_valid,
    output logic        s_ready,
    input  logic [63:0] s_data,
    input  logic        s_last,

    output logic        m_valid,
    input  logic        m_ready,
    output logic [63:0] m_data,
    output logic [3:0]  m_active_cols,
    output logic [31:0] m_k,
    output logic [31:0] m_tile_row,
    output logic [31:0] m_tile_x,
    output logic        m_tile_start,
    output logic        m_tile_last,
    output logic        done
);
    localparam int OUT_W = ((IN_W + 2*PAD - K_W) / STRIDE) + 1;
    localparam int OUT_H = ((IN_H + 2*PAD - K_H) / STRIDE) + 1;
    localparam int K_LEN = C_IN * K_H * K_W;
    localparam int ROW_W = (IN_H < 1) ? 1 : $clog2(IN_H+1);
    localparam int COL_W = (IN_W < 1) ? 1 : $clog2(IN_W+1);

    typedef enum logic [2:0] {ST_INPUT, ST_READ, ST_OUTPUT, ST_DONE} state_t;
    state_t state;

    logic allow_input;
    logic resume_write;
    logic lb_write_busy;
    logic [ROW_W-1:0] rows_written;
    logic lb_frame_done;
    logic lb_rd_en;
    logic [ROW_W-1:0] lb_rd_row;
    logic [COL_W-1:0] lb_rd_col;
    logic [$clog2(C_IN+1)-1:0] lb_rd_ch;
    logic lb_rd_valid;
    logic [DATA_WIDTH-1:0] lb_rd_byte;

    line_buffer #(
        .K_H        (K_H),
        .C_IN       (C_IN),
        .IN_W       (IN_W),
        .IN_H       (IN_H),
        .DATA_WIDTH (DATA_WIDTH)
    ) u_line_buffer (
        .clk          (clk),
        .rst_n        (rst_n),
        .allow_input  (allow_input),
        .resume_write (resume_write),
        .s_valid      (s_valid),
        .s_ready      (s_ready),
        .s_data      (s_data),
        .s_last      (s_last),
        .write_busy   (lb_write_busy),
        .rows_written (rows_written),
        .frame_done   (lb_frame_done),
        .rd_en        (lb_rd_en),
        .rd_row       (lb_rd_row),
        .rd_col       (lb_rd_col),
        .rd_ch        (lb_rd_ch),
        .rd_valid     (lb_rd_valid),
        .rd_byte      (lb_rd_byte)
    );

    integer out_y;
    integer tile_x;
    integer k_count;
    integer gather_lane;
    integer ci_index;
    integer kh_index;
    integer kw_index;
    integer source_row;
    integer source_col;
    integer bottom_row;
    integer active_count;
    logic [63:0] gather_reg;

    always_comb begin
        allow_input = (state == ST_INPUT);
        bottom_row = out_y*STRIDE - PAD + K_H - 1;
        resume_write = 1'b0;
        if ((state == ST_INPUT) && !lb_write_busy &&
            (bottom_row >= -1) && (int'(rows_written) > bottom_row) &&
            (out_y < OUT_H))
            allow_input = 1'b0;
        else if (state == ST_INPUT)
            resume_write = 1'b1;
        m_valid = (state == ST_OUTPUT);
        m_data = gather_reg;
        m_k = k_count;
        m_tile_row = out_y;
        m_tile_x = tile_x;
        active_count = OUT_W - tile_x;
        if (active_count > 8)
            active_count = 8;
        if (active_count < 0)
            active_count = 0;
        m_active_cols = active_count[3:0];
        m_tile_start = (state == ST_OUTPUT) && (k_count == 0);
        m_tile_last = (state == ST_OUTPUT) && (k_count == K_LEN-1);
        done = (state == ST_DONE);

        ci_index = k_count / (K_H*K_W);
        kh_index = (k_count / K_W) % K_H;
        kw_index = k_count % K_W;
        source_row = out_y*STRIDE - PAD + kh_index;
        source_col = tile_x*STRIDE - PAD + kw_index + gather_lane*STRIDE;

        lb_rd_en = 1'b0;
        lb_rd_row = '0;
        lb_rd_col = '0;
        lb_rd_ch = '0;
        if (state == ST_READ && (gather_lane < active_count) &&
            (source_row >= 0) && (source_row < IN_H) &&
            (source_col >= 0) && (source_col < IN_W)) begin
            lb_rd_en = 1'b1;
            lb_rd_row = source_row[ROW_W-1:0];
            lb_rd_col = source_col[COL_W-1:0];
            lb_rd_ch = ci_index[$clog2(C_IN+1)-1:0];
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state       <= ST_INPUT;
            out_y       <= 0;
            tile_x      <= 0;
            k_count     <= 0;
            gather_lane <= 0;
            gather_reg  <= '0;
        end else begin
            case (state)
                ST_INPUT: begin
                    // A row can finish in the middle of an AXIS beat.  The
                    // line buffer keeps write_busy asserted until all eight
                    // bytes have landed, so no partially-written row is read.
                    if (!lb_write_busy && (bottom_row >= -1) &&
                        (int'(rows_written) > bottom_row) &&
                        (out_y < OUT_H)) begin
                        tile_x      <= 0;
                        k_count     <= 0;
                        gather_lane <= 0;
                        gather_reg  <= '0;
                        state       <= ST_READ;
                    end
                end

                ST_READ: begin
                    if ((gather_lane < active_count) && lb_rd_valid)
                        gather_reg[gather_lane*DATA_WIDTH +: DATA_WIDTH]
                            <= lb_rd_byte;
                    else
                        gather_reg[gather_lane*DATA_WIDTH +: DATA_WIDTH] <= '0;

                    if (gather_lane == 7) begin
                        gather_lane <= 0;
                        state <= ST_OUTPUT;
                    end else begin
                        gather_lane <= gather_lane + 1;
                    end
                end

                ST_OUTPUT: begin
                    if (m_ready) begin
                        if (k_count == K_LEN-1) begin
                            if (tile_x + 8 >= OUT_W) begin
                                if (out_y + 1 >= OUT_H) begin
                                    state <= ST_DONE;
                                end else begin
                                    out_y       <= out_y + 1;
                                    tile_x      <= 0;
                                    k_count     <= 0;
                                    gather_lane <= 0;
                                    gather_reg  <= '0;
                                    state       <= ST_INPUT;
                                end
                            end else begin
                                tile_x      <= tile_x + 8;
                                k_count     <= 0;
                                gather_lane <= 0;
                                gather_reg  <= '0;
                                state       <= ST_READ;
                            end
                        end else begin
                            k_count     <= k_count + 1;
                            gather_lane <= 0;
                            gather_reg  <= '0;
                            state       <= ST_READ;
                        end
                    end
                end

                ST_DONE: begin
                    state <= ST_DONE;
                end

                default: state <= ST_INPUT;
            endcase
        end
    end
endmodule
