import sys

import pytest
import torch
from torch import nn

from model import LeNet5, count_parameters
from model_v2 import LeNetV2
from model_v3 import CompactCNNV3
import train


def test_geometry_parameters_and_macs():
    model = CompactCNNV3()
    expected = [(2,16,32,32),(2,16,32,32),(2,16,16,16),
                (2,24,16,16),(2,24,16,16),(2,24,8,8),
                (2,32,8,8),(2,32,8,8),(2,32,4,4),
                (2,512),(2,64),(2,64),(2,10)]
    layers = list(model.features) + list(model.classifier)
    assert len(layers) == len(expected)
    x = torch.zeros(2,3,32,32)
    macs = 0
    for layer, shape in zip(layers, expected):
        assert type(layer) in (nn.Conv2d, nn.ReLU, nn.MaxPool2d, nn.Flatten, nn.Linear)
        x = layer(x)
        assert tuple(x.shape) == shape
        if isinstance(layer, nn.Conv2d):
            assert layer.kernel_size == (3,3) and layer.padding == (1,1)
            assert layer.stride == (1,1) and layer.dilation == (1,1)
            assert layer.groups == 1 and layer.bias is not None
            macs += x[0].numel() * layer.in_channels * 9
        elif isinstance(layer, nn.Linear):
            macs += layer.in_features * layer.out_features
        elif isinstance(layer, nn.MaxPool2d):
            assert layer.kernel_size == 2 and layer.stride == 2
            assert layer.padding == 0 and not layer.ceil_mode
    assert model.classifier[1].in_features == 512
    assert count_parameters(model.features) == 10872
    assert count_parameters(model.classifier) == 33482
    assert count_parameters(model) == 44354
    assert macs == 1802880


@pytest.mark.parametrize('batch,classes', [(1,10),(3,5),(2,17)])
def test_forward_shape(batch, classes):
    assert CompactCNNV3(classes)(torch.zeros(batch,3,32,32)).shape == (batch,classes)


@pytest.mark.parametrize('shape', [(3,32,32),(2,1,32,32),(2,3,31,32),(2,3,32,33)])
def test_invalid_input(shape):
    with pytest.raises(ValueError, match='input shape'):
        CompactCNNV3()(torch.zeros(shape))


@pytest.mark.parametrize('classes', [True,1,0,2.5])
def test_invalid_classes(classes):
    with pytest.raises(ValueError, match='num_classes'):
        CompactCNNV3(classes)


def test_cli_default_and_explicit_selection(monkeypatch):
    monkeypatch.setattr(sys, 'argv', ['train.py','--dataset','insects'])
    assert train.parse_args().model_version == 'v1'
    for version, cls in [('v1',LeNet5),('v2',LeNetV2),('v3',CompactCNNV3)]:
        monkeypatch.setattr(sys, 'argv', ['train.py','--dataset','insects','--model-version',version])
        assert isinstance(train.build_model(train.parse_args().model_version,3,10), cls)


def test_v1_construction_and_outputs_unchanged():
    torch.manual_seed(42)
    direct = LeNet5(3,10)
    torch.manual_seed(42)
    selected = train.build_model('v1',3,10)
    assert count_parameters(selected) == 62006
    assert direct.state_dict().keys() == selected.state_dict().keys()
    for key, value in direct.state_dict().items():
        assert torch.equal(value, selected.state_dict()[key])
    x = torch.arange(3*32*32, dtype=torch.float32).reshape(1,3,32,32) / 3072
    assert torch.equal(direct(x), selected(x))


def test_rejects_grayscale_v3():
    with pytest.raises(ValueError, match='RGB'):
        train.build_model('v3',1,10)


def test_v3_refuses_existing_output_before_loading_data(tmp_path, monkeypatch):
    monkeypatch.setattr(sys, 'argv', ['train.py','--dataset','insects','--model-version','v3',
                                    '--output-dir',str(tmp_path)])
    def unexpected(*args, **kwargs):
        pytest.fail('must reject existing output before loading data')
    monkeypatch.setattr(train, 'build_insect_loaders', unexpected)
    with pytest.raises(FileExistsError, match='new v3 experiment directory'):
        train.main()


def test_v3_rejects_mnist_before_loading(monkeypatch):
    monkeypatch.setattr(sys, 'argv', ['train.py','--dataset','mnist','--model-version','v3'])
    with pytest.raises(ValueError, match='insect dataset only'):
        train.main()
