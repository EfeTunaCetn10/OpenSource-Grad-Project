# Hardware-aware CNN model selection

**Decision:** freeze `v3_48_deep_pool_refine` as the final ML hardware candidate and stop architecture/hyperparameter search on the reused validation set. This decision does not promote a hardware contract or establish full-network RTL equivalence. The untouched test set remains reserved for final locked evaluation.

## Goal and experimental protocol

Select an accurate insect classifier compatible with the PYNQ-Z2 accelerator, using only Conv2d, ReLU, MaxPool2d, Flatten and Linear. Hardware cost, seed robustness and macro recall matter alongside overall accuracy.

The reference recipe uses the existing split, RGB full-image resize, channel normalization, horizontal flip and ColorJitter; AdamW (LR 0.001, weight decay 0.0001), batch 128, 60 epochs, cosine schedule and no label smoothing. Validation is deterministic, unweighted and contains 1,774 images. Only strictly greater validation accuracy replaces `best.pt`; ties keep the earlier checkpoint. No test accuracy is claimed.

## From 32x32 to the accuracy reference

The original frozen LeNet-style v1 achieved 55.4115% FP32 validation accuracy. CompactCNN-v3 at 32x32 reached 61.4431% FP32 and 60.7666% INT8. Later 32x32 depth, width and pooling experiments did not resolve the accuracy limitation.

The experimental 48x48 v3 improved seed42 FP32 accuracy to 66.9109%. Adding a 32-to-32 convolution before Pool3 produced `v3_48_deep`, the accuracy reference:

| CPU seed | Deep FP32 validation |
|---|---:|
| 42 | 68.9966% |
| 123 | 71.4769% |

Deep seed123 INT8 accuracy is 70.5750%. These comparisons support a better representation, but do not isolate resolution as the sole cause. Fine-grained discrimination remained difficult. The official 32x32 hardware contract is not changed by this ML decision.

## Hardware/ML co-design: reduce FC cost, then refine features

The accuracy-first model ends with 32x6x6 features: FC1 K=1152 and 73,728 INT8 weight bytes. With eight output-channel banks, FC1 requires 9,216 bytes per bank, exceeding the current 8,192-byte bank depth; K also exceeds K_MAX=1024.

The RTL-side proposal was an additional final pool, reducing 32x6x6 to 32x3x3:

- FC1 K: **1152 -> 288**.
- FC1 weights: **73,728 -> 18,432 bytes** (75% reduction).
- FC1 bank requirement: **9,216 -> 2,304 bytes per bank**.

The initial `deep_pool` result lost approximately 2.1 percentage points in the project comparison. Saved pool runs used GPU whereas the cited deep reference used CPU: this is not a clean backend-controlled estimate of the pooling penalty. Aggressive spatial compression was the ML working hypothesis, not a proven causal attribution.

The ML refinement adds Conv32->32 + ReLU at 6x6 **before** that final pool. It preserves the smaller FC geometry while learning discriminative features before compression. Matched CPU seed comparisons against deep show losses of 0.2818 pp (42) and 0.7328 pp (123), averaging **0.5073 pp**. This is the central co-design result: retain the hardware-saving pool, compensate with inexpensive late feature extraction.

## Frozen architecture and hardware geometry

All convolutions use 3x3, stride 1, padding 1, with bias. Pools use 2x2, stride 2. No BatchNorm, dropout, residual connections or exotic operators are present.

| Stage | Output CHW / features | Reduction K | INT8 weights | Bytes per bank* |
|---|---|---:|---:|---:|
| Input | 3x48x48 | — | — | — |
| Conv1 + ReLU | 16x48x48 | 27 | 432 | 54 |
| Pool1 | 16x24x24 | — | — | — |
| Conv2 + ReLU | 24x24x24 | 144 | 3,456 | 432 |
| Pool2 | 24x12x12 | — | — | — |
| Conv3 + ReLU | 32x12x12 | 216 | 6,912 | 864 |
| Conv4 + ReLU | 32x12x12 | 288 | 9,216 | 1,152 |
| Pool3 | 32x6x6 | — | — | — |
| Conv5 + ReLU | 32x6x6 | 288 | 9,216 | 1,152 |
| Pool4 / Flatten | 32x3x3 / 288 | — | — | — |
| FC1 + ReLU | 64 | 288 | 18,432 | 2,304 |
| FC2 signed logits | 10 | 64 | 640 | 128 |

\* Eight output-channel banks; FC2 includes padding to two tiles in the bank calculation. These are per-layer capacity requirements, not a claim that all layers fit simultaneously.

