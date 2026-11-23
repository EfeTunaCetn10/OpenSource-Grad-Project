# LANE-RAPOR-L3 — accel_top: abort, source checks, TLAST, watchdog, register slice

Branch `lane/f-robust`, worktree `C:\grad-wt\c5`, base `faz4-datapath` @ `305214f` (L1 + L2 merged). Contract: `C:\codex-ctx\2026-11-07\acik-kontrat.md` §L3 items 1-7.

## Files

| File | Change |
| --- | --- |
| `systolic-array-8x8/rtl/accel_top.sv` | Abort (O1), START source-geometry and frame-size checks, s_* beat budget with TLAST early/late, watchdog (`WDOG_W`), ERR_DETAIL/ABORTED wiring (O3), 2-entry register slice requant -> pool (O4), rd_geom wired. |
| `systolic-array-8x8/tb/tb_accel_top.sv` | `WDOG_W=10`, the new L3 cases (below); every earlier check kept. |
| `vivado/check_synth_accel.tcl` | Not changed (no new files). |
| `scratch/` (not committed) | `smoke/` (S4 adapted), `smoke_orig/` (the lane C smoke unchanged), `mut/mut.py`, `synth/`, `impl/check_impl_accel.tcl` (archived script, paths -> c5). |

No other RTL changed.

## Design

### START (S = cycle of the regs `start` pulse)

| Cycle | Event |
| --- | --- |
| S..S+3 | `start_p` shift register. `busy = pass_busy \|\| \|start_p`, so COMMIT and LAYER_SWAP are refused from S+1 on. |
| S+4 | `start_dec`. Accepted iff `geometry_valid_reg` (unchanged validator) && `frame_bytes_q[2:0]==0` && (`!src_sel` \|\| `src_ok_q`). Accepted: `pass_busy`, beat budget, dst counters, lane mask loaded. Rejected: ERROR[7], plus ERR_DETAIL[12] if only the source check failed. No pass, no DONE. |
| S+5 | `go` (conv1_top restart + frame_start, act_buffer rd_start/wr_start), as before. |
| S+6 | earliest source beat. |

The four settle cycles let START and LAYER_SWAP come in one CONTROL write (0x9). The swap lands at S. `rd_geom_*` is new at S+1, `rd_hw_q` (h*w) at S+2, `rd_flat_q` (*tiles) at S+3 and `src_ok_q` at S+4. Everything the decision reads is a register, and no product is formed per beat:
- `frame_bytes_q = cfg_in_h * row_bytes_reg`, recomputed every cycle from COMMIT-time registers;
- `rd_hw_q`, then `rd_flat_q`, form a two-stage product of the act_buffer registers;
- `src_ok_q = rd_geom_valid && ((in_h==h && in_w==w && c_phys==8*tiles) || (in_h==1 && in_w==1 && c_phys==8*tiles*h*w))`, which is the contract's rule.

A first version formed the three-way product in one stage. It failed synthesis (-0.114 ns, LUT multiply into the DSP A port), so it was split.

### s_* frame length

- **Beat budget.** `src_rem` is loaded at the START decision with `frame_bytes_q>>3`, which is always a whole number because START checked it. `src_open` gates `s_ready`, `ab_rd_ready` and `src_valid`, and closes on the last expected beat, on an abort or on pass end. Extra beats are therefore not accepted, and no beat enters outside a pass.
- **TLAST early.** `src_last` on a beat with `src_rem != 1` aborts the pass: ERROR[4] + ERR_DETAIL[13].
- **TLAST late.** The last expected beat arrives without `src_last`: ERROR[5] + ERR_DETAIL[14]. This is a flag only; the pass completes.
- **Leftover read words.** The old "act_buffer read words left at pass end" check is also ERROR[5] + ERR_DETAIL[14]. Once the START source check passes, it can no longer happen.
- **Scope.** The check applies to both sources. For `src_sel=1` it cannot fire after a passed source check.

### Watchdog

- `WDOG_W` parameter, default 16. tb_accel_top uses 10.
- While `pass_busy`, a counter counts up. Any source, conv-output or destination handshake resets it (the reset is one registered cycle late, through `wdog_kick`).
- At all-ones the pass aborts: ERROR[6] + ERR_DETAIL[15].
- With the default the limit is 65535 idle cycles, 655 µs at 100 MHz.

### Abort (O1)

`abort_req = pass_busy && !abort_q && !pass_done && (any new conv1 error_flags bit || act_buffer seq || ovf (edge) || pool cfg_error at go || restart_error (edge) || TLAST early || watchdog)`.

If a pass completes in the same cycle as one of these errors, it counts as completed and the error is only flagged.

