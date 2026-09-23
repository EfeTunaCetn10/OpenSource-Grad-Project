"""Standalone ADR-003 integer requantizer; strict 50-bit intermediates, no wrap.

Temporary supported shift domain: 1..49. n=0 is unresolved in the ADR;
50..63 cannot represent the positive rounding constant in signed 50 bits.
Only built-in Python int operands are accepted (including rejection of bool).
"""

INT32_MIN = -(1 << 31)
INT32_MAX = (1 << 31) - 1
SIGNED50_MIN = -(1 << 49)
SIGNED50_MAX = (1 << 49) - 1
M0_MIN = 1 << 16
M0_MAX = (1 << 17) - 1


def _require_int(value: int, name: str) -> None:
    if type(value) is not int:
        raise TypeError(f'{name} must be a built-in Python int, not {type(value).__name__}')


def checked_signed50(value: int, *, name: str = 'intermediate') -> int:
    """Validate a mathematical integer without truncation, wrap or saturation."""
    _require_int(value, name)
    if not SIGNED50_MIN <= value <= SIGNED50_MAX:
        raise OverflowError(f'{name}={value} is outside signed 50-bit range '
                            f'[{SIGNED50_MIN}, {SIGNED50_MAX}]; no wrap/saturation policy')
    return value


def requant_raw(acc: int, M0: int, n: int) -> int:
    """Return the rounded integer before final INT8 saturation.

    Python >> on negative int is arithmetic (floor), matching signed RTL >>>.
    The rounding operand itself must fit, even if a negative product could
    bring an otherwise too-large rounding constant back into range.
    """
    for name, value in (('acc', acc), ('M0', M0), ('n', n)):
        _require_int(value, name)
    if not INT32_MIN <= acc <= INT32_MAX:
        raise ValueError('acc must be signed INT32 [-2^31, 2^31-1]')
    if not M0_MIN <= M0 <= M0_MAX:
        raise ValueError('M0 must be in [2^16, 2^17); positive signed 18-bit carrier')
    if not 0 <= n <= 63:
        raise ValueError('n must fit unsigned 6-bit [0, 63]')
    if n == 0:
        raise ValueError('n=0 is temporarily unsupported: ADR-003 rounding policy unresolved')
    product = checked_signed50(acc * M0, name='acc*M0')
    rounding = checked_signed50(1 << (n - 1), name=f'rounding constant for n={n}')
    total = checked_signed50(product + rounding, name='acc*M0 + rounding constant')
    return total >> n


def requant_ref(acc: int, M0: int, n: int, *, relu: bool = False) -> int:
    """Round half-up, then clamp to [0,127] or [-128,127]; return Python int."""
    if type(relu) is not bool:
        raise TypeError('relu must be bool')
    raw = requant_raw(acc, M0, n)
    return min(127, max(0 if relu else -128, raw))
