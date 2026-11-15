#!/usr/bin/env python3
"""Build the block design and run the Kademe-3 PS7 VIP/DMA replay."""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DESIGN = HERE.parent
ROOT = DESIGN.parent
BUILD = HERE / "build"
VIVADO_BUILD = DESIGN / "vivado" / "build"
VIVADO = Path(r"C:\Vivado\2025.1\Vivado\bin\vivado.bat")


def tee_run(command: list[str], log: Path, env: dict[str, str], cwd: Path = DESIGN) -> int:
    with log.open("w", encoding="utf-8", newline="\n") as output:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end="")
            output.write(line)
        return process.wait()


def write_tb_meta(name: str, meta: dict) -> None:
    words = [0x4E504D31, len(meta["logits"]), meta["class_count"]]
    for item, pred in zip(meta["logits"], meta["expected_argmax"], strict=True):
        words.extend((item["offset"], item["nbeats"], item["count"], pred))
    (BUILD / f"{name}_meta.mem").write_text(
        "".join(f"{word & 0xFFFFFFFF:08X}\n" for word in words),
        encoding="ascii",
        newline="\n",
    )


def emit_one_image(program: str) -> Path:
    sys.path.insert(0, str(DESIGN / "model"))
    from gen_netprog_vectors import (  # type: ignore
        build_lenet_model_and_image,
        build_v3_model_and_images,
    )
    from netprog import emit_program  # type: ignore

    if program == "v3":
        model, images, _ = build_v3_model_and_images()
        name = "np_v3_1"
    else:
        model, images, _ = build_lenet_model_and_image()
        name = "np_lenet_1"
    model_path = BUILD / f"{name}_model.json"
    model_path.write_text(
        json.dumps(model, separators=(",", ":")) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    result = emit_program(model, images[:1], BUILD, name)
    write_tb_meta(name, result["meta"])
    print(
        f"K3_VECTOR: program={name} images=1 "
        f"passes={sum(1 for line in result['program'].read_text(encoding='ascii').splitlines() if line.startswith('W 004 ') and int(line.split()[2], 16) & 1)}"
    )
    return BUILD / name


def make_mutants(kind: str) -> tuple[Path, Path | None]:
    tb = HERE / "tb_k3_prog.sv"
    rtl_override: Path | None = None
    if kind == "length":
        mutated = BUILD / "tb_k3_prog_wrong_length.sv"
        text = tb.read_text(encoding="utf-8")
        old = "localparam int K3_EXPECT_BIAS_BYTES = 0;"
        if text.count(old) != 1:
            raise RuntimeError("length mutation anchor changed")
        mutated.write_text(text.replace(old, "localparam int K3_EXPECT_BIAS_BYTES = 8;"),
                           encoding="utf-8", newline="\n")
        tb = mutated
    elif kind == "tlast":
        rtl_override = BUILD / "rtl_tlast_low"
        shutil.copytree(DESIGN / "rtl", rtl_override)
        shell = rtl_override / "accel_axis.sv"
        text = shell.read_text(encoding="utf-8")
        anchor = ".m_last(m_axis_tlast), .m_sat_flat(saturated), .m_ovf_flat(overflow),"
        if text.count(anchor) != 1:
            raise RuntimeError("TLAST mutation anchor changed")
        text = text.replace(anchor, ".m_last(), .m_sat_flat(saturated), .m_ovf_flat(overflow),")
        assign_anchor = "assign m_axis_tkeep = 8'hFF;"
        text = text.replace(assign_anchor, assign_anchor + "\n    assign m_axis_tlast = 1'b0;", 1)
        shell.write_text(text, encoding="utf-8", newline="\n")
    return tb, rtl_override


def find_simulator_log() -> Path | None:
    sim_root = VIVADO_BUILD / "bd" / "accel_bd_project.sim"
    candidates = []
    if sim_root.exists():
        candidates.extend(sim_root.rglob("simulate.log"))
        candidates.extend(sim_root.rglob("xsim.log"))
    return max(candidates, key=lambda path: path.stat().st_mtime) if candidates else None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--program", choices=("v3", "lenet"), default="v3")
    parser.add_argument("--mutation", choices=("none", "length", "tlast"), default="none")
    args = parser.parse_args()

    if BUILD.exists():
        shutil.rmtree(BUILD)
    BUILD.mkdir(parents=True)
    program_base = emit_one_image(args.program)
    tb, rtl_override = make_mutants(args.mutation)

    env = os.environ.copy()
    env["XILINX_LOCAL_USER_DATA"] = "no"
    # Vivado itself is invoked absolutely; its generated compile.bat calls the
    # sibling xvlog/xelab/xsim launchers by name.
    env["PATH"] = str(VIVADO.parent) + os.pathsep + env.get("PATH", "")
    if rtl_override is not None:
        env["K3_RTL_DIR"] = str(rtl_override)
    else:
        env.pop("K3_RTL_DIR", None)

    start = time.perf_counter()
    build_command = [
        str(VIVADO), "-mode", "batch",
        "-source", str(DESIGN / "vivado" / "build_bd.tcl"),
        "-journal", str(BUILD / "build_bd.jou"),
        "-log", str(BUILD / "build_bd.log"),
    ]
    if tee_run(build_command, BUILD / "build_bd_console.log", env) != 0:
        print("K3_RUNNER_ERROR: block-design build failed")
        return 2

    sim_command = [
        str(VIVADO), "-mode", "batch",
        "-journal", str(BUILD / "run_k3.jou"),
        "-log", str(BUILD / "run_k3_vivado.log"),
        "-source", str(HERE / "run_k3_sim.tcl"),
        "-tclargs", str(program_base), str(tb),
    ]
    sim_rc = tee_run(sim_command, BUILD / "run_k3_console.log", env)
    sim_dir = VIVADO_BUILD / "bd" / "accel_bd_project.sim" / "sim_1" / "behav" / "xsim"
    command_shell = Path(os.environ.get("COMSPEC", r"C:\Windows\System32\cmd.exe"))
    if sim_rc == 0:
        for suffix in (".prog", "_in.mem", "_exp.mem", "_meta.mem"):
            shutil.copyfile(Path(str(program_base) + suffix), sim_dir / ("k3_program" + suffix))
        for stage in ("compile", "elaborate", "simulate"):
            script = sim_dir / f"{stage}.bat"
            if not script.exists():
                print(f"K3_RUNNER_ERROR: generated script absent: {script}")
                sim_rc = 3
                break
            sim_rc = tee_run(
                [str(command_shell), "/d", "/c", str(script)],
                BUILD / f"{stage}.log",
                env,
                cwd=sim_dir,
            )
            if sim_rc != 0:
                print(f"K3_RUNNER_ERROR: {stage}.bat failed")
                break
    elapsed = time.perf_counter() - start

    simulator_log = find_simulator_log()
    final_log = BUILD / "tb_k3_prog.log"
    if simulator_log is not None:
        shutil.copyfile(simulator_log, final_log)
        sim_text = final_log.read_text(encoding="utf-8", errors="replace")
    else:
        sim_text = (BUILD / "run_k3_console.log").read_text(encoding="utf-8", errors="replace")
        final_log.write_text(sim_text, encoding="utf-8", newline="\n")

    time_matches = re.findall(r"(?:Time|time)\s*[:=]\s*([^\r\n]+)", sim_text)
    simulated = time_matches[-1].strip() if time_matches else "not-reported"
    print(f"K3_RUN: mutation={args.mutation} wall_seconds={elapsed:.3f} simulated_time={simulated}")

    pass_line = re.search(r"^PASS tb_k3_prog:.*$", sim_text, re.MULTILINE)
    bad = re.search(r"^(?:K3-ERROR:|FAIL tb_k3_prog:|FATAL_ERROR:).*$", sim_text, re.MULTILINE)
    if sim_rc != 0 or pass_line is None or bad is not None:
        if pass_line is None:
            print("K3_RUNNER_ERROR: PASS line absent")
        if bad is not None:
            print(f"K3_RUNNER_ERROR: simulator marker: {bad.group(0)}")
        return 1
    print(pass_line.group(0))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
