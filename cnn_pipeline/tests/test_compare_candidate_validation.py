import json

import pytest

from compare_candidate_validation import metrics,subset_indices,add_diagnostics,save_report


def test_metrics_hand_accounting():
    r=metrics([0,0,1,1,2],[0,1,1,0,0],[0,0,0,2,0],['a','b','c','empty'])
    assert r['samples']==5 and r['fp32_accuracy']==r['int8_accuracy']==.4
    assert r['agreement_rate']==.4
    assert r['accounting']==dict(both_correct=1,fp32_correct_int8_wrong=1,fp32_wrong_int8_correct=1,both_wrong=2)
    assert sum(map(sum,r['agreement_matrix_fp32_int8']))==5
    assert r['agreement_matrix_fp32_int8'][0][0]==2
    assert r['per_class'][0]['fp32_accuracy']==.5 and r['per_class'][0]['int8_accuracy']==1.
    assert r['per_class'][3]['samples']==0
    assert r['per_class'][3]['fp32_accuracy'] is None
    assert r['per_class'][3]['agreement'] is None


def test_percentage_point_difference():
    r=metrics([0,1],[0,1],[0,0],['a','b'])
    assert r['absolute_accuracy_difference_pp']==50 and r['int8_minus_fp32_pp']==-50


def test_subset_determinism():
    a=subset_indices(200,100)
    assert a==subset_indices(200,100) and a!=subset_indices(200,100,43)
    assert len(set(a))==100 and a!=list(range(100))
    assert a==subset_indices(200)[:100]


@pytest.mark.parametrize('size,limit',[(0,1),(10,0),(10,-1)])
def test_bad_subset(size,limit):
    with pytest.raises(ValueError): subset_indices(size,limit)


def test_diagnostic_aggregation():
    total={'input_elements':0,'input_clipping_count':0,'stages':{}}
    t={'input_elements':3,'input_clipping_count':1,'stages':[{'stage':'fc3','output_count':10,'minus128_count':2,'plus127_count':1}]}
    add_diagnostics(total,t);add_diagnostics(total,t)
    assert total['input_elements']==6 and total['input_clipping_count']==2
    assert total['stages']['fc3']==dict(output_count=20,minus128_count=4,plus127_count=2)


def test_report_json_and_no_overwrite(tmp_path):
    r={'schema_version':1,'split':{'name':'val'},'samples':[{}], 'metrics':metrics([0],[0],[0],['a','empty'])}
    path=tmp_path/'run';save_report(r,path)
    assert json.loads((path/'report.json').read_text())==r
    with pytest.raises(FileExistsError): save_report(r,path)
    r['split']['name']='test'
    with pytest.raises(ValueError): save_report(r,tmp_path/'bad')


@pytest.mark.parametrize('labels,fp,iq',[([],[],[]),([0],[0,1],[0]),([0],[True],[0]),([0],[3],[0])])
def test_bad_metrics(labels,fp,iq):
    with pytest.raises(ValueError): metrics(labels,fp,iq,['a','b'])
