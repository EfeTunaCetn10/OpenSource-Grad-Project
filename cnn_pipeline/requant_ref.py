"""ADR-003 revision 2026-09-25: INT32 wrap, signed-64 requant, n=0..63.

requant_raw keeps pre-clamp y_raw observable. Existing scalar return APIs remain.
"""
from integer_linear_ref import wrap32

INT32_MIN = -(1 << 31)
INT32_MAX = (1 << 31) - 1
SIGNED50_MIN = -(1 << 49)
SIGNED50_MAX = (1 << 49) - 1
SIGNED64_MIN = -(1 << 63)
SIGNED64_MAX = (1 << 63) - 1
M0_MIN = 1 << 16
M0_MAX = (1 << 17) - 1


def _require_int(value: int, name: str) -> None:
    if type(value) is not int:
        raise TypeError(f'{name} must be a built-in Python int, not {type(value).__name__}')


def checked_signed50(value: int, *, name: str = 'intermediate') -> int:
    """Legacy 50-bit range utility, retained for callers; NOT the requant path."""
    _require_int(value, name)
    if not SIGNED50_MIN <= value <= SIGNED50_MAX:
        raise OverflowError(f'{name}={value} is outside signed 50-bit range '
                            f'[{SIGNED50_MIN}, {SIGNED50_MAX}]; no wrap/saturation policy')
    return value



def checked_signed64(value: int, *, name: str = 'intermediate') -> int:
    """Validate a signed-64 intermediate; never truncate or saturate."""
    _require_int(value, name)
    if not SIGNED64_MIN <= value <= SIGNED64_MAX:
        raise OverflowError(f'{name}={value} outside signed 64-bit range')
    return value


def requant_raw(acc: int, M0: int, n: int) -> int:
    """Wrap accumulator input to INT32, return pre-clamp half-up result.

    n=0 has zero rounding offset and no shift. Product, offset and sum are
    explicitly checked as signed64. No hardware timing or flag protocol implied.
    """
    for name, value in (('acc', acc), ('M0', M0), ('n', n)):
        _require_int(value, name)
    if not M0_MIN <= M0 <= M0_MAX:
        raise ValueError('M0 must be in [2^16, 2^17); positive signed 18-bit carrier')
    if not 0 <= n <= 63:
        raise ValueError('n must fit unsigned 6-bit [0, 63]')
    product = checked_signed64(wrap32(acc) * M0, name='acc*M0')
    rounding = checked_signed64(0 if n == 0 else 1 << (n - 1), name='half_ulp')
    total = checked_signed64(product + rounding, name='product + half_ulp')
    return total >> n


def requant_ref(acc: int, M0: int, n: int, *, relu: bool = False) -> int:
    """Round half-up, then clamp to [0,127] or [-128,127]; return Python int."""
    if type(relu) is not bool:
        raise TypeError('relu must be bool')
    raw = requant_raw(acc, M0, n)
    return min(127, max(0 if relu else -128, raw))
