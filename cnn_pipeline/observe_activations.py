"""Auditable FP32 calibration extrema only; no quantization policy is selected."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import json
from pathlib import Path

import torch
from torch import nn

from calibration import (REPO_ROOT, build_calibration_loader, check_batches,
                         json_bytes, load_checkpoint, relative_path, sha256,
                         validate_metadata)
from model import LeNet5

ACTIVATIONS = ('features.1', 'features.4', 'classifier.2', 'classifier.4', 'classifier.5')
WEIGHTS = ('features.0', 'features.3', 'classifier.1', 'classifier.3', 'classifier.5')


def finite_tensor(value: torch.Tensor) -> None:
    if value.numel() == 0:
        raise ValueError('Empty observation tensor')
    if value.dtype != torch.float32:
        raise ValueError('Expected FP32 observation tensor')
    if not torch.isfinite(value).all().item():
        raise ValueError('NaN/Inf in observation tensor')


class TensorExtrema:
    """Online extrema across all elements/batches; stores scalars, never aliases."""

    def __init__(self) -> None:
        self.minimum = float('inf')
        self.maximum = -float('inf')
        self.elements = self.samples = self.updates = self.negatives = 0
        self.shape = None
        self.batch_sizes: set[int] = set()

    def update(self, value: torch.Tensor) -> None:
        finite_tensor(value)
        if value.ndim < 2:
            raise ValueError('Expected batch dimension and at least one feature dimension')
        shape = list(value.shape[1:])
        if self.shape is not None and self.shape != shape:
            raise ValueError('Observation shape changed')
        # .item() reduces immediately, before a later inplace ReLU can mutate storage.
        low, high = value.amin().item(), value.amax().item()
        self.minimum, self.maximum = min(self.minimum, low), max(self.maximum, high)
        self.elements += value.numel()
        self.samples += value.shape[0]
        self.updates += 1
        self.negatives += (value < 0).sum().item()
        self.shape = shape
        self.batch_sizes.add(value.shape[0])

    def report(self) -> dict:
        if not self.updates:
            raise ValueError('Empty observer: no updates')
        return {'min': self.minimum, 'max': self.maximum,
                'absmax': max(abs(self.minimum), abs(self.maximum)),
                'zero_range': self.minimum == self.maximum,
                'all_zero': self.minimum == self.maximum == 0,
                'negative_elements': self.negatives, 'elements': self.elements,
                'samples': self.samples, 'updates': self.updates,
                'tensor_shape': ['N', *self.shape], 'batch_sizes': sorted(self.batch_sizes),
                'dtype': 'float32', 'granularity': 'per_tensor'}


@contextmanager
def activation_hooks(model: nn.Module, names=ACTIVATIONS):
    observers = {name: TensorExtrema() for name in names}
    handles = []
    try:
        for name, observer in observers.items():
            def hook(module, inputs, output, observer=observer):
                observer.update(output)
            handles.append(model.get_submodule(name).register_forward_hook(hook))
        yield observers
    finally:
        for handle in handles:
            handle.remove()


def weight_statistics(weight: torch.Tensor, bias: torch.Tensor | None) -> dict:
    finite_tensor(weight)
    if weight.ndim not in (2, 4):
        raise ValueError('Expected Linear or Conv2d weights')
    rows = weight.detach().flatten(start_dim=1)
    low, high = rows.amin(dim=1), rows.amax(dim=1)
    absolute = torch.maximum(low.abs(), high.abs())
    if bias is not None:
        finite_tensor(bias)
        if tuple(bias.shape) != (weight.shape[0],):
            raise ValueError('Bias shape does not match output channels')
    return {'tensor_shape': list(weight.shape), 'dtype': 'float32',
            'granularity': 'per_output_channel', 'channel_axis': 0,
            'min': low.tolist(), 'max': high.tolist(), 'absmax': absolute.tolist(),
            'zero_range_channels': (low == high).nonzero().flatten().tolist(),
            'all_zero_channels': (absolute == 0).nonzero().flatten().tolist(),
            'bias_fp32': None if bias is None else bias.detach().tolist()}


def collect_statistics(model: nn.Module, loader) -> dict:
    """Run eval/inference, preserving parameters, buffers and original train flags."""
    state = {name: value.detach().clone() for name, value in model.state_dict().items()}
    modes = {module: module.training for module in model.modules()}
    inputs = TensorExtrema()
    try:
        weights = {name: weight_statistics(model.get_submodule(name).weight,
                                          model.get_submodule(name).bias) for name in WEIGHTS}
        model.eval()
        with activation_hooks(model) as observers, torch.inference_mode():
            for images, _ in loader:
                inputs.update(images)
                model(images)
            activations = {'input': inputs.report(),
                           **{name: observer.report() for name, observer in observers.items()}}
        for name, stats in activations.items():
            if stats['samples'] != inputs.samples or stats['updates'] != inputs.updates:
                raise ValueError(f'Observation coverage mismatch: {name}')
            if name in ACTIVATIONS[:-1] and stats['min'] < 0:
                raise ValueError(f'Negative post-ReLU observation: {name}')
        warnings = [f'{name}: zero activation range; scale fallback unresolved'
                    for name, s in activations.items() if s['zero_range']]
        warnings += [f'{name}: zero weight channels {s["all_zero_channels"]}; scale fallback unresolved'
                     for name, s in weights.items() if s['all_zero_channels']]
        if activations['classifier.5']['negative_elements'] == 0:
            warnings.append('No negative final logits observed; not clipped or forced negative')
        return {'activations': activations, 'weights': weights, 'warnings': warnings}
    finally:
        for module, mode in modes.items():
            module.training = mode
        if any(not torch.equal(value, model.state_dict()[name]) for name, value in state.items()):
            raise RuntimeError('Model state changed during observation')


def verify_selection(bundle, manifest_path: Path) -> str:
    raw = manifest_path.read_bytes()
    saved = json.loads(raw)
    digest = hashlib.sha256(raw).hexdigest()
    summary = json.loads(manifest_path.with_name('summary.json').read_text())
    if summary['selection_manifest_sha256'] != digest:
        raise ValueError('Calibration selection manifest SHA256 mismatch')
    # Ordered records include actual image hashes. Also pin settings, preprocessing,
    # split identity, versions and source hashes; do not silently accept drift.
    if saved != bundle.manifest:
        differing = sorted(k for k in set(saved) | set(bundle.manifest)
                           if saved.get(k) != bundle.manifest.get(k))
        raise ValueError(f'Calibration selection manifest mismatch: {differing}')
    return digest


def observe_run(checkpoint_path: Path, selected_model_path: Path, data_dir: Path,
                manifest_path: Path, batch_size: int = 32, *, samples_per_class: int = 100,
                seed: int = 42, repo_root: Path = REPO_ROOT) -> dict:
    checkpoint, digest = load_checkpoint(checkpoint_path)
    selected_raw = selected_model_path.read_bytes()
    selected = json.loads(selected_raw)
    if digest != selected['checkpoint_sha256']:
        raise ValueError('Selected checkpoint SHA256 mismatch')
    if checkpoint.get('seed') != 42 or checkpoint.get('best_epoch') != 51:
        raise ValueError('Expected selected seed=42, epoch=51 checkpoint')
    classes, _, _ = validate_metadata(checkpoint)
    bundle = build_calibration_loader(checkpoint_path, data_dir, samples_per_class,
                                      seed, batch_size, repo_root=repo_root)
    if bundle.manifest['checkpoint']['sha256'] != digest:
        raise ValueError('Checkpoint changed while preparing loader')
    manifest_hash = verify_selection(bundle, manifest_path)
    checks = check_batches(bundle)
    with torch.random.fork_rng(devices=[]):
        model = LeNet5(input_channels=3, num_classes=len(classes))
    model.load_state_dict(checkpoint['model_state'], strict=True)
    statistics = collect_statistics(model, bundle.loader)
    if statistics['activations']['input']['samples'] != checks['samples_checked']:
        raise ValueError('Observed sample count differs from validated selection')
    if sha256(checkpoint_path) != digest:
        raise ValueError('Checkpoint changed during observation')
    return {'schema_version': 1,
            'checkpoint': {'path': relative_path(checkpoint_path, repo_root), 'sha256': digest,
                           'seed': 42, 'epoch': 51},
            'selected_model_sha256': hashlib.sha256(selected_raw).hexdigest(),
            'calibration': {'selection_manifest_path': relative_path(manifest_path, repo_root),
                            'selection_manifest_sha256': manifest_hash,
                            'selection': bundle.manifest['selection'],
                            'split': bundle.manifest['split'],
                            'preprocessing': bundle.manifest['preprocessing'], 'checks': checks,
                            'limitations': bundle.manifest['limitations']},
            'class_names': classes, 'versions': bundle.manifest['versions'],
            'source_sha256': {**bundle.manifest['source_sha256'],
                              'model.py': sha256(Path(__file__).with_name('model.py')),
                              'observe_activations.py': sha256(Path(__file__))},
            'observer_settings': {'implementation': 'immediate FP32 extrema; no quantized runtime',
                                  'activation_reduction': 'all tensor elements across all batches',
                                  'weight_reduction': 'all axes except output-channel axis 0',
                                  'moving_average': False, 'clipping': False,
                                  'epsilon': None, 'qmin': None, 'qmax': None,
                                  'scale_denominator': None, 'float_to_integer_rounding': None,
                                  'scales_computed': False, 'device': 'cpu',
                                  'threads': torch.get_num_threads(),
                                  'deterministic_algorithms': torch.are_deterministic_algorithms_enabled(),
                                  'mkldnn_enabled': torch.backends.mkldnn.enabled,
                                  'eval': True, 'inference_mode': True},
            'scale_transfer': {'status': 'proposed; RTL boundary agreement still required',
                               'features.2': 'preserve features.1 scale/zero-point through MaxPool',
                               'features.5': 'preserve features.4 scale/zero-point through MaxPool',
                               'classifier.0': 'preserve pooled features.4 scale/zero-point and CHW order',
                               'observation_points_are_final_boundaries': False},
            **statistics}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('checkpoint', 'selected-model', 'data-dir', 'selection-manifest', 'output-dir'):
        parser.add_argument(f'--{name}', type=Path, required=True)
    parser.add_argument('--batch-size', type=int, default=32)
    parser.add_argument('--threads', type=int, default=2)
    args = parser.parse_args()
    if args.output_dir.exists():
        parser.error('Refusing to overwrite existing output directory')
    output = args.output_dir.resolve()
    if not output.is_relative_to(REPO_ROOT / 'cnn_pipeline/outputs/activation_calibration'):
        parser.error('output-dir must be a new run under cnn_pipeline/outputs/activation_calibration')
    if args.threads <= 0:
        parser.error('threads must be positive')
    torch.set_num_threads(args.threads)
    torch.use_deterministic_algorithms(True)
    report = observe_run(args.checkpoint, args.selected_model, args.data_dir,
                         args.selection_manifest, args.batch_size)
    if len(report['class_names']) != 10 or report['calibration']['checks']['samples_checked'] != 1000:
        raise ValueError('This CLI requires 10 classes x 100 train samples, seed=42')
    args.output_dir.mkdir(parents=True, exist_ok=False)
    (args.output_dir / 'statistics.json').write_bytes(json_bytes(report))
    print(f'Observed 1000 train images. Report: {args.output_dir / "statistics.json"}')
    for name, values in report['activations'].items():
        print(f'{name}: [{values["min"]:.8g}, {values["max"]:.8g}]')


if __name__ == '__main__':
    main()
