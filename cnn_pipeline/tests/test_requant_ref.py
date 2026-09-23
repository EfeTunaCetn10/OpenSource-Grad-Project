"""T_NUM_REQ_001: independent arithmetic checks; no dataset or model imports."""
from fractions import Fraction
import random

import pytest

from requant_ref import checked_signed50, requant_raw, requant_ref


def nearest_ties_positive(product, denominator):
    """Independent exact-distance oracle: no rounding offset or right shift."""
    value = Fraction(product, denominator)
    lower = value.numerator // value.denominator
    upper = lower + 1
    return lower if value - lower < upper - value else upper


@pytest.mark.parametrize('acc,expected', [(0, 0), (1, 1), (-1, 0), (3, 2), (-3, -1),
                                         (5, 3), (-5, -2), (2, 1), (-2, -1)])
def test_T_NUM_REQ_001_even_multiplier_manual_half_ties(acc, expected):
    # M0=65536, n=17 => acc/2 exactly. Both signed ties and exact integers.
    assert requant_raw(acc, 65536, 17) == expected
    assert requant_ref(acc, 65536, 17) == expected


@pytest.mark.parametrize('acc,expected', [(1, 32769), (-1, -32768), (3, 98306), (-3, -98305)])
def test_T_NUM_REQ_001_odd_multiplier_manual_ties(acc, expected):
    # M0=65537, n=1: +/-32768.5 and +/-98305.5, before saturation.
    assert requant_raw(acc, 65537, 1) == expected


def test_T_NUM_REQ_001_rounding_modes_are_distinguished():
    # +0.5: half-up=1, nearest-even=0. -1.5: half-up=-1, both alternatives=-2.
    assert requant_raw(1, 65536, 17) == 1
    assert requant_raw(1, 65536, 17) != 0
    assert requant_raw(-3, 65536, 17) == -1
    assert requant_raw(-3, 65536, 17) != -2
    # -0.75 -> -1: catches truncation toward zero instead of arithmetic shift.
    assert requant_raw(-3, 65536, 18) == -1


@pytest.mark.parametrize('raw', [-130, -129, -128, -127, -1, 0, 1, 125, 126, 127, 128, 129])
def test_T_NUM_REQ_001_saturation_and_half_step_neighbors(raw):
    # Identity multiplier, followed by half steps immediately around each boundary.
    expected = {-130: -128, -129: -128, -128: -128, -127: -127, -1: -1,
                0: 0, 1: 1, 125: 125, 126: 126, 127: 127, 128: 127, 129: 127}[raw]
    assert requant_ref(raw, 65536, 16) == expected
    assert requant_ref(raw, 65536, 16, relu=True) == max(0, expected)
    for offset, target in [(-1, raw), (0, raw), (1, raw + 1)]:
        acc = 2 * raw + offset
        assert requant_raw(acc, 65536, 17) == target
        assert requant_ref(acc, 65536, 17) == min(127, max(-128, target))
        assert requant_ref(acc, 65536, 17, relu=True) == min(127, max(0, target))


@pytest.mark.parametrize('M0', [65536, 65537, 131070, 131071])
def test_T_NUM_REQ_001_all_supported_shifts_and_int32_edges(M0):
    for n in range(1, 50):
        for acc in [-(2**31), -1, 0, 1, 2**31 - 1]:
            expected = nearest_ties_positive(acc * M0, 2**n)
            assert requant_raw(acc, M0, n) == expected
    assert requant_raw(-(2**31), M0, 49) == 0
    assert requant_raw(2**31 - 1, M0, 49) == 0


@pytest.mark.parametrize('M0', [-1, 0, 65535, 131072, 262143])
def test_T_NUM_REQ_001_invalid_multiplier(M0):
    with pytest.raises(ValueError, match='M0'):
        requant_ref(0, M0, 17)


@pytest.mark.parametrize('acc', [-(2**31) - 1, 2**31])
def test_T_NUM_REQ_001_invalid_accumulator(acc):
    with pytest.raises(ValueError, match='INT32'):
        requant_ref(acc, 65536, 17)


@pytest.mark.parametrize('n', [-1, 64])
def test_T_NUM_REQ_001_invalid_shift_field(n):
    with pytest.raises(ValueError, match='6-bit'):
        requant_ref(0, 65536, n)


def test_T_NUM_REQ_001_zero_shift_unresolved():
    with pytest.raises(ValueError, match='n=0.*temporarily.*unresolved'):
        requant_ref(0, 65536, 0)


@pytest.mark.parametrize('n', range(50, 64))
def test_T_NUM_REQ_001_rounding_operand_overflows_50_bits(n):
    for acc in [-(2**31), -1, 0, 2**31 - 1]:
        with pytest.raises(OverflowError, match=f'rounding constant for n={n}.*50-bit'):
            requant_ref(acc, 131071, n)
    # n=50, negative acc: sum could fit, but its positive rounding operand cannot.


def test_T_NUM_REQ_001_signed50_guard_and_reachable_sum_bound():
    lo, hi = -(2**49), 2**49 - 1
    assert checked_signed50(lo) == lo
    assert checked_signed50(hi) == hi
    for value in (lo - 1, hi + 1):
        with pytest.raises(OverflowError, match='test sum.*50-bit'):
            checked_signed50(value, name='test sum')
    # No sum overflow is reachable after valid operands pass: positive maximum
    # is (2^31-1)*(2^17-1) + 2^48 < 2^49, at n=49.
    maximum_sum = (2**31 - 1) * (2**17 - 1) + 2**48
    assert checked_signed50(maximum_sum) == maximum_sum
    assert maximum_sum == 2**49 - 2**31 - 2**17 + 1


@pytest.mark.parametrize('args', [(True, 65536, 17), (1., 65536, 17),
                                  (0, 65536., 17), (0, 65536, True), (0, 65536, '17')])
def test_T_NUM_REQ_001_strict_python_integer_inputs(args):
    with pytest.raises(TypeError, match='Python int'):
        requant_ref(*args)
    with pytest.raises(TypeError, match='relu'):
        requant_ref(0, 65536, 17, relu=1)


def test_T_NUM_REQ_001_deterministic_random_valid_vectors():
    rng = random.Random(42)
    for _ in range(2000):
        acc = rng.randint(-(2**31), 2**31 - 1)
        M0, n = rng.randint(65536, 131071), rng.randint(1, 49)
        raw = nearest_ties_positive(acc * M0, 2**n)
        assert requant_raw(acc, M0, n) == raw
        for relu in (False, True):
            expected = min(127, max(0 if relu else -128, raw))
            assert requant_ref(acc, M0, n, relu=relu) == expected
