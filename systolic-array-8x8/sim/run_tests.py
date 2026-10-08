#!/usr/bin/env python3
"""XSim regression runner (ADR-009 Katman 1 + Katman 2).

Compiles every source under rtl/ and tb/, then elaborates and runs every
module whose name starts with `tb_`. A test passes when XSim exits 0, its
output contains a PASS line, and it contains no error/failure marker.

Why XSim and not cocotb+Icarus: ADR-009 chose cocotb+Icarus because Vivado
was assumed absent and cocotb does not support XSim. Vivado 2025.1 is
installed on this machine and XSim runs the whole contract -- including
SystemVerilog assertions and encrypted Xilinx IP, which Icarus cannot do.
One simulator now covers both verification layers.

Usage:
    python sim/run_tests.py                # run everything
    python sim/run_tests.py tb_pe_os       # run named tests only
    python sim/run_tests.py --list         # list discovered tests
    python sim/run_tests.py --keep         # keep build dir on success

Vivado location is taken from $VIVADO_BIN, else $XILINX_VIVADO/bin, else a
short list of default install paths.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
RTL_DIR = PROJECT / "rtl"
TB_DIR = PROJECT / "tb"
BUILD = PROJECT / "sim" / "build"

# A test is only green if it says so. Absence of failure is not success:
# an XSim run that ends early still exits 0.
PASS_RE = re.compile(r"\bPASS\b")
FAIL_RE = re.compile(
    r"\bFAIL\b|\bFAILED\b|\bMISMATCH\b"
    r"|Error:|ERROR:"
    r"|\$error|\$fatal"
    r"|Assertion .* failed"
    r"|\bUNRESOLVED\b",
    re.IGNORECASE,
)

DEFAULT_VIVADO_DIRS = [
    r"C:\Vivado\2025.1\Vivado\bin",
    r"C:\Xilinx\Vivado\2025.1\bin",
    r"C:\Xilinx\Vivado\2024.2\bin",
    r"/tools/Xilinx/Vivado/2025.1/bin",
]


def find_vivado_bin() -> Path:
    env = os.environ.get("VIVADO_BIN")
    if env:
        p = Path(env)
        if p.is_dir():
            return p
        raise SystemExit(f"VIVADO_BIN is set but not a directory: {env}")

    xv = os.environ.get("XILINX_VIVADO")
    if xv and (Path(xv) / "bin").is_dir():
        return Path(xv) / "bin"

    for cand in DEFAULT_VIVADO_DIRS:
        if Path(cand).is_dir():
            return Path(cand)

    on_path = shutil.which("xvlog")
    if on_path:
        return Path(on_path).parent

    raise SystemExit(
        "Could not locate Vivado. Set VIVADO_BIN to the directory holding "
        "xvlog/xelab/xsim."
    )


def tool(bin_dir: Path, name: str) -> str:
    """xvlog on Windows is a .bat wrapper; bare name has no exec bit."""
    bat = bin_dir / f"{name}.bat"
    if bat.exists():
        return str(bat)
    return str(bin_dir / name)


def ascii_guard() -> None:
    """Vivado silently mangles non-ASCII path characters into '?'.

    Observed 2026-09-26: a source under a directory named with an emoji is
    reported as "Can not find file" with the character replaced. Fail loudly
    here instead of debugging a phantom missing file later.
    """
    try:
        str(PROJECT).encode("ascii")
    except UnicodeEncodeError:
        raise SystemExit(
            f"Project path contains non-ASCII characters and Vivado cannot read it:\n"
            f"  {PROJECT}\n"
            f"Move or clone the repository to an ASCII-only path."
        )


# Each generator is paired with one file it must produce.  Checking a per
# generator sentinel rather than "any *.mem exists" matters: the requant
# vectors alone used to satisfy that test, so a second generator would have
# been skipped and its testbench would then fail on a missing file.
VECTOR_GENERATORS = [
    ("gen_requant_vectors.py", "req_y.mem"),
    ("gen_conv1_vectors.py", "c1_y.mem"),
    ("gen_act_buffer_vectors.py", "actbuf_frame0.mem"),
]


def ensure_vectors() -> None:
    """Regenerate the $readmemh vectors if they are missing.

    They are deterministic (seeded) and several MB, so they are gitignored
    rather than committed -- which means a fresh clone has none and the tests
    that read them would fail on a missing file instead of a real defect.
    """
    vec_dir = PROJECT / "sim" / "vectors"
    for gen_name, sentinel in VECTOR_GENERATORS:
        gen = PROJECT / "model" / gen_name
        if not gen.exists():
            continue
        if (vec_dir / sentinel).exists():
            continue
        print(f"[vectors] generating vectors with {gen_name}")
        proc = subprocess.run(
            [sys.executable, str(gen)], cwd=str(PROJECT),
            capture_output=True, text=True
        )
        if proc.returncode != 0:
            raise SystemExit(
                f"{gen_name} failed:\n{proc.stdout}\n{proc.stderr}"
            )


def sources() -> list[Path]:
    rtl = sorted(RTL_DIR.glob("*.sv"))
    tb = sorted(TB_DIR.glob("*.sv"))
    if not rtl:
        raise SystemExit(f"No RTL sources found under {RTL_DIR}")
    return rtl + tb


def discover_tests() -> list[str]:
    tops: list[str] = []
    for f in sorted(TB_DIR.glob("*.sv")):
        for m in re.finditer(r"^\s*module\s+(tb_\w+)", f.read_text(encoding="utf-8", errors="replace"), re.M):
            tops.append(m.group(1))
    return tops


def run(cmd: list[str], cwd: Path) -> tuple[int, str]:
    proc = subprocess.run(
        cmd, cwd=str(cwd), capture_output=True, text=True, errors="replace"
    )
    return proc.returncode, proc.stdout + proc.stderr


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("tests", nargs="*", help="test tops to run (default: all)")
    ap.add_argument("--list", action="store_true", help="list tests and exit")
    ap.add_argument("--keep", action="store_true", help="keep build dir")
    ap.add_argument("--verbose", "-v", action="store_true", help="always show output")
    args = ap.parse_args()

    ascii_guard()

    all_tests = discover_tests()
    if args.list:
        for t in all_tests:
            print(t)
        return 0

    selected = args.tests or all_tests
    unknown = [t for t in selected if t not in all_tests]
    if unknown:
        print(f"Unknown test(s): {', '.join(unknown)}")
        print(f"Available: {', '.join(all_tests) or '(none)'}")
        return 2
    if not selected:
        print("No tb_* modules found -- nothing to run.")
        return 2

    bin_dir = find_vivado_bin()
    ensure_vectors()
    BUILD.mkdir(parents=True, exist_ok=True)

    srcs = sources()
    rel = [os.path.relpath(s, BUILD) for s in srcs]
    print(f"[xvlog] compiling {len(rel)} file(s)")
    rc, out = run([tool(bin_dir, "xvlog"), "-sv", "--incr", *rel], BUILD)
    if rc != 0 or "ERROR" in out:
        print(out)
        print("FAIL: compilation failed")
        return 1

    results: list[tuple[str, bool, str]] = []
    for top in selected:
        snap = f"{top}_snap"
        rc, out = run(
            [tool(bin_dir, "xelab"), "-debug", "off", "-top", top, "-snapshot", snap],
            BUILD,
        )
        if rc != 0 or "ERROR" in out:
            results.append((top, False, f"elaboration failed\n{out}"))
            continue

        rc, out = run([tool(bin_dir, "xsim"), snap, "-runall"], BUILD)
        ok = rc == 0 and bool(PASS_RE.search(out)) and not FAIL_RE.search(out)
        results.append((top, ok, out))

    print()
    width = max(len(t) for t, _, _ in results)
    failed = 0
    for top, ok, out in results:
        print(f"  {top.ljust(width)}  {'PASS' if ok else 'FAIL'}")
        if not ok:
            failed += 1
        if args.verbose or not ok:
            for line in out.splitlines():
                print(f"      | {line}")

    total = len(results)
    print(f"\n{total - failed}/{total} passed")

    if failed == 0 and not args.keep:
        shutil.rmtree(BUILD, ignore_errors=True)

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
