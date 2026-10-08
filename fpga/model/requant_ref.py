"""Golden reference model for the ADR-003 INT32 -> INT8 requantizer.

y = clamp(lo, 127, (acc * m0 + half_ulp) >>> n), lo = 0 if relu_en else -128
half_ulp = 0 for n=0, otherwise 2**(n-1); n is in [0, 63].

Python's `>>` on negative ints is a floor (arithmetic) shift, identical to
Verilog's `>>>` on a signed value -- this is what lets requant_ref() and the
RTL agree bit-for-bit with no rounding-mode compensation code on either side
(verified in ADR-003: -5 >> 1 == -3, -8 >> 2 == -2).
"""

from __future__ import annotations

import random

ACC_LO, ACC_HI = -(2**31), 2**31 - 1
M0_LO, M0_HI = 2**16, 2**17  # M0 normalized to [2**16, 2**17), 17 significant bits


def requant_ref(acc: int, m0: int, n: int, relu_en: bool) -> int:
    """ADR-003 requantization with signed INT8 output saturation."""
    y_raw = requant_raw_ref(acc, m0, n)
    lo = 0 if relu_en else -128
    return max(lo, min(127, y_raw))


def requant_raw_ref(acc: int, m0: int, n: int) -> int:
    """Signed 64-bit multiply/round/shift path before INT8 saturation."""
    if not ACC_LO <= acc <= ACC_HI:
        raise ValueError("acc must be signed INT32")
    if not M0_LO <= m0 < M0_HI:
        raise ValueError("m0 must be a normalized positive 17-bit value")
    if not 0 <= n <= 63:
        raise ValueError("n must fit unsigned 6-bit")
    half_ulp = 0 if n == 0 else 1 << (n - 1)
    # |acc*m0| < 2**48 and half_ulp <= 2**62: their sum fits signed INT64.
    return (acc * m0 + half_ulp) >> n


def tie_vectors(m0: int, n: int, spread: int = 50) -> list[int]:
    """acc values where acc*m0 sits exactly halfway between two quantization steps.

    Random vectors essentially never hit this case (0 hits in 200,000 random
    draws, measured while writing ADR-003) -- yet it is the only case where
    round-half-up, nearest-even and away-from-zero disagree in the raw result.
    With normalized M0, all such ties saturate to the same final INT8 value;
    the RTL test must compare its internal pre-clamp y_raw as well.

    m0 must be odd (invertible mod 2**n) so `base` below exists.
    Only signed INT32 inputs are returned. For n=0 there is no rounding tie.
    """
    if m0 % 2 == 0:
        raise ValueError("m0 must be odd for the modular-inverse tie construction")
    if not 0 <= n <= 63:
        raise ValueError("n must fit unsigned 6-bit")
    if n == 0:
        return []
    inv = pow(m0, -1, 2**n)
    base = (2 ** (n - 1) * inv) % 2**n
    # The 2**n multiple of j must be added to acc, not folded into the
    # multiplication that produces base -- doing the latter loses j entirely
    # under the mod 2**n and yields the same tie value 101 times instead of
    # 101 distinct ties (the bug ADR-003 flags explicitly).
    return [acc for j in range(-spread, spread + 1)
            if ACC_LO <= (acc := base + j * 2**n) <= ACC_HI]


def boundary_vectors(m0: int, n: int) -> list[int]:
    """acc values that land right at the int8 saturation edges (-128/127 and one past)."""
    return [acc for t in (-129, -128, -127, 126, 127, 128) for d in (0, 1)
            if ACC_LO <= (acc := (t * 2**n) // m0 + d) <= ACC_HI]


def random_vectors(count: int, lo: int = -(2**23), hi: int = 2**23, seed: int | None = None) -> list[int]:
    rng = random.Random(seed)
    return [rng.randint(lo, hi) for _ in range(count)]


def all_test_accs(m0: int, n: int, random_count: int = 10000, seed: int | None = None) -> list[int]:
    """The full T_NUM_REQ_001 vector set for one (m0, n) channel, per ADR-003."""
    vectors = (
        [0, 1, -1, ACC_HI, ACC_LO]
        + tie_vectors(m0, n)
        + boundary_vectors(m0, n)
        + random_vectors(random_count, seed=seed)
    )
    assert all(ACC_LO <= acc <= ACC_HI for acc in vectors)
    return vectors


if __name__ == "__main__":
    # Self-check: prove the tie generator actually generates the property it
    # claims to, and that it is discriminating (round-half-up disagrees with
    # nearest-even on at least one tie) -- the same live verification ADR-003
    # did before trusting this generator.
    m0, n = 98765, 20
    assert m0 % 2 == 1 and M0_LO <= m0 < M0_HI

    ties = tie_vectors(m0, n)
    assert len(ties) == len(set(ties)) == 101, "generator must produce 101 distinct ties"
    for acc in ties:
        assert (acc * m0) % (2**n) == 2 ** (n - 1), "acc*m0 must sit exactly on a half-ULP"

    def half_up_raw(acc: int, m0_: int, n_: int) -> int:
        return (acc * m0_ + (1 << (n_ - 1))) >> n_

    def nearest_even_raw(acc: int, m0_: int, n_: int) -> int:
        y_raw = half_up_raw(acc, m0_, n_)
        # At an exact tie, half-up always lands on the upper of the two
        # candidates; nearest-even instead wants whichever of the two is
        # even, so it steps down when that upper candidate is odd.
        if y_raw % 2 == 1:
            y_raw -= 1
        return y_raw

    # Compare raw values: for normalized M0, every valid tie saturates to
    # -128/127 and the final INT8 result cannot distinguish rounding rules.
    disagreements = sum(
        1 for acc in ties if half_up_raw(acc, m0, n) != nearest_even_raw(acc, m0, n)
    )
    assert disagreements > 0, "tie set must be able to distinguish round-half-up from nearest-even"
    clamp = lambda value: max(-128, min(127, value))
    assert all(clamp(half_up_raw(acc, m0, n)) == clamp(nearest_even_raw(acc, m0, n))
               for acc in ties)

    assert requant_raw_ref(ACC_HI, 131071, 0) == ACC_HI * 131071
    assert requant_raw_ref(ACC_LO, 131071, 63) == 0
    assert len(tie_vectors(131071, 31)) == 2
    assert all(ACC_LO <= acc <= ACC_HI for acc in all_test_accs(131071, 63, random_count=0))

    random_ties_hits = sum(1 for acc in random_vectors(200_000, seed=0) if (acc * m0) % (2**n) == 2 ** (n - 1))
    assert random_ties_hits == 0, "sanity: random vectors should not hit a tie either"

    print(f"m0={m0} n={n}: {len(ties)} distinct ties, {disagreements} disagree with nearest-even, "
          f"0/200000 random draws hit a tie -- generator confirmed.")
