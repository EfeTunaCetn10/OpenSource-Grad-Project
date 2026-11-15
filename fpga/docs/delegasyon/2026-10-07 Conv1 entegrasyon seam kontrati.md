# Conv1 integration seam contract (authored by the integrator, NOT negotiable)

Two modules are being written in parallel by separate agents. Port names, widths and
semantics below are FIXED so the two halves compose without edits. Do not rename, do not
add or remove top-level ports, do not change widths. Internal structure is yours.

Project: `C:\grad-rtl\systolic-array-8x8` (SystemVerilog, Vivado 2025.1 / XSim,
xc7z020clg400-1, 100 MHz target). House style: English comments, 4-space indent, `logic`,
`always_ff`/`always_comb`, explicit reset of every register, SVA assertions for contracts,
no `#delay` in RTL.

## Already existing and NOT to be modified

`rtl/compute_engine.sv`, `rtl/systolic_array_os.sv`, `rtl/pe_os.sv`, `rtl/window_gen.sv`,
`rtl/line_buffer.sv`, `rtl/requant_unit.sv`, `rtl/requant_array.sv`, `rtl/axi_lite_regs.sv`
and everything in `tb/`, `model/`, `sim/`. Read them. Touch nothing but your own two files.

## compute_engine facts you must honour (verified in the RTL, do not re-derive)

- `start` is sampled only while `start_ready` (state IDLE). On accept: IDLE -> CLEAR
  (1 cycle) -> FEED. The first activation/weight beat can therefore be consumed no earlier
  than 2 cycles after the accepted `start`.
- `active_rows`, `active_cols`, `k_len` are latched at that accepted `start`.
- The two source edges are COUPLED:
  `weight_ready = activation_ready = (state==FEED) && weight_valid && activation_valid`.
  A lone valid source is never consumed. Backpressure is symmetric: either both edges
  advance on a cycle or neither does.
- `weight_data` is `ROWS*8 = 64` bits: lane r (`weight_data[r*8 +: 8]`) is output channel
  `tile_idx*8 + r`. `activation_data` is `COLS*8 = 64` bits, lane c = output position c.
- After `k_len` paired beats: FLUSH (`rows+cols-2` cycles), then DRAIN (`active_cols`
  output beats, gated by `out_ready`), then a one-cycle `done`, then IDLE.

## ADR-011 weight addressing (accepted ADR, binding)

`bank = c_out mod 8` (bank r == engine row r == `weight_data` lane r); bank-local address
`addr = tile_idx*K + k`, the same address broadcast to all 8 banks on the same cycle;
`k = ci*(kH*kW) + kh*kW + kw` (channel-major, PyTorch-native, no permutation). The row skew
is applied INSIDE the engine, not by the feeder: all 8 banks deliver their byte for the same
`k` in the same beat.

## Module A - `rtl/weight_feeder.sv` (agent A)

```systemverilog
module weight_feeder #(
    parameter int ROWS       = 8,
    parameter int DATA_WIDTH = 8,
    parameter int K_MAX      = 1024,
    parameter int DEPTH      = 8192,                  // words per bank
    parameter int TILE_MAX   = 16,                    // max channel-tile index + 1
    parameter int K_W        = $clog2(K_MAX+1),
    parameter int ADDR_W     = $clog2(DEPTH),
    parameter int TILE_W     = $clog2(TILE_MAX)
) (
    input  logic                        clk,
    input  logic                        rst_n,

    // Tile command.  `start` is a pulse, accepted only while `ready`.
    input  logic                        start,
    output logic                        ready,
    input  logic [TILE_W-1:0]           tile_idx,
    input  logic [K_W-1:0]              k_len,

    // Weight stream to compute_engine (paired with the activation edge).
    output logic                        weight_valid,
    input  logic                        weight_ready,
    output logic [ROWS*DATA_WIDTH-1:0]  weight_data,

    output logic                        done,          // one-cycle pulse after last beat
    output logic                        cfg_error      // k_len==0, >K_MAX, or addr overflow
);
```

