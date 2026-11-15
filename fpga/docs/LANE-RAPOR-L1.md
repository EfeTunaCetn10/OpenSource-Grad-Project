# LANE-RAPOR-L1 — act_buffer swap completeness and rd_geom (lane/d-actbuf2)

Base faz4-datapath 7fbf3f8. Files: `systolic-array-8x8/rtl/act_buffer.sv`, `systolic-array-8x8/tb/tb_act_buffer.sv`. accel_top not edited.

## Design
- New registered outputs `rd_geom_valid` (= `rd_have`), `rd_geom_h/w/tiles`; they change only at an accepted `layer_swap` (reset clears them). `soft_reset` keeps them, as it keeps `rd_have` and the read geometry.
- O5: `wl_mask` (tiles whose pass COMPLETED since the last accepted swap), `wl_h/w/tiles` + `wl_have` (geometry of the completed passes), `wl_full` (registered at wr_done: mask == tiles 0..tiles-1). A pass with different h/w/tiles than `wl_*` is rejected in W_CHECK with seq_error (same path as cfg_bad: nothing written, write side idle). `swap_ok` now includes `wl_full`; a rejected swap sets seq_error through the existing `layer_swap && !swap_ok` term. An accepted swap clears mask/have/full. `soft_reset` keeps the mask (completed passes are real data) and aborted passes never set a bit.
- `wr_have` removed (replaced by wl_have/wl_full). `wr_h_q/wr_w_q` latch h/w at wr_start. The full-mask compare is only on the last beat of a pass, no per-beat multiply.
- Behaviour change to note: swap with no new write since the previous swap is now rejected (was accepted; lane A open point 4).
- `(C_TILE_MAX'(1) << tiles) - 1` relies on 16-bit wrap for tiles = C_TILE_MAX = 16 (gives all ones); the tb covers 16 tiles.

## tb additions
rd_geom checks at reset, after every swap, after rejected swaps and soft_reset; swap without any write; swap without new write; tile 15 of 16 alone; tile missing (3 tiles, 0 and 2 written); tile rewrite allowed; mixed w / h / tiles in a layer rejected and mask not polluted; geometry free after a swap; aborted pass sets no bit; a 16-tile 1x1 layer completed across a soft_reset and read back. tb_act_buffer needed an L5 completion (tile 15 alone used to be left incomplete), existing checks kept.

## Regression (python sim/run_tests.py from systolic-array-8x8/)
`16/16 passed` (tb_accel_top PASS: no test swaps an incomplete layer in this tree; new outputs unconnected there). tb_act_buffer: `PASS: act_buffer HWC read of 11 layers, 39 write passes, replay, concurrent write, LFSR backpressure, errors, soft_reset, swap completeness, mixed geometry, rd_geom`.

## Mutations (tb_act_buffer only, RTL restored afterwards)
- M1: drop `&& wl_full` from swap_ok -> FAIL (`swap without any write`, `rd_geom v=1 ...`, swap counts).
- M2: drop `|| wr_geom_bad` from W_CHECK -> FAIL (`mixed w in layer: wr_ready asserted`).

## Not run
No synthesis/timing for the new logic (not requested; no accel_top integration). 

## Open questions
- L3: accel_top has no rd_geom connection yet; wire to the O2 check. After a rejected START or an abort mid-layer, the mask persists (soft_reset keeps it), so a layer whose passes were interrupted can be completed by later passes of the same geometry; if L3 wants a fresh layer it needs a way to clear the mask (none exists on purpose).
