"""T_NUM_REQ_001: independent arithmetic checks; no dataset or model imports."""
from fractions import Fraction
import random

import pytest

from requant_ref import checked_signed64, requant_raw, requant_ref


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
    for n in range(64):
        for acc in [-(2**31), -1, 0, 1, 2**31 - 1]:
            expected = nearest_ties_positive(acc * M0, 2**n)
            assert requant_raw(acc, M0, n) == expected
    assert requant_raw(-(2**31), M0, 49) == 0
    assert requant_raw(2**31 - 1, M0, 49) == 0


@pytest.mark.parametrize('M0', [-1, 0, 65535, 131072, 262143])
def test_T_NUM_REQ_001_invalid_multiplier(M0):
    with pytest.raises(ValueError, match='M0'):
        requant_ref(0, M0, 17)


@pytest.mark.parametrize('acc,wrapped', [(-(2**31)-1, 2**31-1), (2**31, -(2**31))])
def test_T_NUM_REQ_001_accumulator_wrap(acc, wrapped):
    assert requant_raw(acc, 65536, 16) == wrapped


@pytest.mark.parametrize('n', [-1, 64])
def test_T_NUM_REQ_001_invalid_shift_field(n):
    with pytest.raises(ValueError, match='6-bit'):
        requant_ref(0, 65536, n)


@pytest.mark.parametrize('acc', [-(2**31), -1, 0, 1, 2**31-1])
@pytest.mark.parametrize('n', [0, 1, 49, 50, 63])
def test_T_NUM_REQ_001_signed64_full_shift_domain(acc, n):
    assert requant_raw(acc, 131071, n) == nearest_ties_positive(acc*131071, 2**n)
    if n == 0:
        assert requant_raw(acc, 131071, n) == acc*131071


def test_T_NUM_REQ_001_signed64_guard():
    lo, hi = -(2**63), 2**63-1
    assert checked_signed64(lo) == lo and checked_signed64(hi) == hi
    for value in (lo-1, hi+1):
        with pytest.raises(OverflowError, match='64-bit'):
            checked_signed64(value)
    with pytest.raises(TypeError):
        checked_signed64(True)
    maximum = (2**31-1)*131071 + 2**62
    assert checked_signed64(maximum) == maximum < hi


@pytest.mark.parametrize('n', [1,16,20,24,27,31,32,33,50,63])
def test_T_NUM_REQ_001_odd_multiplier_tie_coverage(n):
    M0 = 65537
    base = (2**(n-1)*pow(M0,-1,2**n)) % 2**n
    ties = [base+j*2**n for j in range(-50,51) if -2**31 <= base+j*2**n < 2**31]
    assert ties or n > 32
    assert bool(ties) == (n <= 32)  # This statement is for odd M0 only.
    for acc in ties:
        assert (acc*M0) % 2**n == 2**(n-1)
        assert requant_raw(acc,M0,n) == nearest_ties_positive(acc*M0,2**n)


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
        M0, n = rng.randint(65536, 131071), rng.randint(0, 63)
        raw = nearest_ties_positive(acc * M0, 2**n)
        assert requant_raw(acc, M0, n) == raw
        for relu in (False, True):
            expected = min(127, max(0 if relu else -128, raw))
            assert requant_ref(acc, M0, n, relu=relu) == expected


def test_even_multiplier_can_have_ties_above_shift32():
    # ADR odd-multiplier tie-generator coverage must not be generalized to even M0.
    assert requant_raw(65536, 65536, 33) == 1
    assert requant_raw(-65536, 65536, 33) == 0
