`timescale 1ns/1ps

// HWC line buffer: a ring of K_H_MAX rows in eight byte banks.  The bank is
// physical-row-byte modulo eight, so each bank is a plain byte memory with one
// synchronous read port and one serialized write port.  The gather stage
// issues one read per cycle; the registered result is returned one cycle
// later.
//
// AXIS beats are serialized because one beat can touch a bank several times
// and can cross a row boundary (the padded conv2 row is 112 bytes).  The ring
// is not overwritten until the current output row has drained, so any ring of
// at least cfg_kh rows suffices; K_H_MAX rows is the largest kernel.
//
// Runtime geometry (faz3-param).  The frame height and the PHYSICAL row size
// in bytes are quasi-static inputs: the caller changes them only between
// frames.  cfg_row_bytes = in_w * c_phys is the caller's registered product
// (ADR-018 Decision 2: the physical column stride is not the logical channel
// count, see window_gen).  This module never multiplies, divides or takes a
// modulo at runtime:
//
//   * every ring row starts on a power-of-two pitch of ROW_PITCH words, so a
//     bank address is {ring slot, byte group} -- concatenation, not slot*rows;
//   * the read side is handed the ring slot and the physical byte offset
//     directly.  The caller keeps both as wrap/increment counters, which
//     replaces the former `rd_row % K_H` and `rd_col * C_PHYS` cones;
//   * the end-of-row and end-of-frame compares use values re-registered every
//     cycle from the quasi-static inputs, so they are register-to-register.
module line_buffer #(
    parameter int K_H_MAX       = 5,
    parameter int IN_H_MAX      = 48,
    parameter int ROW_BYTES_MAX = 512,
    parameter int DATA_WIDTH    = 8,

    parameter int ROW_W         = (IN_H_MAX < 1) ? 1 : $clog2(IN_H_MAX+1),
    parameter int RING_W        = (K_H_MAX <= 1) ? 1 : $clog2(K_H_MAX+1),
    parameter int BYTE_W        = (ROW_BYTES_MAX <= 1) ? 1 : $clog2(ROW_BYTES_MAX+1)
) (
    input  logic                           clk,
    input  logic                           rst_n,
    // Single-cycle frame restart: returns the write side to its reset state so
    // a fresh frame can be streamed in.  Defaulted so an instantiation that
    // predates this port is driven with a known value instead of 'z.
    input  logic                           clear = 1'b0,
    // Quasi-static frame geometry: rows per frame and physical bytes per row.
    input  logic [ROW_W-1:0]               cfg_in_h,
    input  logic [BYTE_W-1:0]              cfg_row_bytes,
    input  logic                           allow_input,
    input  logic                           resume_write,
    input  logic                           s_valid,
    output logic                           s_ready,
    input  logic [63:0]                    s_data,
    input  logic                           s_last,
    output logic                           write_busy,
    output logic [ROW_W-1:0]               rows_written,
    output logic                           frame_done,
    // rd_row is used only to check that the row has been written; rd_slot is
    // its ring slot and rd_offset its physical byte offset inside the row.
    input  logic                           rd_en,
    input  logic [ROW_W-1:0]               rd_row,
    input  logic [RING_W-1:0]              rd_slot,
    input  logic [BYTE_W-1:0]              rd_offset,
    output logic                           rd_valid,
    output logic [DATA_WIDTH-1:0]          rd_byte
);
    localparam int GROUPS_MAX = (ROW_BYTES_MAX + 7) / 8;
    // A group INDEX runs 0..GROUPS_MAX-1, so $clog2(GROUPS_MAX) is the right
    // width here; it is also the log2 of the power-of-two row pitch.
    localparam int PITCH_W    = (GROUPS_MAX <= 1) ? 1 : $clog2(GROUPS_MAX);
    localparam int MEM_DEPTH  = K_H_MAX << PITCH_W;
    localparam int MEM_ADDR_W = RING_W + PITCH_W;

    localparam logic [RING_W-1:0] LAST_RING_SLOT = K_H_MAX - 1;

    // The ring lives in eight ONE-dimensional arrays declared in the generate
    // block near the bottom, not in one byte_mem [0:7][0:MEM_DEPTH-1]:
    // Vivado 2025.1 does not run RAM inference on a two-dimensional array and
    // builds flip-flops plus a mux cone instead (measured on this file: 3951
    // LUT + 3985 FF with a combinational read, and still 7.38 ns of routing on
    // the critical path once the read was registered).
    //
    // ram_style = "distributed" is deliberate, not a fallback.  With the
    // envelope defaults the ring is K_H_MAX x 64 groups = 320 entries per
    // bank (2560 bytes in all), still small next to a RAMB18 per bank, and it
    // keeps the read path shallow.  Block RAM is the right tool for the
    // weight banks (8192 entries each); it is the wrong tool here.
    logic [DATA_WIDTH-1:0] bank_q [0:7];
    logic [2:0]            rd_bank_q;

    logic [63:0] beat_reg;
    logic        beat_pending;
    logic        row_pause;
    logic [2:0]  beat_lane;

    // The write location advances with the stream.  Keeping the row, byte,
    // ring slot, bank and group explicitly keeps divide/modulo out of the
    // write port.
    logic [ROW_W-1:0]       write_row;
    logic [BYTE_W-1:0]      write_byte_in_row;
    logic [RING_W-1:0]      write_ring_slot;
    logic [2:0]             write_bank;
    logic [PITCH_W-1:0]     write_group;
    logic [MEM_ADDR_W-1:0]  write_addr;

    // Derived geometry, re-registered every cycle.  The inputs are
    // quasi-static, so the one-cycle lag is only visible right after a
    // change, and the first byte of a frame is written at least one cycle
    // after its beat was accepted.
    logic [ROW_W-1:0]       last_row_q;
    logic [BYTE_W-1:0]      last_row_byte_q;
    logic [ROW_W-1:0]       in_h_q;
    logic [BYTE_W-1:0]      row_bytes_q;

    logic                         rd_request_valid;
    logic [MEM_ADDR_W-1:0]        rd_addr_calc;

    assign write_busy = beat_pending && !row_pause;
    // clear blocks the handshake for its own cycle, so a beat cannot be
    // accepted by the handshake and dropped by the clear on the same edge.
    assign s_ready = allow_input && !beat_pending && !frame_done && !clear;
    assign write_addr = {write_ring_slot, write_group};

    always_ff @(posedge clk) begin
        last_row_q      <= cfg_in_h - 1'b1;
        last_row_byte_q <= cfg_row_bytes - 1'b1;
        in_h_q          <= cfg_in_h;
        row_bytes_q     <= cfg_row_bytes;
    end

    always_comb begin
        rd_request_valid = rd_en && (rd_row < rows_written) &&
                           (rd_row < in_h_q) && (rd_offset < row_bytes_q) &&
                           (rd_slot <= LAST_RING_SLOT);
        // Divide by eight is wiring; the slot is the high address field.
        rd_addr_calc = {rd_slot, rd_offset[3 +: PITCH_W]};
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            beat_reg          <= '0;
            beat_pending      <= 1'b0;
            row_pause         <= 1'b0;
            beat_lane         <= '0;
            write_row         <= '0;
            write_byte_in_row <= '0;
            write_ring_slot   <= '0;
            write_bank        <= '0;
            write_group       <= '0;
            rows_written      <= '0;
            frame_done        <= 1'b0;
            rd_valid          <= 1'b0;
            rd_bank_q         <= '0;
        end else if (clear) begin
            // Frame restart.  Only the write side and the frame bookkeeping
            // are reset; the ring CONTENTS are deliberately NOT cleared, and
            // that is a decision rather than an omission:
            //
            //   * A read is only honoured while rd_row < rows_written, and
            //     rows_written is zeroed here, so no byte in the ring is
            //     reachable until the row that owns it has been fully
            //     rewritten.  rows_written only increments on the byte that
            //     completes a row, so a slot is never half-valid.
            //   * rd_offset is bounded by the row size (rd_offset <
            //     cfg_row_bytes is part of the request check), so a read can
            //     never address the slack bytes in the last byte group of a
            //     row -- the only bytes a rewrite leaves untouched.
            //
            // Sweeping 8 x MEM_DEPTH bytes instead would need its own state
            // machine and a multi-cycle busy handshake.  A HALF-cleared ring
            // is the genuinely dangerous option, because it silently mixes
            // bytes of two frames.  So: all or nothing, and here nothing.
            beat_pending      <= 1'b0;
            row_pause         <= 1'b0;
            beat_lane         <= '0;
            write_row         <= '0;
            write_byte_in_row <= '0;
            write_ring_slot   <= '0;
            write_bank        <= '0;
            write_group       <= '0;
            rows_written      <= '0;
            frame_done        <= 1'b0;
            // beat_reg is left alone on purpose: it is a data register that is
            // only ever consumed while beat_pending is set, and clearing it
            // would cost a 64-bit reset for no observable difference.
            //
            // rd_valid keeps its normal assignment instead of being forced
            // low: it has to stay equal to $past(rd_request_valid), or the
            // a_registered_read_valid contract the gather stage depends on
            // would be broken by the clear itself.
            rd_valid          <= rd_request_valid;
            rd_bank_q         <= rd_offset[2:0];
        end else begin
            // Synchronous memory read.  The address is sampled on this edge in
            // the per-bank blocks below and the byte is selected after their
            // output registers, so the address path and the bank select sit in
            // different cycles.  Latency is unchanged: rd_byte is valid in the
            // cycle after the request, which is what the gather stage expects.
            rd_valid  <= rd_request_valid;
            rd_bank_q <= rd_offset[2:0];

            if (row_pause) begin
                // A beat crossed a row boundary.  Hold its remaining lanes
                // until the generator has either drained the output row that
                // owns this ring slot or requested more input.
                if (resume_write)
                    row_pause <= 1'b0;
            end

            if (s_valid && s_ready) begin
                beat_reg     <= s_data;
                beat_pending <= 1'b1;
                beat_lane    <= '0;
            end

            if (beat_pending && !row_pause) begin
                // The byte itself is written in the per-bank blocks below.
                if (write_byte_in_row == last_row_byte_q) begin
                    rows_written      <= rows_written + 1'b1;
                    write_byte_in_row <= '0;
                    write_bank        <= '0;
                    // Every ring row starts on its own pitch boundary.
                    write_group       <= '0;

                    if (write_ring_slot == LAST_RING_SLOT)
                        write_ring_slot <= '0;
                    else
                        write_ring_slot <= write_ring_slot + 1'b1;

                    if (write_row == last_row_q) begin
                        frame_done   <= 1'b1;
                        beat_pending <= 1'b0;
                    end else begin
                        write_row <= write_row + 1'b1;
                        if (beat_lane == 3'd7) begin
                            beat_pending <= 1'b0;
                        end else begin
                            row_pause <= 1'b1;
                            beat_lane <= beat_lane + 1'b1;
                        end
                    end
                end else begin
                    write_byte_in_row <= write_byte_in_row + 1'b1;
                    if (write_bank == 3'd7) begin
                        write_bank  <= '0;
                        write_group <= write_group + 1'b1;
                    end else begin
                        write_bank <= write_bank + 1'b1;
                    end

                    if (beat_lane == 3'd7)
                        beat_pending <= 1'b0;
                    else
                        beat_lane <= beat_lane + 1'b1;
                end
            end
        end
    end

    property p_pause_keeps_pending_beat;
        @(posedge clk) disable iff (!rst_n)
        row_pause |-> beat_pending;
    endproperty
    a_pause_keeps_pending_beat: assert property (p_pause_keeps_pending_beat);

    property p_registered_read_valid;
        @(posedge clk) disable iff (!rst_n)
        rd_valid == $past(rd_request_valid);
    endproperty
    a_registered_read_valid: assert property (p_registered_read_valid);

    // A clear is a write-side reset, so the cycle after it the write pointers
    // must actually be at the frame origin.  This is the property that catches
    // a clear which forgot one of the five pointers.
    property p_clear_resets_write_side;
        @(posedge clk) disable iff (!rst_n)
        $past(clear) |-> ((write_row == '0) && (write_byte_in_row == '0) &&
                          (write_ring_slot == '0) && (write_bank == '0) &&
                          (write_group == '0) && (rows_written == '0) &&
                          !frame_done && !beat_pending && !row_pause &&
                          (beat_lane == '0));
    endproperty
    a_clear_resets_write_side: assert property (p_clear_resets_write_side);


    // One memory per bank.  All eight are read at the same address on the same
    // cycle and the registered bank index picks the byte afterwards, which
    // keeps the address arithmetic and the eight-way select in separate
    // cycles.  Reading all eight costs nothing here: they are distributed RAM,
    // and a single shared array would need an eight-way read port.
    logic write_fire;
    assign write_fire = beat_pending && !row_pause && !clear;

    genvar gb;
    generate
        for (gb = 0; gb < 8; gb++) begin : g_bank
            (* ram_style = "distributed" *)
            logic [DATA_WIDTH-1:0] bank_mem [0:MEM_DEPTH-1];

            // bank_q is the memory's output register and is deliberately not
            // reset: it is only consumed when rd_valid says a request landed.
            // For the same reason it has no read enable -- gating it with
            // rd_request_valid put the whole request check in front of 64
            // clock enables and was the synthesis critical path.
            always_ff @(posedge clk) begin
                if (write_fire && (write_bank == 3'(gb)))
                    bank_mem[write_addr] <=
                        beat_reg[beat_lane*DATA_WIDTH +: DATA_WIDTH];
                bank_q[gb] <= bank_mem[rd_addr_calc];
            end
        end
    endgenerate

    always_comb rd_byte = rd_valid ? bank_q[rd_bank_q] : '0;

    // Fixed eight-byte beats have no TKEEP; geometry is the byte-count
    // contract.  Keep s_last in the interface for the DMA wrapper.
    logic unused_s_last;
    always_comb unused_s_last = s_last;
endmodule
