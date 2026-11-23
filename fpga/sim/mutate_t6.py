#!/usr/bin/env python3
"""Mutation testing runner for Phase 6 (faz6 Lane TM).

Verifies that tb_fc1_order and tb_axis_lane detect their intended defects:
  - M1 (flatten-order): swaps HWC address terms in rtl/act_buffer.sv
  - M2 (s_axis lane reversal): reverses byte lanes on s_axis_tdata in rtl/accel_axis.sv
  - M3 (m_axis lane reversal): reverses byte lanes on m_axis_tdata in rtl/accel_axis.sv

Scratch builds are isolated in sim/mutbuild_t6/<run_name>/.
Controls are run unmutated through the same scratch flow to ensure validity.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

# Locate directories
SIM_DIR = Path(__file__).resolve().parent
PROJECT = SIM_DIR.parent
RTL_DIR = PROJECT / "rtl"
TB_DIR = PROJECT / "tb"
MUTBUILD_BASE = SIM_DIR / "mutbuild_t6"

# Import helpers from run_tests.py
if str(SIM_DIR) not in sys.path:
    sys.path.insert(0, str(SIM_DIR))

import run_tests

MUTANTS = [
    {
        "id": "m1",
        "name": "m1_flatten_order",
        "test": "tb_fc1_order",
        "file": "act_buffer.sv",
        "anchor": (
            "                else if (rd_t == rd_tiles_m1) begin\n"
            "                    rd_t <= '0;\n"
            "                    rd_pix <= rd_pix + 1'b1;\n"
            "                    rd_addr <= rd_pix + 1'b1;\n"
            "                end else begin\n"
            "                    rd_t <= rd_t + 1'b1;\n"
            "                    rd_addr <= rd_addr + rd_plane;\n"
            "                end"
        ),
        "replacement": (
            "                else if (rd_t == rd_tiles_m1) begin\n"
            "                    rd_t <= '0;\n"
            "                    rd_pix <= rd_pix + 1'b1;\n"
            "                    rd_addr <= rd_pix + rd_plane;\n"
            "                end else begin\n"
            "                    rd_t <= rd_t + 1'b1;\n"
            "                    rd_addr <= rd_addr + 1'b1;\n"
            "                end"
        ),
    },
    {
        "id": "m2",
        "name": "m2_s_axis_lane",
        "test": "tb_axis_lane",
        "file": "accel_axis.sv",
        "anchor": "        .s_data(s_axis_tdata), .s_last(s_axis_tlast),",
        "replacement": (
            "        .s_data({s_axis_tdata[7:0], s_axis_tdata[15:8],\n"
            "                 s_axis_tdata[23:16], s_axis_tdata[31:24],\n"
            "                 s_axis_tdata[39:32], s_axis_tdata[47:40],\n"
            "                 s_axis_tdata[55:48], s_axis_tdata[63:56]}),\n"
            "        .s_last(s_axis_tlast),"
        ),
    },
    {
        "id": "m3",
        "name": "m3_m_axis_lane",
        "test": "tb_axis_lane",
        "file": "accel_axis.sv",
        "anchor": (
            "    assign m_axis_tkeep = 8'hFF;\n"
            "\n"
            "    accel_top u_accel_top (\n"
            "        .clk(aclk), .rst_n(aresetn),\n"
            "        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid),\n"
            "        .s_axi_awready(s_axi_awready), .s_axi_wdata(s_axi_wdata),\n"
            "        .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),\n"
            "        .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp),\n"
            "        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),\n"
            "        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),\n"
            "        .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata),\n"
            "        .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),\n"
            "        .s_axi_rready(s_axi_rready),\n"
            "        .s_valid(s_axis_tvalid), .s_ready(s_axis_tready),\n"
            "        .s_data(s_axis_tdata), .s_last(s_axis_tlast),\n"
            "        .w_wr_en(1'b0), .w_wr_bank(3'b000), .w_wr_addr(13'h0000),\n"
            "        .w_wr_data(8'h00),\n"
            "        .m_valid(m_axis_tvalid), .m_ready(m_axis_tready),\n"
            "        .m_y_flat(m_axis_tdata),"
        ),
        "replacement": (
            "    assign m_axis_tkeep = 8'hFF;\n"
            "    logic [63:0] m_axis_tdata_core;\n"
            "    assign m_axis_tdata = {m_axis_tdata_core[7:0], m_axis_tdata_core[15:8],\n"
            "                           m_axis_tdata_core[23:16], m_axis_tdata_core[31:24],\n"
            "                           m_axis_tdata_core[39:32], m_axis_tdata_core[47:40],\n"
            "                           m_axis_tdata_core[55:48], m_axis_tdata_core[63:56]};\n"
            "\n"
            "    accel_top u_accel_top (\n"
            "        .clk(aclk), .rst_n(aresetn),\n"
            "        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid),\n"
            "        .s_axi_awready(s_axi_awready), .s_axi_wdata(s_axi_wdata),\n"
            "        .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),\n"
            "        .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp),\n"
            "        .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),\n"
            "        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),\n"
            "        .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata),\n"
            "        .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid),\n"
            "        .s_axi_rready(s_axi_rready),\n"
            "        .s_valid(s_axis_tvalid), .s_ready(s_axis_tready),\n"
            "        .s_data(s_axis_tdata), .s_last(s_axis_tlast),\n"
            "        .w_wr_en(1'b0), .w_wr_bank(3'b000), .w_wr_addr(13'h0000),\n"
            "        .w_wr_data(8'h00),\n"
            "        .m_valid(m_axis_tvalid), .m_ready(m_axis_tready),\n"
            "        .m_y_flat(m_axis_tdata_core),"
        ),
    },
]


def safe_rmtree(path: Path) -> None:
    if not path.exists():
        return
    for _ in range(5):
        try:
            shutil.rmtree(path)
            return
        except OSError:
            time.sleep(0.2)
    shutil.rmtree(path, ignore_errors=True)


def link_or_copy_vectors(dest: Path, src: Path) -> None:
    if dest.exists():
        return
    try:
        dest.symlink_to(src, target_is_directory=True)
    except OSError:
        try:
            import _winapi
            _winapi.CreateJunction(str(src), str(dest))
        except Exception:
            shutil.copytree(src, dest)


def run_cmd(cmd: list[str], cwd: Path, timeout: int = 300) -> tuple[int, str]:
    try:
        proc = subprocess.run(
            cmd, cwd=str(cwd), capture_output=True, text=True, errors="replace", timeout=timeout
        )
        return proc.returncode, proc.stdout + proc.stderr
    except subprocess.TimeoutExpired as exc:
        out = (exc.stdout or "") + (exc.stderr or "") + f"\nTIMEOUT: command timed out after {timeout}s\n"
        return 1, out


def extract_first_fail(out: str) -> str:
    for line in out.splitlines():
        s = line.strip()
        if not s:
            continue
        if run_tests.FAIL_RE.search(s) or "ERROR" in s or "Error" in s:
            return " ".join(s.split())
    for line in out.splitlines():
        s = line.strip()
        if s:
            return " ".join(s.split())
    return "UNKNOWN FAILURE"


def compile_and_run(
    bin_dir: Path, build_dir: Path, scratch_rtl: Path, scratch_tb: Path, top: str
) -> tuple[bool, str]:
    srcs = sorted(scratch_rtl.glob("*.sv")) + sorted(scratch_tb.glob("*.sv"))
    rel = [os.path.relpath(s, build_dir) for s in srcs]
    xvlog_exe = run_tests.tool(bin_dir, "xvlog")
    rc, out = run_cmd([xvlog_exe, "-sv", "--incr", *rel], build_dir)
    if rc != 0 or "ERROR" in out:
        return False, f"compilation failed:\n{out}"

    snap = f"{top}_snap"
    xelab_exe = run_tests.tool(bin_dir, "xelab")
    rc, out = run_cmd([xelab_exe, "-debug", "off", "-top", top, "-snapshot", snap], build_dir)
    if rc != 0 or "ERROR" in out:
        return False, f"elaboration failed:\n{out}"

    xsim_exe = run_tests.tool(bin_dir, "xsim")
    rc, out = run_cmd([xsim_exe, snap, "-runall"], build_dir)
    passed = (rc == 0 and bool(run_tests.PASS_RE.search(out)) and not bool(run_tests.FAIL_RE.search(out)))
    return passed, out


def run_single(
    bin_dir: Path,
    run_name: str,
    top_name: str,
    kind: str,
    mutation: dict | None,
) -> tuple[bool, str]:
    scratch_dir = MUTBUILD_BASE / run_name
    safe_rmtree(scratch_dir)
    scratch_dir.mkdir(parents=True, exist_ok=True)

    scratch_rtl = scratch_dir / "rtl"
    scratch_tb = scratch_dir / "tb"
    shutil.copytree(RTL_DIR, scratch_rtl)
    shutil.copytree(TB_DIR, scratch_tb)

    if mutation:
        target_path = scratch_rtl / mutation["file"]
        content = target_path.read_text(encoding="utf-8")
        count = content.count(mutation["anchor"])
        if count != 1:
            raise SystemExit(
                f"Mutant {run_name}: anchor occurred {count} times in {target_path.name}, expected exactly 1."
            )
        mutated_content = content.replace(mutation["anchor"], mutation["replacement"], 1)
        target_path.write_text(mutated_content, encoding="utf-8", newline="\n")

    # Build directory keeps same relative depth to vectors as run_tests.py
    build_dir = scratch_dir / "build"
    build_dir.mkdir(parents=True, exist_ok=True)

    vec_dir = SIM_DIR / "vectors"
    link_or_copy_vectors(scratch_dir / "vectors", vec_dir)
    link_or_copy_vectors(MUTBUILD_BASE / "vectors", vec_dir)

    return compile_and_run(bin_dir, build_dir, scratch_rtl, scratch_tb, top_name)


def main() -> int:
    run_tests.ascii_guard()

    selected_arg = sys.argv[1].lower() if len(sys.argv) > 1 else None
    if selected_arg:
        selected_mutants = [
            m for m in MUTANTS
            if selected_arg in (m["id"], m["name"], m["name"].replace("_", "-"))
        ]
        if not selected_mutants:
            print(f"Unknown mutant: {selected_arg}")
            print(f"Available mutants: {[m['id'] for m in MUTANTS]}")
            return 2
    else:
        selected_mutants = MUTANTS

    bin_dir = run_tests.find_vivado_bin()
    run_tests.ensure_vectors()
    MUTBUILD_BASE.mkdir(parents=True, exist_ok=True)

    # Unique testbenches needed for controls
    control_tests = list(dict.fromkeys(m["test"] for m in selected_mutants))

    controls_passed = 0
    killed_count = 0

    # 1. Controls (UNMUTATED)
    for test_name in control_tests:
        ctrl_name = f"ctrl_{test_name}"
        ok, out = run_single(bin_dir, ctrl_name, test_name, "control", None)
        result = "PASS" if ok else "FAIL"
        killed = "n/a"
        first = "-" if ok else extract_first_fail(out)
        if ok:
            controls_passed += 1
        print(f"MUT {ctrl_name} test={test_name} control result={result} killed={killed} first={first}")

    # 2. Mutants
    for m in selected_mutants:
        name = m["name"]
        test_name = m["test"]
        ok, out = run_single(bin_dir, name, test_name, "mutant", m)
        result = "PASS" if ok else "FAIL"
        is_killed = not ok
        killed = "yes" if is_killed else "no"
        first = extract_first_fail(out) if is_killed else "-"
        if is_killed:
            killed_count += 1
        print(f"MUT {name} test={test_name} mutant result={result} killed={killed} first={first}")

    total_mutants = len(selected_mutants)
    total_controls = len(control_tests)
    print(f"MUTATE_T6: killed={killed_count}/{total_mutants} controls={controls_passed}/{total_controls}")

    all_ok = (controls_passed == total_controls) and (killed_count == total_mutants)
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
