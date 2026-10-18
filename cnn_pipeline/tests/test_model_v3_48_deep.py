import torch
from torch import nn

from model import count_parameters
from model_v3_48 import CompactCNNV3_48
from train import build_model


def test_extra_conv_geometry_parameters_and_macs():
    baseline = CompactCNNV3_48()
    model = build_model('v3_48_deep', 3, 10)
    expected = [(16,48,48),(16,48,48),(16,24,24),
                (24,24,24),(24,24,24),(24,12,12),
                (32,12,12),(32,12,12),(32,12,12),(32,12,12),(32,6,6),
                (1152,),(64,),(64,),(10,)]
    x = torch.zeros(2,3,48,48)
    macs = 0
    for layer, shape in zip(list(model.features)+list(model.classifier), expected):
        x = layer(x)
        assert tuple(x.shape) == (2,*shape)
        if isinstance(layer, nn.Conv2d):
            macs += x[0].numel()*layer.in_channels*layer.kernel_size[0]*layer.kernel_size[1]
        elif isinstance(layer, nn.Linear):
            macs += layer.in_features*layer.out_features
    assert len(model.features)==11 and len(model.classifier)==4
    assert [(m.in_channels,m.out_channels) for m in model.features if isinstance(m,nn.Conv2d)]==[(3,16),(16,24),(24,32),(32,32)]
    extra=model.features[8]
    assert extra.kernel_size==(3,3) and extra.padding==(1,1) and extra.stride==(1,1)
    assert isinstance(model.features[9],nn.ReLU) and isinstance(model.features[10],nn.MaxPool2d)
    assert model.classifier[1].in_features==1152 and model.classifier[1].out_features==64
    assert model.classifier[3].in_features==64 and model.classifier[3].out_features==10
    assert model(torch.zeros(2,3,48,48)).shape==(2,10)
    assert count_parameters(baseline)==85314 and len(baseline.features)==9
    assert count_parameters(model)==94562
    assert count_parameters(model)-count_parameters(baseline)==9248
    assert macs==5382784
    assert macs-4055680==1327104
