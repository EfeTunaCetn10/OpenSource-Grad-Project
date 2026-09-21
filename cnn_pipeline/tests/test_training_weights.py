import pytest
import torch
from torch import nn
from torch.utils.data import DataLoader, Dataset, Subset, TensorDataset
from train import training_class_weights, run_epoch


class LabelsOnly(Dataset):
    targets = [0, 0, 0, 1]
    def __len__(self):
        return len(self.targets)
    def __getitem__(self, index):
        raise AssertionError('Weight computation must not load images')


def test_weights_balance_total_class_contribution():
    state = torch.get_rng_state()
    weights, counts = training_class_weights(LabelsOnly(), 2)
    assert counts.tolist() == [3, 1]
    assert torch.allclose(weights * counts, torch.tensor([2., 2.]))
    assert torch.equal(state, torch.get_rng_state())


def test_subset_uses_only_selected_training_labels():
    weights, counts = training_class_weights(Subset(LabelsOnly(), [0, 3]), 2)
    assert counts.tolist() == [1, 1]
    assert weights.tolist() == [1., 1.]
    with pytest.raises(ValueError):
        training_class_weights(Subset(LabelsOnly(), [0, 1]), 2)


def test_weighted_epoch_loss_matches_whole_dataset():
    logits = torch.tensor([[2., 0.], [0., 3.], [1., 2.], [3., 1.]])
    labels = torch.tensor([0, 1, 0, 0])
    criterion = nn.CrossEntropyLoss(weight=torch.tensor([0.5, 2.]))
    expected = criterion(logits, labels).item()
    for batch_size in (1, 3, 4):
        loader = DataLoader(TensorDataset(logits, labels), batch_size=batch_size)
        metrics = run_epoch(nn.Identity(), loader, criterion, torch.device('cpu'))
        assert metrics['loss'] == pytest.approx(expected, rel=1e-6)


def test_square_root_softens_relative_weights():
    original, _ = training_class_weights(LabelsOnly(), 2)
    softened, _ = training_class_weights(LabelsOnly(), 2, power=0.5)
    assert torch.allclose(softened.square(), original)
    assert (softened[1] / softened[0]).item() == pytest.approx(3 ** 0.5)
    uniform, _ = training_class_weights(LabelsOnly(), 2, power=0.0)
    assert torch.equal(uniform, torch.ones(2))


@pytest.mark.parametrize('power', [-1, 2, float('nan')])
def test_invalid_weight_power(power):
    with pytest.raises(ValueError):
        training_class_weights(LabelsOnly(), 2, power=power)
