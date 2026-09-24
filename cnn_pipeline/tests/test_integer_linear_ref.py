from copy import deepcopy

import pytest

from integer_linear_ref import checked_int32, integer_linear_ref


def test_two_channel_manual_mac_and_immutability():
    x, w = [2, -3, 4], [[5, 6, -2], [-1, 0, 3]]
    before = deepcopy((x, w))
    # 10-18-8=-16; -2+0+12=10.
    result = integer_linear_ref(x, w)
    assert result == [-16, 10]
    assert all(type(v) is int for v in result)
    assert (x, w) == before


def test_multiple_channels_order_and_cancellation():
    x = (3, -3, 2)
    w = ((4, 4, 0), (1, 0, 0), (0, 1, 0), (0, 0, -2))
    assert integer_linear_ref(x, w) == [0, 3, -3, -4]
    assert integer_linear_ref(x, tuple(reversed(w))) == [-4, -3, 3, 0]


def test_signed_int8_endpoints():
    assert integer_linear_ref([-128, 127], [[-128, 127], [127, -128]]) == [32513, -32512]
    assert integer_linear_ref([-128], [[-128]]) == [16384]


def test_zero_inputs_and_weights():
    assert integer_linear_ref([0, 0], [[127, -128], [2, 3]]) == [0, 0]
    assert integer_linear_ref([127, -128], [[0, 0]]) == [0]


@pytest.mark.parametrize('x,w', [([], [[1]]), ([1], []), ([1], [[]]),
                                  ([1, 2], [[1]]), ([1], [[1], [2, 3]])])
def test_empty_or_mismatched_dimensions(x, w):
    with pytest.raises(ValueError):
        integer_linear_ref(x, w)


@pytest.mark.parametrize('x,w', [(1, [[1]]), ('1', [[1]]), ([1], [1]),
                                  ([1], None), ([True], [[1]]), ([1.0], [[1]]),
                                  ([1], [[False]]), ([1], [['1']]), ([[1]], [[1]])])
def test_wrong_types(x, w):
    with pytest.raises(TypeError):
        integer_linear_ref(x, w)


@pytest.mark.parametrize('value', [-129, 128])
def test_int8_out_of_range(value):
    with pytest.raises(ValueError, match=r'x\[0\].*INT8'):
        integer_linear_ref([value], [[1]])
    with pytest.raises(ValueError, match=r'weights\[0\]\[0\].*INT8'):
        integer_linear_ref([1], [[value]])


@pytest.mark.parametrize('value', [-(2**31), -1, 0, 2**31 - 1])
def test_int32_exact_boundaries(value):
    assert checked_int32(value) == value


@pytest.mark.parametrize('value', [-(2**31) - 1, 2**31])
def test_int32_overflow(value):
    with pytest.raises(OverflowError, match='RTL overflow policy unresolved'):
        checked_int32(value)


@pytest.mark.parametrize('value', [True, 1.0, '1'])
def test_int32_guard_rejects_implicit_conversion(value):
    with pytest.raises(TypeError):
        checked_int32(value)


def test_reachable_positive_mac_overflow():
    # 131072 * (-128 * -128) = 2^31, one above INT32 maximum.
    with pytest.raises(OverflowError, match=r'output\[0\] exact sum=2147483648'):
        integer_linear_ref([-128] * 131072, [[-128] * 131072])


def test_reachable_negative_mac_overflow():
    # 132105 * (-128 * 127) = -2147498880, below INT32 minimum.
    with pytest.raises(OverflowError, match='exact sum=-2147498880'):
        integer_linear_ref([-128] * 132105, [[127] * 132105])


def test_partial_overflow_then_cancellation_is_reported():
    # Positive prefix reaches 2^31, final -128 term returns to INT32 range.
    x = [-128] * 131073
    w = [[-128] * 131072 + [1]]
    with pytest.raises(OverflowError, match=r'partial sum at k=131071 \(final=2147483520\)'):
        integer_linear_ref(x, w)
    assert x[-1] == -128 and w[0][-1] == 1
