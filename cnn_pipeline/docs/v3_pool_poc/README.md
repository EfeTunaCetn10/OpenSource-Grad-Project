# Shared INT8 MaxPool2D RTL POC

One `fpga/rtl/maxpool2d_int8.sv` serves all three candidate v3 pooling stages.
It selects the signed maximum of each 2×2 window, with stride 2 and no padding,
scale change, bias, rounding or requantization. No contracts or existing RTL
are changed. This is not full-network integration or v3 promotion.

## Interface and buffering

Parameters: `CHANNELS`, `HEIGHT`, `WIDTH`. Channels must be a positive multiple
of eight; H/W must be even and at least two. Unsupported geometries fail
elaboration. Partial channel planes are outside this bounded version.

Both streams are `[c_tile][H][W][8]`; lane zero occupies the low byte. For each
channel tile, pixels arrive row-major. On an even row, the block stores eight
horizontal maxima for each column pair. On the next row, it combines that stored
pair with the two current pixels and emits one eight-channel output beat.
It holds output stable during backpressure and stops accepting inputs as needed.
Channel/spatial order is preserved. Equal maxima return the same value; this
interface does not return argmax indices or define an index tie-break policy.

The row-pair store is `WIDTH/2 × 64 bits`: 128 / 64 / 32 bytes for Pool1/2/3,
independent of channel-tile count. It is reused across row pairs/tiles. Memory is
not reset; valid processing writes each pair before it is read, including after
restart. One left-pixel register, one read register and the output register are
additional storage. No full-frame buffer or repacker is needed.

POC `s_last`/`m_last` denote the **whole tensor**, not the end of a compute tile.
`done` becomes true after the last output is accepted. A `restart` is allowed
only when idle or done; a fresh complete tensor must then be supplied. Invalid
last placement/restart raises a sticky error, cleared by reset. This block is
not wired directly to Conv's per-compute-tile last markers: framing conversion
and inter-layer control remain future integration work, not an ADR change.

For positive shared scale and unchanged zero point, dequantization is monotonic:
selecting the maximum integer selects the maximum represented activation. The
export records equal input/output scales for each pooling stage; no new qparams
are calculated. Control counters use integer arithmetic, but the activation
path performs only signed comparisons and selection.

## Real fixtures and independent tests

`export_v3_pool_poc.py` verifies the existing PTQ/checkpoint/calibration/sample
identities through the existing exporter helper. Using the same real debug
validation image, it calls existing integer Conv/requant and scalar MaxPool
references to capture Conv1→Pool1, Conv2→Pool2 and Conv3→Pool3 fixtures. It does
not execute FC, evaluate accuracy, calibrate, or reselect parameters.

Files are isolated in
`cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_pool_poc/`:
`pool{1,2,3}_input.mem`, `pool{1,2,3}_expected.mem`, and `manifest.json`.
The manifest records source hashes, saved checkpoint identity, image provenance,
layout, shapes, scales and vector hashes. Existing output directories are refused.

| Stage | Input CHW | Output CHW | Output INT8 values / beats |
|---|---|---|---:|
| Pool1 | 16×32×32 | 16×16×16 | 4,096 / 512 |
| Pool2 | 24×16×16 | 24×8×8 | 1,536 / 192 |
| Pool3 | 32×8×8 | 32×4×4 | 512 / 64 |

`tb_v3_pool_poc` instantiates the same RTL three times. Each stage checks every
output under periodic and deterministic LFSR backpressure, with input gaps,
exact counts, complete-tensor last markers, ordering, completion and stalled
payload stability. Total real comparisons: **6,144 per pattern**, 12,288 over two.

`tb_maxpool2d_directed` uses 24×4×6 and minimum 8×2×2 geometries, changing contents
on replay. Independent formulas cover negative values, mixed signed extremes,
all-negative/all-127 ties, all four winning positions, c=7/8 and c=15/16,
first/last spatial windows and channel ordering. Eight cases have explicit
coverage checks. Python tests separately verify these scalar/packing properties
and overwrite refusal, along with existing exporter/oracle/pooling tests.

## Exact commands

From repository root (the export destination already exists; do not overwrite):

