import copy
from pathlib import Path
import hashlib
import json

import pytest
import torch

import experimental_v3_ptq as v3
from model_v3 import CompactCNNV3
from model import LeNet5
from integer_conv2d_ref import integer_conv2d_ref
from integer_linear_ref import integer_linear_ref, wrap32
from requant_ref import requant_ref
from quantization import quantize_int8, POLICY


def test_layer_order_and_v1_rejected():
    rows=v3.discover_layers(CompactCNNV3())
    assert [r['name'] for r in rows]==['features.0','features.3','features.6','classifier.1','classifier.3']
    assert [r['output_key'] for r in rows]==['features.1','features.4','features.7','classifier.2','classifier.3']
    assert [r['input_key'] for r in rows]==['input','features.1','features.4','features.7','classifier.2']
    assert [r['kind'] for r in rows]==['conv']*3+['linear']*2
    with pytest.raises(ValueError): v3.discover_layers(LeNet5(3,10))


def test_padding_asymmetric_hand_result():
    x=torch.tensor([[[[1,2],[3,4]]]],dtype=torch.int64)
    w=torch.tensor([[[[1,2,3],[4,5,6],[7,8,9]]]],dtype=torch.int64)
    # Cross-correlation with zeros beyond all four edges, no kernel flipping.
    assert v3.integer_mac(x,w).tolist()==[[[[77,67],[47,37]]]]
    padded=[[[0,0,0,0],[0,1,2,0],[0,3,4,0],[0,0,0,0]]]
    assert v3.integer_mac(x,w)[0].tolist()==integer_conv2d_ref(padded,w.tolist())


def test_random_multichannel_conv_against_python_primitive():
    g=torch.Generator().manual_seed(7)
    x=torch.randint(-128,128,(2,3,4,5),generator=g,dtype=torch.int64)
    w=torch.randint(-128,128,(4,3,3,3),generator=g,dtype=torch.int64)
    original=x.clone(); weights=w.clone()
    out=v3.integer_mac(x,w)
    for b in range(2):
        padded=torch.nn.functional.pad(x[b],(1,1,1,1)).tolist()
        assert out[b].tolist()==integer_conv2d_ref(padded,w.tolist())
    assert torch.equal(x,original) and torch.equal(w,weights)


@pytest.mark.parametrize('n',range(64))
def test_tensor_requant_matches_scalar_all_shifts(n):
    vals=[-(1<<31),-65536,-5,-3,-1,0,1,3,5,65536,(1<<31)-1]
    mac=torch.tensor([[v]*4 for v in vals],dtype=torch.int64)
    bias=[0,1,-1,(1<<31)-1];m=[65536,65537,131070,131071];shifts=[n]*4
    for relu in (False,True):
        actual,_=v3.requant_tensor(mac,bias,m,shifts,relu=relu)
        expected=[[requant_ref(wrap32(v+b),mm,n,relu=relu) for b,mm in zip(bias,m)] for v in vals]
        assert actual.tolist()==expected


def test_manual_bias_ties_clamp_and_linear():
    x=torch.tensor([[2,-3,4]],dtype=torch.int64)
    w=torch.tensor([[5,6,-2],[-1,0,3]],dtype=torch.int64)
    mac=v3.integer_mac(x,w)
    assert mac.tolist()==[[-16,10]]
    assert mac[0].tolist()==integer_linear_ref(x[0].tolist(),w.tolist())
    y,_=v3.requant_tensor(mac,[1,-7],[65536,98304],[17,17],relu=False)
    assert y.tolist()==[[-7,2]]
    y,clamps=v3.requant_tensor(torch.tensor([[-1000,1000]]),[0,0],[65536]*2,[16]*2,relu=False)
    assert y.tolist()==[[-128,127]] and clamps==2


def fixture():
    torch.manual_seed(42)
    model=CompactCNNV3()
    rows=v3.discover_layers(model)
    g=torch.Generator().manual_seed(123)
    images=torch.randn(2,3,32,32,generator=g)
    stats=v3.observe(model,[(images,torch.tensor([0,1]))],rows)
    prepared=v3.prepare(model,stats,rows)
    return model,images,stats,prepared


