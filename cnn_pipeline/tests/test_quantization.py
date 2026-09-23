import json

import pytest
import torch
from PIL import Image

from calibration import build_calibration_loader, check_batches, json_bytes, sha256, write_outputs
from model import LeNet5
from observe_activations import observe_run
from quantization import (candidate_scale, generate_candidates, quantize_int8,
                          round_half_up, save_candidates, weight_metrics)


def test_half_up_signed_ties():
    x = torch.tensor([-2.5, -1.5, -0.5, 0., 0.5, 1.5, 2.5], dtype=torch.float64)
    assert quantize_int8(x, 1.).tolist() == [-2, -1, 0, 0, 1, 2, 3]
    assert torch.equal(x, torch.tensor([-2.5, -1.5, -0.5, 0., 0.5, 1.5, 2.5], dtype=torch.float64))
    below = torch.nextafter(torch.tensor(0.5, dtype=torch.float64), torch.tensor(0., dtype=torch.float64))
    assert round_half_up(below).item() == 0


def test_clip_before_int8_cast_and_endpoints():
    x = torch.tensor([[-1000., -128., -127., 0., 127., 128., 1000.]])
    q = quantize_int8(x, 1.)
    assert q.dtype == torch.int8
    assert q.tolist() == [[-127, -127, -127, 0, 127, 127, 127]]
    m = weight_metrics(x, q, [1.])
    assert m['clipped_count'] == 4 and m['endpoint_count'] == 6
    assert m['clipping_rate'] == pytest.approx(4 / 7)


@pytest.mark.parametrize('shape', [(2, 3), (2, 1, 1, 3)])
def test_per_channel_axis_and_error(shape):
    x = torch.tensor([[-127., 0., 127.], [-254., 1., 254.]]).reshape(shape)
    s = candidate_scale([-127, -254], [127, 254], [127, 254])
    assert s.tolist() == [1, 2]
    q = quantize_int8(x, s, axis=0)
    assert q.shape == x.shape
    assert q.reshape(2, 3).tolist() == [[-127, 0, 127], [-127, 1, 127]]
    assert weight_metrics(x, q, s)['mae'] == pytest.approx(1 / 6)
    with pytest.raises(ValueError, match='axis=0'):
        quantize_int8(x, s, axis=1)


def test_per_tensor_scale_signed_activation():
    s = candidate_scale(-254., 127., 254.)
    assert s.ndim == 0 and s.item() == 2.
    assert quantize_int8(torch.tensor([-254., -1., 1., 127.]), s).tolist() == [-127, 0, 1, 64]


@pytest.mark.parametrize('low,high,absolute', [(0, 0, 0), (5, 5, 5), ([0, -1], [0, 1], [0, 1])])
def test_zero_range_requires_decision(low, high, absolute):
    with pytest.raises(ValueError, match='fallback decision'):
        candidate_scale(low, high, absolute)


@pytest.mark.parametrize('bad', [float('nan'), float('inf'), -float('inf')])
def test_nonfinite_rejected(bad):
    with pytest.raises(ValueError, match='NaN/Inf'):
        quantize_int8(torch.tensor([bad]), 1.)
    with pytest.raises(ValueError, match='NaN/Inf'):
        candidate_scale(-1, bad, 1)
    with pytest.raises(ValueError, match='finite'):
        quantize_int8(torch.ones(1), bad)


@pytest.mark.parametrize('scale', [0., -1., [1., 2.]])
def test_invalid_scale(scale):
    with pytest.raises(ValueError):
        quantize_int8(torch.ones(2), scale)


@pytest.fixture
def artifacts(tmp_path):
    for name in ('a', 'b'):
        folder = tmp_path / 'data/train' / name
        folder.mkdir(parents=True)
        for i in range(3):
            Image.new('RGB', (32, 32), (30 + i * 70, 80, 120)).save(folder / f'{i}.png')
    with torch.random.fork_rng(devices=[]):
        torch.manual_seed(42)
        model = LeNet5(3, 2)
    cp = tmp_path / 'checkpoint.pt'
    torch.save({'model_name': 'LeNet5ReLUMaxPool', 'input_channels': 3,
                'image_size': [32, 32], 'class_names': ['a', 'b'],
                'mean': [0.1] * 3, 'std': [0.5] * 3, 'seed': 42, 'best_epoch': 51,
                'model_state': model.state_dict()}, cp)
    selected = tmp_path / 'selected_model.json'
    selected.write_bytes(json_bytes({'checkpoint_sha256': sha256(cp)}))
    bundle = build_calibration_loader(cp, tmp_path / 'data', 2, 42, 2, repo_root=tmp_path)
    output = tmp_path / 'calibration'
    write_outputs(bundle, check_batches(bundle), output)
    manifest = output / 'selection_manifest.json'
    stats = observe_run(cp, selected, tmp_path / 'data', manifest, 2,
                        samples_per_class=2, repo_root=tmp_path)
    stats_path = tmp_path / 'statistics.json'
    stats_path.write_bytes(json_bytes(stats))
    return cp, stats_path, manifest, selected, tmp_path


def generate(artifacts):
    return generate_candidates(*artifacts[:4], repo_root=artifacts[4])


def test_artifacts_identity_immutability_and_no_overwrite(artifacts):
    paths = list(artifacts[:4]) + [artifacts[2].with_name('summary.json')]
    before = {p: p.read_bytes() for p in paths}
    report, tensors = generate(artifacts)
    assert report['policy']['status'].startswith('candidate')
    assert len(tensors) == 5 and all(t.dtype == torch.int8 for t in tensors.values())
    assert all(s['metrics']['clipped_count'] == 0 for s in report['weight_qparams'].values())
    output = artifacts[4] / 'new_run'
    save_candidates(report, tensors, output)
    loaded = torch.load(output / 'candidate_weights_int8.pt', weights_only=True)
    assert all(torch.equal(t, loaded[k]) for k, t in tensors.items())
    assert all(p.read_bytes() == raw for p, raw in before.items())
    with pytest.raises(FileExistsError):
        save_candidates(report, tensors, output)


@pytest.mark.parametrize('field', ['checkpoint', 'manifest', 'weight', 'activation', 'source'])
def test_bad_statistics_identity_or_content(artifacts, field):
    path = artifacts[1]
    stats = json.loads(path.read_text())
    if field == 'checkpoint':
        stats['checkpoint']['sha256'] = '0' * 64
    elif field == 'manifest':
        stats['calibration']['selection_manifest_sha256'] = '0' * 64
    elif field == 'weight':
        stats['weights']['features.0']['absmax'][0] += 1
    elif field == 'activation':
        stats['activations']['input']['absmax'] += 1
    else:
        stats['source_sha256']['model.py'] = '0' * 64
    path.write_bytes(json_bytes(stats))
    with pytest.raises(ValueError):
        generate(artifacts)


def test_changed_checkpoint_rejected(artifacts):
    cp = torch.load(artifacts[0], weights_only=True)
    cp['model_state']['features.0.weight'][0, 0, 0, 0] += 1
    torch.save(cp, artifacts[0])
    with pytest.raises(ValueError, match='identity mismatch'):
        generate(artifacts)


def test_changed_image_rejected_without_reselection(artifacts):
    manifest = json.loads(artifacts[2].read_text())
    (artifacts[4] / manifest['samples'][0]['path']).write_bytes(b'changed')
    with pytest.raises(ValueError, match='image hash mismatch'):
        generate(artifacts)


def test_missing_statistics_does_not_recalibrate(artifacts):
    artifacts[1].unlink()
    with pytest.raises(FileNotFoundError):
        generate(artifacts)