Requirements:

- 8 independent banks, `(* ram_style = "block" *)`,
  `logic [DATA_WIDTH-1:0] bank_mem [0:ROWS-1][0:DEPTH-1]` or an equivalent that still infers
  BRAM. Synchronous read. A `.coe` / Block Memory Generator swap-in is Stage 2; for now the
  testbench loads the banks hierarchically with `$readmemh`, so keep the memory array name
  stable and document it in a header comment.
- Base address registered at `start`: `base = tile_idx * k_len` (one multiplier, here only).
  Raise `cfg_error` if `k_len == 0`, `k_len > K_MAX`, or `base + k_len > DEPTH`; in that case
  do not stream and do not hang - return to idle.
- Synchronous BRAM read latency must NOT cost a bubble per beat: prefetch / skid so
  `weight_valid` can stay asserted back-to-back while `weight_ready` is high, and no word is
  lost when `weight_ready` drops. The engine stalls on every cycle the activation edge
  starves, so backpressure is the common case, not a corner case.
- Exactly `k_len` beats per tile, in `k = 0..k_len-1` order, then `done`.
- SVA: `weight_valid`/`weight_data` stable while `weight_ready` is low (no valid drop without
  an accept), beats per tile equals `k_len`, address never exceeds `DEPTH-1`.

## Module B - `rtl/layer_ctrl.sv` (agent B)

```systemverilog
module layer_ctrl #(
    parameter int ROWS     = 8,
    parameter int COLS     = 8,
    parameter int K_MAX    = 1024,
    parameter int TILE_MAX = 16,
    parameter int ROW_W    = $clog2(ROWS+1),
    parameter int COL_W    = $clog2(COLS+1),
    parameter int K_W      = $clog2(K_MAX+1),
    parameter int TILE_W   = $clog2(TILE_MAX)
) (
    input  logic                  clk,
    input  logic                  rst_n,

    // Layer command / geometry (Stage 1: driven by the testbench, later axi_lite_regs)
    input  logic                  frame_start,       // pulse, accepted while !busy
    input  logic [ROW_W-1:0]      cfg_active_rows,   // output channels in this channel tile
    input  logic [K_W-1:0]        cfg_k_len,         // K = c_in*kH*kW
    input  logic [TILE_W-1:0]     cfg_tile_idx,      // channel tile (Stage 1 conv1: 0)
    output logic                  busy,
    output logic                  layer_done,        // pulse: w_done AND last tile drained

    // window_gen master side (this block is its only consumer)
    input  logic                  w_valid,
    output logic                  w_ready,
    input  logic [63:0]           w_data,
    input  logic [3:0]            w_active_cols,
    input  logic [31:0]           w_k,
    input  logic                  w_tile_start,
    input  logic                  w_tile_last,
    input  logic                  w_done,

    // compute_engine side
    output logic                  eng_start,
    input  logic                  eng_start_ready,
    output logic [ROW_W-1:0]      eng_active_rows,
    output logic [COL_W-1:0]      eng_active_cols,
    output logic [K_W-1:0]        eng_k_len,
    output logic                  eng_activation_valid,
    input  logic                  eng_activation_ready,
    output logic [63:0]           eng_activation_data,
    input  logic                  eng_done,
    input  logic                  eng_config_error,

    // weight_feeder side
    output logic                  wf_start,
    input  logic                  wf_ready,
    output logic [TILE_W-1:0]     wf_tile_idx,
    output logic [K_W-1:0]        wf_k_len,
    input  logic                  wf_done,
    input  logic                  wf_cfg_error,

    // status
    output logic [31:0]           tile_count,        // tiles started in this frame
    output logic [7:0]            error_flags        // sticky, cleared by reset/frame_start
);
```