def test_preparation_geometry_all_five_layers_and_immutability():
    model,images,stats,p=fixture()
    before={k:v.clone() for k,v in model.state_dict().items()}
    stats_before=copy.deepcopy(stats)
    assert len(p['layers'])==5
    assert [r['weights'].shape for r in p['layers']]==[(16,3,3,3),(24,16,3,3),(32,24,3,3),(64,512),(10,64)]
    assert all(r['weights'].dtype==torch.int8 and r['accumulator_safety']['safe'] for r in p['layers'])
    y,diag=v3.integer_forward(images,p)
    assert y.shape==(2,10)
    assert [s['shape'] for s in diag['stages'].values()]==[[16,32,32],[24,16,16],[32,8,8],[64],[10]]
    again,_=v3.integer_forward(images,p)
    assert torch.equal(y,again)
    assert stats==stats_before and all(torch.equal(v,model.state_dict()[k]) for k,v in before.items())
    assert all(not m._forward_hooks for m in model.modules())


def test_safety_applied_at_preparation_and_execution():
    model,images,stats,p=fixture()
    p['layers'][0]['bias_q'][0]=(1<<31)-1
    with pytest.raises(ValueError,match='safety'): v3.integer_forward(images,p)
    with torch.no_grad(): model.features[0].bias.fill_(1e10)
    with pytest.raises(OverflowError): v3.prepare(model,stats,v3.discover_layers(model))


def test_zero_range_rejected():
    model,_,stats,_=fixture()
    stats['activations']['input'].update(min=0,max=0,absmax=0)
    with pytest.raises(ValueError,match='Zero range'): v3.prepare(model,stats,v3.discover_layers(model))


def test_existing_contract_is_preserved():
    assert POLICY['qmin']==-127 and POLICY['qmax']==127 and POLICY['zero_point']==0
    assert quantize_int8(torch.tensor([-2.5,2.5]),1.).tolist()==[-2,3]
    assert requant_ref(-1000,65536,16)==-128
    assert requant_ref(1<<31,65536,16)==-128


def test_manifest_hash_rejected_before_dataset_access(tmp_path):
    manifest=tmp_path/'selection_manifest.json';manifest.write_text('{}')
    (tmp_path/'summary.json').write_text(json.dumps({'selection_manifest_sha256':'wrong'}))
    with pytest.raises(ValueError,match='hash mismatch'): v3.calibration_loader(manifest,{})


def test_no_overwrite_before_loading(tmp_path):
    with pytest.raises(FileExistsError): v3.run(tmp_path/'missing.pt',tmp_path/'missing.json',tmp_path)


def test_full_integer_path_matches_existing_scalar_composition():
    from integer_layer_ref import integer_conv2d_layer_ref, integer_linear_layer_ref
    from integer_tensor_ops_ref import integer_maxpool2d_ref, integer_flatten_chw_ref
    model,images,_,p=fixture()
    selected=Path(__file__).parents[1]/'docs/accuracy_improvement/selected_model.json'
    selected_before=selected.read_bytes()
    value=quantize_int8(images[0],p['activation_scales']['input']).tolist()
    for layer in p['layers']:
        if layer['kind']=='conv':
            # Explicit integer-zero border, then the frozen valid-convolution primitive.
            value=[[[0]*(len(plane[0])+2)]+[[0]+row+[0] for row in plane]+
                   [[0]*(len(plane[0])+2)] for plane in value]
            value=integer_conv2d_layer_ref(value,layer['weights'].tolist(),layer['bias_q'],
                                         layer['M0'],layer['n'],relu=layer['relu'])
            value=integer_maxpool2d_ref(value)
        else:
            if isinstance(value[0],list): value=integer_flatten_chw_ref(value)
            value=integer_linear_layer_ref(value,layer['weights'].tolist(),layer['bias_q'],
                                         layer['M0'],layer['n'],relu=layer['relu'])
    actual,_=v3.integer_forward(images[:1],p)
    assert actual[0].tolist()==value
    assert selected.read_bytes()==selected_before
