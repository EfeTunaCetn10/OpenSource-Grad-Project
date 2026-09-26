`timescale 1ns/1ps

// HWC line buffer: a ring of K_H rows in eight byte banks.  The bank is
// logical-row-byte modulo eight, so each bank is a plain byte memory with one
// read port and one serialized write port.  The gather stage therefore needs
// one read per cycle and never more than two ports per memory, while the
// external beat still contains eight spatial positions.
//
// AXIS beats are serialized because one beat can touch a bank several times
// and can cross a row boundary (conv2 has 84-byte rows).  The ring is not
// overwritten until the current output row has drained, so K_H rows suffice.
module line_buffer #(
    parameter int K_H        = 5,
    parameter int C_IN       = 3,
    parameter int IN_W       = 32,
    parameter int IN_H       = 32,
    parameter int DATA_WIDTH = 8
) (
    input  logic                         clk,
    input  logic                         rst_n,
    input  logic                         allow_input,
    input  logic                         resume_write,
    input  logic                         s_valid,
    output logic                         s_ready,
    input  logic [63:0]                  s_data,
    input  logic                         s_last,
    output logic                         write_busy,
    output logic [$clog2(IN_H+1)-1:0]    rows_written,
    output logic                         frame_done,
    input  logic                         rd_en,
    input  logic [$clog2(IN_H+1)-1:0]    rd_row,
    input  logic [$clog2(IN_W+1)-1:0]    rd_col,
    input  logic [$clog2(C_IN+1)-1:0]    rd_ch,
    output logic                         rd_valid,
    output logic [DATA_WIDTH-1:0]        rd_byte
);
    localparam int ROW_BYTES   = IN_W * C_IN;
    localparam int BYTE_GROUPS = (ROW_BYTES + 7) / 8;
    localparam int MEM_DEPTH   = K_H * BYTE_GROUPS;
    localparam int TOTAL_BYTES = IN_H * ROW_BYTES;
    localparam int ROW_W       = (IN_H < 1) ? 1 : $clog2(IN_H+1);

    (* ram_style = "block" *) logic [DATA_WIDTH-1:0] byte_mem [0:7][0:MEM_DEPTH-1];
    logic [63:0] beat_reg;
    logic        beat_pending;
    logic        row_pause;
    integer     beat_lane;
    integer     frame_byte_count;
    integer     next_count;
    integer     byte_row;
    integer     byte_col_in_row;
    integer     byte_bank;
    integer     byte_addr;
    integer     completed_rows;
    integer     rd_byte_index;
    integer     rd_bank;
    integer     rd_addr;

    assign write_busy = beat_pending && !row_pause;
    assign s_ready = allow_input && !beat_pending && !frame_done &&
                     (frame_byte_count < TOTAL_BYTES);

    always_comb begin
        rd_valid      = 1'b0;
        rd_byte       = '0;
        rd_byte_index = 0;
        rd_bank       = 0;
        rd_addr       = 0;
        if (rd_en && (int'(rd_row) < int'(rows_written)) &&
            (int'(rd_row) < IN_H) && (int'(rd_col) < IN_W) &&
            (int'(rd_ch) < C_IN)) begin
            rd_byte_index = int'(rd_col)*C_IN + int'(rd_ch);
            rd_bank = rd_byte_index % 8;
            rd_addr = (int'(rd_row) % K_H) * BYTE_GROUPS +
                      (rd_byte_index / 8);
            rd_byte = byte_mem[rd_bank][rd_addr];
            rd_valid = 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            beat_reg         <= '0;
            beat_pending     <= 1'b0;
            row_pause        <= 1'b0;
            beat_lane        <= 0;
            frame_byte_count <= 0;
            rows_written     <= '0;
            frame_done       <= 1'b0;
        end else begin
            if (row_pause) begin
                // A beat crossed the last byte of the retained ring.  Hold
                // its remaining lanes until the generator has drained the
                // output row that still uses the overwritten slot.
                if (resume_write)
                    row_pause <= 1'b0;
            end

            if (s_valid && s_ready) begin
                beat_reg     <= s_data;
                beat_pending <= 1'b1;
                beat_lane    <= 0;
            end

            if (beat_pending && !row_pause) begin
                if (frame_byte_count < TOTAL_BYTES) begin
                    byte_row        = frame_byte_count / ROW_BYTES;
                    byte_col_in_row = frame_byte_count % ROW_BYTES;
                    byte_bank       = byte_col_in_row % 8;
                    byte_addr       = (byte_row % K_H) * BYTE_GROUPS +
                                      (byte_col_in_row / 8);
                    byte_mem[byte_bank][byte_addr]
                        <= beat_reg[beat_lane*DATA_WIDTH +: DATA_WIDTH];

                    next_count = frame_byte_count + 1;
                    frame_byte_count <= next_count;
                    completed_rows = next_count / ROW_BYTES;
                    if (completed_rows > int'(rows_written))
                        rows_written <= completed_rows[ROW_W-1:0];

                    if (next_count >= TOTAL_BYTES) begin
                        frame_done   <= 1'b1;
                        beat_pending <= 1'b0;
                    end else if (beat_lane == 7) begin
                        beat_pending <= 1'b0;
                    end else if ((next_count % ROW_BYTES) == 0) begin
                        row_pause <= 1'b1;
                        beat_lane <= beat_lane + 1;
                    end else begin
                        beat_lane <= beat_lane + 1;
                    end
                end else begin
                    beat_pending <= 1'b0;
                    frame_done   <= 1'b1;
                end
            end
        end
    end

    // Fixed eight-byte beats have no TKEEP; geometry is the byte-count
    // contract.  Keep s_last in the interface for the DMA wrapper.
    logic unused_s_last;
    always_comb unused_s_last = s_last;
endmodule
