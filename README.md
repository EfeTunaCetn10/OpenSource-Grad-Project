# PYNQ-Z2 CNN Accelerator

A PYNQ-Z2 FPGA accelerator project using a LeNet-style CNN for 32×32 RGB insect
classification across 10 labels. **The candidate INT8 Python pipeline is complete
through full validation and canonical test-vector export. No RTL implementation
is available; cocotb/RTL bit-exact verification has not started.**

## Current validated status

This is the authoritative project status summary (2026-10-02). Component reports
retain implementation details and explicitly labelled historical results.

**Selected FP32 checkpoint → deterministic train-only calibration → candidate INT8
qparams → integer primitives → full integer forward → full validation → canonical
hardware test vectors → waiting for Person B's RTL/interface availability.**

The selected checkpoint is seed **42**, epoch **51**, recorded in
[selected_model.json](cnn_pipeline/docs/accuracy_improvement/selected_model.json).
Calibration uses 1,000 train images (100 per class), followed by activation and
per-output-channel weight statistics. Candidate model preparation validates source
provenance and accumulator safety for five weighted layers / 236 output channels.

### Validation evidence

The same **1,774 validation images** were evaluated through ordinary FP32 and the
candidate integer forward, with deterministic preprocessing and no tuning.

| Metric | Result |
|---|---:|
| FP32 top-1 accuracy | 55.4115% |
| Candidate INT8 top-1 accuracy | 54.6787% |
| INT8 − FP32 | −0.7328 percentage points |
| Prediction agreement | 95.6032% |
| Both correct | 952 |
| FP32 correct / INT8 wrong | 31 |
| FP32 wrong / INT8 correct | 18 |
| Both wrong | 773 |
| Input clipping | 0 / 5,449,728 elements |

Baseline accuracy is modest and class-wise performance is uneven. Quantization
introduces a small global accuracy drop, but this does not imply small changes
for every class. Agreement is diagnostic; accuracy against labels is the quality
measure. +127 boundary hits occurred and are **not proof of clipping**; true
internal clamp counts are unavailable. See the [validation report](cnn_pipeline/docs/validation_comparison/README.md)
for per-class metrics, stage counters and runtime. The saved full-run artifact is
[report.json](cnn_pipeline/outputs/validation_comparison/seed42_full_run01/report.json)
(local, excluded from Git). Historical test-split results are separate from this
validation comparison.

### Locked arithmetic, candidate policy and proposed interfaces

- Current ADR-003 arithmetic: signed INT32 MAC/bias wrap modulo 2^32; signed64
  requantization, n=0…63 (zero offset at n=0), half-up ties toward +∞; final clamp
  [0,127] with ReLU or [-128,127] without it. Configuration errors remain rejected.
- Candidate software policy: symmetric float quantization with zero-point 0,
  [-127,127] and absmax/127; candidate bias rounding and multiplier selection are
  not newly approved RTL production policies. Multiplier search remains n=1…49,
  distinct from the requant arithmetic domain.
- Canonical mathematical activations remain **CHW**, Conv weights [out,in,kH,kW],
  Linear weights [out,in], and Flatten c→h→w. **FC3 returns signed INT8 logits.**
- Proposed ADR-014/015/016 interfaces, timing/register behavior, HWC transport,
  packing, FC1 permutation and FC3 INT32 bypass are not authoritative golden
  behavior. Canonical vectors do not implement those proposals or physical banking.

See [contract synchronization](cnn_pipeline/docs/contract_sync/README.md) for the
arithmetic changes and their distinction from proposed hardware interfaces.

### What is complete / What remains

**Complete:** provenance-checked candidate parameter preparation, integer
Conv/Linear/bias/requant/Pool/Flatten composition, full LeNet forward, validation,
and [canonical JSON test vectors](cnn_pipeline/docs/hardware_test_vectors/README.md).
One deterministic train debug sample was exported with all nine expected stages,
five parameter sets, 26 requant corner cases and small synthetic MAC/Linear/Conv
vectors. This debug sample is not an accuracy evaluation.

The most recent recorded regression is **555 passed**, after test-vector export
(focused export/forward tests: **27 passed**). These are prior execution results;
this documentation update did not rerun tests or validation.

**Next dependency:** Person B must provide RTL and its usable interface definition.
Then interface adapters and cocotb tests can consume the canonical vectors, compare
primitive and intermediate results, and investigate mismatches. RTL equivalence,
hardware packing/export, AXI/DMA integration, FPGA execution and hardware
performance measurements remain future work; none is established by Python tests.

## Guides and repository

- [CNN pipeline guide](cnn_pipeline/README.md): environment, data and historical training commands.
- [Candidate parameters](cnn_pipeline/docs/candidate_integer_model/README.md) and
  [full forward](cnn_pipeline/docs/candidate_integer_forward/README.md): current Python APIs.
- [Validation comparison](cnn_pipeline/docs/validation_comparison/README.md) and
  [test-vector export](cnn_pipeline/docs/hardware_test_vectors/README.md): evidence and schemas.
- [Kontratlar/](Kontratlar/): architecture decisions, interface proposals and roadmap;
  each document's acceptance status matters.

The network has two 5×5 Conv/ReLU/2×2 MaxPool stages and three Linear layers.
Raw images, checkpoint binaries and generated outputs remain local and excluded
from Git; documentation and source identities are versioned.
