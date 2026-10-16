# Experimental CompactCNN-v3 PTQ

Separate software evaluation, not promotion, hardware export, or RTL equivalence.
Frozen v1 sources, selected metadata and artifacts are unchanged.

## Audit and reuse

The v1 orchestration is not generic: calibration.validate_metadata requires the
LeNet name; observation/quantization/model preparation pin seed42 epoch51 and
selected_model.json. WEIGHTS/ACTIVATIONS/LAYERS encode two 5x5 valid convolutions,
3→6→16 channels, CHW flatten400 and FC400→120→84→10. The scalar Conv primitive
only supports no-padding; full forward hardcodes two pools and those shapes.

experimental_v3_ptq.py discovers and validates v3's three padded 3x3 Conv layers
and two Linear layers. It reuses TensorExtrema/activation_hooks/weight_statistics,
candidate_scale/quantize_int8/weight_metrics, quantize_bias_candidate,
candidate_requant_params, require_accumulator_safety and comparison metrics.
None of these existing modules was edited.

The original calibration manifest is replayed, not resampled. Its checkpoint
identity still identifies its original v1 selection provenance; it is NOT passed
off as a v3 checkpoint manifest. qparams.json separately binds the v3 checkpoint,
original manifest hash, selection configuration and new activation statistics.
Train containment, unique image paths, labels, hashes, train inventory, class
order, normalization and resize settings are verified. Exactly 100 images per
class, seed42, total1000; original day-round-robin sample order is retained.
Capture day is only a proxy for insect identity; cross-day near-duplicates remain
possible. No random augmentation is used for calibration or validation.

## Numerical behavior

- Original candidate float quantization: signed [-127,127], zero-point0,
  symmetric absmax/127, per-tensor activations/per-output-channel weights axis0.
- Float64 half-up quantization; no zero-range fallback.
- Bias: existing half-up candidate in s_x*s_w[c], checked INT32.
- Multiplier selection: unchanged analyze_multiplier, n search1…49;
  runtime supports the existing signed64 arithmetic domain n0…63.
- Runtime: INT32 wrap, signed64 half-up, ReLU clamp[0,127], logits[-128,127].
- Pool and CHW flatten preserve scale/zero-point. No FC bypass or HWC packing.
- Padding=1 uses integer zero, correct because zero-point is0.

CPU int64 tensor dot products avoid the cost of billions of Python-loop MACs.
No floating convolution or quantized runtime is used for integer inference.
Unfold is an in-memory integer sliding-window view, not a hardware export.
Safety proof abs(bias)+K*16384 <= INT32_MAX is enforced in preparation/execution.
The vector requant implementation validates parameters with existing scalar
requant_raw; valid INT32/M0/n guarantees its signed64 product/rounding sum fits.
Tests compare it to scalar requant across all64 shifts, and compare an entire
synthetic v3 integer forward to existing scalar Conv/Linear/Pool/Flatten functions
with an explicit integer-zero border. This is software cross-validation only.

## Recorded run

Checkpoint: outputs/model_v3_compact_seed42_60epochs/insects/best.pt,
seed42, epoch52, SHA256
09d17b5b8a77b5850645c9bb575c0cf12aaf8a9720ffe0677e1fc527016468f6.
Full validation:1774 samples; recomputed FP32 confusion equals the saved reference.

| Metric | FP32 | Candidate INT8 |
|---|---:|---:|
| Correct |1090|1078|
| Accuracy |61.4431%|60.7666%|
| Macro recall |46.7730%|45.4279%|

Accuracy drop0.6764pp; macro-recall drop1.3451pp. Agreement96.7869%;57 predictions
changed. Both correct1066, FP32-only correct24, INT8-only correct12, both wrong672.
Full comparison loop took4.227s on CPU (includes data loading and both paths;
excludes calibration/provenance hashing). This is not FPGA latency.

Input clipping0/5,449,728; weight clipping0 for every layer. Output +127 occurs
once at FC1; a boundary hit alone does not establish clipping. The recorded
clamp_count includes ordinary ReLU negative-to-zero operations and must NOT be
interpreted as excessive upper-range saturation. Final logits have no clamp events.
All146 output channels passed safety checks; selected n values span25…29.

Weak-class losses warrant investigation before promotion, especially
hfly_sphaero(-4.41pp), bug(-4.08pp), fly_sarco(-3.28pp), hfly_eupeo(-2.85pp).
No tuning or promotion was performed. A seed confirmation and hardware feasibility
review remain separate decisions; v3's third Conv/padding are not supported by
simply supplying new weights to the existing v1 golden/RTL pipeline.

## Commands (repository root)

```bash
CUDA_VISIBLE_DEVICES="" PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B cnn_pipeline/experimental_v3_ptq.py --checkpoint cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/best.pt --selection-manifest cnn_pipeline/outputs/calibration/seed42_100perclass_20260924/selection_manifest.json --output-dir cnn_pipeline/outputs/model_v3_compact_seed42_60epochs/insects/ptq

PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests/test_experimental_v3_ptq.py
# 75 passed

PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests
# 658 passed

git diff --check
```

The run refuses an existing ptq directory; do not delete/reuse the recorded run.
Outputs: qparams.json, statistics.json, weights_int8.pt,
calibration_selection_manifest.json, validation_metrics.json, artifact_manifest.json.
The last file hashes every other generated artifact (no recursive self-hash).
Validation report contains per-class comparisons, confusion matrices, predictions,
image hashes, accounting and diagnostics. qparams records all five layers' INT32
bias lists, scales, M0/n, approximation diagnostics, safety proofs and source hashes.
No test-set images were evaluated. No training, RTL, selected-model or Git writes.
