# Deterministic validation: FP32 versus candidate INT8

`compare_candidate_validation.py` evaluates the same normalized image tensor through
normal FP32 LeNet and the existing candidate integer forward. No training,
calibration, parameter tuning, test-split inference, hardware export or topology
change is performed. Accuracy against labels is the quality metric; prediction
agreement is a diagnostic, not a substitute for accuracy.

## Data and identity

`load_candidate_integer_model` preserves the existing provenance verification.
The exact checkpoint named in its verified provenance is loaded with the existing
`load_checkpoint` helper, checked against its SHA256, and strict-loaded into
`LeNet5(3,10)` in eval/inference mode. FP32 computation uses ordinary PyTorch;
INT8 uses `candidate_integer_forward` with trace enabled.

The existing `build_insect_loaders` supplies its validation dataset. Its class
order and normalization must match checkpoint metadata. This loader constructs
train/test datasets but only validation images are opened for evaluation.
Validation inventory must exactly match split_manifest.json; selected labels and
image bytes must match the manifest. Source and selected-image hashes are checked
again at the end. No selection based on predictions is allowed.

A local Python RNG seeded 42 shuffles validation indices. The 100-image pilot is
the prefix of the full ordering. This is an unstratified subset; the full run
covers all classes and avoids subset class-imbalance interpretation. Empty classes
are retained with count 0 and null accuracy/agreement, never silently dropped.
First-index argmax breaks ties for both paths. CLI selects deterministic PyTorch
algorithms, CPU execution and two CPU threads.

## Metrics and diagnostics

The JSON includes sample count, both top-1 accuracies (fractions), signed and
absolute percentage-point difference, agreement, four correctness categories,
true/predicted confusion matrices for both paths and an FP32-prediction ×
INT8-prediction agreement matrix. Both-wrong includes both matching and differing
wrong predictions. Per-class accuracy is correct/count for samples of that true
class (recall); per-class agreement is conditional on the same true class.

Input clipping is measured by the existing forward quantizer diagnostic. Input
warning spam is suppressed only because every clipping event is aggregated into
the report. Stage output counts and separate -128/+127 hits were added to the
forward trace; numerical execution and return APIs are unchanged. These hits are
boundary proxies, not true internal clamp counters. In particular ReLU zeros are
not counted as -128 boundaries. No internal clamp count is invented.

Each report records checkpoint/qparams hashes, split/statistics hashes, sample
paths/indices/hashes/predictions, class order, preprocessing, evaluated-source code
hashes and measured runtime. `selection_sha256` hashes the complete evaluated
sample records (including predictions); it identifies the evaluation record,
not merely the unordered input subset. Output directory must be new and under
`cnn_pipeline/outputs/validation_comparison/`; no existing artifacts overwritten.

## Reproduce

From repository root, using the existing environment:

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B cnn_pipeline/compare_candidate_validation.py --qparams cnn_pipeline/outputs/quantization/seed42_epoch51_candidate_run01/qparams.json --data-dir cnn_pipeline/data/insects --limit 100 --output-dir cnn_pipeline/outputs/validation_comparison/seed42_pilot100_run01

PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B cnn_pipeline/compare_candidate_validation.py --qparams cnn_pipeline/outputs/quantization/seed42_epoch51_candidate_run01/qparams.json --data-dir cnn_pipeline/data/insects --full --output-dir cnn_pipeline/outputs/validation_comparison/seed42_full_run01
```

Use different run-directory names for repeats. The pilot measured 6.635 seconds
INT8 time for 100 images (66.35 ms/image), projecting 117.70 seconds for 1,774.
Pilot accuracy: FP32 56%, INT8 55%, agreement 96%. The full-run results below
supersede this pilot for validation-quality reporting; no parameters were tuned.

## Unit verification

Pure metric tests cover exact accounting, agreement matrices, percentage points,
class-wise aggregation including empty classes, diagnostic counters, deterministic
selection, JSON round-trip/schema checks, and refusal to overwrite output. Forward
trace tests verify that ReLU zeros are not misreported as -128 hits. No real-data
run is added to the normal pytest suite.

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests/test_compare_candidate_validation.py cnn_pipeline/tests/test_candidate_integer_forward.py

PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests
```

## Full validation results

Full validation completed: **1,774 samples**. FP32 **55.4115%** (983 correct),
candidate INT8 **54.6787%** (970 correct). Absolute difference **0.7328 pp**;
INT8−FP32 **−0.7328 pp**. Agreement **95.6032%** (1,696/1,774).

Both correct: 952; FP32 correct/INT8 wrong: 31; FP32 wrong/INT8 correct: 18;
both wrong: 773. The FP32 result reproduces the selected model validation record.

| Class | Samples | FP32 % | INT8 % | Agreement % |
|---|---:|---:|---:|---:|
| bee | 188 | 57.98 | 60.11 | 95.21 |
| beetle | 85 | 2.35 | 2.35 | 90.59 |
| beetle_cocci | 120 | 56.67 | 55.83 | 98.33 |
| bug | 49 | 24.49 | 22.45 | 91.84 |
| fly | 277 | 68.59 | 69.68 | 95.67 |
| fly_sarco | 61 | 3.28 | 1.64 | 91.80 |
| fly_small | 229 | 58.08 | 58.52 | 98.69 |
| hfly_episyr | 451 | 84.92 | 84.92 | 97.12 |
| hfly_eupeo | 246 | 29.27 | 23.98 | 93.09 |
| hfly_sphaero | 68 | 17.65 | 10.29 | 92.65 |

No class is empty in this full validation split. Per-class performance is uneven;
high agreement does not establish good classification quality. No parameters were
adjusted in response to these results.

Input clipping: **0 / 5,449,728 elements (0%)**.

| Stage | Output count | −128 hits | +127 hits |
|---|---:|---:|---:|
| input | 5,449,728 | 0 | 9 |
| conv1 | 8,344,896 | 0 | 6 |
| pool1 | 2,086,224 | 0 | 6 |
| conv2 | 2,838,400 | 0 | 0 |
| pool2 | 709,600 | 0 | 0 |
| flatten | 709,600 | 0 | 0 |
| fc1 | 212,880 | 0 | 1 |
| fc2 | 149,016 | 0 | 0 |
| fc3 | 17,740 | 0 | 0 |

Boundary hits are not true clamp counts; pooling can carry a preceding boundary
value forward, so counts must not be summed as independent saturation events.
Input +127 hits occurred without input clipping, illustrating this distinction.

Runtime: total **114.887 s**, FP32 **1.037 s**, INT8 **111.875 s**,
INT8 **63.064 ms/image**, total **64.761 ms/image**. These are CPU diagnostic
execution timings including INT8 trace collection, not hardware benchmarks.

Reports:
- `outputs/validation_comparison/seed42_pilot100_run01/report.json`
- `outputs/validation_comparison/seed42_full_run01/report.json`

Verification: focused **29 passed in 2.72 s**; full suite **545 passed in 4.42 s**.
The exact commands are above. `git diff --check` passed. An initial pilot attempt
found a relative-path reporting error; it was fixed before the recorded pilot,
and the failed attempt wrote no output artifact.

Files changed/created for this task:
- New `cnn_pipeline/compare_candidate_validation.py`
- New `cnn_pipeline/tests/test_compare_candidate_validation.py`
- New `cnn_pipeline/docs/validation_comparison/README.md`
- Updated `cnn_pipeline/candidate_integer_forward.py` (trace counters only)
- Updated `cnn_pipeline/tests/test_candidate_integer_forward.py`

No implementation blocker remains. True internal clamp-event counts remain
unobservable through the current API. No Git writes were performed.
