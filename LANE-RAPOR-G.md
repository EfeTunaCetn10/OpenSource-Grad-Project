# LANE-RAPOR-G: runtime geometry (faz3-param, lane G)

Branch `lane/g-param`, base `faz3-param` @ 2985e8e. Contract: `C:\codex-ctx\2026-11-04\param-kontrat.md`.

## Files changed

| File | Change |
|---|---|
| `rtl/line_buffer.sv` | Params `K_H_MAX, IN_H_MAX, ROW_BYTES_MAX, DATA_WIDTH`. New inputs `cfg_in_h`, `cfg_row_bytes`; read side takes `rd_row` (written check only), `rd_slot`, `rd_offset` in place of `rd_row/rd_col/rd_ch`. Each ring row sits on a power-of-two pitch, so the address is `{slot, offset>>3}`. No `%` and no runtime multiply. End-of-row and end-of-frame values are re-registered every cycle. The bank output register no longer has a read enable (it was the critical path). |
| `rtl/window_gen.sv` | Params `IN_H_MAX, IN_W_MAX, C_MAX, ROW_BYTES_MAX, K_H_MAX, K_W_MAX, PAD_MAX, K_MAX, DATA_WIDTH` (STRIDE removed: always 1). New inputs `cfg_in_h, cfg_in_w, cfg_c_in[8:0], cfg_c_phys[8:0], cfg_kh[2:0], cfg_kw[2:0], cfg_pad[1:0]`, new outputs `cfg_error`, `k_len`. Geometry latch: stage 1 samples the ports and forms the only two multiplies (`in_w*c_phys`, `c_in*kh*kw`). Stage 2 derives the last-values, `out_w`, `-(pad*c_phys)` and `cfg_error`. Per-beat addressing uses wrap counters (`base_slot`, `kh_slot`) and byte accumulators (`tile/ci/kw/lane_byte`, kept modulo 2^BYTE_W). Person A's fixes are ported: (a) `TILE_X_W = $clog2(OUT_W_MAX+1)`; (b) virtual bottom padding waits for `rows_written == in_h`. Pad up to PAD_MAX is supported: top, left, right and bottom zeros are generated, never streamed. |
| `rtl/conv1_top.sv` | Envelope params per contract 4.1. New ports `cfg_in_h ... cfg_pad, cfg_w_base` (no defaults). `cfg_w_base` is unconnected, with the exact marker comment. Geometry error is mapped to `error_flags[7]`. The `a_k_len_matches_geometry` assertion now compares against the latched product on every busy cycle. The compile-time K checks are removed (now the runtime `cfg_error`). |
| `tb/tb_window_gen.sv` | 4 instances on default envelope, geometry through cfg ports; adds a check that `cfg_error` stays 0 for the legal geometries. |
| `tb/tb_conv1_top.sv`, `tb/tb_fc_layer.sv` | Geometry params removed, the same geometry is driven on the cfg ports, and `cfg_w_base='0`. |
| `tb/tb_lenet_e2e.sv` | Only the `conv1_top` instance in `lenet_e2e_stage` changed: the five stages now instantiate the same envelope (ROWS/COLS/K_MAX/TILE_MAX/W_DEPTH overrides kept), with geometry on the cfg ports. |
| `vivado/check_synth_geom.tcl` | New OOC gate (xc7z020clg400-1, 10 ns, envelope defaults). It reports DSP, WNS, the worst path, the worst path ending in `u_window`, and memory, and gates on DSP==80, WNS>=1.0 and weight BRAM. |

Untouched: `weight_feeder.sv`, `pool2x2.sv`, `accel_top.sv`, `filelist.f`, `run_tests.py`, `model/*`.

## Error-flag mapping (bad cfg)

`window_gen.cfg_error` (level, from the frozen latch) is set when any of these holds:
- `in_h==0`, `in_h>IN_H_MAX`, `in_w==0`, `in_w>IN_W_MAX`
- `c_in==0`, `c_in>C_MAX`, `c_phys>C_MAX`, `c_phys<c_in`
- `kh==0`, `kh>K_H_MAX`, `kw==0`, `kw>K_W_MAX`
- `pad>PAD_MAX`, `pad>=kh`, `pad>=kw`
- `in_h+2pad<kh`, `in_w+2pad<kw` (output size <= 0)
- `in_w*c_phys>ROW_BYTES_MAX`, `c_in*kh*kw>K_MAX`

While it is set, `s_ready` is 0 and the generator stays idle and keeps re-latching, so a corrected cfg recovers without reset.

`conv1_top.error_flags[7]` (reserved-zero in layer_ctrl) = `window cfg_error OR (cfg_k_len != latched c_in*kh*kw)`. Like the layer_ctrl bits, it is cleared by `frame_start` and set while `busy`. `restart_error` is unchanged.

`pad>=kh` / `pad>=kw` is my addition: it keeps every window touching one real row/column and bounds `out <= in + PAD_MAX`.

