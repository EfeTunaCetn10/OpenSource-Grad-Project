import json
import torch
from PIL import Image
from torchvision import transforms
from data import build_insect_loaders


def test_only_color_jitter_removed_and_eval_unchanged(tmp_path):
    for split in ('train', 'val', 'test'):
        for label in ('a', 'b'):
            folder = tmp_path / split / label
            folder.mkdir(parents=True)
            Image.new('RGB', (40, 32), (20, 80, 160)).save(folder / 'image.png')
    stats = tmp_path / 'stats.json'
    stats.write_text(json.dumps({'mean': [0.2, 0.3, 0.4], 'std': [0.5, 0.6, 0.7]}))
    default = build_insect_loaders(tmp_path, stats, 2, 0, False, train_resize=True)
    disabled = build_insect_loaders(tmp_path, stats, 2, 0, False,
                                    train_resize=True, train_color_jitter=False)
    original = default.train_loader.dataset.transform.transforms
    changed = disabled.train_loader.dataset.transform.transforms
    assert [type(t) for t in original] == [transforms.Resize, transforms.RandomHorizontalFlip,
        transforms.ColorJitter, transforms.ToTensor, transforms.Normalize]
    assert [type(t) for t in changed] == [transforms.Resize, transforms.RandomHorizontalFlip,
        transforms.ToTensor, transforms.Normalize]
    assert [repr(t) for t in original if not isinstance(t, transforms.ColorJitter)] == [repr(t) for t in changed]
    for name in ('val_loader', 'test_loader'):
        assert torch.equal(getattr(default, name).dataset[0][0], getattr(disabled, name).dataset[0][0])
    torch.manual_seed(42)
    output = disabled.train_loader.dataset[0][0]
    expected = torch.tensor([(20/255-.2)/.5, (80/255-.3)/.6, (160/255-.4)/.7])
    torch.testing.assert_close(output[:, 0, 0], expected)
    assert output.shape == (3, 32, 32)
