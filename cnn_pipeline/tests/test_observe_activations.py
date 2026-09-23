import json

import pytest
import torch
from PIL import Image
from torch import nn
from torch.utils.data import DataLoader, TensorDataset

from calibration import build_calibration_loader, check_batches, sha256, write_outputs
from model import LeNet5
from observe_activations import (TensorExtrema, activation_hooks, collect_statistics,
                                 observe_run, weight_statistics)


def test_extrema_independent_updates():
    obs = TensorExtrema()
    obs.update(torch.tensor([[-3., 2.], [1., 0.]]))
    obs.update(torch.tensor([[4., -1.]]))
    result = obs.report()
    assert (result['min'], result['max'], result['absmax']) == (-3, 4, 4)
    assert result['negative_elements'] == 2
    assert result['samples'] == 3 and result['elements'] == 6
    assert result['batch_sizes'] == [1, 2]


@pytest.mark.parametrize('value', [0., 5.])
def test_zero_and_constant_ranges(value):
    obs = TensorExtrema()
    obs.update(torch.full((2, 3), value))
    assert obs.report()['zero_range']
    assert obs.report()['all_zero'] == (value == 0)


def test_empty_observer_and_empty_tensor():
    obs = TensorExtrema()
    with pytest.raises(ValueError, match='Empty observer'):
        obs.report()
    with pytest.raises(ValueError, match='Empty observation'):
        obs.update(torch.empty(0, 2))


@pytest.mark.parametrize('bad', [float('nan'), float('inf'), -float('inf')])
def test_nonfinite_activation_weight_and_bias(bad):
    with pytest.raises(ValueError, match='NaN/Inf'):
        TensorExtrema().update(torch.tensor([[bad]]))
    with pytest.raises(ValueError, match='NaN/Inf'):
        weight_statistics(torch.tensor([[bad]]), None)
    with pytest.raises(ValueError, match='NaN/Inf'):
        weight_statistics(torch.ones(1, 2), torch.tensor([bad]))


@pytest.mark.parametrize('shape', [(3, 2), (3, 1, 1, 2)])
def test_output_channel_axis_and_zero_channel(shape):
    weight = torch.tensor([[-2., 1.], [0., 0.], [3., 7.]]).reshape(shape)
    stats = weight_statistics(weight, torch.tensor([-0.5, 0., 1.]))
    assert stats['min'] == [-2, 0, 3]
    assert stats['max'] == [1, 0, 7]
    assert stats['absmax'] == [2, 0, 7]
    assert stats['all_zero_channels'] == [1]
    assert stats['zero_range_channels'] == [1]
    assert stats['channel_axis'] == 0
    assert stats['bias_fp32'] == [-0.5, 0, 1]


def test_immediate_hooks_preserve_pre_and_post_inplace_relu():
    model = nn.Sequential(nn.Identity(), nn.ReLU(inplace=True))
    values = torch.tensor([[-4., 2.]])
    with activation_hooks(model, ('0', '1')) as observers:
        model(values)
    assert values.tolist() == [[0, 2]]
    assert observers['0'].report()['min'] == -4
    assert observers['1'].report()['min'] == 0
    assert all(not m._forward_hooks for m in model.modules())
    with pytest.raises(ValueError, match='NaN/Inf'):
        with activation_hooks(model, ('0', '1')):
            model(torch.tensor([[float('nan'), 0.]]))
    assert all(not m._forward_hooks for m in model.modules())