Sequence:

| Cycle | Event |
| --- | --- |
| A | Error event. ERROR and ERR_DETAIL bits are set from the event itself, edge-detected as before. `src_open` closes. |
| A+1 | `abort_q`. `pass_busy`, `dst_done_seen` and the watchdog clear at the end of this cycle. The regs' `done` (= `pass_done \|\| abort_q`) sets STATUS.DONE, and `pass_aborted` sets STATUS.ABORTED. act_buffer `soft_reset` = `soft_reset \|\| abort_q`: both FSMs go idle and seq/ovf clear; memory, bank select, stored geometry and the completed-tile mask are kept. |
| A+2 | `dp_rst_n` low: conv1_top, the slice and pool2x2 are reset. `cycle_count_base <= base - raw`, so CYCLE_COUNT keeps its value. |

- **Kept and cleared.** No AXI register is cleared, ERR_DETAIL included (L2's warning). The teardown raises no detail bit: the sources it resets go low, so their edge detectors see no rising edge.
- **FRAME_COUNT** counts completed passes only.
- **Not aborts.** Requant overflow (ERROR[2]) and lockstep_error (ERROR[2]) stay flags.
- **SOFT_RESET** is unchanged: the same datapath reset, no DONE, no ABORTED.

### ERROR / ERR_DETAIL

| Event | ERROR | ERR_DETAIL | Effect |
| --- | --- | --- | --- |
| conv1_top error_flags bit b (new) | [4] for 0x48, [5] for 0x10, [6] for 0x27, [7] for 0x80 (unchanged) | [b] | abort |
| act_buffer seq_error | [7] (was [6]) | [8] | abort in a pass, flag when idle (e.g. a refused LAYER_SWAP) |
| act_buffer ovf_error | [7] | [9] | abort |
| pool2x2 cfg_error at go (pool_en) | [7] | [10] | abort |
| window_gen restart_error | [7] (was [6]) | [11] | abort |
| START: stored layer does not match the committed geometry | [7] | [12] | START rejected |
| START: validator rejects, or the s_* frame is not a whole number of beats | [7] | none | START rejected |
| s_last before the last expected beat | [4] | [13] | abort |
| last expected beat without s_last; leftover read words | [5] | [14] | flag |
| watchdog | [6] | [15] | abort |
| requant overflow, lockstep | [2] | none | flag |

### Register slice (O4)

- **Structure.** A main register plus a skid register.
  - `conv_m_ready = !sk_s_vld`, which is a register.
  - The output comes from the main register, which feeds pool2x2 `s_data` and the bypass path.
  - The payload is y (lane-masked at the input), sat, ovf and col, so in bypass `m_col`, `m_sat_flat` and `m_ovf_flat` stay aligned with their beat.
- **Reset.** The slice is reset by `dp_rst_n`.
- **Throughput.** It runs at full rate. A stall costs one bubble when it clears.
- **Latency.** One extra cycle from requant to the pool.
- **ACC_OVF.** It is still taken at the conv1_top handshake.

## What the PS must do

1. Per pass, as before: write the shadows and the 24 parameter words, COMMIT, START. Then wait for **STATUS.DONE** and read ERROR, ERR_DETAIL and STATUS.ABORTED:
   - DONE && !ABORTED: the pass completed. Flags such as ERROR[2] or [5] may still be set.
   - DONE && ABORTED: the pass was abandoned. BUSY is already low, and its output (m_* beats or the act_buffer tile) is invalid.
   - !BUSY && !DONE && ERROR[7] after START: START was rejected. If ERR_DETAIL[12] is set, the stored layer does not match.
2. After an abort, no SOFT_RESET is needed:
   - W1C DONE, ERROR and ERR_DETAIL;
   - fix the cause;
   - run START again, or COMMIT+START.

   The act_buffer completed-tile mask survives, so only the aborted tile has to be redone. ABORTED is cleared by the DONE W1C or by the next START.
3. DMA:
   - after TLAST early (ERROR[4]), the MM2S transfer has already ended;
   - after TLAST late (ERROR[5]), the DMA still holds the rest of its frame, and s_ready stays low for it. Reset or drain the MM2S channel before the next START, or those beats become the start of the next frame;
   - after an abort with `dst_sel=1`, the S2MM transfer has no `m_last`. Reset that channel.
4. Start the MM2S/S2MM DMA within 2^WDOG_W cycles of START, and do not stall `m_ready` that long (655 µs at the default).
5. `src_sel=1` needs one of:
   - `in_h/in_w` equal to the stored plane and `c_phys = 8*tiles`;
   - 1x1 input with `c_phys = 8*tiles*h*w`.

   The s_* frame size `in_h*in_w*c_phys` must be a multiple of 8.
6. START+LAYER_SWAP in one CONTROL write is supported. The check sees the layer brought in by the swap.

## Verification

### Regression

`python sim/run_tests.py` from systolic-array-8x8/, final RTL:
```
16/16 passed
```
tb_accel_top: `PASS tb_accel_top: 6 bit-exact frames of 784 beats`. Before the change, the baseline in this tree was also 16/16.

New tb_accel_top cases (WDOG_W=10):
- **Frames 2/3** now also require ERR_DETAIL=0 and ABORTED=0.
- **TLAST early.** s_last on beat 200 of 384. The prefix of the output is checked bit-exact. Then STATUS shows !BUSY, DONE and ABORTED; ERROR=0x10, ERR_DETAIL=0x2000; FRAME_COUNT is unchanged. A DONE W1C clears ABORTED. COMMIT+START with no SOFT_RESET then gives an exact frame, with ERROR and DETAIL 0.
- **TLAST late.** A 384-beat frame without s_last, followed by an extra beat (with s_last) held valid until after the pass. The frame is exact; ERROR=0x20, ERR_DETAIL=0x4000; not aborted. The extra beat is taken 0 times.
- **Watchdog.** START with no source beat. At 900 cycles: BUSY, no error. At 1200 cycles: aborted, ERROR=0x40, ERR_DETAIL=0x8000. START alone then gives an exact frame.
- **START rejects.** Each gives !BUSY and no DONE:
  - non-integer frame (5x5x3 s_*): ERROR=0x80, DETAIL=0;
  - src_sel=1 before any swap: 0x80/0x1000.
- **Stored-layer cases.** 8x8x3 s_* → k5 → a 4x4 one-tile store, then LAYER_SWAP; rd_geom = 4/4/1 is checked.
  - Rejected with 0x80/0x1000: c_phys 16, in_w 5, and a flattened c_phys of 120.
  - Accepted and run to DONE with ERROR 0: a 4x4 c_phys-8 source (4 beats, one m_last) and a flattened 1x1 c_phys-128 source (1 beat).
- **SWAP+START in one write.** A 2x2 pooled store, then CONTROL=0x9 with a 2x2 source pass. It is accepted, runs 4 beats and completes.
- **FRAME_COUNT** reaches 10 (completed passes only).

### System smoke (`scratch/smoke`, `bash run_smoke.sh C:/grad-wt/c5/systolic-array-8x8/rtl`)

```
S1 PASS: conv1(2 tiles,pool)->swap->conv2(3 tiles,pool)->swap->conv3(4 tiles)->m_*, 576 words, errors=0
S2 PASS: two further STARTs, no COMMIT, conv3 tile 3 replayed exact twice, errors=0
S3 PASS: LAYER_CFG/LAYER_CFG2/TILE_CFG/W_BASE/DP_CFG written mid-pass, pass exact, errors=0
S4 bad pass: STATUS=0000002d ERROR=80 ERR_DETAIL=0200
S4 PASS: overflow pass -> abort (DONE+ERROR[7]+ABORTED, ERR_DETAIL[9]), no SOFT_RESET -> COMMIT+START exact, errors=0
SMOKE PASS: errors=0 FRAME_COUNT=13 act_buffer swaps=2
```

**How S4 changed.** Lane C's S4 expected BUSY+ERROR with no DONE after the overflow pass, then recovered with SOFT_RESET. With the abort the expectation is:
- STATUS = 0x2d (IDLE, DONE, ERROR, ABORTED), ERROR = 0x80, ERR_DETAIL = 0x0200;
- the feeder is stopped, because s_ready has closed;
- DONE, ERROR and DETAIL are cleared with W1C, with no SOFT_RESET;
- the conv3 tile-0 COMMIT+START from act_buffer is exact, which also shows that act_buffer memory survives the abort.

FRAME_COUNT is 13 instead of 1 because no SOFT_RESET clears the counters any more: 9 + 2 + 1 + 1 completed passes.

**The unchanged lane C smoke on this RTL** (`scratch/smoke_orig`): S1-S3 PASS. S4 fails only on the old expectations:
- `S4 bad pass STATUS=0000002d (want BUSY+ERROR)`;
- `S4 good pass: beats=0/144`. Its `wait_pass` saw the stale DONE of the aborted pass, which that tb never cleared, and returned before the good pass ran.

### Mutations (`scratch/mut/mut.py`, tb_accel_top, each alone, file restored byte-exact)

| ID | Mechanism | Mutation | Result |
| --- | --- | --- | --- |
| MA | abort | abort no longer resets the datapath (`dp_rst_n` without `!abort_q`) | CAUGHT: `conv1_top: error_flags raised 20` assertions, the next frame fails |
| MG | geometry check | drop `c_phys == 8*tiles` from the plane branch | CAUGHT: `source c_phys 16 vs 1 tile: STATUS=00000002 ERROR=00`, … |
| MTE | TLAST early | `tlast_early = 0` | CAUGHT: `TLAST early abort: STATUS=00000002 ERROR=00 ERR_DETAIL=0000` |
| MTL | TLAST late | `tlast_late = 0` | CAUGHT: `TLAST late flag: STATUS=00000005 ERROR=00 ERR_DETAIL=0000` |
| MTX | extra beats refused | `src_open` not closed on the last expected beat | **SURVIVED** (see open question 1) |
| MW | watchdog | handshakes do not restart the counter | CAUGHT: aborts mid-frame, `global timeout` |
| MW0 | watchdog | never fires | CAUGHT: `watchdog abort: STATUS=00000002 ERROR=00 ERR_DETAIL=0000` |
| MS | register slice | `conv_m_ready = 1` | CAUGHT: `output 4 = … expected …` |
| MS2 | register slice | main register never takes the skid entry | CAUGHT: `output 3 = … expected …` |
| MSW | START settle | decide at `start_p[0]` | CAUGHT: `SWAP+START one write: STATUS=00000009 ERROR=80 ERR_DETAIL=1000` |

### Synthesis (`vivado/check_synth_accel.tcl`, run from `scratch/synth/`)

```
ACCEL_SYNTH: WNS=1.595 ns LUT=8764 FF=6499 BRAM=48 DSP=88
PASS: accel_top synthesis margin
```

- **Utilization:** Slice LUTs 7871 (678 as memory), Slice Registers 6499, Block RAM 48 (RAMB36), DSP 88. The baseline was 7612 / 6192 / 48 / 86. The two extra DSPs are the `frame_bytes_q` and `rd_flat_q` products.
- **Worst path:** `u_regs/active_layer_cfg_reg[26]` → `row_bytes_reg` DSP, the unchanged COMMIT-time validator product. The baseline was +1.592.
- **Note:** the first synth attempt died before elaboration with `couldn't read file ".../scripts/rt/data/lib_core.tcl": no such file or directory`. The file exists and no other tool process was running; the rerun worked.

### Post-route (`scratch/impl/check_impl_accel.tcl`)

```
IMPL_WNS: 0.809
IMPL_WHS: 0.082
```

- **Utilization:** Slice LUTs 7677, Slice Registers 6499, RAMB36 48, RAMB18 0, DSP 88.
- **Baseline:** +0.477 / +0.038.
- **Setup:**
  - +0.809 and +0.848: `u_regs/active_layer_cfg_reg[17]` → `row_bytes_reg` DSP (COMMIT-time product);
  - +0.921: `u_conv1/u_engine/drain_col_reg[1]` → requant `s1_product` B port.

  The old requant → mask → pool `lane_max` path and the pool `s_ready` → requant CE path are no longer in the top 5.
- **Worst hold:** still `u_window/u_line_buffer/write_group_reg[0]` → line-buffer LUTRAM WADR, at +0.082. This is inside window_gen, outside L3's files.

## Open questions

1. **MTX survived.** After the frame's last byte, line_buffer's own `frame_done` already holds window_gen's `s_ready` low. In this datapath, `src_open` closing on the last beat is therefore a second guard that the tb cannot separate from the first. The TLAST-late flag itself is covered (MTL). The guard is still worth keeping: it does not rely on window_gen internals, and it keeps `src_rem` from wrapping.
2. **lockstep_error** (requant lockstep failure) stays a flag on ERROR[2], as the contract lists only overflow there. It indicates corrupted output; should it abort?
3. **FRAME_COUNT** counts completed passes only, and an aborted pass does not increment it. CYCLE_COUNT is carried across the abort's datapath reset.
4. **SOFT_RESET** still does not clear STATUS.ABORTED (L2 open question, unchanged). After an abort, ABORTED stays until a DONE W1C or the next START.
5. **pool2x2 cfg_error** is still reported as an abort at `go`, not as a START reject. That is what the contract asks; it could become a START reject later (the pool geometry is known at COMMIT).
6. **START latency** is 4 cycles longer than lane C's. This is negligible per pass, but the START cycle order in LANE-RAPOR-C is superseded by the table above.
7. **Watchdog** default 2^16 cycles (655 µs) assumes the PS starts the DMA promptly after START; a slower driver needs a larger `WDOG_W`.
