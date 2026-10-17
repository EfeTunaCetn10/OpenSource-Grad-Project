import json
import sys

import pytest
import torch
from PIL import Image
from torch import nn

from data import build_insect_loaders
from model import count_parameters
from model_v3 import CompactCNNV3
from model_v3_48 import CompactCNNV3_48
import train


def test_geometry_and_parameter_count():
    model = CompactCNNV3_48()
    x = torch.zeros(2, 3, 48, 48)
    shapes = [(16,48,48),(16,48,48),(16,24,24),
              (24,24,24),(24,24,24),(24,12,12),
              (32,12,12),(32,12,12),(32,6,6)]
    for layer, shape in zip(model.features, shapes):
        x = layer(x)
        assert tuple(x.shape) == (2, *shape)
    assert model.classifier[0](x).shape == (2,1152)
    assert model.classifier[1].in_features == 1152
    assert model.classifier[1].out_features == 64
    assert model.classifier[3].out_features == 10
    assert model(torch.zeros(2,3,48,48)).shape == (2,10)
    assert count_parameters(model.features) == 10872
    assert count_parameters(model.classifier) == 74442
    assert count_parameters(model) == 85314
    assert CompactCNNV3().classifier[1].in_features == 512
    assert count_parameters(CompactCNNV3()) == 44354


@pytest.mark.parametrize('shape', [(2,3,32,32),(2,1,48,48),(3,48,48)])
def test_invalid_input(shape):
    with pytest.raises(ValueError, match='input shape'):
        CompactCNNV3_48()(torch.zeros(shape))


def test_cli_selection_and_safety(tmp_path, monkeypatch):
    monkeypatch.setattr(sys,'argv',['train.py','--dataset','insects','--model-version','v3_48',
                                   '--output-dir',str(tmp_path)])
    args=train.parse_args()
    assert isinstance(train.build_model(args.model_version,3,10),CompactCNNV3_48)
    with pytest.raises(FileExistsError):train.main()
    with pytest.raises(ValueError,match='RGB'):train.build_model('v3_48',1,10)


def test_loader_sizes_and_unchanged_augmentation(tmp_path):
    for split in ('train','val','test'):
        for name in ('a','b'):
            path=tmp_path/split/name;path.mkdir(parents=True)
            Image.new('RGB',(60,50),(80,90,100)).save(path/'sample.png')
    stats=tmp_path/'stats.json'
    stats.write_text(json.dumps({'mean':[.1,.2,.3],'std':[.4,.5,.6]}))
    original=build_insect_loaders(tmp_path,stats,2,0,False,train_resize=True)
    variant=build_insect_loaders(tmp_path,stats,2,0,False,train_resize=True,image_size=48)
    for attr in ('train_loader','val_loader','test_loader'):
        old,new=getattr(original,attr),getattr(variant,attr)
        assert old.dataset.samples==new.dataset.samples
        assert next(iter(old))[0].shape==(2,3,32,32)
        assert next(iter(new))[0].shape==(2,3,48,48)
        assert [type(t) for t in old.dataset.transform.transforms]==[type(t) for t in new.dataset.transform.transforms]
        assert repr(old.dataset.transform.transforms[1:])==repr(new.dataset.transform.transforms[1:])
