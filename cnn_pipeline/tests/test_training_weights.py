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


def test_sampler_train_only_deterministic_and_inverse_frequency():
    from data import DataBundle, _loader
    from train import with_weighted_training_sampler
    ds=LabelsOnly()
    original=DataBundle(_loader(ds,2,True,0,False),_loader(ds,2,False,0,False),
                        _loader(ds,2,False,0,False),3,['a','b'],[0]*3,[1]*3)
    state=torch.get_rng_state()
    first,counts=with_weighted_training_sampler(original,42)
    second,_=with_weighted_training_sampler(original,42)
    assert torch.equal(state,torch.get_rng_state())
    assert first.val_loader is original.val_loader
    assert first.test_loader is original.test_loader
    assert first.train_loader.dataset is original.train_loader.dataset
    assert first.train_loader.batch_size==2
    assert isinstance(original.train_loader.sampler,torch.utils.data.RandomSampler)
    sampler=first.train_loader.sampler
    assert counts.tolist()==[3,1]
    assert sampler.weights.tolist()==pytest.approx([1/3,1/3,1/3,1])
    assert sampler.replacement and sampler.num_samples==len(ds)
    seq1=[list(sampler) for _ in range(5)]
    assert seq1==[list(second.train_loader.sampler) for _ in range(5)]
    third,_=with_weighted_training_sampler(original,123)
    assert seq1!=[list(third.train_loader.sampler) for _ in range(5)]
    assert all(len(epoch)==4 and all(0<=i<4 for i in epoch) for epoch in seq1)


def test_targeted_weights_and_validation_loss():
    from train import targeted_class_weights, build_loss_functions
    names = ['bee','beetle','beetle_cocci','bug','fly','fly_sarco',
             'fly_small','hfly_episyr','hfly_eupeo','hfly_sphaero']
    weights = targeted_class_weights(names)
    assert weights.tolist() == pytest.approx([1,1.15,1,1.15,1,1.15,1,1,1,1.15])
    assert torch.equal(targeted_class_weights(names[::-1]), weights.flip(0))
    train, val = build_loss_functions(0, weights)
    logits = torch.arange(20, dtype=torch.float32).reshape(2,10)/10
    targets = torch.tensor([0,1])
    losses = nn.functional.cross_entropy(logits,targets,reduction='none')
    assert train(logits,targets).item() == pytest.approx(((losses[0]+1.15*losses[1])/2.15).item())
    assert val.weight is None
    assert val(logits,targets).item() == pytest.approx(losses.mean().item())
    normal_train, normal_val = build_loss_functions(0)
    assert normal_train.weight is None and normal_val.weight is None
    with pytest.raises(ValueError):
        targeted_class_weights(names[:-1])
    with pytest.raises(ValueError):
        targeted_class_weights(names[:-1]+['bee'])


def test_targeted_cli_is_opt_in(monkeypatch):
    import sys
    from train import parse_args
    monkeypatch.setattr(sys,'argv',['train.py','--dataset','insects'])
    assert not parse_args().targeted_class_weighted
    monkeypatch.setattr(sys,'argv',['train.py','--dataset','insects','--targeted-class-weighted'])
    args = parse_args()
    assert args.targeted_class_weighted
    assert not args.weighted_sampler and not args.class_weighted
