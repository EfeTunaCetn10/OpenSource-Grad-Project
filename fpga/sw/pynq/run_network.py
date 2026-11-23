#!/usr/bin/env python3
"""PYNQ-Z2 board entry point for a generated netprog."""
import argparse
import sys
import time
from pathlib import Path

from accel_driver import AccelDriver

COMMON = Path(__file__).resolve().parents[1] / "common"
if str(COMMON) not in sys.path:
    sys.path.insert(0, str(COMMON))
import accel_regs as R


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bit", help=".bit file; matching .hwh must be beside it")
    parser.add_argument("program", help="generated .prog file")
    parser.add_argument("--accel", default="accel_0", help="accelerator block-design name")
    parser.add_argument("--dma", default="axi_dma_0", help="AXI DMA block-design name")
    parser.add_argument("--timeout", type=float, default=1.0)
    parser.add_argument("--no-compare", action="store_true", help="return hardware output without golden comparison")
    args = parser.parse_args()

    bit = Path(args.bit)
    hwh = bit.with_suffix(".hwh")
    if bit.suffix.lower() != ".bit" or not bit.is_file() or not hwh.is_file():
        parser.error(f"overlay pair is required: {bit} and {hwh}")

    from pynq import Overlay, allocate
    overlay = Overlay(str(bit))
    accel = getattr(overlay, args.accel)
    dma = getattr(overlay, args.dma)
    version = accel.mmio.read(R.VERSION) & 0xFFFF
    if version != R.REGMAP_VERSION:
        raise RuntimeError(f"register map version {version}, expected {R.REGMAP_VERSION}")

    driver = AccelDriver(accel.mmio, dma, allocate, compare=not args.no_compare, timeout=args.timeout)
    start = time.monotonic()
    classes = driver.classify(args.program)
    elapsed = time.monotonic() - start
    per_image = elapsed / len(classes)
    print("predicted classes:", " ".join(map(str, classes)))
    print(f"per-image wall time: {per_image:.6f} s ({len(classes)} image(s))")
    for name in ("CYCLE_COUNT", "STALL_IN", "STALL_OUT", "FRAME_COUNT"):
        print(f"{name}: {accel.mmio.read(getattr(R, name))}")


if __name__ == "__main__":
    main()
