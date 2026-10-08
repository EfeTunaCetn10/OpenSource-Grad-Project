# Experimental FP32 model v2 — seed 42

Decision: **do not promote or quantize**. Candidate v1 remains frozen.
The previous run had an epoch-58 best checkpoint but no history.json, no live
trainer, and no optimizer/scheduler/RNG resume state. It was preserved unchanged.
The identical experiment was restarted in a new directory and completed all 60
epochs. The first three logged epochs reproduced the previous session's results.

## Separate topology

`model_v2.py`: LeNetV2, RGB 3×32×32 → Conv(3→8,5×5,valid,stride1) → ReLU →
MaxPool(2,2) → Conv(8→24,5×5,valid,stride1) → ReLU → MaxPool(2,2) →
Flatten(600) → Linear(600→64) → ReLU → Linear(64→32) → ReLU → Linear(32→10).
Spatial path 32→28→14→10→5. No extra operators. V1 remains the default in train.py;
model.py and integer/golden modules are unchanged. V2 checkpoints have a distinct
model_name and recorded model_version/source hash, and must not be fed to v1 loaders.

| Parameters (including biases) | Count | Share |
|---|---:|---:|
| Conv | 5,432 | 11.7307% |
| FC | 40,874 | 88.2693% |
| Total | 46,306 | 100% |

This corrects the earlier planning estimate of 46,658. V1 has 62,006 parameters,
with only 4.63% in Conv. Fewer weights do not imply less convolution compute or
validated FPGA compatibility; channel sizes and feature buffers differ.

## Recipe and command

Same split, normalization, full-image resize, horizontal flip, ColorJitter,
AdamW LR .001, weight decay .0001, smoothing 0, batch128, cosine60, seed42,
CPU/two threads and highest-validation-accuracy/first-tie checkpoint rule.
Only model topology changes. Architecture-dependent initialization consumes a
different RNG stream; same seed does not guarantee paired augmentation draws.
From `cnn_pipeline/`:

```bash
PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=2 MKL_NUM_THREADS=2 /home/cgj/anaconda3/envs/pynq-cnn/bin/python -B -u train.py --dataset insects --model-version v2 --data-dir data/insects --stats data/insects/stats.json --output-dir outputs/model_v2_seed42_60epochs_restart01 --epochs 60 --batch-size 128 --learning-rate 0.001 --weight-decay 0.0001 --label-smoothing 0 --workers 0 --seed 42 --train-resize --scheduler cosine --skip-test
```

Completed output: `cnn_pipeline/outputs/model_v2_seed42_60epochs_restart01/insects/`.
Incomplete preserved output: `cnn_pipeline/outputs/model_v2_seed42_60epochs/insects/`.

## Validation comparison

The selected checkpoint was reloaded independently using LeNetV2 and evaluated
on 1,774 validation images with existing preprocessing and unsmoothed CE.
Epoch 60 tied epoch 58 accuracy; epoch 58 correctly remained selected.

| Metric | V1 | WD 1e-3 | Smoothing .05 | No jitter | V2 |
|---|---:|---:|---:|---:|---:|
| Best epoch | 51.0000 | 60.0000 | 50.0000 | 46.0000 | 58.0000 |
| Train accuracy % | 70.5358 | 71.5911 | 71.2759 | 68.4939 | 65.6297 |
| Train loss | 0.8474 | 0.8243 | 1.0233 | 0.8888 | 0.9766 |
| Val accuracy % | 55.4115 | 55.3551 | 55.5242 | 54.3405 | 54.3405 |
| Val loss | 1.3351 | 1.3507 | 1.3124 | 1.4006 | 1.4177 |
| Gap pp | 15.1243 | 16.2359 | 15.7516 | 14.1534 | 11.2892 |
| Macro recall % | 40.3275 | 39.7441 | 39.5734 | 39.6734 | 36.9463 |

