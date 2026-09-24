import pytest
import torch

from bias_quant_ref import quantize_bias_candidate


def test_exact_channels_and_signed_ties():
    # Denominators .125, .125, .25, .5: ratios 2.5, -2.5, 4, -3.
    b = torch.tensor([.3125, -.3125, 1., -1.5], dtype=torch.float32)
    q = quantize_bias_candidate(b, .5, [.25, .25, .5, 1.])
    assert q.tolist() == [3, -2, 4, -3]
    assert q.dtype == torch.int32 and q.device.type == 'cpu'


@pytest.mark.parametrize('bias,expected', [(0., 0), (.5, 1), (-.5, 0),
                                         (1.5, 2), (-1.5, -1),
                                         (2.5, 3), (-2.5, -2)])
def test_hand_calculated_rounding(bias, expected):
    assert quantize_bias_candidate([bias], 1., [1.]).tolist() == [expected]


def test_neighbors_of_tie_float64():
    tie = torch.tensor([2.5, -2.5], dtype=torch.float64)
    below = torch.nextafter(tie, torch.full_like(tie, -float('inf')))
    above = torch.nextafter(tie, torch.full_like(tie, float('inf')))
    assert quantize_bias_candidate(below, 1., [1., 1.]).tolist() == [2, -3]
    assert quantize_bias_candidate(above, 1., [1., 1.]).tolist() == [3, -2]


@pytest.mark.parametrize('value', [-(2**31), 2**31 - 1])
def test_int32_boundaries(value):
    assert quantize_bias_candidate([float(value)], 1., [1.]).item() == value


def test_fp32_bias_with_float64_scale_at_upper_boundary():
    assert quantize_bias_candidate(torch.tensor([1.], dtype=torch.float32),
                                   1., [1. / (2**31 - 1)]).item() == 2**31 - 1


@pytest.mark.parametrize('value', [-(2**31)-1., 2**31 * 1., 2**31-.5])
def test_int32_overflow_before_cast(value):
    with pytest.raises(OverflowError, match='channel 1.*signed INT32'):
        quantize_bias_candidate([0., value], 1., [1., 1.])


def test_rounding_before_range_check():
    assert quantize_bias_candidate([-(2**31)-.5], 1., [1.]).item() == -(2**31)


@pytest.mark.parametrize('bad', [float('nan'), float('inf'), -float('inf')])
@pytest.mark.parametrize('which', ['bias', 'activation', 'weight'])
def test_nonfinite(bad, which):
    args = [[1.], 1., [1.]]
    args[['bias', 'activation', 'weight'].index(which)] = bad if which == 'activation' else [bad]
    with pytest.raises(ValueError, match='NaN/Inf'):
        quantize_bias_candidate(*args)


@pytest.mark.parametrize('bad', [0., -1.])
@pytest.mark.parametrize('which', [1, 2])
def test_nonpositive_scale(bad, which):
    args = [[1.], 1., [1.]]
    args[which] = bad if which == 1 else [bad]
    with pytest.raises(ValueError, match='positive'):
        quantize_bias_candidate(*args)


@pytest.mark.parametrize('args', [([], 1., []), ([[1.]], 1., [1.]),
                                  ([1.], [1.], [1.]), ([1.], 1., []),
                                  ([1.], 1., [1., 2.]), ([1., 2.], 1., [1.]),
                                  ([1.], 1., [[1.]]), ([[1.], []], 1., [1.])])
def test_bad_shapes(args):
    with pytest.raises(ValueError):
        quantize_bias_candidate(*args)


@pytest.mark.parametrize('bad', [[True], [1], ['1'], [1+0j], torch.tensor([1]), None])
def test_bad_types(bad):
    with pytest.raises(TypeError):
        quantize_bias_candidate(bad, 1., [1.])


@pytest.mark.parametrize('sx,sw,match', [(1e-300, 1e-300, 'scale product'),
                                       (1e300, 1e300, 'scale product'),
                                       (1e-300, 1., 'non-finite scaled bias')])
def test_float64_intermediate_failure(sx, sw, match):
    with pytest.raises(ValueError, match=match):
        quantize_bias_candidate([1e300], sx, [sw])


def test_inputs_unchanged():
    b = torch.tensor([.3125, -.3125], requires_grad=True)
    sx = torch.tensor(.5, dtype=torch.float64)
    sw = torch.tensor([.25, .25], dtype=torch.float64)
    copies = [v.detach().clone() for v in (b, sx, sw)]
    quantize_bias_candidate(b, sx, sw)
    assert all(torch.equal(v, before) for v, before in zip((b, sx, sw), copies))
    assert b.requires_grad and b.grad is None
    seq = [.3125, -.3125]
    scales = [.25, .25]
    quantize_bias_candidate(seq, .5, scales)
    assert seq == [.3125, -.3125] and scales == [.25, .25]
