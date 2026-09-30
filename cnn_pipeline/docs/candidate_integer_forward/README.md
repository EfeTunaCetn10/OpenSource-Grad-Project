# Candidate full INT8 LeNet forward — CHW

`candidate_integer_forward.py` connects existing verified integer components.
It is candidate software inference, not FPGA/RTL equivalence or hardware export.

```python
from candidate_integer_model import load_candidate_integer_model
from candidate_integer_forward import candidate_integer_forward
prepared = load_candidate_integer_model(qparams_path)
logits = candidate_integer_forward(normalized_cpu_float32_chw_image, prepared)
logits, diagnostic = candidate_integer_forward(
    normalized_cpu_float32_chw_image, prepared, trace=True)
```

Input must be finite CPU float32 [3,32,32], already RGB/resize/normalized. No batch
axis or implicit preprocessing is accepted. Load once through the existing
provenance-checked loader; the forward function neither reads checkpoint/qparams
nor repeats parameter preparation. Synthetic inputs may use the pure preparation
API. Prepared packages are assumed to come from that validated API, not arbitrary
untrusted mappings; topology/ReLU and consecutive scale metadata are checked too.

The default result is a new list of 10 built-in Python ints in [-128,127].
Inputs/prepared tensors and lists are not modified. There is no full-network
PyTorch Conv/Linear execution, quantized backend, HWC packing, FC1 permutation,
FC3 bypass, AXI, register protocol or timing implementation.

## Exact topology and smoke trace

Input quantization reuses `quantize_int8` and its scale: symmetric zero-point 0,
[-127,127], existing half-up rounding. Conv/FC use integer_layer_ref, with locked
INT32 wrap and signed64 requant; pool/flatten use integer_tensor_ops_ref.

| Stage | Shape | Smoke min…max | Scale observation |
|---|---|---|---|
| Quantized input | [3,32,32] | -75…22 | input |
| Conv1 + requant/ReLU | [6,28,28] | 0…121 | features.1 |
| MaxPool 2×2/2 | [6,14,14] | 0…121 | features.1 |
| Conv2 + requant/ReLU | [16,10,10] | 0…65 | features.4 |
| MaxPool 2×2/2 | [16,5,5] | 0…65 | features.4 |
| CHW Flatten | [400] | 0…65 | features.4 |
| FC1 + requant/ReLU | [120] | 0…109 | classifier.2 |
| FC2 + requant/ReLU | [84] | 0…91 | classifier.4 |
| FC3 + requant, no ReLU | [10] | -80…46 | classifier.5 |

Both Conv stages retain valid 5×5, stride1/padding0/dilation1 behavior. Flatten
uses c→h→w, with w fastest. Pool/flatten preserve scale/zero-point. FC3 stays INT8;
proposed ADR-016 INT32 transport/bypass does not change mathematical semantics.

## Diagnostics and limits

Trace records shape, min/max, integer domain, scale name/value, zero-point and
endpoint counts. Input clipping counts use existing `scaled_values` and
`round_half_up` helpers to count rounded values outside [-127,127]; no second
quantizer is implemented. Nonzero clipping raises a RuntimeWarning even with
trace=False, so clipping is not silently hidden. Trace does not retain activations.

Existing weighted-layer APIs expose only clamped outputs. Therefore internal
`saturation_count` is null, with an explicit unavailable status. Endpoint counts
are not saturation counts: in ReLU stages zeros can be exact or clamped. Pool
and Flatten themselves perform no saturation. No duplicate MAC/requant run is
performed solely to infer hidden pre-clamp statistics.

## Real selected-model smoke (2026-09-30)

Prepared parameters came from:
`outputs/quantization/seed42_epoch51_candidate_run01/qparams.json` via
`load_candidate_integer_model`. Existing provenance/hash checks were preserved.
The first sample in the existing calibration selection manifest was used, without
new selection or calibration:

`data/insects/train/beetle_cocci/20230529_18-17-49.659651_76_crop.jpg`

Image SHA256: `893974a74c8f4f4a3052b91581a3271a2a37f71bcf6f816a0de0fa16a09082db`.
The manifest hash, train-directory containment and image hash were verified.
`pil_loader` supplied RGB, and the shared `build_insect_eval_transform` applied
resize/ToTensor/Normalize using the verified preprocessing metadata. Existing
source hashes were checked again after execution. No test/validation image used.

Logits: **[-48,22,46,32,3,-30,-52,-9,-2,-80]**.
Argmax: **2**, class **beetle_cocci** (first-index tie convention if needed).
Input clipping: **0/3072**. No weighted output reached +127 or -128, so range
saturation to those limits was not observed. Hidden ReLU clamp counts remain
unavailable; zeros are not proof of clipping. This is one debug example, not an
accuracy claim or a tuning result. No scales were changed.

## Tests

Synthetic tests use fixed LeNet-sized parameters, not the real dataset. A
bias-only network verifies hidden ReLU and negative final logits; a sparse
nonzero network independently yields [3,-3,0,0,0,0,0,0,0,0]. Tests cover all stage
shapes, input clipping warnings, CHW flatten handoff, scale preservation,
unchanged inputs/packages, deterministic results and invalid input/metadata.

Commands from repository root, using the existing environment:

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests/test_candidate_integer_forward.py

PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests
```

Only the forward module, its test module and this README were added for this task.
Earlier contract-sync implementation was left unchanged. No Git write was performed;
training/calibration/data/checkpoint/qparam policies and files were not changed.
No dataset-wide accuracy/clipping evaluation or final hardware artifacts produced.

Results: focused suite **16 passed in 2.24s**; full suite **532 passed in 4.41s**.
The real-image smoke above was a separate manual run, not counted as a pytest case.
