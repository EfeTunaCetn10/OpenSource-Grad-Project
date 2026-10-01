from copy import deepcopy

import pytest
import torch

import candidate_integer_forward as forward
from candidate_integer_model import prepare_candidate_integer_model
from test_candidate_integer_model import fixture


@pytest.fixture
def prepared(fixture):
    q,state,weights=fixture
    for name in state:
        state[name].zero_()
    for w in weights.values(): w.zero_()
    # Bias-only known network: hidden negative biases must be clamped, final signed.
    for name in state:
        if name.endswith('.bias'): state[name].fill_(-1.)
    return prepare_candidate_integer_model(q,state,weights)


def test_full_manual_trace_and_immutability(prepared):
    image=torch.zeros(3,32,32)
    before=deepcopy(prepared)
    image_before=image.clone()
    result,trace=forward.candidate_integer_forward(image,prepared,trace=True)
    assert result==[-1]*10 and all(type(v) is int for v in result)
    assert [r['shape'] for r in trace['stages']]==[[3,32,32],[6,28,28],[6,14,14],[16,10,10],[16,5,5],[400],[120],[84],[10]]
    assert [r['stage'] for r in trace['stages']]==['input','conv1','pool1','conv2','pool2','flatten','fc1','fc2','fc3']
    assert all(r['min']==r['max']==0 for r in trace['stages'][1:-1])
    for a,b in [(1,2),(3,4),(4,5)]:
        assert trace['stages'][a]['scale']==trace['stages'][b]['scale']
        assert trace['stages'][a]['scale_name']==trace['stages'][b]['scale_name']
    assert torch.equal(image,image_before)
    for name,p in prepared['layers'].items():
        for key,val in p.items():
            old=before['layers'][name][key]
            assert torch.equal(val,old) if isinstance(val,torch.Tensor) else val==old
    result[0]=123
    assert forward.candidate_integer_forward(image,prepared)==[-1]*10


def test_flatten_delegates_chw_order(prepared,monkeypatch):
    real=forward.integer_flatten_chw_ref
    captured=[]
    def check(x):
        result=real(x)
        assert result==[x[c][h][w] for c in range(16) for h in range(5) for w in range(5)]
        captured.append(result)
        return result
    # A nonuniform synthetic pool output isolates the flatten handoff to FC1.
    real_pool=forward.integer_maxpool2d_ref
    calls=[]
    def pool(x):
        result=real_pool(x);calls.append(1)
        if len(calls)==2:
            return [[[c*5+h+w for w in range(5)] for h in range(5)] for c in range(16)]
        return result
    monkeypatch.setattr(forward,'integer_flatten_chw_ref',check)
    monkeypatch.setattr(forward,'integer_maxpool2d_ref',pool)
    assert forward.candidate_integer_forward(torch.zeros(3,32,32),prepared)==[-1]*10
    assert captured[0][:6]==[0,1,2,3,4,1] and captured[0][25]==5


def test_input_clipping_and_rounding(prepared):
    x=torch.zeros(3,32,32);x[0,0,:4]=torch.tensor([128.,-128.,2.5,-2.5])
    with pytest.warns(RuntimeWarning,match='clipped 2/3072'):
        _,t=forward.candidate_integer_forward(x,prepared,trace=True)
    assert t['input_clipping_count']==2
    assert t['stages'][0]['min']==-127 and t['stages'][0]['max']==127
    assert t['stages'][-1]['saturation_count'] is None


@pytest.mark.parametrize('bad',[None,[],torch.zeros(3,32,32,dtype=torch.int8),torch.zeros(3,32,32,dtype=torch.float64)])
def test_invalid_type(prepared,bad):
    with pytest.raises(TypeError): forward.candidate_integer_forward(bad,prepared)


@pytest.mark.parametrize('shape',[(1,3,32,32),(1,32,32),(3,31,32),(3,32)])
def test_invalid_shape(prepared,shape):
    with pytest.raises(ValueError,match='CHW'): forward.candidate_integer_forward(torch.zeros(shape),prepared)


@pytest.mark.parametrize('bad',[float('nan'),float('inf')])
def test_nonfinite(prepared,bad):
    x=torch.zeros(3,32,32);x[0,0,0]=bad
    with pytest.raises(ValueError): forward.candidate_integer_forward(x,prepared)


@pytest.mark.parametrize('key,val',[('relu',True),('s_x',2.)])
def test_bad_prepared_metadata(prepared,key,val):
    prepared['layers']['classifier.5'][key]=val
    with pytest.raises(ValueError): forward.candidate_integer_forward(torch.zeros(3,32,32),prepared)


def test_sparse_nonzero_end_to_end(fixture):
    q,state,weights=fixture
    for value in state.values(): value.zero_()
    for name,wi in weights.items():
        wi.zero_()
        wi.reshape(wi.shape[0],-1)[0,0]=1
        if name=='classifier.5.weight': wi[1,0]=-1
        state[name].copy_(wi.float())
        q['weight_qparams'][name.removesuffix('.weight')]['scale']=[1.]*wi.shape[0]
    prepared=prepare_candidate_integer_model(q,state,weights)
    # Every weighted layer routes its first input to output 0. Constant 3 survives
    # both max pools; final channel 1 independently negates it.
    out=forward.candidate_integer_forward(torch.full((3,32,32),3.),prepared)
    assert out==[3,-3,0,0,0,0,0,0,0,0]


def test_trace_boundary_counts_are_separate_from_relu_zeros(prepared):
    _,trace=forward.candidate_integer_forward(torch.zeros(3,32,32),prepared,trace=True)
    hidden=trace['stages'][1]
    assert hidden['output_count']==6*28*28
    assert hidden['endpoint_count']==6*28*28  # All ReLU-domain lower endpoints.
    assert hidden['minus128_count']==hidden['plus127_count']==0
    assert hidden['saturation_count'] is None
