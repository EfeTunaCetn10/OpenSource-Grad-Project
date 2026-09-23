import hashlib
import json
from pathlib import Path

import pytest
import torch
from PIL import Image
from torchvision import transforms

from calibration import (build_calibration_loader, check_batches, json_bytes,
                         write_outputs)
from data import build_insect_eval_transform


@pytest.fixture
def inputs(tmp_path):
    data_dir = tmp_path / "data"
    samples = []
    for label, name in enumerate(("a", "b")):
        for i in range(12):
            path = data_dir / "train" / name / f"image_{i:02d}.png"
            path.parent.mkdir(parents=True, exist_ok=True)
            # Grayscale deliberately exercises mandatory RGB conversion.
            image = Image.new("L", (40, 24), i * 20)
            image.putpixel((0, 0), 255)
            image.save(path)
            samples.append({"destination": path.relative_to(data_dir).as_posix(),
                            "split": "train", "class": name,
                            "day": f"2026010{1 + i // 4}",
                            "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    checkpoint = tmp_path / "checkpoint.pt"
    torch.save({"model_name": "LeNet5ReLUMaxPool", "input_channels": 3,
                "image_size": [32, 32], "class_names": ["a", "b"],
                "mean": [0.1, 0.2, 0.3], "std": [0.5, 0.4, 0.3]}, checkpoint)
    (data_dir / "split_manifest.json").write_text(json.dumps({
        "class_to_idx": {"a": 0, "b": 1}, "samples": samples}))
    return checkpoint, data_dir, tmp_path


def build(inputs, **kwargs):
    checkpoint, data_dir, root = inputs
    return build_calibration_loader(checkpoint, data_dir, repo_root=root,
                                    **{"samples_per_class": 5, **kwargs})


def change_manifest(inputs, mutate):
    path = inputs[1] / "split_manifest.json"
    payload = json.loads(path.read_text())
    mutate(payload)
    path.write_text(json.dumps(payload))


def test_reproducible_selection_order_and_batches(inputs):
    a, b = build(inputs, seed=42, batch_size=3), build(inputs, seed=42, batch_size=3)
    assert json_bytes(a.manifest) == json_bytes(b.manifest)
    assert len({s['path'] for s in a.manifest['samples']}) == 10
    for (ax, ay), (bx, by) in zip(a.loader, b.loader):
        assert torch.equal(ax, bx) and torch.equal(ay, by)
    assert [len(x) for x, _ in a.loader] == [3, 3, 3, 1]
    changed = build(inputs, seed=123)
    assert {s['path'] for s in a.manifest['samples']} != {
        s['path'] for s in changed.manifest['samples']}


def test_day_coverage_uses_metadata_not_filename(inputs):
    bundle = build(inputs, samples_per_class=3)
    for name in ("a", "b"):
        days = {s['capture_day'] for s in bundle.manifest['samples'] if s['class'] == name}
        assert days == {"20260101", "20260102", "20260103"}
        assert bundle.manifest['selection']['strategy_by_class'][name].startswith('seeded_capture_day')


def test_train_only_no_eval_directories_needed(inputs):
    # No val/test directories exist. Adding corrupt eval images must be irrelevant.
    a = build(inputs)
    for split in ('val', 'test'):
        path = inputs[1] / split / 'a' / 'bad.png'
        path.parent.mkdir(parents=True)
        path.write_bytes(b'not an image')
    b = build(inputs)
    assert a.manifest == b.manifest
    assert all(s['path'].startswith('data/train/') for s in b.manifest['samples'])
    assert check_batches(b)['samples_checked'] == 10


def test_shared_transform_no_augmentation_rgb_shape_and_normalization(inputs):
    bundle = build(inputs)
    transform = bundle.loader.dataset.dataset.transform
    shared = build_insect_eval_transform([0.1, 0.2, 0.3], [0.5, 0.4, 0.3])
    assert repr(transform) == repr(shared)
    assert [type(t) for t in transform.transforms] == [
        transforms.Resize, transforms.ToTensor, transforms.Normalize]
    x, _ = bundle.loader.dataset[0]
    assert x.shape == (3, 32, 32) and x.dtype == torch.float32
    assert torch.equal(x, bundle.loader.dataset[0][0])
    # Independent known pixel check: resize of a constant black image stays black.
    black = transform(Image.new('RGB', (64, 48), 'black'))
    expected = torch.tensor([-0.1 / 0.5, -0.2 / 0.4, -0.3 / 0.3])
    torch.testing.assert_close(black[:, 16, 16], expected)
    summary = check_batches(bundle)
    assert summary['samples_checked'] == 10 and summary['dtype'] == 'float32'


def test_class_order_mismatch(inputs):
    checkpoint = torch.load(inputs[0], weights_only=True)
    checkpoint['class_names'] = ['b', 'a']
    torch.save(checkpoint, inputs[0])
    with pytest.raises(ValueError, match='class order'):
        build(inputs)


def test_insufficient_class_samples(inputs):
    with pytest.raises(ValueError, match='Class a: requested 13.*only 12'):
        build(inputs, samples_per_class=13)


@pytest.mark.parametrize('mode', ['missing_manifest', 'missing_day', 'missing_hash'])
def test_missing_day_fallback_is_explicit_and_reproducible(inputs, mode):
    if mode == 'missing_manifest':
        (inputs[1] / 'split_manifest.json').unlink()
    else:
        key = 'day' if mode == 'missing_day' else 'sha256'
        change_manifest(inputs, lambda p: [s.pop(key) for s in p['samples']])
    a, b = build(inputs), build(inputs)
    assert a.manifest == b.manifest
    assert a.manifest['limitations']
    assert set(a.manifest['selection']['strategy_by_class'].values()) == {
        'seeded_random_without_replacement'}
    assert all(s['capture_day'] is None for s in a.manifest['samples'])


def test_split_membership_conflict_rejected(inputs):
    change_manifest(inputs, lambda p: p['samples'][0].update(split='val'))
    with pytest.raises(ValueError, match='train membership'):
        build(inputs)


def test_selected_image_hash_mismatch_rejected(inputs):
    change_manifest(inputs, lambda p: [s.update(sha256='0' * 64) for s in p['samples']])
    with pytest.raises(ValueError, match='Image SHA256'):
        build(inputs)


def test_train_symlink_escape_rejected(inputs):
    path = inputs[1] / 'train/a/image_00.png'
    outside = inputs[1] / 'val.png'
    path.rename(outside)
    path.symlink_to(outside)
    with pytest.raises(ValueError, match='escapes train'):
        build(inputs)


def test_manifest_hash_paths_and_no_overwrite(inputs):
    bundle = build(inputs)
    output = inputs[2] / 'outputs/run1'
    checks = check_batches(bundle)
    summary = write_outputs(bundle, checks, output)
    raw = (output / 'selection_manifest.json').read_bytes()
    assert hashlib.sha256(raw).hexdigest() == summary['selection_manifest_sha256']
    assert set(p.name for p in output.iterdir()) == {'selection_manifest.json', 'summary.json'}
    for sample in bundle.manifest['samples']:
        assert not Path(sample['path']).is_absolute()
        assert hashlib.sha256((inputs[2] / sample['path']).read_bytes()).hexdigest() == sample['sha256']
    with pytest.raises(FileExistsError):
        write_outputs(bundle, checks, output)
    assert (output / 'selection_manifest.json').read_bytes() == raw


@pytest.mark.parametrize('std', [[0, 1, 1], [float('nan'), 1, 1]])
def test_invalid_checkpoint_normalization(inputs, std):
    checkpoint = torch.load(inputs[0], weights_only=True)
    checkpoint['std'] = std
    torch.save(checkpoint, inputs[0])
    with pytest.raises(ValueError, match='std must be positive'):
        build(inputs)


def test_batch_range_guard(inputs):
    bundle = build(inputs)
    bundle.loader.dataset.dataset.transform.transforms.append(lambda x: x + 100)
    with pytest.raises(ValueError, match='outside normalized'):
        check_batches(bundle)
