`timescale 1ns/1ps

// ADR-011 weight-bank streamer.
//
// g_bank[r].bank_mem is intentionally a stable hierarchical name: Stage 1
// testbenches preload the ROWS independent BRAM banks through it directly.  The banks also carry a
// synchronous write port (wr_*): ADR-011 preloads them from eight .coe files
// through the Block Memory Generator, and this port is the RTL-side equivalent
// plus the hook for ADR-012 runtime loading.  It is not optional decoration --
// a memory with neither a write port nor an initialization is a constant to
// synthesis, so the whole weight path is optimized away while simulation stays
// green (measured 2026-10-07 before the port existed).  Bank r supplies weight_data lane r, and every bank is
// read at the same registered address (tile_idx*k_len + k).
//
// INIT_PREFIX (default "") is option (b) of the ADR-011-preload-karar-memosu
// decision memo: a parametric $readmemh initial value per bank, the pure-RTL
// alternative to eight .coe files through the Block Memory Generator. It
// coexists with wr_*, not replaces it -- init supplies the bitstream value,
// wr_* can still overwrite it at runtime (ADR-012). Leaving it "" (every
// instantiation as of this writing) reaches none of that code.
//
// The synchronous BRAM output register feeds a two-entry elastic FIFO.  The
// output register is held whenever the FIFO cannot accept it, so a late
// weight_ready deassertion cannot overwrite an unaccepted word.  When ready
// stays high, FIFO pop, BRAM-output transfer, and the next registered-address
// read occur together; after initial fill this sustains one beat per clock
// without losing, duplicating, or reordering a word.
module weight_feeder #(
    parameter int    ROWS       = 8,
    parameter int    DATA_WIDTH = 8,
    parameter int    K_MAX      = 1024,
    parameter int    DEPTH      = 8192,
    parameter int    TILE_MAX   = 16,
    // Bitstream-embedded initialization, option (b) of the ADR-011 preload
    // decision memo.  Empty (the default, and what every existing
    // instantiation -- tb_weight_feeder, conv1_top -- passes) disables this
    // entirely: no $readmemh call is even reached, so the wr_* load port
    // stays the only way weights get in and nothing here changes behavior.
    // A non-empty value is a path prefix; bank r reads
    // "<INIT_PREFIX><r>.mem" into bank_mem at time zero, matching
    // gen_conv1_vectors.py's "c1_wbank<r>.mem" naming one-to-one.
    parameter string INIT_PREFIX = "",
    parameter int    K_W        = $clog2(K_MAX+1),
    parameter int    ADDR_W     = $clog2(DEPTH),
    parameter int    TILE_W     = $clog2(TILE_MAX),
    parameter int    BANK_W     = $clog2(ROWS)
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // Weight load port.  Driven by the integration top's boundary, so an
    // out-of-context synthesis cannot optimize the banks out.
    input  logic                        wr_en,
    input  logic [BANK_W-1:0]           wr_bank,
    input  logic [ADDR_W-1:0]           wr_addr,
    input  logic [DATA_WIDTH-1:0]       wr_data,

    input  logic                        start,
    output logic                        ready,
    input  logic [TILE_W-1:0]           tile_idx,
    input  logic [K_W-1:0]              k_len,

    output logic                        weight_valid,
    input  logic                        weight_ready,
    output logic [ROWS*DATA_WIDTH-1:0]  weight_data,

    output logic                        done,
    output logic                        cfg_error
);
    localparam int WORD_W = ROWS * DATA_WIDTH;
    localparam int BASE_W = TILE_W + K_W;
    localparam int END_W  = BASE_W + 1;

    // One ONE-dimensional array per bank, declared inside a generate block.
    // A single two-dimensional `bank_mem [0:ROWS-1][0:DEPTH-1]` is functionally
    // identical and reads more cleanly, but Vivado 2025.1 does not run block
    // RAM inference on it: it reported
    //   WARNING: [Synth 8-11357] Potential Runtime issue for 3D-RAM ...
    //   bank_mem_reg with 524288 registers
    // and tried to build 8 x 8192 x 8 bits out of flip-flops on a device that
    // has 106,400 of them (measured 2026-10-07).  Per-bank arrays with a
    // registered read are the pattern the tool actually infers, and they match
    // ADR-011's eight physically separate banks one-to-one -- the eight .coe /
    // Block Memory Generator instances of that ADR drop into this same place.

    logic [BASE_W-1:0] base_calc;
    logic [END_W-1:0]  end_calc;
    logic [ADDR_W-1:0] base_reg;
    logic [ADDR_W-1:0] next_addr;
    logic [K_W-1:0]    len_reg;
    logic [K_W-1:0]    reads_issued;
    logic [K_W-1:0]    beats_accepted;
    logic              active;

    // Synchronous BRAM output stage.  rd_pending means rd_data contains the
    // oldest issued read and must be transferred before another read occurs.
    logic [WORD_W-1:0] rd_data;   // driven bank by bank in g_bank below
    logic              rd_pending;

    // Two-entry output FIFO.  The one-bit pointers wrap naturally at depth 2.
    logic [WORD_W-1:0] fifo_data [0:1];
    logic              fifo_wr_ptr;
    logic              fifo_rd_ptr;
    logic [1:0]        fifo_count;

    logic fifo_pop;
    logic rd_transfer;
    logic issue_read;
    logic last_accept;

    // Share the sole multiplication between the registered base and the
    // overflow guard.  Its result is sampled only on an accepted start.
    always_comb begin
        base_calc = $unsigned(tile_idx) * $unsigned(k_len);
        end_calc  = {{(END_W-BASE_W){1'b0}}, base_calc}
                    + {{(END_W-K_W){1'b0}}, k_len};
    end

    assign ready        = !active;
    assign weight_valid = (fifo_count != 0);
    assign weight_data  = fifo_data[fifo_rd_ptr];
    assign fifo_pop     = weight_valid && weight_ready;

    // rd_data may move when the FIFO already has a free entry or when its
    // head is being accepted on this edge.  A new BRAM read may replace it on
    // that same edge, which is the full-rate path.
    assign rd_transfer = rd_pending && ((fifo_count < 2) || fifo_pop);
    assign issue_read  = active && (reads_issued < len_reg) &&
                         (!rd_pending || rd_transfer);
    assign last_accept = fifo_pop && (beats_accepted == len_reg - 1'b1);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            base_reg       <= '0;
            next_addr      <= '0;
            len_reg        <= '0;
            reads_issued   <= '0;
            beats_accepted <= '0;
            active         <= 1'b0;
            rd_pending     <= 1'b0;
            fifo_data[0]   <= '0;
            fifo_data[1]   <= '0;
            fifo_wr_ptr    <= 1'b0;
            fifo_rd_ptr    <= 1'b0;
            fifo_count     <= '0;
            done           <= 1'b0;
            cfg_error      <= 1'b0;
        end else begin
            done      <= 1'b0;
            cfg_error <= 1'b0;

            if (start && ready) begin
                // A rejected command never enters active state, so the
                // controller remains ready and cannot deadlock its caller.
                if ((k_len == 0) || (int'(k_len) > K_MAX) ||
                    (end_calc > END_W'(DEPTH))) begin
                    cfg_error <= 1'b1;
                end else begin
                    base_reg       <= base_calc[ADDR_W-1:0];
                    next_addr      <= base_calc[ADDR_W-1:0];
                    len_reg        <= k_len;
                    reads_issued   <= '0;
                    beats_accepted <= '0;
                    active         <= 1'b1;
                    rd_pending     <= 1'b0;
                    fifo_wr_ptr    <= 1'b0;
                    fifo_rd_ptr    <= 1'b0;
                    fifo_count     <= '0;
                end
            end

            if (active) begin
                if (rd_transfer) begin
                    fifo_data[fifo_wr_ptr] <= rd_data;
                    fifo_wr_ptr            <= fifo_wr_ptr + 1'b1;
                end

                if (fifo_pop)
                    fifo_rd_ptr <= fifo_rd_ptr + 1'b1;

                case ({rd_transfer, fifo_pop})
                    2'b10: fifo_count <= fifo_count + 1'b1;
                    2'b01: fifo_count <= fifo_count - 1'b1;
                    default: fifo_count <= fifo_count;
                endcase

                if (issue_read) begin
                    // The banks themselves are read in the per-bank blocks
                    // below; this only tracks that a read is in flight.
                    rd_pending   <= 1'b1;
                    reads_issued <= reads_issued + 1'b1;
                    next_addr    <= next_addr + 1'b1;
                end else if (rd_transfer) begin
                    rd_pending <= 1'b0;
                end

                if (fifo_pop)
                    beats_accepted <= beats_accepted + 1'b1;

                if (last_accept) begin
                    active     <= 1'b0;
                    rd_pending <= 1'b0;
                    done       <= 1'b1;
                end
            end
        end
    end

    // A presented beat is an ordinary ready/valid source contract: neither
    // valid nor payload may change until the consumer accepts it.
    property p_hold_valid_on_stall;
        @(posedge clk) disable iff (!rst_n)
            (weight_valid && !weight_ready) |=> weight_valid;
    endproperty
    a_hold_valid_on_stall: assert property (p_hold_valid_on_stall)
        else $error("weight_valid dropped without an acceptance");

    property p_hold_data_on_stall;
        @(posedge clk) disable iff (!rst_n)
            (weight_valid && !weight_ready) |=> $stable(weight_data);
    endproperty
    a_hold_data_on_stall: assert property (p_hold_data_on_stall)
        else $error("weight_data changed while stalled");

    property p_done_after_exact_length;
        @(posedge clk) disable iff (!rst_n)
            done |-> (beats_accepted == len_reg);
    endproperty
    a_done_after_exact_length: assert property (p_done_after_exact_length)
        else $error("done asserted before exactly k_len accepted beats");

    property p_read_address_in_range;
        @(posedge clk) disable iff (!rst_n)
            issue_read |-> (int'(next_addr) < DEPTH);
    endproperty
    a_read_address_in_range: assert property (p_read_address_in_range)
        else $error("weight BRAM read address exceeds DEPTH-1");

    property p_read_address_sequence;
        @(posedge clk) disable iff (!rst_n)
            issue_read |->
                (int'(next_addr) == int'(base_reg) + int'(reads_issued));
    endproperty
    a_read_address_sequence: assert property (p_read_address_sequence)
        else $error("weight BRAM reads are not base+k ordered");

    initial begin
        if (ROWS < 1)
            $error("ROWS must be at least 1");
        if (DATA_WIDTH < 1)
            $error("DATA_WIDTH must be at least 1");
        if (K_MAX < 1)
            $error("K_MAX must be at least 1");
        if (DEPTH < 2)
            $error("DEPTH must be at least 2");
        if (TILE_MAX < 1)
            $error("TILE_MAX must be at least 1");
    end



    // Bank r holds output channel tile_idx*ROWS + r and is read at the same
    // address as every other bank on the same cycle (ADR-011).  The write port
    // is how weights get in: with neither a write port nor an initialization a
    // memory is a constant to synthesis, and the whole weight path was being
    // optimized away while simulation stayed green, because the testbench loads
    // the banks hierarchically.  `g_bank[r].bank_mem` is that hierarchical name.
    genvar gb;
    generate
        for (gb = 0; gb < ROWS; gb++) begin : g_bank
            (* ram_style = "block" *)
            logic [DATA_WIDTH-1:0] bank_mem [0:DEPTH-1];
            logic [DATA_WIDTH-1:0] rd_q;

            // Option (b) of the ADR-011 preload decision memo: a bitstream
            // -embedded initial value straight from RTL, no .coe / Block
            // Memory Generator IP involved.  Guarded on INIT_PREFIX so the
            // common case (every current instantiation) elaborates this
            // initial block to nothing -- not even the $sformatf argument is
            // evaluated at runtime, since INIT_PREFIX is a parameter and the
            // guard is resolved at elaboration/synthesis-compile time, same
            // as any other parameter-constant `if`.
            initial begin
                if (INIT_PREFIX != "")
                    $readmemh($sformatf("%s%0d.mem", INIT_PREFIX, gb), bank_mem);
            end

            // rd_q is the block RAM's own output register and is deliberately
            // not reset: a reset here costs the inferred output register.  It
            // is never consumed before it has been written, because rd_pending
            // gates it.
            always_ff @(posedge clk) begin
                if (wr_en && (wr_bank == BANK_W'(gb)))
                    bank_mem[wr_addr] <= wr_data;
                if (issue_read)
                    rd_q <= bank_mem[next_addr];
            end

            assign rd_data[gb*DATA_WIDTH +: DATA_WIDTH] = rd_q;
        end
    endgenerate

`ifndef SYNTHESIS
    a_no_load_while_active: assert property (
        @(posedge clk) disable iff (!rst_n)
        wr_en |-> !active
    ) else $error("weight_feeder: bank written while a tile was streaming");
`endif

endmodule
