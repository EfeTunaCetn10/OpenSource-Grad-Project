Implemented the tile sequencer and self-checking verification in exactly the two requested files:

- [layer_ctrl.sv](C:/grad-lc/systolic-array-8x8/rtl/layer_ctrl.sv)
- [tb_layer_ctrl.sv](C:/grad-lc/systolic-array-8x8/tb/tb_layer_ctrl.sv)

### Handshake scheme

The controller stalls the first tile beat with `w_ready=0`, captures its `w_active_cols`, and independently launches the engine and feeder. The activation gate opens only after:

1. `eng_start` was accepted,
2. the engine’s CLEAR cycle completed, and
3. `wf_start` was accepted.

Once open, activation data is pass-through and acceptance requires both `w_ready` and the engine’s coupled activation handshake. The gate closes on the Kth accepted beat and remains closed through FLUSH/DRAIN. This preserves k=0, prevents cross-tile routing, and permits only one tile in flight.

Configuration errors terminate the current frame and return the controller to idle rather than leaving `busy` deadlocked.

### Verification

The new test uses the real `compute_engine` and a behavioral feeder. It covers:

- Consecutive K=75 tiles with `active_cols` 8 then 4
- Exact activation, weight, and drain-beat counts
- Full-rate feeding
- Generator valid gaps
- Weight starvation lasting 1, 2, and 7 cycles
- Twelve-cycle output backpressure during DRAIN
- Delayed engine command readiness
- Every defined error bit 0–6, stickiness, and reserved bit 7
- Engine/feeder configuration-error recovery

Final command and result:

```text
python sim/run_tests.py

  tb_axi_lite_regs        PASS
  tb_compute_engine       PASS
  tb_layer_ctrl           PASS
  tb_pe_os                PASS
  tb_requant_array        PASS
  tb_requant_unit_num     PASS
  tb_requant_unit_timing  PASS
  tb_window_gen           PASS

8/8 passed
```

### Mutation results

| Mutation | Result |
|---|---|
| Activation gate opened during CLEAR | Caught |
| `active_cols` captured as first-beat value + 1 | Caught |
| `eng_start` ignored `eng_start_ready` | Caught |
| Tile counter incremented by 2 | Caught |
| `error_flags[4]` made non-sticky | Caught |

No surviving mutants.

### Assumptions and observations

- Bit 6 is interpreted as `w_done` arriving before the K-beat feed finishes. Existing `window_gen` normally raises `done` after its final beat but while the engine is still flushing/draining; flagging that normal interval would make every valid frame erroneous.
- Bit 2 is reachable through a deliberately faulty/substituted engine claiming readiness while the controller gate is closed. The real engine structurally prevents this condition.
- Stage 1 keeps one configured output-channel tile; the Stage 2 activation-replay hook is documented without adding a rewind interface.
- Existing `window_gen` remains permanently in `ST_DONE`, so another frame requires its reset/restart at integration level.
- Later STA should inspect the activation valid/ready pass-through path between `layer_ctrl` and `compute_engine`; tile metadata and command geometry are registered before launch.