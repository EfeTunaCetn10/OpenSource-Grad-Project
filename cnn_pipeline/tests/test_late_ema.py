import copy
import torch
from torch import nn
from train import LateEMA, run_epoch


def test_epoch40_exact_independent_copy_and_equation():
    student = nn.Linear(1,1)
    ema = LateEMA()
    for epoch in range(1,40):
        ema.update(student)
        ema.end_epoch(student,epoch)
    assert ema.model is None and ema.updates == 0
    with torch.no_grad():
        student.weight.fill_(2);student.bias.fill_(4)
    rng = torch.get_rng_state().clone()
    ema.end_epoch(student,40)
    assert torch.equal(rng,torch.get_rng_state())
    assert not ema.model.training
    assert all(not p.requires_grad and p.grad is None for p in ema.model.parameters())
    for a,b in zip(student.parameters(),ema.model.parameters()):
        assert torch.equal(a,b) and a.data_ptr()!=b.data_ptr()
    with torch.no_grad():
        student.weight.fill_(12);student.bias.fill_(14)
    ema.update(student)
    torch.testing.assert_close(ema.model.weight,torch.tensor([[2.1]]))
    torch.testing.assert_close(ema.model.bias,torch.tensor([4.1]))
    assert student.weight.item()==12 and student.bias.item()==14
    ema.end_epoch(student,41)
    assert ema.updates==1


def test_ema_does_not_change_student_updates_and_disabled_compatibility():
    student = nn.Linear(2,2)
    baseline = copy.deepcopy(student)
    disabled = copy.deepcopy(student)
    batch = [(torch.tensor([[1.,2.],[3.,4.]]),torch.tensor([0,1]))]
    ema=LateEMA();ema.end_epoch(student,40)
    original=copy.deepcopy(student.state_dict())
    results=[]
    for model,kwargs in [(baseline,{}),(disabled,{'ema':None}),(student,{'ema':ema})]:
        results.append(run_epoch(model,batch,nn.CrossEntropyLoss(),torch.device('cpu'),
                                 torch.optim.SGD(model.parameters(),lr=.1),**kwargs))
    assert results[0]==results[1]==results[2]
    for key,value in student.state_dict().items():
        assert torch.equal(value,baseline.state_dict()[key])
        assert torch.equal(value,disabled.state_dict()[key])
        torch.testing.assert_close(ema.model.state_dict()[key],.99*original[key]+.01*value)
    assert ema.updates==1 and not ema.model.training
    assert all(p.grad is None for p in ema.model.parameters())
