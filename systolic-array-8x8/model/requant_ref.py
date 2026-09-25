"""Golden reference model for the ADR-003 INT32 -> INT8 requantizer.

y = clamp(lo, 127, (acc * m0 + (1 << (n - 1))) >>> n), lo = 0 if relu_en else -128

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
    """ADR-003 requantization formula, evaluated in arbitrary-precision Python ints."""
    y_raw = (acc * m0 + (1 << (n - 1))) >> n
    lo = 0 if relu_en else -128
    return max(lo, min(127, y_raw))


def tie_vectors(m0: int, n: int, spread: int = 50) -> list[int]:
    """acc values where acc*m0 sits exactly halfway between two quantization steps.

    Random vectors essentially never hit this case (0 hits in 200,000 random
    draws, measured while writing ADR-003) -- yet it is the only case where
    round-half-up, nearest-even and away-from-zero disagree. Skipping it lets
    a wrong rounding rule pass every test and show up three months later as a
    few stray pixels.

    m0 must be odd (invertible mod 2**n) so `base` below exists.
    """
    if m0 % 2 == 0:
        raise ValueError("m0 must be odd for the modular-inverse tie construction")
    inv = pow(m0, -1, 2**n)
    base = (2 ** (n - 1) * inv) % 2**n
    # The 2**n multiple of j must be added to acc, not folded into the
    # multiplication that produces base -- doing the latter loses j entirely
    # under the mod 2**n and yields the same tie value 101 times instead of
    # 101 distinct ties (the bug ADR-003 flags explicitly).
    return [base + j * 2**n for j in range(-spread, spread + 1)]


def boundary_vectors(m0: int, n: int) -> list[int]:
    """acc values that land right at the int8 saturation edges (-128/127 and one past)."""
    return [(t * 2**n) // m0 + d for t in (-129, -128, -127, 126, 127, 128) for d in (0, 1)]


def random_vectors(count: int, lo: int = -(2**23), hi: int = 2**23, seed: int | None = None) -> list[int]:
    rng = random.Random(seed)
    return [rng.randint(lo, hi) for _ in range(count)]


def all_test_accs(m0: int, n: int, random_count: int = 10000, seed: int | None = None) -> list[int]:
    """The full T_NUM_REQ_001 vector set for one (m0, n) channel, per ADR-003."""
    return (
        [0, 1, -1, ACC_HI, ACC_LO]
        + tie_vectors(m0, n)
        + boundary_vectors(m0, n)
        + random_vectors(random_count, seed=seed)
    )


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

    # Compared unclamped: saturation would clip both rules to the same
    # -128/127 bucket for the far-out j values and mask a real disagreement.
    disagreements = sum(
        1 for acc in ties if half_up_raw(acc, m0, n) != nearest_even_raw(acc, m0, n)
    )
    assert disagreements > 0, "tie set must be able to distinguish round-half-up from nearest-even"

    random_ties_hits = sum(1 for acc in random_vectors(200_000, seed=0) if (acc * m0) % (2**n) == 2 ** (n - 1))
    assert random_ties_hits == 0, "sanity: random vectors should not hit a tie either"

    print(f"m0={m0} n={n}: {len(ties)} distinct ties, {disagreements} disagree with nearest-even, "
          f"0/200000 random draws hit a tie -- generator confirmed.")