Quasi-static timing assumption: cfg ports must be stable for at least 2 cycles before the first input beat after reset/restart, and before `frame_start`.

## Test summary

`python sim/run_tests.py` in this worktree (final RTL): **13/16 passed**.
FAIL: `tb_accel_top`, `tb_pool2x2`, `tb_lenet_e2e`. All three are **elaboration** errors in files G does not own:
- `accel_top.sv:165` overrides the removed `conv1_top` params (`KERN_H`, `IN_H`, ...). Expected per contract 4.5; the orchestrator connects at merge.
- `pool2x2.sv:71` instantiates `line_buffer` with the old params (`K_H`, `IN_W`, ...). See contract problem 1.

Evidence for these two (scratch copy, not committed): `pool2x2`'s `line_buffer` instance was adapted to the new interface (`K_H_MAX(3), IN_H_MAX(TOTAL_H), ROW_BYTES_MAX(IN_W*8)`, `cfg_in_h=TOTAL_H`, `cfg_row_bytes=IN_W*8`, `rd_slot=rd_row%3`, `rd_offset=rd_col*8+rd_ch`). With that, `tb_pool2x2 PASS` and `tb_lenet_e2e PASS` (all 7 boundaries, predicted=2) on the final G RTL.

Mutation: `kh_slot <= next_slot(kh_slot)` was replaced by `kh_slot <= kh_slot` in window_gen (scratch copy). Result: `tb_window_gen FAIL` (first: `FAIL c1 byte row=0 x=0 k=5 lane=0 got=0b exp=eb`) and `tb_conv1_top FAIL`. `tb_fc_layer PASS` is expected, since kh=1 there. The worktree was never mutated.

Smoke (scratch, not committed): 48x48x3, 3x3, pad 1, C_out 6 through `conv1_top`, against a scratch copy of `conv1_ref.py`/`gen_conv1_vectors.py` (geometry constants changed; the narrow-range and partial-tile checks disabled). Result: `PASS tb_smoke_pad1: 288 tiles, 2304 beats checked twice, bit exact`.

Bad-cfg scratch test (`conv1_top`): 14 cases (2 good, 1 legal c_in=511, 11 bad incl. k_len mismatch), all as expected. Bad geometry gives `win_cfg_error=1`, `s_ready=0`, `error_flags=80`. k_len mismatch gives `win_cfg_error=0`, `error_flags=80`.

## Synthesis (OOC, xc7z020clg400-1, 10 ns, envelope defaults)

| | base (check_synth_conv1, 2985e8e) | lane G (check_synth_geom) |
|---|---:|---:|
| WNS (overall) | 0.897 ns | **0.886 ns** |
| worst path | u_ctrl/cfg_tile_reg -> u_weights/beats_accepted CE | u_ctrl/cfg_tile_reg -> u_weights/next_addr CE (10 levels) |
| worst path ending in u_window | 1.939 ns | **1.497 ns** (tile_base_col -> line_buffer rd_valid D, 10 levels) |
| LUT (total / u_window) | 4994 / 323 | 5916 / 1231 |
| LUT as distributed RAM | 110 | 494 |
| FF | 4035 | 4253 |
| BRAM | 16 RAMB36 | 16 RAMB36 |
| DSP | 80 | 80 |

Gate line: `GATE FAILED: see the ERROR lines above (WNS 0.886 ns, DSP 80)`. The miss of the +1.0 target is the **pre-existing** layer_ctrl -> weight_feeder start path (base 0.897 ns on the same path). The G-owned window path is at 1.497 ns. A first version had window WNS 0.662 ns (read-enable fan-out to 64 bank_q CEs); dropping that enable fixed it. LUT growth comes mostly from the ring: 8 banks x 320 entries (5 rows x 64-group pitch, for the 512-byte envelope), against 60-70 entries before.

## Contract problems / open questions

1. **`line_buffer` is not G-internal.** `pool2x2` (P) instantiates it (`pool2x2.sv:70`). The runtime line_buffer breaks P's pool2x2 in any merged tree unless its instance is updated. The scratch adapter above is a working instance for today's pool2x2. P's runtime pool should keep `rd_slot` as a wrap counter instead of the `%3` used in the adapter. Orchestrator decision needed.
2. **`error_flags[7]` is not visible to software yet.** `accel_top` maps `error_flags` with masks 0x48/0x10/0x27 into `hw_error_set`, so bit 7 is dropped. Suggest R/orchestrator map it, e.g. into the geometry bit `hw_error_set[7]`.
3. On a geometry error, `layer_ctrl` stays busy waiting for window beats: flagged, not silent, but it needs reset or frame_start to leave. `layer_ctrl` is not G's.
4. Overall synth WNS 0.886 ns < +1.0 ns target, from the pre-existing weight_feeder path (R's / orchestrator's).
5. Line endings: files were rewritten with LF in the working copy; git (autocrlf=true) normalizes, so the diff is content only.
