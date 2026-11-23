# Lane B report — register map v3

## Files

- `systolic-array-8x8/rtl/axi_lite_regs.sv`
- `systolic-array-8x8/tb/tb_axi_lite_regs.sv`
- `LANE-RAPOR-B.md`

## Decisions

- Split `LAYER_CFG`, `TILE_CFG`, `LAYER_CFG2`, `W_BASE`, and the new
  `DP_CFG` into shadow and active images. AXI readback exposes shadow state;
  all `cfg_*` outputs expose active state only.
- A successful COMMIT atomically copies geometry, tile, datapath selection,
  weight base, and the existing parameter banks into their active images.
  `cfg_k_len` is computed from the shadow `c_in`, `kh`, and `kw` values in
  that same accepted COMMIT.
- Added `DP_CFG` at `0x020` with active outputs `cfg_src_sel`, `cfg_pool_en`,
  and `cfg_dst_sel`; bits `[31:3]` are RAZ/WI.
- Added the one-cycle `layer_swap` output for CONTROL bit 3. It is accepted
  only while idle and is not readable as a level.
- Bumped `REGMAP_VERSION` to `16'h0003` and documented the v3 field map at
  the top of the RTL.
- Kept parameter completeness, M0 validation, W1C priority, and AXI channel
  timing unchanged.

## Error mapping

- ERROR[3] (`ERR_CFG_WR_BUSY`) is set when COMMIT or LAYER_SWAP is requested
  while `busy`; the command pulse is suppressed.
- ERROR[7] (`ERR_PARAM_INCOMPLETE`) remains the rejected-COMMIT/START guard
  for incomplete parameters, active stride other than one, or an active
  `PARAM_SRC=1` image without `table_valid`.
- ERROR[0] remains the M0 range error. Existing hardware-set and W1C behavior
  is unchanged.

## Regression

Command: `python sim/run_tests.py -v`

Summary line (verbatim):

```text
15/16 passed
```

`tb_axi_lite_regs` passed, and a clean focused rerun after mutation restore
printed:

```text
1/1 passed
```

The only full-suite failure was `tb_accel_top`. Its first configuration is
committed before START and the bit-exact frame passes. Its final checks then
write `LAYER_CFG` and `TILE_CFG` without COMMIT and expect live changes:

- line 210 expects the uncommitted `out_w` shadow write to create a geometry
  mismatch;
- lines 217 and 219 expect uncommitted tile shadow writes to change
  `cfg_active_rows` immediately.

Those three expectations are the three reported errors. Satisfying them
would contradict section 4, which requires every geometry/tile `cfg_*`
output to remain on ACTIVE until an accepted COMMIT. Per the contract rule,
I stopped this compatibility item rather than restoring live register
behavior or editing the out-of-scope top-level test.

## Mutation

Temporarily changed `cfg_src_sel` to use `shadow_dp_cfg[0]` instead of
`active_dp_cfg[0]`. The focused XSim test failed with:

```text
FAIL tb_axi_lite_regs: DP_CFG shadow write changed active outputs
FAIL tb_axi_lite_regs: BUSY shadow writes changed the active configuration
0/1 passed
```

The mutation was restored. The clean focused result is `1/1 passed`.

## Open questions

- Lane C should revise the final `tb_accel_top` checks to COMMIT the new
  shadow image before expecting active geometry/tile changes, or replace
  them with explicit shadow-isolation checks. No owner-B RTL change can make
  those v2 live-write expectations pass without violating the v3 contract.

## Git

The commit was attempted but the sandbox could not create the linked
worktree lock file:

```text
fatal: Unable to create 'C:/grad-rtl/.git/worktrees/b4/index.lock': Permission denied
```

The changes are therefore left uncommitted on `lane/b-regs`.
