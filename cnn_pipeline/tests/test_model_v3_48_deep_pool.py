import sys

import torch
from torch import nn

from model import count_parameters
from train import build_model, parse_args


def test_deep_pool_geometry_parameters_and_macs(monkeypatch):
    monkeypatch.setattr(sys, 'argv', ['train.py', '--dataset', 'insects',
                                    '--model-version', 'v3_48_deep_pool'])
    model = build_model(parse_args().model_version, 3, 10)
    expected = [(16,48,48),(16,48,48),(16,24,24),
                (24,24,24),(24,24,24),(24,12,12),
                (32,12,12),(32,12,12),(32,12,12),(32,12,12),
                (32,6,6),(32,3,3),(288,),(64,),(64,),(10,)]
    layers = list(model.features) + list(model.classifier)
    assert len(layers) == len(expected)
    assert [type(m) for m in model.features] == [
        nn.Conv2d,nn.ReLU,nn.MaxPool2d,nn.Conv2d,nn.ReLU,nn.MaxPool2d,
        nn.Conv2d,nn.ReLU,nn.Conv2d,nn.ReLU,nn.MaxPool2d,nn.MaxPool2d]
    x = torch.zeros(2,3,48,48)
    macs = 0
    ks = []
    for layer, shape in zip(layers, expected):
        x = layer(x)
        assert tuple(x.shape) == (2,*shape)
        if isinstance(layer, nn.Conv2d):
            assert layer.kernel_size == (3,3) and layer.padding == (1,1) and layer.stride == (1,1)
            ks.append(layer.in_channels*9)
            macs += x[0].numel()*ks[-1]
        elif isinstance(layer, nn.Linear):
            ks.append(layer.in_features)
            macs += layer.in_features*layer.out_features
        elif isinstance(layer, nn.MaxPool2d):
            assert layer.kernel_size == 2 and layer.stride == 2 and layer.padding == 0
    assert [(m.in_channels,m.out_channels) for m in model.features if isinstance(m,nn.Conv2d)] == [(3,16),(16,24),(24,32),(32,32)]
    assert model.classifier[1].in_features == 288 and model.classifier[1].out_features == 64
    assert model.classifier[3].in_features == 64 and model.classifier[3].out_features == 10
    assert model(torch.zeros(2,3,48,48)).shape == (2,10)
    assert count_parameters(model.features) == 20120
    assert count_parameters(model.classifier) == 19146
    assert count_parameters(model) == 39266
    assert macs == 5327488
    assert ks == [27,144,216,288,288,64]
    baseline = build_model('v3_48_deep',3,10)
    assert baseline.classifier[1].in_features == 1152
    assert len(baseline.features) == 11 and count_parameters(baseline) == 94562
