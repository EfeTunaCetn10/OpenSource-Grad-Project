`timescale 1ns/1ps

// HWC line buffer: a ring of K_H rows in eight byte banks.  The bank is
// logical-row-byte modulo eight, so each bank is a plain byte memory with one
// synchronous read port and one serialized write port.  The gather stage
// issues one read per cycle; the registered result is returned one cycle
// later.
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
    localparam int ROW_BYTES     = IN_W * C_IN;
    localparam int BYTE_GROUPS   = (ROW_BYTES + 7) / 8;
    localparam int MEM_DEPTH     = K_H * BYTE_GROUPS;
    localparam int ROW_W         = (IN_H < 1) ? 1 : $clog2(IN_H+1);
    localparam int ROW_BYTE_W    = (ROW_BYTES <= 1) ? 1 : $clog2(ROW_BYTES);
    localparam int BYTE_INDEX_W  = (ROW_BYTES <= 8) ? 3 : $clog2(ROW_BYTES);
    localparam int MEM_ADDR_W    = (MEM_DEPTH <= 1) ? 1 : $clog2(MEM_DEPTH);
    localparam int RING_W        = (K_H <= 1) ? 1 : $clog2(K_H);

    localparam logic [ROW_W-1:0]        LAST_ROW          = IN_H - 1;
    localparam logic [ROW_BYTE_W-1:0]   LAST_ROW_BYTE     = ROW_BYTES - 1;
    localparam logic [RING_W-1:0]       LAST_RING_SLOT    = K_H - 1;
    localparam logic [ROW_W-1:0]        IN_H_VALUE        = IN_H;
    localparam logic [RING_W-1:0]       K_H_VALUE         = K_H;
    localparam logic [BYTE_INDEX_W-1:0] C_IN_VALUE        = C_IN;
    localparam logic [MEM_ADDR_W-1:0]   BYTE_GROUPS_VALUE = BYTE_GROUPS;

    // The ring lives in eight ONE-dimensional arrays declared in the generate
    // block near the bottom, not in one `byte_mem [0:7][0:MEM_DEPTH-1]`:
    // Vivado 2025.1 does not run RAM inference on a two-dimensional array and
    // builds flip-flops plus a mux cone instead (measured on this file: 3951
    // LUT + 3985 FF with a combinational read, and still 7.38 ns of routing on
    // the critical path once the read was registered).
    //
    // `ram_style = "distributed"` is deliberate, not a fallback.  The ring is
    // K_H rows: 5 x 96 = 480 bytes for conv1 and 5 x 112 = 560 bytes for the
    // padded conv2 input, i.e. 60-70 entries per bank.  A RAMB18 holds 18 Kb,
    // so block RAM would spend a whole block per bank on a memory that fits in
    // a handful of LUTs, and add a deeper read path for nothing.  Block RAM is
    // the right tool for the weight banks (8192 entries each); it is the wrong
    // tool here, and the earlier `ram_style = "block"` hint on this array was
    // never honoured anyway.
    logic [DATA_WIDTH-1:0] bank_q [0:7];
    logic [2:0]            rd_bank_q;

    logic [63:0] beat_reg;
    logic        beat_pending;
    logic        row_pause;
    logic [2:0]  beat_lane;

    // The write location advances with the stream.  Keeping the row, byte,
    // ring slot, bank and address explicitly removes the former 32-bit
    // divide/modulo cone from the write port.
    logic [ROW_W-1:0]       write_row;
    logic [ROW_BYTE_W-1:0]  write_byte_in_row;
    logic [RING_W-1:0]      write_ring_slot;
    logic [2:0]             write_bank;
    logic [MEM_ADDR_W-1:0]  write_addr;

    // Read coordinates are not sequential, so the only retained modulo is
    // the cheap narrow row-to-ring mapping.  Divide by eight is wiring.
    logic                         rd_request_valid;
    logic [BYTE_INDEX_W-1:0]      rd_byte_index;
    logic [RING_W-1:0]            rd_ring_slot;
    logic [2:0]                   rd_bank_calc;
    logic [MEM_ADDR_W-1:0]        rd_group_calc;
    logic [MEM_ADDR_W-1:0]        rd_addr_calc;

    assign write_busy = beat_pending && !row_pause;
    assign s_ready = allow_input && !beat_pending && !frame_done;

    always_comb begin
        rd_request_valid = rd_en && (rd_row < rows_written) &&
                           (rd_row < IN_H_VALUE) && (rd_col < IN_W) &&
                           (rd_ch < C_IN);

        rd_byte_index = (rd_col * C_IN_VALUE) + rd_ch;
        rd_ring_slot  = rd_row % K_H_VALUE;
        rd_bank_calc  = rd_byte_index[2:0];
        rd_group_calc = rd_byte_index >> 3;
        rd_addr_calc  = (rd_ring_slot * BYTE_GROUPS_VALUE) + rd_group_calc;
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
            write_addr        <= '0;
            rows_written      <= '0;
            frame_done        <= 1'b0;
            rd_valid          <= 1'b0;
            rd_bank_q         <= '0;
        end else begin
            // Synchronous memory read.  The address is sampled on this edge in
            // the per-bank blocks below and the byte is selected after their
            // output registers, so the address path and the bank select sit in
            // different cycles.  Latency is unchanged: rd_byte is valid in the
            // cycle after the request, which is what the gather stage expects.
            rd_valid  <= rd_request_valid;
            rd_bank_q <= rd_bank_calc;

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
                if (write_byte_in_row == LAST_ROW_BYTE) begin
                    rows_written      <= rows_written + 1'b1;
                    write_byte_in_row <= '0;
                    write_bank        <= '0;

                    if (write_ring_slot == LAST_RING_SLOT) begin
                        write_ring_slot <= '0;
                        write_addr      <= '0;
                    end else begin
                        write_ring_slot <= write_ring_slot + 1'b1;
                        // The byte that ends a row is always in the last
                        // group, so the next address is the next row base.
                        write_addr <= write_addr + 1'b1;
                    end

                    if (write_row == LAST_ROW) begin
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
                        write_bank <= '0;
                        write_addr <= write_addr + 1'b1;
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


    // One memory per bank.  All eight are read at the same address on the same
    // cycle and the registered bank index picks the byte afterwards, which
    // keeps the address arithmetic and the eight-way select in separate
    // cycles.  Reading all eight costs nothing here: they are distributed RAM,
    // and a single shared array would need an eight-way read port.
    logic write_fire;
    assign write_fire = beat_pending && !row_pause;

    genvar gb;
    generate
        for (gb = 0; gb < 8; gb++) begin : g_bank
            (* ram_style = "distributed" *)
            logic [DATA_WIDTH-1:0] bank_mem [0:MEM_DEPTH-1];

            // bank_q is the memory's output register and is deliberately not
            // reset: it is only consumed when rd_valid says a request landed.
            always_ff @(posedge clk) begin
                if (write_fire && (write_bank == 3'(gb)))
                    bank_mem[write_addr] <=
                        beat_reg[beat_lane*DATA_WIDTH +: DATA_WIDTH];
                if (rd_request_valid)
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