```sh
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B cnn_pipeline/export_v3_pool_poc.py --ptq-dir cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/ptq --output-dir cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_pool_poc

PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -q -p no:cacheprovider cnn_pipeline/tests/test_export_v3_pool_poc.py cnn_pipeline/tests/test_export_v3_conv1_poc.py cnn_pipeline/tests/test_export_v3_conv2_poc.py cnn_pipeline/tests/test_export_v3_conv3_poc.py cnn_pipeline/tests/test_integer_tensor_ops_ref.py cnn_pipeline/tests/test_experimental_v3_ptq.py

VIVADO_BIN=/home/cgj/Desktop/AMD/2025.2/Vivado/bin PYTHONDONTWRITEBYTECODE=1 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -c 'import sys;sys.path.insert(0,"fpga/sim");import run_tests;run_tests.BUILD=run_tests.PROJECT/"sim"/"build_v3_pool";sys.exit(run_tests.main())' tb_maxpool2d_directed tb_v3_pool_poc --keep --verbose

VIVADO_BIN=/home/cgj/Desktop/AMD/2025.2/Vivado/bin PYTHONDONTWRITEBYTECODE=1 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -c 'import sys;sys.path.insert(0,"fpga/sim");import run_tests;run_tests.BUILD=run_tests.PROJECT/"sim"/"build_v3_pool";sys.exit(run_tests.main())' --keep

git diff --check
```

Synthesis from `/tmp/v3_pool_synthesis_work`:

```sh
/home/cgj/Desktop/AMD/2025.2/Vivado/bin/vivado -mode batch -source /home/cgj/Desktop/OpenSource-Grad-Project/fpga/vivado/check_synth_v3_pool.tcl -tclargs /home/cgj/Desktop/OpenSource-Grad-Project/cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/rtl_pool_poc/synthesis
```

## Remaining integration gates

FC1 requires validating the 32×4×4 Pool3 tensor's tile-major→CHW flatten/weight
ordering, K=512 execution and its configuration interface. FC2 requires a
64→10 real layer gate, tail-lane handling and the existing signed INT8 logits
semantics. Full chaining still needs activation-buffer ownership/replay,
per-layer parameter loading, frame/tile completion conversion and sequencing.
No FC, full-network sequencer, AXI DMA, board flow or contract promotion is
implemented by this POC.

## Measured result — 2026-10-17

**PASS for the bounded pooling gate.** Vivado/XSim 2025.2:

- Focused tests: **2/2 passed**.
- Full RTL regression: **22/22 passed**, including all 20 pre-existing tests.
- Relevant Python tests: **157 passed** (13 new + 144 existing).
- Real fixtures: Pool1 **4,096/4,096**, Pool2 **1,536/1,536**, Pool3 **512/512**
  bit-exact under each of two stall patterns. Signed/tie/four-position/boundary
  directed cases passed. No missing/extra output, ordering or completion errors.
- Scales preserved exactly: Pool1 `0.032354568871926136`, Pool2
  `0.06064476178387019`, Pool3 `0.11131243067463552`; zero point remains zero.

Representative Pool1 OOC post-synthesis result, xc7z020clg400-1:

| Measurement | Value |
|---|---:|
| Target clock | 100 MHz |
| Slice LUTs | 310 |
| Logic LUTs / distributed RAM LUTs | 246 / 64 |
| FFs | 209 |
| RAMB36 / RAMB18 | 0 / 0 |
| DSPs | 0 |
| Setup WNS | +3.948 ns |

The raw logic-LUT primitive count in `summary.txt` (285) is not the resource
utilization; the utilization report gives 310 total Slice LUTs including memory.
No place-and-route or board timing was performed. Clock-only OOC constraints
have no unconstrained internal endpoints but omit external delays on 69 input
and 69 output ports. The other two geometries were simulated, not separately
synthesized; the table is specifically C16/H32/W32.

Vector hashes, source preservation and scale equality were checked.
`verification/results.json` and logs accompany the new fixture directory;
`synthesis/` contains reports. The temporary build is removed after saving logs.
All pre-existing files were preserved. No training, PTQ rerun, promotion,
contract edit or Git write operation occurred. `git diff --check` passed.