- **48,514 parameters**, including biases; **5,659,264 Conv/Linear MACs per image**.
- Conv K: **27, 144, 216, 288, 288**; FC K: **288, 64**.
- Maximum K **288 < 1024**; maximum bank requirement **2,304 < 8,192 bytes**.
- Largest logical activation: **16x48x48 = 36,864 INT8 bytes**.
- These capacity checks do not establish routed timing, total BRAM use or complete 48x48 RTL integration.

## Frozen FP32 and INT8 results

| CPU run | FP32 accuracy | INT8 accuracy | FP32 macro recall | INT8 macro recall |
|---|---:|---:|---:|---:|
| Refine seed42 | 68.7148% | — | — | — |
| Refine seed123 | 70.7441% | 70.0113% | 57.0330% | 55.7920% |

Seed123 selects epoch57. PTQ drops accuracy by **0.7328 pp**, with **97.2943% prediction agreement**. PTQ arithmetic is not the main accuracy bottleneck. Weak classes include beetle, bug, fly_sarco and hfly_sphaero; overall accuracy alone conceals uneven class performance.

## Rejected experiments

| Experiment | Finding / selection lesson |
|---|---|
| 32x32 deep, no-pool3, wide | Did not solve the accuracy limitation; larger tensors/classifiers alone were insufficient. |
| 48x48 A/C architecture variants | Did not beat deep; additional convolutions are not automatically useful. |
| Hard inverse-frequency sampler | Increased macro recall but reduced overall accuracy. |
| RandomAffine | Clearly worse; augmentation must preserve discriminative detail. |
| Higher weight decay / label smoothing | Tried settings were unsuccessful; not evidence that every setting is ineffective. |
| Conservative KD, T=2, alpha=0.20 | Seed123 CPU 70.1240%; below frozen baseline. |
| Targeted weighted CE | 70.4622% accuracy, 59.1012% macro recall: -0.2818 pp accuracy, +2.0682 pp macro. Useful trade-off, not the chosen accuracy winner. |
| Wide40 | CPU seed123 71.8151%, seed42 66.1218%; rejected for poor observed cross-seed robustness. GPU seed123 71.4769% did not remove this concern. |
| Late EMA | Failed predefined success criteria; no promotion. |

Late EMA copied the student after epoch40, updated at decay0.99 during epochs41-60, and evaluated only fixed epoch60:

| CPU seed | Raw epoch60 | EMA epoch60 | Same-run normal best |
|---|---:|---:|---:|
| 42 | 67.6437% | 67.6437% | 68.7148% |
| 123 | 69.6167% | 69.8985% | 70.7441% |

EMA slightly improved seed123 over raw epoch60, but neither seed exceeded its normal validation-selected checkpoint.

## Seed/backend sensitivity and scientific limitations

Refine GPU best accuracies were 70.4059% (seed42) and 69.7294% (seed123), reversing the CPU ordering. The CPU seed spread is 2.0293 pp for refine, 2.4803 pp for deep and 5.6933 pp for wide40. Two seeds do not establish a reliable population variance.

The ordinary data loader fixes its shuffle generator at 42. Experiment seeds change initialization and augmentation RNG; these effects were not independently isolated. Backend numerics can alter optimization trajectories. Late plateau differences show that checkpoint noise alone does not explain the seed gaps.

Many architectures and training settings were compared on the same validation set. The maximum observed validation score is therefore selection-biased. Class ambiguity, label noise and sharpness were not causally established. Do not interpret the results as test-set performance or universal architecture rankings.

## Final decision, retained code and remaining work

Freeze [v3_48_deep_pool_refine](model_v3_48_deep_pool_refine.py), stop further search, and retain the ordinary CE seed123 checkpoint. KD, weighting and EMA remain opt-in experimental support, not part of the chosen recipe.

Retain `model_v3_48_deep_pool.py`: the frozen refine class inherits from it. Retain deep as the accuracy reference and preserve historical/core baselines. Obsolete 32x32 deep/no-pool3/wide and wide40 source/test variants were removed locally; their output artifacts were not deleted. A/C source variants were already absent. Removed untracked files do not appear as Git deletions in this commit.

Remaining work is hardware/interface alignment for the frozen geometry, full-network integration and verification, and final locked test-set evaluation. This report does not claim full-network FPGA equivalence, contract promotion or board completion.

Evidence is recorded locally under `outputs/<experiment>/insects/` in `history.json`, `run_config.json`, `best.pt`, `ptq/validation_metrics.json`, and the EMA runs' `ema_validation_comparison.json`. These datasets/checkpoints/generated artifacts are intentionally excluded from this source/documentation commit. The targeted-weight macro result also comes from the prior read-only validation evaluation. Historical rejected-experiment conclusions combine saved records with the project experiment log.
