from copy import deepcopy

import pytest
import torch
import torch.nn.functional as F

from integer_conv2d_ref import integer_conv2d_ref
from integer_linear_ref import checked_int32


def test_asymmetric_kernel_manual_and_unchanged_inputs():
    x = [[[1, 2, 3], [4, 5, 6], [7, 8, 9]]]
    w = [[[[1, 2], [3, 4]]]]
    before = deepcopy((x, w))
    # Top-left: 1*1+2*2+4*3+5*4=37; flipped kernel gives 23.
    assert integer_conv2d_ref(x, w) == [[[37, 47], [67, 77]]]
    assert (x, w) == before


def test_multiple_channels_order_signed_and_cancellation():
    x = [[[1, -2], [3, 4]], [[-1, 2], [-3, -4]]]
    w = [[[[1]], [[1]]], [[[2]], [[-1]]], [[[0]], [[1]]]]
    assert integer_conv2d_ref(x, w) == [
        [[0, 0], [0, 0]], [[3, -6], [9, 12]], [[-1, 2], [-3, -4]]]
    assert integer_conv2d_ref(x, [w[2], w[0]]) == [
        [[-1, 2], [-3, -4]], [[0, 0], [0, 0]]]


def test_signed_endpoints_and_zero():
    assert integer_conv2d_ref([[[-128, 127]]], [[[[-128, 127]]]]) == [[[32513]]]
    assert integer_conv2d_ref([[[-128, 127]]], [[[[127, -128]]]]) == [[[-32512]]]
    assert integer_conv2d_ref([[[0, 0]]], [[[[-128]]], [[[127]]]]) == [[[0, 0]], [[0, 0]]]


def test_rectangular_kernel_tuple_input():
    assert integer_conv2d_ref((((1, 2, 3), (4, 5, 6)),),
                              ((((1, -1, 2),),),)) == [[[5], [11]]]


def test_small_exact_fp32_cross_correlation():
    x = torch.tensor([[[1, -2, 3], [4, 0, -1]], [[2, 1, -3], [0, 2, 4]]], dtype=torch.float32)
    w = torch.tensor([[[[1, 2], [-1, 3]], [[0, -2], [1, 1]]],
                      [[[2, 0], [1, -1]], [[3, 1], [-2, 0]]]], dtype=torch.float32)
    actual = integer_conv2d_ref(x.to(torch.int64).tolist(), w.to(torch.int64).tolist())
    # All products and sums are small integers exactly representable in FP32.
    expected = F.conv2d(x.unsqueeze(0), w, bias=None, stride=1, padding=0, dilation=1)
    assert actual == expected.squeeze(0).tolist()


@pytest.mark.parametrize('ci,co,size,out_size', [(3, 6, 32, 28), (6, 16, 14, 10)])
def test_lenet_shapes_and_known_constant_output(ci, co, size, out_size):
    x = [[[1] * size for _ in range(size)] for _ in range(ci)]
    weights = [[[[1] * 5 for _ in range(5)] for _ in range(ci)] for _ in range(co)]
    y = integer_conv2d_ref(x, weights)
    assert len(y) == co and all(len(p) == out_size for p in y)
    assert all(len(r) == out_size and all(v == ci * 25 for v in r) for p in y for r in p)


@pytest.mark.parametrize('x,w', [([], [[[[1]]]]), ([[]], [[[[1]]]]), ([[[]]], [[[[1]]]]),
    ([[[1]]], []), ([[[1]]], [[[]]]), ([[[1], [2, 3]]], [[[[1]]]]),
    ([[[1]], [[2, 3]]], [[[[1]], [[1]]]]),
    ([[[1, 2], [3, 4]]], [[[[1]], [[2]]]]),
    ([[[1]]], [[[[1, 2]]]]), ([[[1]]], [[[[1], [2]]]]),
    ([[[1, 2]]], [[[[1]]], [[[1, 2]]]])])
def test_bad_dimensions(x, w):
    with pytest.raises(ValueError):
        integer_conv2d_ref(x, w)


@pytest.mark.parametrize('bad', [True, 1.0, '1', None, [1]])
def test_bad_scalar_types(bad):
    with pytest.raises(TypeError):
        integer_conv2d_ref([[[bad]]], [[[[1]]]])
    with pytest.raises(TypeError):
        integer_conv2d_ref([[[1]]], [[[[bad]]]])


@pytest.mark.parametrize('bad', [-129, 128])
def test_int8_range(bad):
    with pytest.raises(ValueError, match='INT8'):
        integer_conv2d_ref([[[bad]]], [[[[1]]]])
    with pytest.raises(ValueError, match='INT8'):
        integer_conv2d_ref([[[1]]], [[[[bad]]]])


def test_tensor_container_and_layer_types():
    with pytest.raises(TypeError):
        integer_conv2d_ref(torch.ones(1, 1, 1), [[[[1]]]])
    with pytest.raises(TypeError):
        integer_conv2d_ref([[[1]]], [[[[1]]]], layer=None)


def test_int32_guard_boundaries_separate_from_lenet():
    for value in (-(2**31), 2**31 - 1):
        assert checked_int32(value) == value
    for value in (-(2**31) - 1, 2**31):
        with pytest.raises(OverflowError):
            checked_int32(value)
    # Actual LeNet reductions are only 75 and 150 terms: no INT32 overflow.
    assert 150 * 16384 == 2457600 < 2**31


def test_oversized_synthetic_kernel_overflow_location():
    # Not a LeNet shape. 131072 products of 16384 reach 2^31.
    x = [[[-128] * 131072]]
    w = [[[[-128] * 131072]]]
    with pytest.raises(OverflowError, match=r'wide_test output\[0,0,0\] partial ci=0,kh=0,kw=131071'):
        integer_conv2d_ref(x, w, layer='wide_test')
