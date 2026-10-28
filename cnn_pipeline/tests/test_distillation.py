import copy
import math

import pytest
import torch
from torch import nn
from train import kd_loss, run_epoch


def test_kd_formula_and_detached_teacher():
    s = torch.tensor([[0., 0.]], requires_grad=True)
    t = torch.tensor([[2*math.log(3), 0.]], requires_grad=True)
    loss = kd_loss(s, t, torch.tensor([0]))
    expected = .8*math.log(2) + .2*4*(.75*math.log(1.5)+.25*math.log(.5))
    assert loss.item() == pytest.approx(expected)
    loss.backward()
    assert s.grad is not None and t.grad is None


@pytest.mark.parametrize('temperature,alpha', [(0,.2),(float('nan'),.2),(2,-1),(2,float('inf'))])
def test_invalid_kd_settings(temperature, alpha):
    with pytest.raises(ValueError):
        kd_loss(torch.zeros(1,2),torch.zeros(1,2),torch.tensor([0]),temperature,alpha)


class Spy(nn.Linear):
    def forward(self, x):
        self.seen = x
        self.grad_enabled = torch.is_grad_enabled()
        return super().forward(x)


def test_training_shared_tensor_and_validation_student_only():
    student, teacher = Spy(3,2), Spy(3,2)
    before = copy.deepcopy(teacher.state_dict())
    batch = [(torch.randn(4,3),torch.tensor([0,1,0,1]))]
    run_epoch(student,batch,nn.CrossEntropyLoss(),torch.device('cpu'),
              torch.optim.SGD(student.parameters(),lr=.01),teacher=teacher)
    assert teacher.seen is student.seen
    assert not teacher.training and not teacher.grad_enabled
    assert all(p.grad is None for p in teacher.parameters())
    assert all(torch.equal(v,teacher.state_dict()[k]) for k,v in before.items())
    teacher.forward = lambda x: (_ for _ in ()).throw(AssertionError('teacher used for validation'))
    result = run_epoch(student,batch,nn.CrossEntropyLoss(),torch.device('cpu'),teacher=teacher)
    assert result['loss'] == pytest.approx(nn.functional.cross_entropy(student(batch[0][0]),batch[0][1]).item())


def test_disabled_kd_matches_plain_ce_update():
    model = nn.Linear(3,2)
    reference = copy.deepcopy(model)
    x,y = torch.randn(4,3),torch.tensor([0,1,1,0])
    opt = torch.optim.SGD(model.parameters(),lr=.01)
    ref_opt = torch.optim.SGD(reference.parameters(),lr=.01)
    expected = nn.functional.cross_entropy(reference(x),y)
    expected.backward();ref_opt.step()
    result = run_epoch(model,[(x,y)],nn.CrossEntropyLoss(),torch.device('cpu'),opt)
    assert result['loss'] == expected.item()
    assert all(torch.equal(a,b) for a,b in zip(model.parameters(),reference.parameters()))
