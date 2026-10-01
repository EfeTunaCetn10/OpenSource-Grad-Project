# Canonical candidate golden test vectors

These deterministic JSON vectors are mathematical reference data for future
cocotb/RTL comparisons. They are **not** packed hardware memory/register files
or evidence that RTL matches Python. No cocotb, RTL or timing code is added.

## Canonical layout and API

`export_test_vectors.py` owns serialization. `build_vectors` assembles data from
prepared parameters and a normalized FP32 image; `write_vectors` writes a new
run directory. `export_real` uses the existing provenance-checked candidate model
loader and the first sample of the existing train calibration manifest. It does
not resample or recalibrate. Sample bytes/hash/train containment and source
artifact hashes are checked, and the shared deterministic image transform is used.

The sole inference API extension is optional
`candidate_integer_forward(..., trace=True, capture_tensors=True)`: each stage
record gains independent `values`. Default behavior and numerical math are
unchanged. The exporter captures these values directly rather than implementing
another network. Full-network internal accumulators are not exposed or invented;
focused primitive vectors use existing MAC/requant APIs to expose them reliably.

Activations are **CHW**, Conv weights **[out,in,kH,kW]**, Linear weights **[out,in]**;
flatten remains c→h→w. FC3 output is signed INT8. There is no HWC conversion,
FC1 permutation, byte packing, bank interleaving, padding, .coe/.bin, register map
or proposed FC3 INT32 bypass. ADR-014/015/016 remain proposed hardware interfaces.
Locked wrap32, signed64 requant, half-up and n=0…63 semantics are unchanged.

## Artifact schema (version 1)

```text
metadata.json
normalized_input.json
requant_vectors.json
focused_vectors.json
layer_params/{features.0,features.3,classifier.1,classifier.3,classifier.5}.json
expected/{input_int8,conv1,pool1,conv2,pool2,flatten,fc1,fc2,fc3}.json
```

18 JSON files total. `metadata.json` records sample identity/path/hash/label,
ordered class names, input preprocessing/qparams provenance, verified model source
hashes, code hashes, layer/stage order, logits and aggregate trace diagnostics.
`file_sha256` covers every payload file except metadata itself (no recursive
self-hash). Run directory and timestamps do not affect bytes; repeats with the
same inputs and code yield identical file bytes. Existing directories are refused.

Tensor objects contain `dtype`, `shape`, `layout`, `values`. Signed integer values
are decimal JSON integers, never converted through float. Readers must use integer
parsers (Python json preserves signed64 exactly); JavaScript Number is unsafe for
large values such as half_ulp=2^62. FP32 normalized input is separately labelled
float32 with CHW values and normalization provenance. Its file hash covers its
serialization; float fields are not integer transport fields.

Each layer contains ordered weights, bias_q, M0, n, input/weight/output scales,
scale names, zero-point, ReLU, K and safety proof. M0/n use int32 JSON tensor
containers with explicit constraints: M0 normalized [65536,131071] in a signed
18-bit carrier; n unsigned 6-bit. This is not a register layout.

Expected stage shapes:
`[3,32,32] → [6,28,28] → [6,14,14] → [16,10,10] → [16,5,5] → [400] → [120] → [84] → [10]`.

## Focused cases

26 requant vectors: ordinary positive/negative, n=0/1/49/50/63, both signed half-up
ties, positive/negative output saturation and positive/negative INT32 wrap inputs;
each runs with ReLU False and True. Fields: acc_input, wrapped_acc, M0, n,
half_ulp, expected_raw and expected_int8. Raw values expose rounding differences
that final clamp can hide. Out-of-range mathematical acc inputs explicitly test
wrap32; a future RTL driver must drive the wrapped INT32 bits, not attempt to
place 2^31 in a signed32 port unchanged.

Synthetic short MAC: `[2,-3,4]·[5,6,-2] = -16`.
Linear: MAC `[-16,10]`, bias `[1,-7]`, acc `[-15,3]`, output `[-7,2]`.
Asymmetric 2×2 Conv: MAC `[[[37,47],[67,77]]]`, bias -40, scale 0.5,
raw/final `[[[-1,4],[14,19]]]`. These are independent of the real image/model.

Future cocotb can load JSON, verify file hashes, drive primitive inputs and compare
pre-clamp and final results. Layer/stage arrays localize the first divergence to
input, Conv, Pool, flatten or FC. Mapping to ports/cycles/packed memories requires
a separately agreed hardware adapter; none is assumed by these artifacts.

## Real export and verification

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B cnn_pipeline/export_test_vectors.py --qparams cnn_pipeline/outputs/quantization/seed42_epoch51_candidate_run01/qparams.json --output-dir cnn_pipeline/outputs/hardware_test_vectors/seed42_canonical_debug_run01
```

Selected sample (train debug only):
`cnn_pipeline/data/insects/train/beetle_cocci/20230529_18-17-49.659651_76_crop.jpg`

Label 2 (`beetle_cocci`); SHA256
`893974a74c8f4f4a3052b91581a3271a2a37f71bcf6f816a0de0fa16a09082db`.
No tuning or accuracy inference is based on this sample.
Logits: `[-48,22,46,32,3,-30,-52,-9,-2,-80]`.

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests/test_export_test_vectors.py cnn_pipeline/tests/test_candidate_integer_forward.py

PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests
```

Tests cover byte-deterministic export, hashes, all stage shapes, signed integer
round trips, channel parameter preservation, CHW flatten, independently calculated
primitive outputs, no mutation and no overwrite. No full validation rerun.
Previous validation reports remain unchanged historical artifacts: their source
hash identifies the earlier forward implementation before optional capture was
added. No Git write or package install was performed.

Verification: focused tests **27 passed**; full regression **555 passed**.
The real export contains 18 JSON files; all 17 payload hashes in metadata were
verified after writing. `git diff --check` passed.
