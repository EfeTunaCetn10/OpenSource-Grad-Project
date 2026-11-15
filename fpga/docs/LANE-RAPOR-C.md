# LANE-RAPOR-C — accel_top integration (faz4-datapath, lane C)

Branch `lane/c-integ`, worktree `C:\grad-wt\c4`, base `faz4-datapath` @ `5285e17` (lanes A+B merged). Contract: `C:\codex-ctx\2026-11-06\faz4-kontrat.md` §2, §6, §8.

## Files

| File | Change |
| --- | --- |
| `systolic-array-8x8/rtl/accel_top.sv` | Single layer datapath: source mux, START sequence, lane mask, pool2x2/bypass, act_buffer, destination mux, pass completion, soft-reset fan-out, error routing, validator parity. |
| `systolic-array-8x8/rtl/window_gen.sv` | S14 only: `p_kernel_counters_in_range` is no longer checked in `ST_DONE`. |
| `systolic-array-8x8/tb/tb_accel_top.sv` | Updated for v3 (see Verification). |
| `systolic-array-8x8/vivado/check_synth_accel.tcl` | Adds `pool2x2.sv` and `act_buffer.sv` to the file list. It has no DSP/BRAM expectations, so nothing else changed. |
| `scratch/smoke/` | `gen_smoke.py`, `tb_smoke_accel.sv`, `run_smoke.sh` (not committed). |
| `scratch/mut/mut.sh` | Mutation runner, `bash mut.sh M1` … `M6` (not committed). |
| `scratch/synth/`, `scratch/impl/check_impl_accel.tcl` | Synthesis log, copied implementation script with fixed paths (not committed). |

No owner-A/B module or conv1_top/pool2x2/weight_feeder/layer_ctrl was edited.

## Design

### Topology

```
src_sel=0: s_*  ----------------\
src_sel=1: act_buffer rd_* ------+-> conv1_top -> lane mask -> pool2x2 | bypass
                                     -> dst_sel=0: act_buffer wr (tile plane = tile_idx)
                                     -> dst_sel=1: m_*
```

- **Source mux.** `src_valid = pass_busy && (src_sel ? rd_valid : s_valid)`. `rd_data` is forced to 0 and `rd_last` to 0 while `!rd_valid`. The unselected source sees ready low: external `s_ready = pass_busy && !src_sel && conv_s_ready`, `rd_ready = pass_busy && src_sel && conv_s_ready`. Because of the `pass_busy` gate no beat can enter window_gen outside a pass. Before, a DMA beat after reset could reach the idle generator, which would then refuse the restart.
- **Lane mask.** `lane_mask[r] = r < cfg_active_rows`, registered at START from the frozen active image. This is the same mask compute_engine/requant put on `m_lane_valid`; it zeroes inactive rows before the pool and both destinations, and it drives the external `m_lane_valid` in both pool and bypass mode. requant_array already zeroes inactive lanes in `out_y_flat`, so on the data the mask is a boundary guarantee, not a functional change. A mutation of the mask itself is caught through `m_lane_valid` (M6).
- **Pool.** `pool2x2 #(C_TILE_MAX=1)` with `cfg_in_h/w = out_h/out_w`, `cfg_c_tiles = 1`. With `pool_en=0` it is bypassed and never fed.
- **Destination.** `dst_sel=0`: act_buffer write with `cfg_wr_h/w` = pooled or conv plane, `cfg_wr_tile = tile_idx`, `cfg_wr_tiles = tile_count`. `dst_sel=1`: `m_*`. `m_last` is computed from the destination raster counters (`dst_row == h-1 && dst_col == w-1`, limits registered at START); conv1_top's own `m_last` (per 8-column group) is not used. `m_col`, `m_sat_flat`, `m_ovf_flat` pass through in bypass and read 0 in pool mode (they describe one conv column, not a pooled pixel).
- **Pass vs. registers.** The cfg_* image is the ACTIVE image (lane B). COMMIT is refused while `busy`, and `busy` is the whole pass, so the pass configuration is frozen without any extra latch in accel_top. The old `committed_*` copy and its 14 comparisons were therefore always equal to cfg_* and have been removed (§8 item 8: "clearly dead"). `geometry_ok` is the COMMIT-time validator result alone.