`error_flags` bit assignment (fixed - the integration top maps these into `hw_error_set`):
`[0]` engine `config_error`, `[1]` weight_feeder `cfg_error`, `[2]` activation beat accepted
outside the enabled FEED window, `[3]` `w_tile_last` seen at a beat count other than
`cfg_k_len-1`, `[4]` `w_active_cols` changed mid-tile, `[5]` `frame_start` while busy,
`[6]` `w_done` while a tile is still in flight, `[7]` reserved, tied 0.

Requirements:

- The activation path is pass-through, not a buffer: `eng_activation_data = w_data`, with
  `eng_activation_valid` / `w_ready` gated by a feed-enable. Never accept a window beat while
  the engine is outside FEED, and never lose the first beat of a tile: hold `w_ready` low,
  sample `w_active_cols` from the stalled first beat (`w_tile_start`), THEN assert
  `eng_start`, then open the gate - remembering CLEAR costs one cycle after the accepted
  start.
- `eng_active_cols` = `w_active_cols` of that tile's first beat. The right-edge tile is
  partial: conv1 drives 8/8/8/4 per output row. Getting this wrong silently corrupts the last
  pixels of every output row - the exact silent-failure class ADR-018 flagged.
  `eng_active_rows = cfg_active_rows`, `eng_k_len = cfg_k_len`.
- Start `weight_feeder` for the same tile (`wf_tile_idx = cfg_tile_idx`,
  `wf_k_len = cfg_k_len`) so its `k=0` beat is available when the engine reaches FEED. The
  feeder is started per tile - its address restarts at `tile_idx*k_len` for every tile.
- One tile in flight at a time: the next `eng_start` only after the previous tile's
  `eng_done`.
- `layer_done` only after `w_done` AND the last tile's `eng_done`.
- Stage 1 scope: exactly one channel tile (conv1 has 6 output channels), `pad = 0`, no
  activation replay. Conv2's two-channel-tile replay would need a window-generator rewind
  port that does not exist - do NOT invent it; leave a clearly marked `Stage 2` comment
  where it would hook in.
- SVA for every `error_flags` condition, plus: `eng_start` only while `eng_start_ready`, no
  activation accept outside the enabled window, beats per tile == `cfg_k_len`.

## Verification requirement for BOTH lanes

Write your own testbench (`tb/tb_weight_feeder.sv` / `tb/tb_layer_ctrl.sv`), self-checking,
printing a single `PASS` line at the end and `FAIL` / `$error` on any mismatch. The runner is
`python sim/run_tests.py` (auto-discovers `tb_*` in `tb/`, XSim; needs Vivado on PATH or
`VIVADO_BIN` set). Your lane has its own private git worktree, so run the FULL regression -
every existing test plus yours must pass. XSim does NOT support seeded `$urandom`; use an
explicit LFSR if you want pseudo-random stimulus (`tb/tb_requant_array.sv` is the house
pattern).

Phase coverage is not optional. Per module, at minimum:

- backpressure phases where the partner edge starves for 1, 2 and many cycles (the paired
  handshake makes stalls the normal case)
- a geometry-varying phase: consecutive tiles with DIFFERENT `active_cols` (8 then 4) and
  different `k_len`. A fixed-geometry testbench provably hides lockstep bugs in this design -
  a lesson already paid for once on `requant_array`.
- every error / guard path (`cfg_error`, each `error_flags` bit), asserted deliberately.

Then mutation-test your own code: introduce at least 4 plausible single-line mutations
(off-by-one beat counter, dropped backpressure guard, wrong base address, gate opened one
cycle early, metadata sampled from the wrong beat), confirm your testbench FAILS for each,
revert them, and report which were caught and which survived. A surviving mutant is a
finding to report, not something to hide.

## Reporting

End with a short report: what you wrote, the exact regression result (test count), the
mutation results, every assumption you had to make, and anything you found wrong in the
EXISTING code - report it, do not fix it, it is outside your two files.
