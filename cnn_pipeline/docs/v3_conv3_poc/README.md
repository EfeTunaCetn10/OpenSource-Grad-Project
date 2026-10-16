# Conv3 and reusable tile-major repacker feasibility gate

This bounded gate shares one repacking implementation between the already
validated Conv2 geometry and Conv3. It does not promote v3, implement pooling RTL,
FC, network sequencing, AXI DMA or board flow. Numerical parameters and frozen
model artifacts remain unchanged.

## Generalization decision

The previous full-frame buffer/handshake design is reusable, but its two-plane
address bit permutation is not valid for three input planes. The shared
`fpga/rtl/tile_major_repack.sv` instead tracks a pixel and a channel-tile counter:

```
physical_word_address = channel_tile * (HEIGHT * WIDTH) + pixel
internal_dense_order  = pixel, then channel_tile, then lane
```

The tile counter advances first; after the last tile, it resets and the pixel
counter advances. Constant multiplication sets the physical address; no runtime
divider/modulo or power-of-two plane assumption is needed. Counters have minimum
width one, including the single-word case. Channels must be a positive multiple
of eight and H/W must be positive; unsupported geometry fails elaboration.
Partial channel planes are not silently assigned a padding policy.

The block retains full-frame buffering, a synchronous 64-bit RAM read, held
output under backpressure, last-beat checks, sticky error reporting and complete
reload after restart. It does not clear RAM; all locations must be overwritten
before the next drain begins. The external layout remains `[c_tile][H][W][8]`,
with lane zero in the low byte. Dense HWC exists only inside the adapter-to-line-
buffer connection; it is not a contract change.

| Geometry | Planes | Pixels | Words / logical buffer bytes |
|---|---:|---:|---:|
| Conv2: Cin16, 16×16 | 2 | 256 | 512 / 4,096 |
| Conv3: Cin24, 8×8 | 3 | 64 | 192 / 1,536 |

`v3_conv2_repack.sv` is now a thin compatibility wrapper around the shared block.
The existing Conv2 top/testbenches and vectors are retained. Its synthesis script
adds the shared source dependency. `v3_conv3_poc_top.sv` instantiates the same
block at 24×8×8 and the existing `conv1_top` at K=216, 3×3, padding=1. No MAC,
requantization, window-generator or line-buffer implementation is duplicated
or modified. Output-channel passes and input replay remain testbench-driven.

This is a local generalization of the staging adapter, not the final shared
activation-memory architecture. Full-frame buffering and reload per output tile
still have storage/latency costs.

## Real oracle fixture

`export_v3_conv3_poc.py` reuses saved-artifact provenance validation and existing
integer arithmetic. It computes software Conv1/Pool1 and Conv2/Pool2 from the
same real debug image, then Conv3 MAC, bias-added and requantized expected values.
It reuses the existing integer MaxPool primitive; no new pooling implementation
or RTL pooling is added. No calibration or parameter search runs.

Outputs are isolated at
`cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_conv3_poc/`:

- `frame.mem`: 192 tile-major Pool2 beats; `pool2_chw.mem`: 1,536 logical values.
- `weights_oihw.mem`, eight `wbank*.mem` files: existing Conv3 weights; each bank
  has 864 bytes, address `output_tile*216 + ci*9 + kh*3 + kw`.
- `bias_q.mem`, `M0.mem`, `n.mem`: the existing 32 channel parameters.
- `t0_*` through `t3_*`: MAC, bias-added INT32 and packed INT8 expected outputs.
- `manifest.json`: checkpoint/source/sample hashes, parameters, scales, shapes,
  layout and all vector hashes. Existing directories cannot be overwritten.

## Tests

- Existing Conv2 reader and real-output regressions run through the shared block.
- `tb_tile_major_repack`: one-word/one-plane, three-plane 3×5, and four-plane 2×3
  geometries, two different frames each, with stalls. Covers non-power-of-two
  spatial dimensions and plane counts plus minimum counter widths.
- `tb_v3_conv3_reader`: every repacked beat and every padded window byte against
  independent coordinate calculations. Each pattern checks 192 repacked beats,
  13,824 window bytes, including 1,152 at c=7/8 and 1,152 at c=15/16. All corners,
  edges and center are covered. A changed second input checks stale-buffer reuse.
- `tb_v3_conv3_poc`: every real MAC, actual requantizer bias-adder value and final
  INT8 value for all channels 0–31. Each of two deterministic backpressure patterns
  checks 2,048 values at each level, 256 output beats and all four channel tiles.
  Counts, ordering, metadata, errors, stalled payload stability and completion
  are checked with no tolerance. Padding must complete without deadlock.
- Python tests check three-plane serialization, both channel boundaries,
  deterministic non-mutating behavior, a hand-computable Pool2 fixture and
  overwrite refusal, plus the existing exporter/oracle/pooling tests.

An initial new Conv3 testbench run pointed at the old Conv2 vector directory and
correctly failed its scoreboards. The path was corrected before the reported
passing run; no RTL or oracle arithmetic was changed to mask the failure.

## Exact commands

Run from repository root. The generated directory already exists; do not export
over it again.

```sh
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B cnn_pipeline/export_v3_conv3_poc.py --ptq-dir cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/ptq --output-dir cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_conv3_poc

PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -q -p no:cacheprovider cnn_pipeline/tests/test_export_v3_conv3_poc.py cnn_pipeline/tests/test_export_v3_conv2_poc.py cnn_pipeline/tests/test_export_v3_conv1_poc.py cnn_pipeline/tests/test_experimental_v3_ptq.py cnn_pipeline/tests/test_integer_tensor_ops_ref.py

VIVADO_BIN=/home/cgj/Desktop/AMD/2025.2/Vivado/bin PYTHONDONTWRITEBYTECODE=1 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -c 'import sys; sys.path.insert(0,"fpga/sim"); import run_tests; run_tests.BUILD=run_tests.PROJECT/"sim"/"build_v3_conv3"; sys.exit(run_tests.main())' tb_tile_major_repack tb_v3_conv2_reader tb_v3_conv2_poc tb_v3_conv3_reader tb_v3_conv3_poc --keep --verbose

VIVADO_BIN=/home/cgj/Desktop/AMD/2025.2/Vivado/bin PYTHONDONTWRITEBYTECODE=1 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -c 'import sys; sys.path.insert(0,"fpga/sim"); import run_tests; run_tests.BUILD=run_tests.PROJECT/"sim"/"build_v3_conv3"; sys.exit(run_tests.main())' --keep

git diff --check
```

Synthesis commands (from `/tmp/v3_conv3_synthesis_work` and
`/tmp/v3_conv2_generic_synthesis_work`, respectively), both using new report
folders under this gate so prior Conv2 measurements are preserved:

```sh
/home/cgj/Desktop/AMD/2025.2/Vivado/bin/vivado -mode batch -source /home/cgj/Desktop/OpenSource-Grad-Project/fpga/vivado/check_synth_v3_conv3.tcl -tclargs /home/cgj/Desktop/OpenSource-Grad-Project/cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_conv3_poc/synthesis_conv3

/home/cgj/Desktop/AMD/2025.2/Vivado/bin/vivado -mode batch -source /home/cgj/Desktop/OpenSource-Grad-Project/fpga/vivado/check_synth_v3_conv2.tcl -tclargs /home/cgj/Desktop/OpenSource-Grad-Project/cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_conv3_poc/synthesis_conv2_generic
```
