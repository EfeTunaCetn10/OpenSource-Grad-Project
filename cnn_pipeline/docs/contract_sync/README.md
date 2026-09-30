# Contract synchronization — 2026-09-30

Authoritative contract snapshot: GitHub main commit
[`c8168425ab965fa8e68caae7f52375c9db7c9afc`](https://github.com/EfeTunaCetn10/OpenSource-Grad-Project/tree/c8168425ab965fa8e68caae7f52375c9db7c9afc/Kontratlar).
The local feature checkout still contains the older ADR-003 and lacks ADR-014/015/016
and the September 25 interface note. All five updated documents were read via
GitHub's read-only API at the pinned commit and cached under /tmp. No Git write,
fetch, merge or ADR modification was performed. Local ADR links therefore do not
yet describe the updated code; the user must synchronize contracts separately.

## LOCKED changes implemented

- Requant arithmetic: signed64 product, half_ulp and sum, shifts 0…63. For n=0,
  half_ulp=0. Otherwise half_ulp=2^(n-1). Half-up ties toward positive infinity and
  INT8 output saturation are unchanged. `requant_raw` still returns pre-clamp y_raw.
- INT32 arithmetic: explicit `wrap32` at MAC output and MAC+bias boundaries.
  Exact Python accumulation followed by modulo is equivalent to wrapping each add.
  `requant_raw` also wraps incoming mathematical acc, so its scalar public API can
  accept an overflowing accumulator without silently saturating or throwing.
- Configuration values remain checked: INT32 bias must be representable, M0 must
  be normalized and n must fit unsigned 6 bits. Bias quantization overflow is a
  configuration error, not runtime accumulator arithmetic, and remains rejected.
- New `accumulator_safety` and `require_accumulator_safety` functions report/check
  `abs(bias_q[c])+K*16384 <= 2^31-1`. Package preparation attaches the proof and
  rejects unsafe configurations. Raw numerical primitives still wrap even when
  a proof fails. Each channel has bound, margin and safe fields.
- Requant precedes INT8 pooling/flattening; scale and zero-point=0 are preserved.
  Existing CHW pooling/flatten primitives and their tests remain unchanged.

Scalar/list return APIs remain compatible. `checked_int32` is retained for
configuration/range checking; `checked_signed50` remains a legacy utility only.
Neither is used to reject runtime accumulator wrap or to limit requant arithmetic.

## Candidate policy versus arithmetic

The multiplier search still scans n=1…49, keeping previous candidates and recorded
qparam results stable. That is a candidate preparation/configuration policy, not
the arithmetic domain. `candidate_requant_params` validates selected pairs against
n=0…63. No scale, calibration, quantization rounding or M0 selection algorithm was
changed. All real selected pairs remain in n=25…29.

## PROPOSED — deliberately not implemented

ADR-014 port handshake, k_last, pipeline timing and out_sat/out_ovf protocol;
ADR-015 shadow/commit/AXI registers; ADR-016 HWC transport, byte lanes, padding,
FC1 export permutation and FC3 INT32 bypass are not mandatory golden semantics.
No optional packing helper was needed for this numerical sync. CHW flatten and
native FC1 weights remain unchanged; FC3 still requantizes to signed INT8 without
ReLU. No timing, status-flag tuple API, full forward or hardware files were added.
Pre-clamp y_raw is already observable through the existing requant_raw function.

## Real selected candidate safety proof

Loaded via existing `load_candidate_integer_model` / `verify_qparams` with source
hash checks unchanged. No image, Conv/FC or model forward was executed. Five layers,
236 channels passed; source artifacts were not rewritten.

| Layer | K | Maximum abs(bias_q) | Minimum INT32 headroom | n range |
|---|---:|---:|---:|---|
| Conv1 | 75 | 7,676 | 2,146,247,171 | 26…27 |
| Conv2 | 150 | 4,354 | 2,145,021,693 | 26…27 |
| FC1 | 400 | 1,753 | 2,140,928,294 | 26…29 |
| FC2 | 120 | 1,053 | 2,145,516,514 | 25…27 |
| FC3 | 84 | 652 | 2,146,106,739 | 26 |

Headroom = (2^31-1) - (abs(bias_q)+K*16384), in integer accumulator units.
This is a conservative bound, not a measured activation maximum or an FPGA result.

## Tests and superseded expectations

Tests explicitly replaced old n=0/50…63 rejection with arithmetic expectations;
old MAC and MAC+bias overflow exceptions with exact wrap outputs. Signed64 boundary
checks, raw signed ties, all 64 shifts, deterministic random Fraction oracle,
positive/negative wrap, cancellation after wrap and safety-bound pass/fail are
covered. Invalid types/parameters still fail. The safety gate is tested both as an
independent proof and through synthetic model preparation.

Contract wording caveat: claims that high n has no ties refer to the odd-M0 modular
inverse generator. Even M0 can have ties above n=32; e.g. acc=65536, M0=65536, n=33
is +0.5 and rounds to 1. This is tested, not treated as an ADR edit or a new rule.
Likewise practical multiplier bands are observations, not arithmetic restrictions.
The interface note's suggested `(y,sat,ovf)` API is not adopted while ADR-014 remains
proposed; final wrap values do not reconstruct per-add sticky overflow events.

## Exact test commands and results

Run from the repository root, using the existing environment (no packages installed):

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests/test_requant_ref.py cnn_pipeline/tests/test_integer_linear_ref.py cnn_pipeline/tests/test_integer_conv2d_ref.py cnn_pipeline/tests/test_integer_layer_ref.py cnn_pipeline/tests/test_accumulator_safety.py cnn_pipeline/tests/test_candidate_requant_params.py cnn_pipeline/tests/test_candidate_integer_model.py
# 299 passed in 2.34s

PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -m pytest -c cnn_pipeline/pytest.ini -q -p no:cacheprovider cnn_pipeline/tests
# 516 passed in 2.98s
```

The earlier 496 baseline count is not a new test result. Parametrized legacy
rejection cases were removed/replaced, so the net increase is not the number of
new scenarios. `git diff --check` passed (read-only check).

Real-artifact check used the existing loader and printed the proof without
writing artifacts:

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B - <<'PY'
import sys
sys.path.insert(0,'cnn_pipeline')
from candidate_integer_model import load_candidate_integer_model
r=load_candidate_integer_model('cnn_pipeline/outputs/quantization/seed42_epoch51_candidate_run01/qparams.json')
for name,p in r['layers'].items():
 s=p['accumulator_safety'];print(name,'K',s['K'],'safe',s['safe'],'min_margin',s['min_margin'],'max_abs_bias',max(map(abs,p['bias_q'])),'n',min(p['n']),max(p['n']))
PY
```

## Complete file inventory

Modified code (under `cnn_pipeline/`):
- `requant_ref.py`
- `integer_linear_ref.py`
- `integer_conv2d_ref.py`
- `integer_layer_ref.py`
- `candidate_requant_params.py`
- `candidate_integer_model.py`
- `multiplier_analysis.py` (error text only; search algorithm unchanged)

Created code: `cnn_pipeline/accumulator_safety.py`.

Modified tests (under `cnn_pipeline/tests/`):
- `test_requant_ref.py`
- `test_integer_linear_ref.py`
- `test_integer_conv2d_ref.py`
- `test_integer_layer_ref.py`
- `test_candidate_requant_params.py`
- `test_candidate_integer_model.py`

Created tests: `cnn_pipeline/tests/test_accumulator_safety.py`.

Updated component documentation (under `cnn_pipeline/docs/`):
- `requantization/README.md`
- `integer_linear/README.md`
- `integer_conv2d/README.md`
- `integer_layer/README.md`
- `bias_quantization/README.md`
- `multiplier_analysis/README.md`
- `candidate_requant_params/README.md`
- `candidate_integer_model/README.md`

Created report: `cnn_pipeline/docs/contract_sync/README.md` (this file).
Component documents retain clearly labelled historical records below a current
behavior notice. No ADR, checkpoint, calibration, training/data file or previous
output was edited. Pre-existing untracked archive/MNIST files were left alone.
