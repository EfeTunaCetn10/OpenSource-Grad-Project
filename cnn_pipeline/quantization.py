"""Candidate PTQ parameters and software INT8 weights; no integer inference/export."""
from __future__ import annotations

import argparse
from collections import Counter
import json
import math
from pathlib import Path

import torch

from calibration import REPO_ROOT, json_bytes, load_checkpoint, sha256, validate_metadata
from model import LeNet5
from observe_activations import ACTIVATIONS, WEIGHTS, weight_statistics

POLICY = {
    'status': 'candidate PTQ policy; not an accepted ADR decision',
    'dtype': 'signed INT8', 'symmetric': True, 'zero_point': 0,
    'qmin': -127, 'qmax': 127, 'scale': 'absmax / 127',
    'rounding': 'round-half-up (ties toward positive infinity)',
    'activation': 'per_tensor', 'weight': 'per_output_channel', 'weight_axis': 0,
    'arithmetic': 'CPU float64 division and rounding; clip before int8 cast',
    'zero_range_policy': 'error; no fallback scale',
    'adr_requantization': 'unchanged; not implemented here',
}


def candidate_scale(minimum, maximum, absmax):
    low, high, absolute = [torch.as_tensor(v, dtype=torch.float64) for v in
                           (minimum, maximum, absmax)]
    if not (low.shape == high.shape == absolute.shape) or not low.numel():
        raise ValueError('Invalid extrema shapes')
    if not all(torch.isfinite(t).all() for t in (low, high, absolute)):
        raise ValueError('NaN/Inf in extrema')
    if (low > high).any() or not torch.equal(absolute, torch.maximum(low.abs(), high.abs())):
        raise ValueError('Inconsistent min/max/absmax')
    if (low == high).any() or (absolute == 0).any():
        raise ValueError('Zero range or zero channel: explicit fallback decision required')
    scale = absolute / 127
    if not torch.isfinite(scale).all() or (scale <= 0).any():
        raise ValueError('Unrepresentable positive scale')
    return scale


def scaled_values(value: torch.Tensor, scale, axis: int | None = None):
    if not value.is_floating_point() or not value.numel() or not torch.isfinite(value).all():
        raise ValueError('Expected nonempty finite float tensor; NaN/Inf rejected')
    value = value.detach().to(device='cpu', dtype=torch.float64)
    scale = torch.as_tensor(scale, dtype=torch.float64, device='cpu')
    if not scale.numel() or not torch.isfinite(scale).all() or (scale <= 0).any():
        raise ValueError('Scale must be finite and positive')
    if axis is None:
        if scale.ndim != 0:
            raise ValueError('Per-tensor scale must be scalar')
    else:
        if axis != 0 or value.ndim < 2 or scale.shape != (value.shape[0],):
            raise ValueError('Per-output-channel scale requires axis=0 and one scale per output')
        scale = scale.reshape(-1, *([1] * (value.ndim - 1)))
    normalized = value / scale
    if not torch.isfinite(normalized).all():
        raise ValueError('Non-finite scaled values')
    return normalized, scale


def round_half_up(value: torch.Tensor) -> torch.Tensor:
    if not value.is_floating_point() or not torch.isfinite(value).all():
        raise ValueError('Rounding requires finite float values')
    # Equivalent to floor(x+0.5), without losing a just-below-tie bit during addition.
    floor = value.floor()
    return floor + ((value - floor) >= 0.5).to(value.dtype)


def quantize_int8(value: torch.Tensor, scale, axis: int | None = None) -> torch.Tensor:
    normalized, _ = scaled_values(value, scale, axis)
    return round_half_up(normalized).clamp(-127, 127).to(torch.int8)


