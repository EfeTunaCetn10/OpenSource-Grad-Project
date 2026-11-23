#!/usr/bin/env python3
"""Standard-library host test for accel_driver."""
import json
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(ROOT / "sw" / "common"))
from accel_driver import AccelDriver, DataMismatch, PollTimeout, RegisterMismatch
import accel_regs as R


class FakeBuffer(bytearray):
    def freebuffer(self):
        pass


class FakeChannel:
    def __init__(self, trace, kind, payloads=None):
        self.trace, self.kind = trace, kind
        self.payloads = list(payloads or [])
        self.outstanding = 0

    def transfer(self, buf):
        self.trace.append((self.kind, len(buf)))
        if self.kind == "recv":
            payload = self.payloads.pop(0)
            if len(payload) != len(buf):
                raise AssertionError("fake receive payload length differs")
            memoryview(buf).cast("B")[:] = payload
        self.outstanding += 1

    def wait(self):
        if not self.outstanding:
            raise AssertionError(f"wait without outstanding {self.kind}")
        self.trace.append(("wait_" + self.kind,))
        self.outstanding -= 1


class FakeDMA:
    def __init__(self, trace, recv_payloads):
        self.sendchannel = FakeChannel(trace, "send")
        self.recvchannel = FakeChannel(trace, "recv", recv_payloads)


class FakeMMIO:
    def __init__(self, trace, poll_done=True, overrides=None):
        self.trace, self.poll_done = trace, poll_done
        self.regs = {R.VERSION: R.REGMAP_VERSION, R.STATUS: 1, R.ERROR: 0, R.ERR_DETAIL: 0}
        self.overrides = dict(overrides or {})

    def write(self, addr, value):
        self.trace.append(("write", addr, value))
        self.regs[addr] = value
        if addr == R.CONTROL and value & (1 << R.CONTROL_START_LSB):
            self.regs[R.STATUS] = (1 << R.STATUS_DONE_LSB) if self.poll_done else (1 << R.STATUS_BUSY_LSB)
        if addr == R.STATUS and value & (1 << R.STATUS_DONE_LSB):
            self.regs[R.STATUS] = 1

    def read(self, addr):
        value = self.overrides.get(addr, self.regs.get(addr, 0))
        self.trace.append(("read", addr, value))
        return value


def allocate(shape, dtype):
    assert dtype == "u1"
    return FakeBuffer(shape[0])


def parse_program(prog, exp_words):
    writes, sends, recvs, payloads = [], [], [], []
    for raw in prog.read_text(encoding="ascii").splitlines():
        parts = raw.split("#", 1)[0].split()
        if not parts:
            continue
        if parts[0] == "W":
            writes.append((int(parts[1], 16), int(parts[2], 16)))
        elif parts[0] == "S":
            sends.append(int(parts[2], 16) * 8)
        elif parts[0] == "M":
            offset, count = int(parts[1], 16), int(parts[2], 16)
            recvs.append(count * 8)
            payloads.append(b"".join(word.to_bytes(8, "little") for word in exp_words[offset:offset + count]))
    return writes, sends, recvs, payloads


def make_driver(prog, *, poll_done=True, overrides=None, corrupt=False, timeout=0.01):
    exp = AccelDriver._read_mem(Path(str(prog.with_suffix("")) + "_exp.mem"))
    _, _, _, payloads = parse_program(prog, exp)
    if corrupt and payloads:
        payloads[0] = bytes([payloads[0][0] ^ 1]) + payloads[0][1:]
    trace = []
    return AccelDriver(FakeMMIO(trace, poll_done, overrides), FakeDMA(trace, payloads), allocate,
                       timeout=timeout), trace


def write_case(directory, name, program):
    base = directory / name
    base.with_suffix(".prog").write_text(program, encoding="ascii")
    Path(str(base) + "_in.mem").write_text("0000000000000000\n", encoding="ascii")
    Path(str(base) + "_exp.mem").write_text("0000000000000000\n", encoding="ascii")
    return base.with_suffix(".prog")


def main():
    prog = ROOT / "sim" / "vectors" / "np_v3.prog"
    if not prog.is_file():
        raise SystemExit("missing sim/vectors/np_v3.*; run: python model/gen_netprog_vectors.py")
    exp = AccelDriver._read_mem(Path(str(prog.with_suffix("")) + "_exp.mem"))
    expected_writes, expected_sends, expected_recvs, _ = parse_program(prog, exp)

    driver, trace = make_driver(prog)
    driver.run_program(prog)
    assert [(item[1], item[2]) for item in trace if item[0] == "write"] == expected_writes
    assert [item[1] for item in trace if item[0] == "send"] == expected_sends
    assert [item[1] for item in trace if item[0] == "recv"] == expected_recvs
    assert sum(item[0] == "wait_send" for item in trace) == len(expected_sends)
    assert sum(item[0] == "wait_recv" for item in trace) == len(expected_recvs)

    driver, _ = make_driver(prog)
    actual_classes = driver.classify(prog)
    meta = json.loads(Path(str(prog.with_suffix("")) + "_meta.json").read_text(encoding="utf-8"))
    assert actual_classes == meta["expected_argmax"]

    with tempfile.TemporaryDirectory() as td:
        directory = Path(td)
        timeout_prog = write_case(directory, "timeout", "P 008 00000004 00000004\n")
        driver, _ = make_driver(timeout_prog, poll_done=False,
                                overrides={R.STATUS: 1 << R.STATUS_BUSY_LSB,
                                           R.ERROR: 1 << R.ERROR_ERR_TIMEOUT_LSB}, timeout=0.001)
        try:
            driver.run_program(timeout_prog)
            raise AssertionError("timeout was ignored")
        except PollTimeout as exc:
            assert exc.status["STATUS.BUSY"] == 1
            assert exc.error["ERROR.ERR_TIMEOUT"] == 1

        mismatch_prog = write_case(directory, "reg", "R 000 FFFF 0004\n")
        driver, _ = make_driver(mismatch_prog)
        try:
            driver.run_program(mismatch_prog)
            raise AssertionError("R mismatch was ignored")
        except RegisterMismatch:
            pass

    driver, _ = make_driver(prog, corrupt=True)
    try:
        driver.run_program(prog)
        raise AssertionError("M data mismatch was ignored")
    except DataMismatch:
        pass

    print(f"PASS test_driver_mock: {len(expected_writes)} writes, {len(expected_sends)} sends, "
          f"{len(expected_recvs)} recvs, classify/timeout/R/M checks")


if __name__ == "__main__":
    main()
