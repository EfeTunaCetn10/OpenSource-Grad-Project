Implemented exactly the two requested files:

- [weight_feeder.sv](C:/grad-wf/systolic-array-8x8/rtl/weight_feeder.sv)
- [tb_weight_feeder.sv](C:/grad-wf/systolic-array-8x8/tb/tb_weight_feeder.sv)

Read-latency scheme: synchronous BRAM output register feeding a two-entry elastic FIFO. The BRAM output holds when the FIFO is blocked; simultaneous FIFO pop, transfer, and next read sustains one beat per cycle without loss or duplication.

Regression result:

```text
tb_axi_lite_regs        PASS
tb_compute_engine       PASS
tb_pe_os                PASS
tb_requant_array        PASS
tb_requant_unit_num     PASS
tb_requant_unit_timing  PASS
tb_weight_feeder        PASS
tb_window_gen           PASS

8/8 passed
```

Mutation results:

| Mutation | Result |
|---|---|
| Last-beat counter off by one | Caught — timeout |
| Base address without tile offset | Caught — byte mismatches |
| `weight_valid` dropped during backpressure | Caught — stability/data failures |
| Prefetch capacity changed from 2 to 3 | Caught — overwrite and SVA failure |
| Banks rotated by one lane | Caught — lane-by-lane mismatches |

Assumptions:

- Weight memories are initialized before commands begin and are read-only during streaming.
- `start` obeys the contracted ready/start handshake.
- An encoded `tile_idx` outside `TILE_MAX` is not a separate error condition; address overflow remains guarded as specified.
- `cfg_error` is a one-cycle pulse and rejected commands remain idle.

Later synthesis/STA should confirm BRAM inference for the two-dimensional bank array and examine the command-only multiply-plus-overflow comparison. The streaming address path itself is registered.

Existing-code finding: [line_buffer.sv](C:/grad-wf/systolic-array-8x8/rtl/line_buffer.sv) reads its `ram_style="block"` memory combinationally. Xilinx block RAM normally requires synchronous reads, so that array may infer LUT/distributed storage despite its attribute.

The runner’s generated vector cache was removed afterward; it is reproducible automatically. Final `git status` shows only the two requested new files.