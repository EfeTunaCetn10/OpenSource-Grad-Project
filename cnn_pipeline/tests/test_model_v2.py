import pytest
import torch
from torch import nn
from model import LeNet5, count_parameters
from model_v2 import LeNetV2


def test_exact_v2_shapes_operators_parameters():
    m = LeNetV2()
    x = torch.zeros(2, 3, 32, 32)
    expected = [(2,8,28,28),(2,8,28,28),(2,8,14,14),
                (2,24,10,10),(2,24,10,10),(2,24,5,5),
                (2,600),(2,64),(2,64),(2,32),(2,32),(2,10)]
    leaves = list(m.features) + list(m.classifier)
    for layer, shape in zip(leaves, expected):
        assert type(layer) in (nn.Conv2d, nn.ReLU, nn.MaxPool2d, nn.Flatten, nn.Linear)
        x = layer(x)
        assert tuple(x.shape) == shape
    assert m(torch.zeros(2,3,32,32)).shape == (2,10)
    assert count_parameters(m.features) == 5432
    assert count_parameters(m.classifier) == 40874
    assert count_parameters(m) == 46306
    assert count_parameters(LeNet5(3,10)) == 62006
    for conv in (m.features[0],m.features[3]):
        assert conv.kernel_size == (5,5) and conv.stride == (1,1)
        assert conv.padding == (0,0) and conv.dilation == (1,1)


@pytest.mark.parametrize('shape', [(3,32,32),(1,1,32,32),(1,3,28,28)])
def test_invalid_v2_input(shape):
    with pytest.raises(ValueError):
        LeNetV2()(torch.zeros(shape))