def test_eval_inference_negative_logits_and_unchanged_model():
    model = LeNet5(3, 2)
    with torch.no_grad():
        for p in model.parameters():
            p.zero_()
        model.classifier[5].bias.copy_(torch.tensor([-3., 2.]))
    model.train()
    model.features[0].eval()
    modes = [m.training for m in model.modules()]
    before = {k: v.clone() for k, v in model.state_dict().items()}
    def verify_mode(module, inputs):
        assert not any(m.training for m in module.modules())
        assert torch.is_inference_mode_enabled()
    handle = model.register_forward_pre_hook(verify_mode)
    loader = DataLoader(TensorDataset(torch.zeros(3, 3, 32, 32), torch.zeros(3)), batch_size=2)
    try:
        a, b = collect_statistics(model, loader), collect_statistics(model, loader)
    finally:
        handle.remove()
    assert a == b
    assert a['activations']['classifier.5']['min'] == -3
    assert a['activations']['classifier.5']['max'] == 2
    assert a['activations']['classifier.5']['negative_elements'] == 3
    assert all(torch.equal(v, model.state_dict()[k]) for k, v in before.items())
    assert [m.training for m in model.modules()] == modes
    assert all(p.grad is None for p in model.parameters())
    assert all(not m._forward_hooks for m in model.modules())


@pytest.fixture
def run_inputs(tmp_path):
    for name in ('a', 'b'):
        folder = tmp_path / 'data/train' / name
        folder.mkdir(parents=True)
        for i in range(3):
            Image.new('RGB', (40, 36), (i * 70, 50, 20)).save(folder / f'{i}.png')
    with torch.random.fork_rng(devices=[]):
        torch.manual_seed(7)
        model = LeNet5(3, 2)
    checkpoint = tmp_path / 'checkpoint.pt'
    torch.save({'model_name': 'LeNet5ReLUMaxPool', 'input_channels': 3,
                'image_size': [32, 32], 'class_names': ['a', 'b'],
                'mean': [0.1, 0.2, 0.3], 'std': [0.5, 0.5, 0.5],
                'seed': 42, 'best_epoch': 51, 'model_state': model.state_dict()}, checkpoint)
    selected = tmp_path / 'selected_model.json'
    selected.write_text(json.dumps({'checkpoint_sha256': sha256(checkpoint)}))
    bundle = build_calibration_loader(checkpoint, tmp_path / 'data', 2, 42, 2, repo_root=tmp_path)
    output = tmp_path / 'selection'
    write_outputs(bundle, check_batches(bundle), output)
    return checkpoint, selected, tmp_path / 'data', output / 'selection_manifest.json', tmp_path


def run(inputs):
    checkpoint, selected, data, manifest, root = inputs
    return observe_run(checkpoint, selected, data, manifest, 2,
                       samples_per_class=2, repo_root=root)


def test_same_selection_reproducible_and_checkpoint_unchanged(run_inputs):
    before = run_inputs[0].read_bytes()
    a, b = run(run_inputs), run(run_inputs)
    assert a == b
    assert run_inputs[0].read_bytes() == before
    assert a['calibration']['checks']['samples_checked'] == 4
    assert a['calibration']['selection_manifest_sha256'] == sha256(run_inputs[3])
    assert a['observer_settings']['scales_computed'] is False


def test_selected_checkpoint_hash_mismatch(run_inputs):
    run_inputs[1].write_text(json.dumps({'checkpoint_sha256': '0' * 64}))
    with pytest.raises(ValueError, match='Selected checkpoint SHA256'):
        run(run_inputs)


@pytest.mark.parametrize('field', ['seed', 'samples', 'image_hash', 'preprocessing'])
def test_manifest_mismatch_even_if_summary_hash_updated(run_inputs, field):
    path = run_inputs[3]
    saved = json.loads(path.read_text())
    if field == 'seed':
        saved['selection']['seed'] = 123
    elif field == 'samples':
        saved['samples'].reverse()
    elif field == 'image_hash':
        saved['samples'][0]['sha256'] = '0' * 64
    else:
        saved['preprocessing']['mean'][0] = 0.9
    path.write_text(json.dumps(saved))
    summary = path.with_name('summary.json')
    summary.write_text(json.dumps({'selection_manifest_sha256': sha256(path)}))
    with pytest.raises(ValueError, match='selection manifest mismatch'):
        run(run_inputs)


def test_manifest_file_hash_mismatch(run_inputs):
    path = run_inputs[3]
    path.write_text(path.read_text() + ' ')
    with pytest.raises(ValueError, match='manifest SHA256 mismatch'):
        run(run_inputs)
