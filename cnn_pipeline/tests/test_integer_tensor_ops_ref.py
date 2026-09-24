from copy import deepcopy

import pytest
import torch
import torch.nn.functional as F

from integer_tensor_ops_ref import integer_flatten_chw_ref as flatten
from integer_tensor_ops_ref import integer_maxpool2d_ref as pool


def test_manual_multichannel_pool_flatten_and_immutability():
    x = [[[1, 5, 2, 4], [3, 0, 8, 6]],
         [[-9, -3, -8, -2], [-4, -7, -6, -5]]]
    before = deepcopy(x)
    pooled = pool(x)
    assert pooled == [[[5, 8]], [[-3, -2]]]
    assert flatten(pooled) == [5, 8, -3, -2]
    assert x == before
    pooled[0][0][0] = 100
    assert x == before


def test_signed_endpoints_equal_maxima_and_vertical_windows():
    x = [[[-128, -128], [-128, -128], [127, 127], [-128, 0]]]
    assert pool(x) == [[[-128], [127]]]
    assert flatten(x) == [-128, -128, -128, -128, 127, 127, -128, 0]


def test_asymmetric_flatten_order_tuple_and_fresh_list():
    x = (((1, 2, 3), (4, 5, 6)), ((-7, -8, -9), (10, 11, 12)))
    result = flatten(x)
    assert result == [1, 2, 3, 4, 5, 6, -7, -8, -9, 10, 11, 12]
    result[0] = 100
    assert x[0][0][0] == 1
    assert flatten([[[7]]]) == [7]  # Pool's even/minimum shape rule does not apply.


def test_small_exact_fp32_pool_and_flatten():
    x = [[[-128, -1, 4, 7], [-3, -2, 127, 0]],
         [[9, 9, -4, -8], [1, 2, -6, -5]]]
    tensor = torch.tensor(x, dtype=torch.float32).unsqueeze(0)
    expected = F.max_pool2d(tensor, kernel_size=2, stride=2, padding=0)
    assert pool(x) == expected[0].tolist()
    assert flatten(x) == torch.nn.Flatten()(tensor)[0].tolist()
    assert flatten(pool(x)) == torch.nn.Flatten()(expected)[0].tolist()


@pytest.mark.parametrize('channels,size,out_size', [(6, 28, 14), (16, 10, 5)])
def test_lenet_shapes_and_values(channels, size, out_size):
    x = [[[c] * size for _ in range(size)] for c in range(channels)]
    y = pool(x)
    assert y == [[[c] * out_size for _ in range(out_size)] for c in range(channels)]
    assert flatten(y) == [c for c in range(channels) for _ in range(out_size * out_size)]
    if channels == 16:
        assert len(flatten(y)) == 400


@pytest.mark.parametrize('op', [pool, flatten])
@pytest.mark.parametrize('x', [[], [[]], [[[]]], [[[1], [2, 3]]],
                              [[[1]], [[2, 3]]]])
def test_empty_and_ragged(op, x):
    with pytest.raises(ValueError):
        op(x)


@pytest.mark.parametrize('op', [pool, flatten])
@pytest.mark.parametrize('x', [None, 1, 'x', [1], [[1]], [[[[1]]]],
                              [[[True]]], [[[1.0]]], [[['1']]]])
def test_wrong_rank_or_type(op, x):
    with pytest.raises(TypeError):
        op(x)


@pytest.mark.parametrize('op', [pool, flatten])
@pytest.mark.parametrize('value', [-129, 128])
def test_outside_int8(op, value):
    with pytest.raises(ValueError, match='INT8'):
        op([[[value, 0], [0, 0]]])


@pytest.mark.parametrize('height,width', [(1, 2), (2, 1), (1, 1), (3, 2), (2, 3), (3, 3)])
def test_pool_odd_or_small_spatial_dimensions(height, width):
    x = [[[0] * width for _ in range(height)]]
    with pytest.raises(ValueError, match='even H/W >=2'):
        pool(x)
    assert flatten(x) == [0] * (height * width)
