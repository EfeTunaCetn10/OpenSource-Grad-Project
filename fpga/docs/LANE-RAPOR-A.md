# LANE-RAPOR-A — act_buffer HWC read stream (faz4-datapath, lane A)

Branch `lane/a-actbuf`, worktree `C:\grad-wt\a4`, base `71663f1`. Contract: `C:\codex-ctx\2026-11-06\faz4-kontrat.md` §2, §3, §7.

## Files

| File | Change |
| --- | --- |
| `systolic-array-8x8/rtl/act_buffer.sv` | Rewritten to the §3 interface (ports and widths as in the contract, `C_TILE_MAX` default 4 -> 16). |
| `systolic-array-8x8/tb/tb_act_buffer.sv` | Rewritten for the new interface, with an SV reference model of the HWC read order. |
| `scratch/check_synth_actbuf.tcl` | Scratch OOC synthesis script (not committed). |

Nothing else instantiates `act_buffer`, so lane C does the rewiring as planned.

## Design

- **Storage** is unchanged and tile-major: `mem[tile*plane + row*w + col]`. There are two banks of `DEPTH x 64`. Each bank is a one-dimensional array inside `g_buffer` with `(* ram_style = "block" *)` and a synchronous read.
- **Write pass** takes 3 cycles of setup, with `wr_ready=0` throughout:
  1. The `wr_start` cycle latches tile and tiles, registers `plane = h*w` from the ports and registers the configuration check.
  2. `W_BASE` registers `base = tile*plane` and `foot = tiles*plane`.
  3. `W_CHECK` either goes to an error state, or sets `wr_ptr = base` and `wr_end = base+plane-1`.

  After that, `W_RUN` accepts one word per handshake to `wr_ptr++`. `wr_done` pulses in the cycle after the h\*w-th word, and the side is idle again in that same cycle. The per-beat path is an increment and a compare.
- **Read order (K1 fix):** `for pixel, for t: mem[t*plane + pixel]`. This uses a pixel pointer `rd_pix`, a tile counter `rd_t` and an address `rd_addr`:
  - On a tile step the address is `rd_addr + rd_plane`.
  - On a pixel step the address is `rd_pix + 1`.

  There is no per-beat multiply, divide or `%`. `rd_last` comes with the word where `pix == plane-1 && t == tiles-1`.
- **Latency hiding:** words land one cycle after issue in a 3-entry register FIFO (circular buffer). A new read is issued while `fifo_count + in_flight < 3`. That condition uses registers only, so `rd_ready` never reaches the BRAM enable or address path, and the stream still runs at full rate with `rd_ready=1`. `rd_data` is a 3:1 mux of registers.
- **Swap:** accepted when both sides are idle and there is no `wr_start`/`rd_start` in the same cycle. It flips `buf_sel`, increments `frame_count` and copies the plane and tiles of the last *completed* write pass to the read side. `rd_busy` covers issue, the word in flight and the FIFO, so it falls with the `rd_last` handshake.

## Error mapping

| Condition | Flag | Effect |
| --- | --- | --- |
| `wr_start` while the write side is busy | seq_error | ignored; the running pass continues |
| `rd_start` while the read side is busy | seq_error | ignored; the read is not restarted |
| `rd_start` with no written layer swapped in | seq_error | nothing starts |
| `layer_swap` while either side is busy, or in the same cycle as `wr_start`/`rd_start` | seq_error | no swap |
| `wr_start` with h or w equal to 0 or above max, tiles 0 or above `C_TILE_MAX`, or tile >= tiles | seq_error | nothing written; write side back to idle |
| `wr_start` with layer footprint `tiles*h*w > DEPTH` | ovf_error | nothing written; write side back to idle |

If a configuration is both malformed and over capacity, only seq_error is set. The flags are sticky until `soft_reset` or `rst_n`, and they never block later commands.

`soft_reset` returns both FSMs to idle, flushes the in-flight word and the FIFO, and clears both flags. It keeps memory, `buf_sel`, `frame_count`, the stored read and write geometry and the "layer present" bits, so the layer can be replayed after a `soft_reset`. The TB verifies this.

## Verification

`tb_act_buffer` builds its reference from two independent views:
- **Producer view:** byte lane r of the tile-t word at (h,w) is `val(layer, 8t+r, h, w)`.
- **Expected stream:** built from the byte-level HWC definition `hwc[(h*W+w)*8T + c]` and cut into 64-bit words.

The two views share only `val()`. A scoreboard checks every read handshake in order, including `rd_last`. It also checks AXI-stream stability: a word held under backpressure must not change.

Covered:
- L0 is 5x7 with 3 tiles, written in tile order 0,2,1, then swapped and replayed 3 times.
- The cfg inputs are scrambled immediately after `wr_start`.
- `wr_valid` and `rd_ready` are paced by an LFSR (no seeded `$urandom`), at about 50% and about 25%.
- L1 (3x3, 4 tiles, order 3,1,0,2) is written while L0 is read. L2 (6x4, 1 tile) is written while L1 is read.
- L3 is 48x48 with 2 tiles, which fills DEPTH=4608 exactly. It is read at `rd_ready=1`.
- Busy commands:
  - with both sides busy: a swap, an extra `wr_start` and an extra `rd_start`;
  - a swap with only the read side busy;
  - a swap with only the write side busy.
