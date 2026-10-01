from copy import deepcopy
import hashlib
import json

import pytest
import torch

from candidate_integer_model import prepare_candidate_integer_model
from candidate_integer_forward import candidate_integer_forward
from export_test_vectors import build_vectors,write_vectors,requant_vectors,focused_vectors,integer_tensor
from test_candidate_integer_model import fixture


@pytest.fixture
def bundle(fixture):
    q,state,wi=fixture
    # Keep fixture's channel-distinct weights; avoid unrealistic large activations.
    return prepare_candidate_integer_model(q,state,wi)


def assemble(bundle):
    return build_vectors(torch.zeros(3,32,32),bundle,
        sample={'path':'synthetic.png','sha256':'synthetic','label':0,'class':'0'},
        class_names=[str(i) for i in range(10)],input_provenance={'status':'synthetic fixture'})


def test_deterministic_complete_export_and_immutability(bundle,tmp_path):
    before=deepcopy(bundle);files=assemble(bundle)
    write_vectors(files,tmp_path/'one');write_vectors(assemble(bundle),tmp_path/'two')
    for path in (tmp_path/'one').rglob('*.json'):
        assert path.read_bytes()==(tmp_path/'two'/path.relative_to(tmp_path/'one')).read_bytes()
    meta=json.loads((tmp_path/'one/metadata.json').read_text())
    assert meta['schema_version']==1 and len(meta['layer_order'])==5
    assert meta['sample']['sha256']=='synthetic' and meta['input_provenance']['status']=='synthetic fixture'
    assert meta['proposed_hardware_semantics_applied'] is False
    assert meta['stage_order']==['input_int8','conv1','pool1','conv2','pool2','flatten','fc1','fc2','fc3']
    assert [files[f'expected/{s}.json']['shape'] for s in meta['stage_order']]==[
        [3,32,32],[6,28,28],[6,14,14],[16,10,10],[16,5,5],[400],[120],[84],[10]]
    for name,h in meta['file_sha256'].items():
        assert hashlib.sha256((tmp_path/'one'/name).read_bytes()).hexdigest()==h
    for name,p in bundle['layers'].items():
        for key,v in p.items():
            assert torch.equal(v,before['layers'][name][key]) if isinstance(v,torch.Tensor) else v==before['layers'][name][key]
        exported=files[f'layer_params/{name}.json']
        assert exported['weights']['values']==p['weights_list']
        for key in ['bias_q','M0','n']: assert exported[key]['values']==p[key]
    with pytest.raises(FileExistsError): write_vectors(files,tmp_path/'one')


def test_capture_chw_and_independent_values(bundle):
    x=torch.zeros(3,32,32);x[0,0,0]=-128.;x[1,0,0]=1.;old=x.clone()
    with pytest.warns(RuntimeWarning):
        logits,t=candidate_integer_forward(x,bundle,trace=True,capture_tensors=True)
    assert t['stages'][0]['values'][0][0][0]==-127
    pool=t['stages'][4]['values'];flat=t['stages'][5]['values']
    assert flat==[v for plane in pool for row in plane for v in row]
    saved=t['stages'][-1]['values'][:];logits[0]=123
    assert t['stages'][-1]['values']==saved and torch.equal(x,old)


def test_signed_serialization_exact(tmp_path):
    values=[-2**63,2**63-1]
    t=integer_tensor(values,[2],'int64','vector')
    assert json.loads(json.dumps(t))['values']==values
    assert integer_tensor([-128,127],[2],'int8','vector')['values']==[-128,127]
    assert integer_tensor([-2**31,2**31-1],[2],'int32','O')['values']==[-2**31,2**31-1]


@pytest.mark.parametrize('values,shape,dtype',[([True],[1],'int8'),([1.],[1],'int32'),([128],[1],'int8'),([1],[2],'int8')])
def test_bad_integer_tensor(values,shape,dtype):
    with pytest.raises(ValueError): integer_tensor(values,shape,dtype,'vector')


def test_hand_calculated_requant_vectors():
    rows=requant_vectors();assert len(rows)==26
    plain={r['name']:r for r in rows if not r['relu']}
    expected={'positive':(3,3),'negative':(-3,-3),'n0':(-65536,-128),'n1':(32769,127),
              'n49':(0,0),'n50':(0,0),'n63':(0,0),'positive_tie':(3,3),'negative_tie':(-2,-2),
              'positive_saturation':(1000,127),'negative_saturation':(-1000,-128),
              'positive_wrap':(-2**31,-128),'negative_wrap':(2**31-1,127)}
    for name,(raw,out) in expected.items():
        r=plain[name];assert (r['expected_raw'],r['expected_int8'])==(raw,out)
    assert plain['n63']['half_ulp']==2**62
    assert plain['n0']['half_ulp']==0
    assert plain['positive_wrap']['wrapped_acc']==-2**31
    assert plain['negative_wrap']['wrapped_acc']==2**31-1
    for r in rows:
        if r['relu']: assert r['expected_int8']==max(0,plain[r['name']]['expected_int8'])


def test_hand_calculated_focused_vectors():
    v=focused_vectors()
    assert v['short_mac']['expected_int32']==-16
    l=v['linear'];assert l['expected_mac_int32']==[-16,10]
    assert l['expected_acc_int32']==[-15,3] and l['expected_raw']==[-7,2]
    assert l['expected_int8']==[-7,2]
    c=v['conv2d'];assert c['expected_mac_int32']==[[[37,47],[67,77]]]
    assert c['expected_acc_int32']==[[[-3,7],[27,37]]]
    assert c['expected_raw']==[[[-1,4],[14,19]]]==c['expected_int8']


def test_capture_requires_trace(bundle):
    with pytest.raises(ValueError): candidate_integer_forward(torch.zeros(3,32,32),bundle,capture_tensors=True)
