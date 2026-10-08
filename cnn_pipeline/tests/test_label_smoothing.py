import pytest
import torch
from train import build_loss_functions


def test_training_smoothing_and_unsmoothed_validation():
    train, val = build_loss_functions(0.05)
    logits = torch.tensor([[2., -1., 0.]], dtype=torch.float64)
    targets = torch.tensor([0])
    logp = logits.log_softmax(1)[0]
    expected = -0.95 * logp[0] - 0.05 * logp.mean()
    assert train(logits, targets).item() == pytest.approx(expected.item())
    assert val(logits, targets).item() == pytest.approx(-logp[0].item())
    assert train(logits, targets) != val(logits, targets)


def test_zero_smoothing_preserves_default_loss():
    train, val = build_loss_functions(0.0)
    x = torch.tensor([[1., 2.], [-2., 1.]])
    y = torch.tensor([0, 1])
    assert torch.equal(train(x, y), val(x, y))


@pytest.mark.parametrize('value', [-0.1, 1.1, float('nan'), float('inf')])
def test_invalid_smoothing(value):
    with pytest.raises(ValueError):
        build_loss_functions(value)
