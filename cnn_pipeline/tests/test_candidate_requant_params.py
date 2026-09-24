import copy
import math

import pytest

import multiplier_analysis as analysis
from candidate_requant_params import candidate_requant_params
from requant_ref import requant_raw, requant_ref


def test_exact_order_and_consistency():
    scales = [.5, .25, .75]
    result = candidate_requant_params(1., 1., scales)
    assert result['M0'] == [65536, 65536, 98304]
    assert result['n'] == [17, 18, 17]
    for i, row in enumerate(result['channels']):
        selected = analysis.analyze_multiplier(scales[i])['selected_candidate']
        assert all(row[k] == v for k, v in selected.items())
        assert row['channel'] == i and row['M'] == scales[i]
        assert row['status'] == 'exact_float64'
        assert requant_raw(4, row['M0'], row['n']) == [2, 1, 3][i]
        assert requant_ref(-4, row['M0'], row['n']) == [-2, -1, -3][i]


def test_nonunit_scales_and_immutability():
    weights = [.25, .5, .125]
    before = copy.deepcopy(weights)
    r = candidate_requant_params(.5, .25, weights)
    assert [c['M'] for c in r['channels']] == [.5, 1., .25]
    assert r == candidate_requant_params(.5, .25, tuple(weights))
    assert weights == before


def test_upper_boundary_preserves_anomaly():
    M = 131071.5 / 2**18
    r = candidate_requant_params(1., 1., [M])
    assert r['M0'] == [65536] and r['n'] == [17]
    assert r['channels'][0]['anomalies'] == analysis.analyze_multiplier(M)['anomalies']
    assert r['channels'][0]['anomalies']
    assert r['channels'][0]['absolute_error'] == 2**-19


@pytest.mark.parametrize('bad', [analysis.MIN_M / 2, analysis.MAX_M * 2])
def test_no_partial_result(bad):
    with pytest.raises(ValueError, match='channel 1.*entire call rejected'):
        candidate_requant_params(1., 1., [.5, bad, .25])


@pytest.mark.parametrize('bad', [True, '1', None, [1.], complex(1)])
@pytest.mark.parametrize('position', [0, 1, 2])
def test_wrong_scalar_types(bad, position):
    args = [1., 1., [1.]]
    args[position] = [bad] if position == 2 else bad
    with pytest.raises(TypeError):
        candidate_requant_params(*args)


@pytest.mark.parametrize('bad', [0., -1., math.nan, math.inf, -math.inf, 10**400])
@pytest.mark.parametrize('position', [0, 1, 2])
def test_invalid_scales(bad, position):
    args = [1., 1., [1.]]
    args[position] = [bad] if position == 2 else bad
    with pytest.raises(ValueError):
        candidate_requant_params(*args)


@pytest.mark.parametrize('bad', [[], (), [[1.]], [[1.], []], 1., {}, '1'])
def test_bad_channel_shape(bad):
    with pytest.raises((ValueError, TypeError)):
        candidate_requant_params(1., 1., bad)


@pytest.mark.parametrize('sx,sy,sw', [(1e-300, 1., 1e-300), (1e300, 1., 1e300),
                                     (1e-200, 1e200, 1.), (1e200, 1e-200, 1.),
                                     (1e-200, 1., 1e-110)])
def test_intermediate_failures(sx, sy, sw):
    with pytest.raises(ValueError, match='channel 0.*underflow/subnormal or overflow'):
        candidate_requant_params(sx, sy, [sw])


@pytest.mark.parametrize('M0,n', [(65535, 17), (131072, 17), (65536, 0),
                                 (65536, 50), (65536, 63), (True, 17)])
def test_guard_against_invalid_selected_pair(monkeypatch, M0, n):
    monkeypatch.setattr(analysis, 'analyze_multiplier', lambda M: {
        'selected_candidate': {'M0': M0, 'n': n}})
    with pytest.raises(ValueError, match='requant contract'):
        candidate_requant_params(1., 1., [.5])


def test_selection_is_delegated(monkeypatch):
    calls = []
    original = analysis.analyze_multiplier
    def observe(M):
        calls.append(M)
        return original(M)
    monkeypatch.setattr(analysis, 'analyze_multiplier', observe)
    candidate_requant_params(1., 1., [.5, .25])
    assert calls == [.5, .25]
