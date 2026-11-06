`timescale 1ns/1ps

// Layer activation ping-pong buffer (faz4 contract, section 3).
//
// Storage stays tile-major (ADR-018): one 64-bit word = 8 channels of one
// pixel of one output-channel tile, at mem[tile*plane + row*w + col] with
// plane = h*w.  A write pass stores one tile plane in raster order.  A read
// pass replays the whole stored layer as an HWC stream, per pixel in raster
// order the T tile words of that pixel:
//   for row, for col, for t: word = mem[t*plane + row*w + col]
// so byte lane r of the t-th word of a pixel is channel 8t+r and the byte
// stream is HWC with c_phys = 8*T, which is what window_gen consumes (K1).
//
// Two banks: the write side fills bank buf_sel while the read side streams
// the other bank, concurrently.  layer_swap (both sides idle) exchanges the
// banks and hands the read side the geometry of the last completed write
// pass.  Products (plane, base, footprint) are formed once in a two-cycle
// write setup with wr_ready low; the per-beat paths only add and compare.
//
// Read latency: the bank read is synchronous, so issued words land one cycle
// later in a 3-entry output FIFO.  A read is issued while FIFO entries plus
// the word in flight are below 3, which depends on registers only (rd_ready
// does not reach the BRAM enable) and still sustains one word per cycle at
// rd_ready=1.
//
// Layer completeness: per write layer (since the last accepted swap) a mask
// records which tile passes COMPLETED (wr_done) and the first completed pass
// fixes the layer geometry h, w, tiles.  A later pass of the same layer with a
// different geometry is rejected at wr_start; layer_swap is accepted only if
// the mask is exactly tiles 0..tiles-1 (rewriting a tile is fine).  An
// accepted swap clears the mask.  A pass aborted by soft_reset sets no bit.
// rd_geom_* is the geometry rd_start will stream, changed only by an accepted
// swap; rd_geom_valid says a complete layer has been swapped in.
//
// Errors are sticky until soft_reset/rst_n and never block later commands:
//   seq_error: wr_start/rd_start while that side is busy; layer_swap while
//              either side is busy or together with a start; rd_start with no
//              written layer swapped in; layer_swap with an incomplete or empty
//              write layer; wr_start with h or w 0 or above max, tiles 0 or
//              above C_TILE_MAX, tile >= tiles, or a geometry different from
//              the completed passes of the same layer.
//   ovf_error: wr_start whose layer footprint tiles*h*w exceeds DEPTH (the
//              whole layer must be readable back, not just this pass).
// A rejected wr_start writes nothing and leaves the write side idle, so a
// producer waiting on wr_ready stalls until soft_reset.  soft_reset returns
// both FSMs to idle and clears the errors; memory, bank select, frame_count
// the stored geometries and the completion mask are kept, so a layer can be
// replayed after it and a half-written layer is finished by the next passes.
module act_buffer #(
    parameter int LANES = 8,
    parameter int OUT_H_MAX = 48,
    parameter int OUT_W_MAX = 48,
    parameter int C_TILE_MAX = 16,
    parameter int DEPTH = 4608
) (
    input  logic clk, rst_n,
    input  logic soft_reset,
    input  logic wr_start,
    input  logic [$clog2(OUT_H_MAX+1)-1:0] cfg_wr_h,
    input  logic [$clog2(OUT_W_MAX+1)-1:0] cfg_wr_w,
    input  logic [$clog2(C_TILE_MAX+1)-1:0] cfg_wr_tile,
    input  logic [$clog2(C_TILE_MAX+1)-1:0] cfg_wr_tiles,
    input  logic wr_valid,
    output logic wr_ready,
    input  logic [LANES*8-1:0] wr_data,
    output logic wr_done,
    input  logic layer_swap,
    input  logic rd_start,
    output logic rd_valid,
    input  logic rd_ready,
    output logic [LANES*8-1:0] rd_data,
    output logic rd_last,
    output logic rd_busy,
    output logic wr_busy,
    output logic buf_sel,
    output logic [31:0] frame_count,
    output logic seq_error,
    output logic ovf_error,
    output logic rd_geom_valid,
    output logic [$clog2(OUT_H_MAX+1)-1:0] rd_geom_h,
    output logic [$clog2(OUT_W_MAX+1)-1:0] rd_geom_w,
    output logic [$clog2(C_TILE_MAX+1)-1:0] rd_geom_tiles
);
    localparam int H_W = $clog2(OUT_H_MAX+1);
    localparam int W_W = $clog2(OUT_W_MAX+1);
    localparam int CT_W = $clog2(C_TILE_MAX+1);
    localparam int PL_W = H_W + W_W;        // h*w of any representable h, w
    localparam int FP_W = PL_W + CT_W;      // tile*plane, tiles*plane
    localparam int A_W = $clog2(DEPTH+1);   // word pointers and counts

    // Write side.
    typedef enum logic [1:0] {W_IDLE, W_BASE, W_CHECK, W_RUN} wstate_t;
    wstate_t wstate;
    logic [CT_W-1:0] wr_tile_q, wr_tiles_q;
    logic [H_W-1:0] wr_h_q;
    logic [W_W-1:0] wr_w_q;
    logic [PL_W-1:0] wr_plane;
    logic [FP_W-1:0] wr_base, wr_foot;
    logic wr_cfg_bad, wr_geom_bad, wr_fire;
    logic [A_W-1:0] wr_ptr, wr_end;
    // Write layer so far: geometry of its completed passes (handed over at
    // layer_swap), the mask of completed tiles and whether it is complete.
    logic wl_have, wl_full;
    logic [H_W-1:0] wl_h;
    logic [W_W-1:0] wl_w;
    logic [CT_W-1:0] wl_tiles;
    logic [C_TILE_MAX-1:0] wl_mask, wl_mask_n;
    logic [A_W-1:0] lw_plane;
    logic [CT_W-1:0] lw_tiles_m1;

    // Read side.
    logic rd_run, rd_have, rd_issue, rd_issue_last, rd_pop, swap_ok;
    logic [A_W-1:0] rd_plane, rd_plane_m1, rd_pix, rd_addr;
    logic [CT_W-1:0] rd_tiles_m1, rd_t;
    logic q_vld, q_last;
    logic [LANES*8-1:0] bank_q [0:1];
    logic [LANES*8-1:0] q_data, f_data0, f_data1, f_data2;
    logic [2:0] f_last;
    logic [1:0] f_cnt, f_wr, f_rd;

    assign wr_ready = (wstate == W_RUN);
    assign wr_fire = wr_valid && wr_ready;
    assign wr_busy = (wstate != W_IDLE);
    assign rd_busy = rd_run || q_vld || (f_cnt != 2'd0);
    assign swap_ok = layer_swap && !wr_busy && !rd_busy && !wr_start && !rd_start &&
                     wl_full;
    assign rd_geom_valid = rd_have;
    // Mask after the pass that ends now; full = exactly tiles 0..tiles-1.
    assign wl_mask_n = wl_mask | (C_TILE_MAX'(1) << wr_tile_q);
    assign wr_geom_bad = wl_have && ((wr_h_q != wl_h) || (wr_w_q != wl_w) ||
                                     (wr_tiles_q != wl_tiles));

    assign rd_issue = rd_run && ({1'b0,f_cnt} + q_vld < 3'd3);
    assign rd_issue_last = (rd_pix == rd_plane_m1) && (rd_t == rd_tiles_m1);
    assign rd_valid = (f_cnt != 2'd0);
    assign rd_pop = rd_valid && rd_ready;
    assign q_data = buf_sel ? bank_q[0] : bank_q[1];
    assign rd_data = (f_rd == 2'd0) ? f_data0 : (f_rd == 2'd1) ? f_data1 : f_data2;
    assign rd_last = rd_valid && f_last[f_rd];   // f_last is not reset

    // Two independent one-dimensional arrays, one aligned 64-bit write port
    // and one synchronous read port each.  Bank buf_sel is written, the other
    // is read.  A 2-D array here once silently became flip-flops.
    genvar b;
    generate for (b=0; b<2; b=b+1) begin : g_buffer
        (* ram_style = "block" *) logic [LANES*8-1:0] mem [0:DEPTH-1];
        always_ff @(posedge clk) begin
            if (wr_fire && buf_sel == b[0]) mem[wr_ptr] <= wr_data;
            if (rd_issue && buf_sel != b[0]) bank_q[b] <= mem[rd_addr];
        end
    end endgenerate

    // FIFO payload needs no reset: f_cnt says which entries are live.
    always_ff @(posedge clk) begin
        if (q_vld) begin
            if (f_wr == 2'd0) f_data0 <= q_data;
            if (f_wr == 2'd1) f_data1 <= q_data;
            if (f_wr == 2'd2) f_data2 <= q_data;
            f_last[f_wr] <= q_last;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wstate <= W_IDLE;
            wr_tile_q <= '0;
            wr_tiles_q <= '0;
            wr_h_q <= '0;
            wr_w_q <= '0;
            wr_plane <= '0;
            wr_base <= '0;
            wr_foot <= '0;
            wr_cfg_bad <= 1'b0;
            wr_ptr <= '0;
            wr_end <= '0;
            wr_done <= 1'b0;
            wl_have <= 1'b0;
            wl_full <= 1'b0;
            wl_h <= '0;
            wl_w <= '0;
            wl_tiles <= '0;
            wl_mask <= '0;
            lw_plane <= '0;
            lw_tiles_m1 <= '0;
            rd_run <= 1'b0;
            rd_have <= 1'b0;
            rd_geom_h <= '0;
            rd_geom_w <= '0;
            rd_geom_tiles <= '0;
            rd_plane <= '0;
            rd_plane_m1 <= '0;
            rd_tiles_m1 <= '0;
            rd_pix <= '0;
            rd_addr <= '0;
            rd_t <= '0;
            q_vld <= 1'b0;
            q_last <= 1'b0;
            f_cnt <= '0;
            f_wr <= '0;
            f_rd <= '0;
            buf_sel <= 1'b0;
            frame_count <= '0;
            seq_error <= 1'b0;
            ovf_error <= 1'b0;
        end else if (soft_reset) begin
            wstate <= W_IDLE;
            wr_done <= 1'b0;
            rd_run <= 1'b0;
            q_vld <= 1'b0;
            q_last <= 1'b0;
            f_cnt <= '0;
            f_wr <= '0;
            f_rd <= '0;
            seq_error <= 1'b0;
            ovf_error <= 1'b0;
        end else begin
            wr_done <= 1'b0;
            if ((wr_start && wr_busy) || (rd_start && rd_busy) ||
                (rd_start && !rd_busy && !rd_have) || (layer_swap && !swap_ok))
                seq_error <= 1'b1;

            // Write pass: latch, multiply, check, then h*w words to base+i.
            case (wstate)
                W_IDLE: if (wr_start) begin
                    wr_tile_q <= cfg_wr_tile;
                    wr_tiles_q <= cfg_wr_tiles;
                    wr_h_q <= cfg_wr_h;
                    wr_w_q <= cfg_wr_w;
                    wr_plane <= cfg_wr_h * cfg_wr_w;
                    wr_cfg_bad <= (cfg_wr_h == 0) || (cfg_wr_h > OUT_H_MAX) ||
                                  (cfg_wr_w == 0) || (cfg_wr_w > OUT_W_MAX) ||
                                  (cfg_wr_tiles == 0) || (cfg_wr_tiles > C_TILE_MAX) ||
                                  (cfg_wr_tile >= cfg_wr_tiles);
                    wstate <= W_BASE;
                end
                W_BASE: begin
                    wr_base <= wr_tile_q * wr_plane;
                    wr_foot <= wr_tiles_q * wr_plane;
                    wstate <= W_CHECK;
                end
                W_CHECK: begin
                    if (wr_cfg_bad || wr_geom_bad) begin
                        seq_error <= 1'b1;
                        wstate <= W_IDLE;
                    end else if (wr_foot > DEPTH) begin
                        ovf_error <= 1'b1;
                        wstate <= W_IDLE;
                    end else begin
                        wr_ptr <= A_W'(wr_base);
                        wr_end <= A_W'(wr_base + wr_plane - 1'b1);
                        wstate <= W_RUN;
                    end
                end
                W_RUN: if (wr_fire) begin
                    wr_ptr <= wr_ptr + 1'b1;
                    if (wr_ptr == wr_end) begin
                        wr_done <= 1'b1;
                        wl_have <= 1'b1;
                        wl_h <= wr_h_q;
                        wl_w <= wr_w_q;
                        wl_tiles <= wr_tiles_q;
                        wl_mask <= wl_mask_n;
                        wl_full <= (wl_mask_n == ((C_TILE_MAX'(1) << wr_tiles_q) - 1'b1));
                        lw_plane <= A_W'(wr_plane);
                        lw_tiles_m1 <= wr_tiles_q - 1'b1;
                        wstate <= W_IDLE;
                    end
                end
                default: wstate <= W_IDLE;
            endcase

            if (swap_ok) begin
                buf_sel <= ~buf_sel;
                frame_count <= frame_count + 1'b1;
                rd_have <= 1'b1;
                rd_geom_h <= wl_h;
                rd_geom_w <= wl_w;
                rd_geom_tiles <= wl_tiles;
                wl_have <= 1'b0;
                wl_full <= 1'b0;
                wl_mask <= '0;
                rd_plane <= lw_plane;
                rd_plane_m1 <= lw_plane - 1'b1;
                rd_tiles_m1 <= lw_tiles_m1;
            end

            // Read issue: pixel pointer plus a tile offset that accumulates
            // plane; the next pixel restarts at its own address.
            if (rd_start && !rd_busy) begin
                if (rd_have) begin
                    rd_run <= 1'b1;
                    rd_pix <= '0;
                    rd_addr <= '0;
                    rd_t <= '0;
                end
            end else if (rd_issue) begin
                if (rd_issue_last) rd_run <= 1'b0;
                else if (rd_t == rd_tiles_m1) begin
                    rd_t <= '0;
                    rd_pix <= rd_pix + 1'b1;
                    rd_addr <= rd_pix + 1'b1;
                end else begin
                    rd_t <= rd_t + 1'b1;
                    rd_addr <= rd_addr + rd_plane;
                end
            end
            q_vld <= rd_issue;
            q_last <= rd_issue && rd_issue_last;

            if (q_vld) f_wr <= (f_wr == 2'd2) ? 2'd0 : f_wr + 1'b1;
            if (rd_pop) f_rd <= (f_rd == 2'd2) ? 2'd0 : f_rd + 1'b1;
            f_cnt <= f_cnt + q_vld - rd_pop;
        end
    end

    initial begin
        if (LANES != 8 || DEPTH < 1 || C_TILE_MAX < 1)
            $error("act_buffer requires LANES=8, DEPTH>=1, C_TILE_MAX>=1");
    end
endmodule