Smoothed training loss is not directly comparable. Train metrics are online
augmented-batch values, not fixed-checkpoint clean-train evaluation.

| Class recall % | V1 | WD | Smoothing | No jitter | V2 |
|---|---:|---:|---:|---:|---:|
| bee | 57.98 | 56.38 | 53.72 | 64.36 | 48.40 |
| beetle | 2.35 | 3.53 | 2.35 | 2.35 | 1.18 |
| beetle_cocci | 56.67 | 58.33 | 55.83 | 50.83 | 53.33 |
| bug | 24.49 | 22.45 | 22.45 | 16.33 | 8.16 |
| fly | 68.59 | 68.95 | 71.48 | 77.62 | 71.12 |
| fly_sarco | 3.28 | 3.28 | 3.28 | 9.84 | 4.92 |
| fly_small | 58.08 | 58.08 | 55.02 | 46.72 | 62.88 |
| hfly_episyr | 84.92 | 85.81 | 88.03 | 80.04 | 88.69 |
| hfly_eupeo | 29.27 | 28.86 | 28.86 | 28.05 | 21.95 |
| hfly_sphaero | 17.65 | 11.76 | 14.71 | 20.59 | 8.82 |

## Confusion matrix

Rows=true, columns=predicted; order: `bee, beetle, beetle_cocci, bug, fly, fly_sarco, fly_small, hfly_episyr, hfly_eupeo, hfly_sphaero`.

```text
 91   1   0   1  22   2  40  13  17   1
 16   1   1   0  16   0  34   7  10   0
  2   7  64   9  13   0   1  14  10   0
  0   9  21   4   0   0   1  10   4   0
 14   0   0   0 197   1  59   3   3   0
  5   0   0   0  47   3   5   0   1   0
 10   0   0   0  44   0 144  22   8   1
  7   5   0   0   5   0  10 400  22   2
 16   6   1   8  22   1  18 117  54   3
  0   1   0   0   0   0   2  59   0   6
```

## Decision

V2 obtains 964 correct vs v1's 983 (−1.0710 pp), and macro recall drops
3.3812 pp. Beetle falls 2→1; fly_sarco rises 2→3; hfly_eupeo falls 72→54;
hfly_sphaero falls 12→6. Bug falls 12→4. Fly, fly_small and hfly_episyr improve,
but feature discrimination is not meaningfully better across the class set.
Hfly_eupeo→hfly_episyr confusion increases 91→117; hfly_sphaero→hfly_episyr
increases 53→59. The smaller gap accompanies lower train and validation accuracy,
not proven superior generalization. This one seed does not establish that all
wider-convolution models fail, nor isolate the effect of narrowing the FC layers.

Seed-123 confirmation is not prioritized as a promotion step: v2 is not clearly
better on the combined criteria. Do not attempt PTQ for this candidate now.
Keep the frozen v1 checkpoint and pipeline selected.

## Verification and files

Previous implementation session: 4 architecture tests passed, full regression
566 passed. Those are historical results, not rerun in this continuation; no code
changed here. Tests cover exact stage shapes, flatten600, 10 logits, operator set,
46,306 parameters and input validation. Independent validation reproduces the
saved selected history row; confusion counts total 1,774. All 175 inventoried
existing artifact/documentation/provenance files, including original partial v2
output and model.py, match pre-continuation SHA256 hashes. No test inference,
quantization, integer export or Git writes. `git diff --check` passed.

Original implementation: added model_v2.py and tests/test_model_v2.py; modified
train.py to add the optional versioned route. This continuation adds only this
report folder's README.md/run_config.json/validation_metrics.json and the new run's
best.pt/history.json/run_config.json/validation_metrics.json/comparison.json.
The old partial run and all earlier local code edits were retained unchanged.

Selected checkpoint SHA256: `6df3aa5435d234627caa4d8d392664de82d7712da66f9f0ce2071c7eae826d12`.
