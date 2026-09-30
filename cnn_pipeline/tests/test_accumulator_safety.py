import pytest

from accumulator_safety import accumulator_safety, require_accumulator_safety
from integer_linear_ref import wrap32


@pytest.mark.parametrize('K', [75,150,400,120,84])
def test_lenet_bound(K):
    r = accumulator_safety([0,1,-1], K)
    assert r['safe']
    assert r['min_margin'] == 2**31-1-K*16384-1
    assert r['channels'][1]['bound'] == r['channels'][2]['bound']


@pytest.mark.parametrize('sign', [-1,1])
def test_exact_boundary_and_one_past(sign):
    bias = 2**31-1-16384
    assert require_accumulator_safety([sign*bias],1)['min_margin'] == 0
    r = accumulator_safety([sign*(bias+1)],1)
    assert not r['safe'] and r['min_margin'] == -1
    with pytest.raises(ValueError,match='layerX channel 0'):
        require_accumulator_safety([sign*(bias+1)],1,layer='layerX')
    # Proof failure does not change runtime arithmetic.
    assert wrap32(2**31) == -2**31


@pytest.mark.parametrize('bias,K', [([],1),([0],0),([0],True),([True],1),([1.],1),([2**31],1)])
def test_bad_configuration(bias,K):
    with pytest.raises((ValueError,TypeError,OverflowError)):
        accumulator_safety(bias,K)


def test_unchanged():
    bias=[1,-2]
    assert accumulator_safety(bias,75)==accumulator_safety(bias,75)
    assert bias==[1,-2]