def weight_metrics(value: torch.Tensor, quantized: torch.Tensor, scale) -> dict:
    normalized, broadcast_scale = scaled_values(value, scale, axis=0)
    rounded = round_half_up(normalized)
    clipped = (rounded < -127) | (rounded > 127)
    endpoints = (quantized == -127) | (quantized == 127)
    error = quantized.to(torch.float64) * broadcast_scale - value.detach().double().cpu()
    return {'elements': value.numel(), 'clipped_count': clipped.sum().item(),
            'clipping_rate': clipped.double().mean().item(),
            'endpoint_count': endpoints.sum().item(),
            'endpoint_rate': endpoints.double().mean().item(),
            'clipped_per_channel': clipped.flatten(1).sum(1).tolist(),
            'mae': error.abs().mean().item(), 'rmse': error.square().mean().sqrt().item(),
            'max_abs_error': error.abs().max().item(),
            'mae_per_channel': error.abs().flatten(1).mean(1).tolist()}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify_inputs(checkpoint_path: Path, statistics_path: Path, manifest_path: Path,
                  selected_path: Path, repo_root: Path = REPO_ROOT):
    # Missing statistics raises here. Never rebuild calibration or run the model.
    stats = json.loads(statistics_path.read_bytes())
    manifest = json.loads(manifest_path.read_bytes())
    selected = json.loads(selected_path.read_bytes())
    summary_path = manifest_path.with_name('summary.json')
    summary = json.loads(summary_path.read_bytes())
    checkpoint, digest = load_checkpoint(checkpoint_path)
    classes, mean, std = validate_metadata(checkpoint)
    require(digest == selected['checkpoint_sha256'] == stats['checkpoint']['sha256']
            == manifest['checkpoint']['sha256'], 'Checkpoint/statistics identity mismatch')
    require(stats['selected_model_sha256'] == sha256(selected_path), 'Selected model record mismatch')
    require(checkpoint.get('seed') == stats['checkpoint']['seed'] == 42
            and checkpoint.get('best_epoch') == stats['checkpoint']['epoch'] == 51,
            'Expected seed=42 epoch=51')
    require(stats['schema_version'] == manifest['schema_version'] == 1, 'Unsupported schema')
    require(classes == stats['class_names'] == manifest['class_names'], 'Class order mismatch')
    manifest_hash = sha256(manifest_path)
    require(manifest_hash == stats['calibration']['selection_manifest_sha256']
            == summary['selection_manifest_sha256'], 'Calibration manifest identity mismatch')
    for key in ('selection', 'split', 'preprocessing'):
        require(stats['calibration'][key] == manifest[key], f'Calibration {key} mismatch')
    require(manifest['preprocessing']['mean'] == mean and manifest['preprocessing']['std'] == std
            and manifest['preprocessing']['random_augmentation'] is False, 'Normalization mismatch')
    selection = manifest['selection']
    records = manifest['samples']
    require(manifest['split']['name'] == 'train' and selection['seed'] == 42,
            'Expected train-only selection with seed=42')
    require(len(records) == selection['count'] == stats['calibration']['checks']['samples_checked']
            and len(records) > 0, 'Sample count mismatch')
    require(Counter(s['class'] for s in records) ==
            Counter({c: selection['samples_per_class'] for c in classes}), 'Class counts mismatch')
    train_root = (repo_root / manifest['split']['data_dir'] / 'train').resolve()
    require(train_root.is_relative_to(repo_root.resolve()), 'Dataset outside repository')
    seen = set()
    for sample in records:
        path = (repo_root / sample['path']).resolve()
        require(path.is_relative_to(train_root) and path not in seen, 'Non-train or duplicate sample')
        require(0 <= sample['label'] < len(classes) and classes[sample['label']] == sample['class'],
                'Sample label mismatch')
        require(sha256(path) == sample['sha256'], 'Calibration image hash mismatch')
        seen.add(path)
    identity_files = [checkpoint_path, statistics_path, manifest_path, selected_path, summary_path]
    if 'manifest_path' in manifest['split']:
        split_path = repo_root / manifest['split']['manifest_path']
        require(sha256(split_path) == manifest['split']['manifest_sha256'], 'Split manifest mismatch')
        identity_files.append(split_path)
    for name in ('model.py', 'data.py', 'calibration.py', 'observe_activations.py'):
        require(stats['source_sha256'][name] == sha256(Path(__file__).with_name(name)),
                f'Statistics source mismatch: {name}')
    for name, digest in manifest['source_sha256'].items():
        require(stats['source_sha256'].get(name) == digest, 'Calibration source mismatch')
    settings = stats['observer_settings']
    require(settings['eval'] is True and settings['inference_mode'] is True
            and settings['clipping'] is False and settings['scales_computed'] is False,
            'Expected unclipped FP32 statistics')
    with torch.random.fork_rng(devices=[]):
        model = LeNet5(3, len(classes))
    model.load_state_dict(checkpoint['model_state'], strict=True)
    require(set(stats['weights']) == set(WEIGHTS), 'Weight layer set mismatch')
    for name in WEIGHTS:
        layer = model.get_submodule(name)
        require(weight_statistics(layer.weight, layer.bias) == stats['weights'][name],
                f'Weight statistics mismatch: {name}')
    shapes = {'input': [3, 32, 32], 'features.1': [6, 28, 28], 'features.4': [16, 10, 10],
              'classifier.2': [120], 'classifier.4': [84], 'classifier.5': [len(classes)]}
    require(set(stats['activations']) == set(shapes), 'Activation point set mismatch')
    for name, shape in shapes.items():
        s = stats['activations'][name]
        require(s['tensor_shape'] == ['N', *shape] and s['samples'] == len(records)
                and s['elements'] == len(records) * math.prod(shape)
                and s['updates'] > 0 and s['dtype'] == 'float32'
                and s['granularity'] == 'per_tensor', f'Activation metadata mismatch: {name}')
        require(s['zero_range'] == (s['min'] == s['max'])
                and s['all_zero'] == (s['min'] == s['max'] == 0), 'Range flag mismatch')
        if name in ACTIVATIONS[:-1]:
            require(s['min'] >= 0, 'Negative post-ReLU statistic')
    return checkpoint, stats, {str(p.resolve()): sha256(p) for p in identity_files}


