# LANE-RAPOR-L4 — system smoke S5..S7 (scratch, not committed)

Worktree `C:\grad-wt\d5` (branch `lane/g-smoke`, faz4-datapath HEAD with L1+L2+L3). RTL under test:
`systolic-array-8x8/rtl`, not modified. Run: `bash C:/grad-wt/d5/scratch/smoke/run_smoke.sh C:/grad-wt/d5/systolic-array-8x8/rtl`
(wall time ~92 s including compile; S1..S4 alone were ~52 s).

## Files (scratch/smoke)
- `gen_smoke.py`: S1..S4 generator untouched; added `gen_chain`/`gen_s56` (pure Python golden: conv reduction order
  ci*kh*kw+ky*kw+kx, FC as 1x1 conv over the (h,w,c) flatten, requant_ref, pool). Weights/biases/M0 random (seeds 20261107/08),
  M0 in [65536,131071], per-channel shift calibrated from each layer's own accumulator spread -> outputs ~+-20..45,
  saturation <1%, zeros <3% to 15% (asserted in the generator). Unused output rows of the last tile carry junk weights/params
  (the lane mask must zero them). Weights written per bank with W_BASE offsets.
- `tb_smoke_accel.sv`: S1..S4 code unchanged apart from three generalisations that keep their behaviour (feed length `feed_n`,
  scoreboard array `expm`, `m_stall`) and `accel_top #(.WDOG_W(13))` (S1..S4 now also run with WDOG_W=13; they pass).
  New generic helpers (`cfg2`, `run_layer`, `check_bank2`, ...) and S5, S6, S7a/b/c.
- `run_smoke.sh`: grep widened to S1..S7.

## Cases
- S5: conv1 32x32x3 5x5 pad0 (s_*, c_phys 3, 1 tile, last_rows 6, pool) -> swap -> conv2 14x14 c_in 6 c_phys 8 5x5 (2 tiles, pool)
  -> swap -> fc1 1x1 c_in/c_phys 400 (15 tiles, k=(h*5+w)*16+c) -> swap -> fc2 120->84 (11 tiles, last_rows 4, c_in=c_phys=120)
  -> swap -> fc3 c_in 84 c_phys 88 (stored 11 tiles = 88 lanes, 84 real) -> 10 (2 tiles, last_rows 2) -> m_*.
  Stored banks after conv1/conv2/fc1/fc2 compared word-by-word (conv1: 196 words, lanes 6,7 = 0), final m_* compared per pass
  with exactly one m_last per pass.
- S6: conv4 12x12 c_in 32 3x3 pad1 (s_*, 4 tiles, pool) -> conv5 6x6 (4 tiles, pool) -> fc1 c_phys 288 (8 tiles) -> fc2 64->10
  (2 tiles, last_rows 2) -> m_*; banks compared after conv4/conv5/fc1.
- S7b: s_last on beat 100 of 576 (conv4 tile 0) -> STATUS 0x2d, ERROR 0x10, ERR_DETAIL 0x2000; W1C; START alone (no COMMIT) then
  tiles 1..3 with COMMIT: conv4 bank exact, ERROR/DETAIL/STATUS clean. No SOFT_RESET.
- S7a: with the 6x6x4-tile conv4 output swapped in: committed 8x8 plane, c_phys 40 (5 tiles), and FC flatten c_phys 288 (stored
  would need 1152) -> each START rejected: idle, no DONE, ERROR 0x80, ERR_DETAIL 0x1000, no hang (checked after 40 cycles); then
  conv5 4 tiles exact.
- S7c: conv5 tile 0, src=1 pool dst_sel=1, m_ready held low -> STATUS 0x2d, ERROR 0x40, ERR_DETAIL 0x8000, 0 m_* beats; then the
  same pass (START only) exact, 9 beats, one m_last, clean.

## Result lines (verbatim from the final run)
```
S1 PASS: conv1(2 tiles,pool)->swap->conv2(3 tiles,pool)->swap->conv3(4 tiles)->m_*, 576 words, errors=0
S2 PASS: two further STARTs, no COMMIT, conv3 tile 3 replayed exact twice, errors=0
S3 PASS: LAYER_CFG/LAYER_CFG2/TILE_CFG/W_BASE/DP_CFG written mid-pass, pass exact, errors=0
S4 bad pass: STATUS=0000002d ERROR=80 ERR_DETAIL=0200
S4 PASS: overflow pass -> abort (DONE+ERROR[7]+ABORTED, ERR_DETAIL[9]), no SOFT_RESET -> COMMIT+START exact, errors=0
S5 PASS: LeNet conv1(6ch padded to 8)->pool->conv2(c_in6,c_phys8)->pool->fc1(400,15 tiles)->fc2(11 tiles)->fc3(2 tiles)->m_*, bit-exact, errors=0
S6 PASS: v3 tail conv4(4 tiles)->pool->conv5->pool->fc1(288,8 tiles)->fc2(64,2 tiles,last_rows 2)->m_*, bit-exact, errors=0
S7b short frame: STATUS=0000002d ERROR=10 ERR_DETAIL=2000
S7b PASS: s_* short frame -> abort (DONE+ERROR[4]+ABORTED, detail[13]), then conv4 4 tiles exact without SOFT_RESET, errors=0
S7a PASS: stored 6x6x4 layer vs 8x8 / c_phys 40 / flatten 288 -> START rejected (ERROR[7]+detail[12], idle, no DONE), then conv5 exact, errors=0
S7c watchdog: STATUS=0000002d ERROR=40 ERR_DETAIL=8000 m_beats=0
S7c PASS: stalled m_ready (WDOG_W=13) -> abort (DONE+ERROR[6]+ABORTED, detail[15]), then the same pass exact without SOFT_RESET, errors=0
S7 PASS: faults a/b/c, errors=0
SMOKE PASS: errors=0 FRAME_COUNT=71 act_buffer swaps=10
```
No `Error:`/`Assertion` lines in the XSim log.

## RTL defects
None found. One smoke bug during development, fixed in the tb: my first S7c waited a fixed 12000 cycles and saw a still-BUSY
pass with no error. Evidence (debug tb with a handshake monitor, `scratch/dbg`): the engine still delivers a burst of conv
outputs every ~2900 cycles while m_ready is low, because the register slice and pool2x2 have room for the first rows; each burst
resets the watchdog (cnt reached 2910 only). The pipeline fully backs up after ~3 bursts and the watchdog then fires 8191 idle
cycles later. Polling until DONE/ERROR (up to 40000 polls) gives the expected abort. Note for the PS: with a real stalled m_ready
the abort comes up to (pipeline absorb time + 2^WDOG_W) cycles after the stall begins, not 2^WDOG_W.

## Not run / limits
- No mutation of the RTL was run in this lane (RTL tree is read-only here); sensitivity rests on bit-exact comparison of every
  stored layer and every m_* word against an independent Python model.
- The unit tb regression (`sim/run_tests.py`) was not run here.
- Only one s_* pacing/LFSR pattern; S7b short frame only tested at beat 100 (not at the first or second-to-last beat).

## Open questions
1. The watchdog latency note above (abort not at exactly 2^WDOG_W after a stall begins); acceptable for the PS timeout design?
2. fc3 reading the 88-lane stored layer with c_in 84 / c_phys 88 works; FC weight order assumes the PS leaves lanes 84..87 out.
