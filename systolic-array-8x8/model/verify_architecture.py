"""Independent cycle model for the output-stationary 8x8 RTL contract."""

from __future__ import annotations

import random


def wrap_int32(value: int) -> int:
    """Signed interpretation of an INT32 accumulator's modulo-2**32 sum."""
    return ((value + (1 << 31)) & 0xFFFFFFFF) - (1 << 31)


def systolic_tile(a: list[list[int]], b: list[list[int]], rows: int, cols: int, k_len: int):
    a_pipe = [[0] * cols for _ in range(rows)]
    b_pipe = [[0] * cols for _ in range(rows)]
    av_pipe = [[False] * cols for _ in range(rows)]
    bv_pipe = [[False] * cols for _ in range(rows)]
    acc = [[0] * cols for _ in range(rows)]
    mac_count = 0

    run_cycles = k_len + rows + cols - 2
    for cycle in range(run_cycles):
        next_a = [[0] * cols for _ in range(rows)]
        next_b = [[0] * cols for _ in range(rows)]
        next_av = [[False] * cols for _ in range(rows)]
        next_bv = [[False] * cols for _ in range(rows)]

        for row in range(rows):
            for col in range(cols):
                if col == 0:
                    a_index = cycle - row
                    a_in = a[row][a_index] if 0 <= a_index < k_len else 0
                    av_in = 0 <= a_index < k_len
                else:
                    a_in = a_pipe[row][col - 1]
                    av_in = av_pipe[row][col - 1]

                if row == 0:
                    b_index = cycle - col
                    b_in = b[b_index][col] if 0 <= b_index < k_len else 0
                    bv_in = 0 <= b_index < k_len
                else:
                    b_in = b_pipe[row - 1][col]
                    bv_in = bv_pipe[row - 1][col]

                next_a[row][col] = a_in
                next_b[row][col] = b_in
                next_av[row][col] = av_in
                next_bv[row][col] = bv_in
                if av_in and bv_in:
                    acc[row][col] = wrap_int32(acc[row][col] + a_in * b_in)
                    mac_count += 1

        a_pipe, b_pipe = next_a, next_b
        av_pipe, bv_pipe = next_av, next_bv

    return acc, mac_count, run_cycles


def golden(a: list[list[int]], b: list[list[int]], rows: int, cols: int, k_len: int):
    return [
        [wrap_int32(sum(a[row][k] * b[k][col] for k in range(k_len))) for col in range(cols)]
        for row in range(rows)
    ]


def main() -> None:
    assert wrap_int32((1 << 31) - 1 + 1) == -(1 << 31)
    assert wrap_int32(-(1 << 31) - 1) == (1 << 31) - 1
    assert wrap_int32((1 << 31) - 1 + 2 * 16384) == -(1 << 31) + 32767
    rng = random.Random(0x8A64)
    cases = [(8, 8, 8), (3, 5, 7), (1, 1, 1), (8, 2, 5)]
    for case_index, (rows, cols, k_len) in enumerate(cases, start=1):
        a = [[rng.randint(-128, 127) for _ in range(k_len)] for _ in range(rows)]
        b = [[rng.randint(-128, 127) for _ in range(cols)] for _ in range(k_len)]
        observed, mac_count, cycles = systolic_tile(a, b, rows, cols, k_len)
        expected = golden(a, b, rows, cols, k_len)
        assert observed == expected, f"case {case_index}: matrix mismatch"
        assert mac_count == rows * cols * k_len, f"case {case_index}: MAC-count mismatch"
        assert cycles == k_len + rows + cols - 2
        print(
            f"PASS case={case_index} shape={rows}x{cols} K={k_len} "
            f"run_cycles={cycles} macs={mac_count}"
        )


if __name__ == "__main__":
    main()