def generate_candidates(checkpoint_path: Path, statistics_path: Path, manifest_path: Path,
                        selected_path: Path, *, repo_root: Path = REPO_ROOT):
    checkpoint, stats, inputs = verify_inputs(checkpoint_path, statistics_path, manifest_path,
                                              selected_path, repo_root)
    activations, weights, tensors = {}, {}, {}
    for name, s in stats['activations'].items():
        try:
            scale = candidate_scale(s['min'], s['max'], s['absmax']).item()
        except ValueError as exc:
            raise ValueError(f'{name}: {exc}') from exc
        activations[name] = {'scale': scale, 'zero_point': 0, 'axis': None,
                             'tensor_shape': s['tensor_shape'],
                             'observed_min': s['min'], 'observed_max': s['max'],
                             'clipping_rate': None, 'endpoint_rate': None,
                             'rate_status': 'Not measured: activation tensors/histograms not retained; no inference rerun'}
    for name in WEIGHTS:
        s = stats['weights'][name]
        try:
            scales = candidate_scale(s['min'], s['max'], s['absmax'])
        except ValueError as exc:
            raise ValueError(f'{name}: {exc}') from exc
        value = checkpoint['model_state'][name + '.weight']
        quantized = quantize_int8(value, scales, axis=0)
        tensors[name + '.weight'] = quantized
        weights[name] = {'scale': scales.tolist(), 'zero_point': [0] * len(scales), 'axis': 0,
                         'tensor_shape': list(value.shape),
                         'metrics': weight_metrics(value, quantized, scales)}
    require(all(sha256(Path(p)) == digest for p, digest in inputs.items()), 'Input changed during run')
    report = {'schema_version': 1, 'policy': POLICY.copy(), 'input_sha256': inputs,
              'checkpoint': stats['checkpoint'], 'class_names': stats['class_names'],
              'calibration': stats['calibration'], 'scale_transfer': stats['scale_transfer'],
              'activation_qparams': activations, 'weight_qparams': weights,
              'source_sha256': {'quantization.py': sha256(Path(__file__))},
              'torch_version': torch.__version__,
              'artifact_role': 'candidate software weight tensors only; not an executable INT8 model or hardware export'}
    return report, tensors


def save_candidates(report: dict, tensors: dict, output_dir: Path):
    output_dir.mkdir(parents=True, exist_ok=False)
    tensor_path = output_dir / 'candidate_weights_int8.pt'
    torch.save(tensors, tensor_path)
    report = {**report, 'weight_artifact': {'file': tensor_path.name, 'sha256': sha256(tensor_path)}}
    (output_dir / 'qparams.json').write_bytes(json_bytes(report))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('checkpoint', 'statistics', 'selection-manifest', 'selected-model', 'output-dir'):
        parser.add_argument('--' + name, type=Path, required=True)
    args = parser.parse_args()
    base = REPO_ROOT / 'cnn_pipeline/outputs/quantization'
    require(not args.output_dir.exists() and args.output_dir.resolve() != base
            and args.output_dir.resolve().is_relative_to(base), 'Use a new run directory under outputs/quantization')
    report, tensors = generate_candidates(args.checkpoint, args.statistics, args.selection_manifest,
                                          args.selected_model)
    require(len(report['class_names']) == 10 and report['calibration']['selection']['count'] == 1000
            and report['calibration']['selection']['samples_per_class'] == 100,
            'CLI requires existing 10x100 calibration selection')
    save_candidates(report, tensors, args.output_dir)
    print(f'Candidate qparams and five INT8 weight tensors saved: {args.output_dir}')
    for name, s in report['weight_qparams'].items():
        print(f'{name}: scale [{min(s["scale"]):.8g}, {max(s["scale"]):.8g}], '
              f'clipping={s["metrics"]["clipping_rate"]:.6%}')


if __name__ == '__main__':
    main()