### START cycle order (S = cycle of axi_lite_regs' `start` pulse)

| Cycle | Event |
| --- | --- |
| S | `start_ok = start && geometry_ok` is sampled. `pass_busy` and `go` are set. Destination counters, their limits and `lane_mask` are loaded. |
| S+1 | `go`: conv1_top `restart` and `frame_start`, act_buffer `rd_start` (src_sel=1) and `wr_start` (dst_sel=0), all in the same cycle. window_gen accepts the restart (ST_DONE, or idle after reset); its line-buffer clear holds `s_ready` low in this cycle. layer_ctrl leaves IDLE at the S+1 edge. |
| S+2 | layer_ctrl is in ST_WAIT_TILE and window_gen already reports `!done` (it left ST_DONE at the same edge), so layer_ctrl cannot see the previous frame's `done`. The first source beat can be accepted from here on. act_buffer's first read word comes at S+4 at the earliest; its write side is ready at S+4. |

### Pass completion

`pass_done = pass_busy && dst_done_seen && !conv_busy`, where `dst_done_seen` is set by act_buffer `wr_done` (dst_sel=0) or by the `m_*` handshake with `m_last` (dst_sel=1). `busy` (to axi_lite_regs) is `pass_busy`; it falls with `pass_done`. `pass_done` drives STATUS.DONE and FRAME_COUNT (completed passes). CYCLE_COUNT is still the engine's active-cycle counter, STALL_IN/STALL_OUT still count the external `s_*`/`m_*` stalls.

### Error mapping (ERROR register; bits unchanged from ADR-015, new sources added)

| Bit | New source added by lane C |
| --- | --- |
| [2] ERR_ACC_OVF | requant overflow is now taken from conv1_top's handshake, not the external `m_*` (which may be idle with dst_sel=0). |
| [5] ERR_TLAST_LATE | pass completed while the act_buffer read stream still had words (`src_sel=1 && rd_busy` at `pass_done`): the stored layer is longer than the frame the geometry describes. |
| [6] ERR_TIMEOUT | act_buffer `seq_error` (rising edge); window_gen `restart_error` (rising edge). |
| [7] ERR_PARAM_INCOMPLETE | act_buffer `ovf_error` (rising edge); pool2x2 `cfg_error` at the `go` cycle of a `pool_en` pass; START with a geometry the validator rejected (already there; now also `out_h==0`, `out_w==0`, `pad>=kh`, `pad>=kw`). |

The sticky act_buffer/window_gen flags are edge-detected, so a W1C clears the ERROR bit and it is set again only by a new event (or after SOFT_RESET clears the source). A datapath error does not end the pass: `busy` stays high and DONE never comes. The PS must treat STATUS.ERROR while BUSY as a failed pass and recover with SOFT_RESET (proven in S4).

### SOFT_RESET

CONTROL.SOFT_RESET (pulse) → `pass_busy`, `go`, `dst_done_seen` cleared the same cycle; `dp_rst_n <= rst_n && !soft_reset` (registered) resets conv1_top and pool2x2 one cycle later; act_buffer gets the pulse on its `soft_reset` port (FSMs idle, errors cleared, memory/bank select/stored geometry kept). axi_lite_regs keeps its active image and `committed`, so START works again without a new COMMIT (tb_accel_top frame 2), and a new COMMIT+START works (S4). `cycle_count_base` is zeroed under `dp_rst_n` because the engine counter itself restarts from 0 there.

### What the PS must guarantee