- All six configuration errors listed above. `tiles=C_TILE_MAX` is accepted.
- `soft_reset` in the middle of a read, then a full replay.
- `soft_reset` in the middle of a write, then a full layer.
- The `wr_done` pulse count matches the number of passes.

The old vectors (`model/gen_act_buffer_vectors.py`, `act_buffer_ref.py`, `actbuf_frame*.mem`) are no longer read by the TB. `run_tests.py` still generates them, and that is harmless. The orchestrator-owned files were not edited.

**Throughput (measured, `rd_ready=1`):** one word per cycle with no bubbles.
- 105/105, 24/24, 4608/4608 and 12/12 words/cycles.
- 3 cycles from the `rd_start` cycle to the first handshake.

On the write side, `wr_ready` rises 3 cycles after `wr_start`, and after that one word per cycle is accepted while `wr_valid=1`. This comes from reading the RTL, not from a measurement: the TB only checks that `wr_ready` is low in the setup cycle.

**Regression** (`python sim/run_tests.py` from `systolic-array-8x8/`, final RTL):
```
16/16 passed
```
(all 16 tests listed PASS; tb_act_buffer PASS line:
`PASS: act_buffer HWC read of 6 layers, 15 write passes, replay, concurrent write, LFSR backpressure, errors, soft_reset`)

**Mutations** (each one applied alone with sed, `tb_act_buffer` rerun, then the RTL restored):

| Mutation | Result |
| --- | --- |
| M1: tile step `rd_addr + rd_plane` -> `rd_addr + 1` (wrong byte order, the K1 class) | FAIL: `read word 1 got 2e06deb68e663e16 expected 300be6c19c77522d`. Rerun on the final RTL. |
| M2: footprint check `>` -> `>=` | FAIL: `write pass L3 t1 stalled after 0 words` |
| M3: FIFO credit `< 3` -> `< 4` | FAIL: `read beat changed under backpressure` and word mismatches |
| M4: swap ignores `rd_busy` | FAIL: `layer_swap while read side busy not rejected`. This mutation survived the first TB version, which only tried a swap with both sides busy; read-only-busy and write-only-busy swap checks were added after that. Rerun on the final RTL. |
| M5: `base` uses the live `cfg_wr_tile` instead of the sampled one | FAIL: read words were X |
| M6: swap ignores `wr_busy` | FAIL: `layer_swap while write side busy not rejected` |

M2, M3, M5 and M6 ran on the RTL from before the last one-line change (`rd_last` is now qualified with `rd_valid`). M1 and M4 were rerun on the final RTL.

**OOC synthesis** of `act_buffer` alone (xc7z020clg400-1, `vivado/constraints.xdc` with a 10 ns clock, final RTL):
```
ACTBUF_SYNTH: WNS=4.960 ns LUT=331 FF=399 RAMB36=32 RAMB18=0 DSP=4
```
- `LUT=331` counts LUT cells. The utilization report gives 268 LUT as Logic.
- RAMB36 is 16 per bank, as expected.
- The critical path is DSP to DSP in the write setup (`wr_plane` to `wr_base`, 0 logic levels). It is not a per-beat path.

## Decisions and contract issues

1. **The overflow check is stricter than the contract text.** The contract says `base+h*w > DEPTH`. I check the whole layer footprint `tiles*h*w > DEPTH`. Since tile < tiles, this catches everything the literal check would catch. It also rejects a pass whose own words would fit but whose layer could never be read back without addressing past DEPTH.
2. **A rejected `wr_start` leaves `wr_ready` low.** The producer (conv/requant/pool) therefore stalls, and the pass never completes. **Lane C:** route seq_error and ovf_error into ERROR so the PS sees them, because DONE will not come. Recovery is `soft_reset`.
3. **`layer_swap` in the same cycle as `wr_start` or `rd_start`** is rejected with seq_error, and the start proceeds. The contract does not cover this case.
4. **Swap without a new completed write since the previous swap** is accepted, as the contract says. The read side then gets the stale bank with the last written geometry. Only "no write pass ever completed" is caught, at `rd_start`. There is also no check that all T tiles of a layer were written before the swap. This is open for the orchestrator: should a swap with no new write be a seq_error?
5. **Read geometry is captured when a pass completes** (at `wr_done`), not when `wr_start` is accepted. So a pass that `soft_reset` aborts does not change it.
6. **`rd_data` is meaningless and `rd_last` is 0 while `rd_valid=0`.** Lane C must qualify both with `rd_valid`.
7. **DSP use:** Vivado maps the three setup multiplies to 4 DSP48E1. If the DSP budget is tight in `accel_top`, `(* use_dsp = "no" *)` would move them to LUTs. The multiplies run in setup only, so timing is not a concern. I did not apply this.
