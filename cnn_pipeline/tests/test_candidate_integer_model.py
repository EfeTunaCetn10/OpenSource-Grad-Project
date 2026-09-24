from copy import deepcopy

import pytest
import torch

import candidate_integer_model as module
from multiplier_analysis import LAYERS
from quantization import POLICY


@pytest.fixture
def fixture():
    shapes = {'input': ['N',3,32,32], 'features.1': ['N',6,28,28],
              'features.4': ['N',16,10,10], 'classifier.2': ['N',120],
              'classifier.4': ['N',84], 'classifier.5': ['N',10]}
    q = {'schema_version':1, 'policy':deepcopy(POLICY),
         'activation_qparams': {k:dict(scale=1.,axis=None,zero_point=0,tensor_shape=s) for k,s in shapes.items()},
         'weight_qparams':{}}
    state, integer = {}, {}
    for name,_,_,shape in LAYERS:
        scales = [.5 if c%2==0 else .25 for c in range(shape[0])]
        wi = torch.stack([torch.full(shape[1:], c%127, dtype=torch.int8) for c in range(shape[0])])
        state[name+'.weight'] = wi.float() * torch.tensor(scales).reshape(-1,*([1]*(len(shape)-1)))
        state[name+'.bias'] = torch.ones(shape[0],dtype=torch.float32)
        integer[name+'.weight'] = wi
        q['weight_qparams'][name] = dict(scale=scales,axis=0,zero_point=[0]*shape[0],tensor_shape=shape)
    return q,state,integer


def test_manual_channels_topology_repeatability(fixture):
    q,state,wi=fixture
    before=deepcopy(fixture)
    result=module.prepare_candidate_integer_model(*fixture)
    again=module.prepare_candidate_integer_model(*fixture)
    assert len(result['layers'])==5 and result['channel_count']==236
    for name,x,y,shape in LAYERS:
        p=result['layers'][name]
        assert (p['input_key'],p['output_key'])==(x,y)
        assert list(p['weights'].shape)==shape
        assert p['bias_q'][:2]==[2,4] and p['M0'][:2]==[65536,65536] and p['n'][:2]==[17,18]
        assert p['relu']==(name!='classifier.5')
        assert p['weights_list'][0]==wi[name+'.weight'][0].tolist()
        assert p['weights_list'][1]==wi[name+'.weight'][1].tolist()
        assert p['weights_list']==again['layers'][name]['weights_list']
        assert p['bias_q']==again['layers'][name]['bias_q']
        assert torch.equal(p['weights'],wi[name+'.weight'])
        p['weights'].zero_()
    assert q==before[0]
    assert all(torch.equal(v,before[1][k]) for k,v in state.items())
    assert all(torch.equal(v,before[2][k]) for k,v in wi.items())


@pytest.mark.parametrize('target,key,action', [('state','features.0.bias','remove'),
    ('state','extra.bias','extra'),('wi','features.0.weight','remove'),('wi','extra.weight','extra'),
    ('state','features.0.weight','double'),('state','features.0.bias','double'),
    ('wi','features.0.weight','float'),('wi','features.0.weight','shape'),
    ('state','features.0.bias','shape'),('wi','features.0.weight','reverse')])
def test_invalid_tensors(fixture,target,key,action):
    d=fixture[1 if target=='state' else 2]
    if action=='remove': d.pop(key)
    elif action=='extra': d[key]=torch.zeros(1)
    elif action=='double': d[key]=d[key].double()
    elif action=='float': d[key]=d[key].float()
    elif action=='shape': d[key]=d[key][:-1]
    else: d[key]=d[key].flip(0)
    with pytest.raises(ValueError): module.prepare_candidate_integer_model(*fixture)


@pytest.mark.parametrize('action', ['missing','zero','nan','channels','zero_point'])
def test_invalid_qparams(fixture,action):
    q=fixture[0]
    if action=='missing': q['activation_qparams'].pop('input')
    elif action in ('zero','nan'): q['activation_qparams']['input']['scale']=0. if action=='zero' else float('nan')
    elif action=='channels': q['weight_qparams']['features.0']['scale']=[1.]
    else: q['weight_qparams']['features.0']['zero_point']=[1]*6
    with pytest.raises(ValueError): module.prepare_candidate_integer_model(*fixture)


@pytest.mark.parametrize('reason',['Checkpoint identity mismatch','Weight artifact hash mismatch','Input hash mismatch'])
def test_verification_failure_stops_before_load(monkeypatch,reason):
    def fail(*a,**kw): raise ValueError(reason)
    def forbidden(*a,**kw): pytest.fail('load before verification')
    monkeypatch.setattr(module.analysis,'verify_qparams',fail)
    monkeypatch.setattr(torch,'load',forbidden)
    with pytest.raises(ValueError,match=reason): module.load_candidate_integer_model('qparams.json')

# Reuse synthetic on-disk provenance fixture; no real checkpoint/dataset needed.
from test_multiplier_analysis import provenance, qparams


@pytest.mark.parametrize('target', ['checkpoint', 'artifact', 'provenance'])
def test_actual_hash_rejection(provenance, target):
    import json
    path, root = provenance
    q = json.loads(path.read_text())
    if target == 'checkpoint':
        (root / q['checkpoint']['path']).write_bytes(b'changed checkpoint')
    elif target == 'artifact':
        (path.parent / q['weight_artifact']['file']).write_bytes(b'changed weights')
    else:
        q['calibration']['selection_manifest_sha256']='wrong'
        path.write_text(json.dumps(q))
    with pytest.raises(ValueError, match='hash mismatch|identity mismatch'):
        module.load_candidate_integer_model(path, root=root)