1. Per pass: write LAYER_CFG, LAYER_CFG2, W_BASE, TILE_CFG, DP_CFG and all 24 parameter words, COMMIT, START, then wait for STATUS.DONE (W1C) **or** STATUS.ERROR.
2. After the last tile of a layer with dst_sel=0: CONTROL.LAYER_SWAP while idle (before the next layer's START).
3. act_buffer-sourced layer: `in_h, in_w` (i.e. `out + k - 1 - 2*pad`) equal the stored plane, and `c_phys = 8 * tiles_of_previous_layer`. If the stored stream is longer, ERROR[5] is set at pass end; if it is **shorter, the pass hangs with no error** (window_gen waits for bytes that never come). Only SOFT_RESET recovers.
4. s_*-sourced layer: re-send the whole frame for every tile pass (window_gen is not a replay buffer). A short frame hangs the same way.
5. dst_sel=0: `tile_count * h * w <= 4608` words (else ERROR[7], pass hangs until SOFT_RESET); pooled dims must be even (else pool `cfg_error`, ERROR[7]).
6. Weights are loaded through `w_wr_*` while no pass is running (weight_feeder asserts on a write while a tile streams).

## Verification

### Regression

`python sim/run_tests.py` from `systolic-array-8x8/`, final RTL, with `sim/vectors` deleted first:

```
16/16 passed
```

All 16 tests are listed as PASS. `tb_accel_top` prints `PASS tb_accel_top: 3 bit-exact frames of 784 beats`.

Changes to `tb_accel_top` (§8 item 10):
- **Setup.** DP_CFG=0x4 (s_* → no pool → m_*) is written before the first COMMIT. `dut.layer_done` is now `dut.pass_done`. A new per-beat check requires `m_last` to be high exactly on beat 783.
- **Busy writes (new).** After 100 output beats of frame 1, the TB writes LAYER_CFG (out_w 27), TILE_CFG, W_BASE=1, DP_CFG=3 and all 24 parameter words, then COMMIT and LAYER_SWAP. Checks:
  - the frame stays bit-exact;
  - the active image is unchanged (`cfg_out_w`, `cfg_w_base`, `cfg_dst_sel`, `cfg_src_sel`, `cfg_active_rows`);
  - ERROR is 0x08 only;
  - W_BASE reads back the shadow.
- **The three old v2 checks became:**
  - (a) An uncommitted LAYER_CFG write reads back as the shadow, and `cfg_out_w`/`cfg_in_w` stay unchanged.
  - (b) A committed out_H=0, and a committed kh=1/kw=3/pad=1, both give ERROR == 0x80 only on START. BUSY never rises and there is no output. These are the new validator-parity cases. Before lane C both were accepted and the pass hung (H2-D/H2-E).
  - (c) TILE_CFG acts only after COMMIT. Active rows are unchanged before the COMMIT, then 8 and 2 after the two COMMITs.
- **Frames 2 and 3 (new).** Same active image, no COMMIT. Frame 2 follows SOFT_RESET. Frame 3 follows frame 2 directly, so only the restart pulse can take window_gen out of ST_DONE. Both are bit-exact, FRAME_COUNT reads 1 and then 2, and ERROR is 0.
- **Unchanged checks:** readbacks, commit status, registered k_len/geometry, STATUS, DONE W1C, the exact CYCLE/STALL_IN/STALL_OUT counts and their clear.

### System smoke (scratch, `bash scratch/smoke/run_smoke.sh`)

`gen_smoke.py` builds the reference chain in Python:
- seed 20261106;
- bias/M0/shift/ReLU per channel, so every tile pass loads different parameters;
- v3 conv1 48x48x3 → 16 ch → pool → conv2 24x24x16 → 24 ch → pool → conv3 12x12x24 → 32 ch.

`tb_smoke_accel.sv` drives accel_top only through AXI-Lite, `s_*`, `m_*` and the weight port. `s_valid` and `m_ready` are paced by two 16-bit LFSRs (about 75%).

Result lines (final RTL):

```
S1 PASS: conv1(2 tiles,pool)->swap->conv2(3 tiles,pool)->swap->conv3(4 tiles)->m_*, 576 words, errors=0
S2 PASS: two further STARTs, no COMMIT, conv3 tile 3 replayed exact twice, errors=0
S3 PASS: LAYER_CFG/LAYER_CFG2/TILE_CFG/W_BASE/DP_CFG written mid-pass, pass exact, errors=0
S4 bad pass: STATUS=0000000a ERROR=80
S4 PASS: overflow pass -> ERROR[7], BUSY held -> SOFT_RESET -> COMMIT+START exact, errors=0
SMOKE PASS: errors=0 FRAME_COUNT=1 act_buffer swaps=2
```

- **S1.** Nine passes, all driven by AXI writes: COMMIT/START/DONE per tile and LAYER_SWAP per layer. The result is bit-exact against Python at three points:
  - the act_buffer write bank after conv1 (1152 words), compared tile-major by hierarchical read;
  - the same bank check after conv2 (432 words);
  - all 576 conv3 words on `m_*`, with exactly one `m_last` per pass, on its 144th beat.

  conv2 and conv3 read multi-tile layers (c_phys 16 and 24) from act_buffer, so this is the in-system proof of the K1 fix.
- **S2.** conv3 tile 3 is STARTed twice more with no COMMIT. Both runs are complete and exact. This covers K2, and it is also an act_buffer replay.
- **S3.** This runs conv3 tile 1. After 40 output beats the TB overwrites the shadows with conv2's geometry, base and tile, and DP_CFG=3. The pass stays exact (K3).
- **S4.** The bad pass uses conv1 geometry, no pool, 3 tiles and dst=act_buffer (3·48·48 > 4608). After 5000 cycles STATUS shows BUSY+ERROR, ERROR is 0x80 and there is no DONE. SOFT_RESET returns the top to idle, and ERROR stays set until W1C. Then COMMIT+START of conv3 tile 0 from act_buffer is exact, which also shows that act_buffer memory survives SOFT_RESET.
- **Assertions.** The run script also greps the XSim log for `Error:`/`Assertion`. Neither appears on the final RTL. S4 reconfigures from conv3 (c_in 24, K 216) to conv1 (c_in 3, K 27) while window_gen is in ST_DONE, which is the S14 case.

### Mutations (each applied alone, original restored byte-exact; `scratch/mut/mut.sh`)

| # | Mutation | Check | Result |
| --- | --- | --- | --- |
| M1 | `.restart(go)` → `.restart(1'b0)` (K2) | tb_accel_top | FAIL: `frame 3 output timeout`, `frame 3 BUSY/DONE`, … It survived the first TB version, which restarted only after SOFT_RESET; frame 3 was added because of that. |
| M2 | `dst_w_m1 <= dst_w` (m_last counter) | tb_accel_top | FAIL: `m_last position`, `pass_done pulse missing`, … |
| M3 | drop `cfg_pad < cfg_kh` from the validator | tb_accel_top | FAIL: `pad>=kh ERROR[7] only`, `pad>=kh started a frame`. It survived the first test case (kh=kw=1), where `pad<kw` rejects too; the case is now kh=1, kw=3. |
| M4 | act_buffer `cfg_wr_tile` tied to 0 | smoke | FAIL: `S1 L1 bank: 1152 of 1152 stored words differ`; later passes fail too. |
| M5 | revert the S14 fix in window_gen | smoke | `ERROR: Assertion failed.` three times during S4. The smoke's own lines still say PASS; the assertion lines in the script output are what catch it. |
| M6 | `lane_mask[r] <= 1'b1` | tb_accel_top | FAIL: `lane mask` |

### Synthesis (`vivado/check_synth_accel.tcl`, run from `scratch/synth/`)

```
ACCEL_SYNTH: WNS=1.592 ns LUT=8371 FF=6192 BRAM=48 DSP=86
PASS: accel_top synthesis margin
```

- **Utilization report:** RAMB36E1 48, RAMB18 0, DSP48E1 86, Slice LUTs 7612 (678 of them as memory). The script's LUT=8371 counts LUT cells.
- **Baseline:** +1.470 ns.
- **Critical path:** `u_regs/active_layer_cfg_reg[17]` → `row_bytes_reg` DSP. This is the COMMIT-time validator product, not a per-beat path.

### Post-route (`scratch/impl/check_impl_accel.tcl`: the archived script with the paths fixed and `pool2x2.sv act_buffer.sv` added)

```
IMPL_WNS: 0.477
IMPL_WHS: 0.038
```

Post-route utilization: Slice LUTs 7481, Slice Registers 6192, RAMB36 48, RAMB18 0, DSP 86. Both slacks are ≥ 0, but thinner than the baseline (+0.619 / +0.097).

Top setup paths:
1. **+0.477 ns:** `u_regs/active_layer_cfg_reg[24]` (out_h) → `u_requant/g_lane[2].u_req/s1_product_reg/CEP`, 8 LUT levels. This is the new ready chain. pool2x2's `s_ready` compares its registered geometry with the live `cfg_in_h/w` ports combinationally (`cfg_matches`, `cfg_valid`), and that ready now feeds `conv_m_ready` → requant pop/CE.
2. **+0.507 / +0.518 / +0.610 ns:** `u_requant/rd_ptr_reg[1]` → LUTRAM meta → `out_y_flat` → lane mask → pool `lane_max` twice → `u_pool/m_data_reg`.

Worst hold path: +0.038 ns, `u_window/u_line_buffer/write_group_reg[3]` → line-buffer LUTRAM WADR. This is inside window_gen, which lane C did not change there.

The first run of the impl script died in synth_design with `couldn't read file ".../unimacro_vhdl.tcl": No error` while the smoke XSim was running in parallel. The rerun, with nothing else running, succeeded; the numbers above come from it.

## Open questions

1. **Timing margin.** Post-route WNS fell from +0.619 to +0.477 ns, and WHS from +0.097 to +0.038 ns. Both critical setup paths go through pool2x2 (not owned by lane C): its `s_ready` is combinational in the live cfg compare, and its `lane_max` comes after requant's combinational output. Two ways to recover margin, neither done here:
   - a register slice between requant and pool in accel_top (one beat of latency, no owner change);
   - a registered `cfg_matches` inside pool2x2 (owner change).
2. **A short source stream hangs with no error.** If the stored layer is shorter than the committed geometry (wrong in_h/in_w/c_phys), window_gen waits forever. Only SOFT_RESET recovers. The opposite case, a longer stream, sets ERROR[5]. Detecting the short case would need either the act_buffer read geometry on a port (owner A) or a watchdog.
3. **Datapath errors do not end the pass.** This is deliberate: ERROR is set, BUSY stays high, and the PS must issue SOFT_RESET. If the orchestrator prefers DONE+ERROR (auto-abort), that is a small change in accel_top.
4. **ERROR bits are shared.** All eight bits were already assigned, so the act_buffer, pool and restart errors share [5]/[6]/[7] with older sources. Separating them needs a wider ERROR or a second register in the register file (owner B). ADR-015's map should list the new sources.
5. **FC and LeNet conv2 are not tested in-system.** Neither runs through accel_top: FC1 (288→64, a 1x1 with c_phys 288 read from a 3x3x4-tile layer) nor LeNet conv2 (c_in 6, c_phys 8, read from act_buffer). tb_lenet_e2e still drives conv1_top directly. The smoke harness can be extended with one more layer for each.
6. **Lane A open point 4 is unchanged.** A LAYER_SWAP with no new write since the previous swap is still accepted; accel_top forwards LAYER_SWAP as is.
7. **Sideband outputs in pool mode.** `m_col`, `m_sat_flat` and `m_ovf_flat` read 0 in pool mode, and `m_lane_valid` is the pass lane mask in both modes. The DMA wrapper does not use them, but ADR-006 may want this documented.
