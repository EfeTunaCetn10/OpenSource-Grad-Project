# Lane P Report — Runtime Geometry

## Files changed

- `systolic-array-8x8/rtl/pool2x2.sv`
- `systolic-array-8x8/rtl/act_buffer.sv`
- `systolic-array-8x8/tb/tb_pool2x2.sv`
- `systolic-array-8x8/tb/tb_act_buffer.sv`
- `systolic-array-8x8/tb/tb_lenet_e2e.sv` (only `lenet_e2e_pool`)
- `LANE-RAPOR-P.md`

## Decisions

- `pool2x2` now has only the envelope parameters `IN_H_MAX=48`,
  `IN_W_MAX=48`, `C_TILE_MAX=4`, and `TILE=8`. Runtime geometry is supplied
  through the binding `cfg_in_h`, `cfg_in_w`, and `cfg_c_tiles` ports.
- The old compile-time `line_buffer` instance could not represent a changing
  runtime row width. It was replaced inside `pool2x2` by a streaming pairwise
  implementation: the even input pixel is held, first-row horizontal maxima
  are cached, and second-row horizontal maxima are combined with that cache.
  One output register preserves data and `m_last` under backpressure.
- Pool geometry is sampled while idle. A changed configuration must be stable
  for one clock before `s_ready` can rise. Registered counters track column,
  row, and channel tile. There is no runtime multiply, divide, or modulo in the
  per-beat path.
- `act_buffer` defaults are now `OUT_H_MAX=48`, `OUT_W_MAX=48`,
  `C_TILE_MAX=4`, and `DEPTH=4608`. Its existing derived address width is 14
  bits (`$clog2(4*48*48+1)`), which safely represents both the end of two
  48x48 tile planes (4608 words) and four 12x12 tile planes (576 words).
- `tb_act_buffer` explicitly uses `DEPTH=784` so its pre-existing overflow
  scenario remains effective rather than being weakened by the larger RTL
  default.

## Error-flag mapping

- `pool2x2.cfg_error`: asserted when idle configuration has zero or odd H/W,
  H/W exceeds its envelope, or the tile count is zero or exceeds
  `C_TILE_MAX`. It clears after a valid idle configuration is sampled and is
  held stable during a frame.
- `act_buffer.seq_error`: unchanged; covers invalid H/W or tile index and
  input sequencing/`in_last` mismatches when a beat is accepted.
- `act_buffer.ovf_error`: unchanged; covers a write pointer at or beyond
  `DEPTH`.

## Verification

- Command: `python sim/run_tests.py -v`
- Exact summary: `16/16 passed`
- Relevant PASS lines included:
  - `PASS tb_pool2x2: pool1=196 beats pool2=50 beats, cycles=1775`
  - `PASS: T_LAYOUT_ADDR_001, 2 frames, 1568 words, ping-pong, errors`
  - `PASS tb_lenet_e2e: all 7 boundaries, predicted=2`
- Mutation sanity: temporarily changed the signed lane comparator from max
  (`>=`) to min (`<=`). `tb_pool2x2` failed at pool case 2, beat 0 with a data
  mismatch, and the runner reported `0/1 passed`. The correct comparator was
  restored before the full regression.

## Synthesis

Not required for lane P by contract section 6; no synthesis run was made.

## Open questions

None. No contract/code contradiction was found in lane P's assigned scope.
