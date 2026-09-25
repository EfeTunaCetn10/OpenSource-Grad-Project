"""T_NUM_REQ_001: bit-exact check of rtl/requantizer.sv against requant_ref().

Per ADR-003, this is the tie-vector test, not a random one: random vectors
essentially never land exactly on a rounding boundary (0 hits in 200,000
draws, measured in ADR-003), so a random-only test would pass even with the
wrong rounding rule. tie_vectors() constructs acc values that force
acc*m0 == exactly half a quantization step. The final INT8 output saturates
for these vectors, so the test also checks the internal pre-clamp y_raw.

Run (requires cocotb + Icarus Verilog):
    cd tb/cocotb && make
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "model"))

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, ReadOnly, RisingEdge

from requant_ref import ACC_HI, ACC_LO, all_test_accs, requant_raw_ref, requant_ref

# (m0, n) pairs exercised: two representative per-channel scales plus the
# n=1 minimal-shift edge. Each m0 is odd and in [2**16, 2**17), as ADR-003's
# modular-inverse tie construction requires.
CHANNELS = [
    (98765, 20),
    (131071, 31),  # 2**17 - 1 : max m0, wide shift
    (65537, 1),    # 2**16 + 1 : min m0, minimal shift
]

ACC_MASK = (1 << 32) - 1
M0_MASK = (1 << 18) - 1


def to_signed(value: int, width: int) -> int:
    value &= (1 << width) - 1
    if value >= 1 << (width - 1):
        value -= 1 << width
    return value


async def drive_and_check(dut, acc: int, m0: int, n: int, relu_en: bool) -> None:
    await FallingEdge(dut.clk)
    dut.acc.value = acc & ACC_MASK
    dut.m0.value = m0 & M0_MASK
    dut.n.value = n
    dut.relu_en.value = int(relu_en)
    dut.valid_in.value = 1
    await RisingEdge(dut.clk)
    await ReadOnly()

    expected = requant_ref(acc, m0, n, relu_en)
    got = to_signed(int(dut.y.value), 8)
    raw_expected = requant_raw_ref(acc, m0, n)
    raw_got = to_signed(int(dut.y_raw.value), 64)
    assert dut.valid_out.value == 1, "valid_out must follow valid_in one cycle later"
    assert raw_got == raw_expected, (
        f"acc={acc} m0={m0} n={n}: RTL y_raw={raw_got} != golden {raw_expected}"
    )
    assert got == expected, (
        f"acc={acc} m0={m0} n={n} relu_en={relu_en}: RTL y={got} != golden {expected}"
    )


@cocotb.test()
async def test_requantizer_bit_exact(dut):
    cocotb.start_soon(Clock(dut.clk, 10, units="ns").start())

    dut.rst_n.value = 0
    dut.valid_in.value = 0
    dut.acc.value = 0
    dut.m0.value = 0
    dut.n.value = 0
    dut.relu_en.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await FallingEdge(dut.clk)
    dut.rst_n.value = 1

    checked = 0
    for m0, n in CHANNELS:
        for relu_en in (False, True):
            for acc in all_test_accs(m0, n, random_count=10000, seed=0):
                await drive_and_check(dut, acc, m0, n, relu_en)
                checked += 1

    # n=0 bypasses the rounding offset; n=49/50/63 exercise bits that a
    # 50-bit multiply/add path cannot represent correctly.
    for n in (0, 49, 50, 63):
        for relu_en in (False, True):
            for acc in (ACC_LO, ACC_LO + 1, -1, 0, 1, ACC_HI - 1, ACC_HI):
                await drive_and_check(dut, acc, 131071, n, relu_en)
                checked += 1

    dut._log.info(
        f"T_NUM_REQ_001: {checked} vectors bit-exact against raw and clamped reference "
        f"across {len(CHANNELS)} main channels plus n=0/49/50/63 edges"
    )
