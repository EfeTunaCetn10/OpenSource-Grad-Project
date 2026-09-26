"""Stdlib-only golden model for the K-streaming output-stationary engine."""

from __future__ import annotations


MASK32 = (1 << 32) - 1
SIGN32 = 1 << 31


def wrap32(value: int) -> int:
    """Return *value* interpreted as a signed two's-complement INT32."""
    value &= MASK32
    return value - (1 << 32) if value & SIGN32 else value


def engine_ref(
    A: list[list[int]],
    B: list[list[int]],
    active_rows: int,
    active_cols: int,
    k_len: int,
) -> tuple[list[list[int]], list[tuple[int, int, int]]]:
    """Return a full result matrix and column-major drain order.

    ``A[r][k]`` is a weight entering the left edge and ``B[k][c]`` is an
    activation entering the top edge.  The drain list is ordered by cycle,
    then lane: ``(lane, column, value)`` for every active row of each active
    column.  Inactive matrix entries are returned as zero.
    """
    if active_rows <= 0 or active_cols <= 0 or k_len <= 0:
        raise ValueError("active dimensions and k_len must be positive")
    if len(A) < active_rows or len(B) < k_len:
        raise ValueError("matrix has fewer rows than the requested tile")
    if any(len(A[r]) < k_len for r in range(active_rows)):
        raise ValueError("A has fewer than k_len columns")
    if any(len(B[k]) < active_cols for k in range(k_len)):
        raise ValueError("B has fewer than active_cols columns")

    rows = len(A)
    cols = max((len(row) for row in B), default=0)
    result = [[0 for _ in range(cols)] for _ in range(rows)]
    drain: list[tuple[int, int, int]] = []

    for r in range(active_rows):
        for c in range(active_cols):
            acc = 0
            for k in range(k_len):
                acc = wrap32(acc + int(A[r][k]) * int(B[k][c]))
            result[r][c] = acc

    for c in range(active_cols):
        for r in range(active_rows):
            drain.append((r, c, result[r][c]))
    return result, drain


compute_engine_ref = engine_ref


def _self_check() -> None:
    A = [[-128, 127, -3], [7, -9, 11]]
    B = [[127, -2], [-128, 5], [3, 17]]
    result, drain = engine_ref(A, B, 2, 2, 3)
    expected = [
        [wrap32(-128 * 127 + 127 * -128 + -3 * 3),
         wrap32(-128 * -2 + 127 * 5 + -3 * 17)],
        [wrap32(7 * 127 + -9 * -128 + 11 * 3),
         wrap32(7 * -2 + -9 * 5 + 11 * 17)],
    ]
    assert result == expected
    assert drain == [
        (0, 0, expected[0][0]), (1, 0, expected[1][0]),
        (0, 1, expected[0][1]), (1, 1, expected[1][1]),
    ]

    wrap_result, _ = engine_ref([[127] * 131073], [[127]] * 131073, 1, 1, 131073)
    assert wrap_result[0][0] == wrap32(127 * 127 * 131073)
    print("PASS engine_ref")


if __name__ == "__main__":
    _self_check()
