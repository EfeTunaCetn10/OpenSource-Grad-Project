"""Small PYNQ/host driver for the frozen netprog text format."""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

COMMON = Path(__file__).resolve().parents[1] / "common"
if str(COMMON) not in sys.path:
    sys.path.insert(0, str(COMMON))
import accel_regs as R


def _decode(prefix, value):
    fields = {}
    marker = prefix + "_"
    for name in dir(R):
        if name.startswith(marker) and name.endswith("_LSB"):
            field = name[len(marker):-4]
            width = getattr(R, marker + field + "_WIDTH")
            fields[prefix + "." + field] = (value >> getattr(R, name)) & ((1 << width) - 1)
    return fields


class AccelDriverError(RuntimeError):
    """Base error carrying a decoded accelerator diagnostic snapshot."""

    def __init__(self, message, status, error, err_detail):
        self.status_raw, self.error_raw, self.err_detail_raw = status, error, err_detail
        self.status = _decode("STATUS", status)
        self.error = _decode("ERROR", error)
        self.err_detail = _decode("ERR_DETAIL", err_detail)
        active = {k: v for group in (self.status, self.error, self.err_detail)
                  for k, v in group.items() if v}
        super().__init__(f"{message}; STATUS=0x{status:08X} ERROR=0x{error:08X} "
                         f"ERR_DETAIL=0x{err_detail:08X} decoded={active}")


class PollTimeout(AccelDriverError):
    pass


class RegisterMismatch(AccelDriverError):
    pass


class DataMismatch(AccelDriverError):
    pass


class ProgramFormatError(ValueError):
    pass


class AccelDriver:
    def __init__(self, mmio, dma, allocate, compare=True, timeout=1.0):
        self.mmio, self.dma, self.allocate = mmio, dma, allocate
        self.compare, self.timeout = compare, timeout
        self._last_received = {}

    @staticmethod
    def _read_mem(path):
        return [int(line.split("#", 1)[0], 16) for line in path.read_text(encoding="ascii").splitlines()
                if line.split("#", 1)[0].strip()]

    def _diagnostics(self):
        return (self.mmio.read(R.STATUS), self.mmio.read(R.ERROR), self.mmio.read(R.ERR_DETAIL))

    def _buffer(self, words):
        buf = self.allocate(shape=(8 * len(words),), dtype="u1")
        view = memoryview(buf).cast("B")
        for index, word in enumerate(words):
            view[index * 8:(index + 1) * 8] = word.to_bytes(8, "little")
        return buf

    @staticmethod
    def _words(buf):
        data = memoryview(buf).cast("B").tobytes()
        return [int.from_bytes(data[i:i + 8], "little") for i in range(0, len(data), 8)]

    @staticmethod
    def _free(buf):
        free = getattr(buf, "freebuffer", None)
        if free is not None:
            free()

    def run_program(self, prog_path):
        prog = Path(prog_path)
        stem = prog.with_suffix("")
        in_words = self._read_mem(Path(str(stem) + "_in.mem"))
        exp_words = self._read_mem(Path(str(stem) + "_exp.mem"))
        sends, recvs, received = [], [], []
        self._last_received = {}

        def join():
            for buf in sends:
                self.dma.sendchannel.wait()
                self._free(buf)
            sends.clear()
            for buf, offset, expected in recvs:
                self.dma.recvchannel.wait()
                actual = self._words(buf)
                received.extend(actual)
                self._last_received.update((offset + i, word) for i, word in enumerate(actual))
                self._free(buf)
                if self.compare and actual != expected:
                    status, error, detail = self._diagnostics()
                    raise DataMismatch(f"M offset 0x{offset:X}: expected {expected}, got {actual}",
                                       status, error, detail)
            recvs.clear()

        for line_no, raw in enumerate(prog.read_text(encoding="ascii").splitlines(), 1):
            text = raw.split("#", 1)[0].strip()
            if not text:
                continue
            parts = text.split()
            op = parts[0]
            try:
                args = [int(token, 16) for token in parts[1:]]
            except ValueError as exc:
                raise ProgramFormatError(f"{prog}:{line_no}: invalid hex operand") from exc
            expected_arity = {"W": 2, "R": 3, "P": 3, "S": 2, "M": 2, "J": 0}
            if op not in expected_arity or len(args) != expected_arity[op]:
                raise ProgramFormatError(f"{prog}:{line_no}: malformed {op} operation")
            if op == "W":
                self.mmio.write(args[0], args[1])
            elif op == "R":
                value = self.mmio.read(args[0])
                if value & args[1] != args[2]:
                    status, error, detail = self._diagnostics()
                    raise RegisterMismatch(
                        f"R 0x{args[0]:03X}: (0x{value:08X} & 0x{args[1]:08X}) != 0x{args[2]:08X}",
                        status, error, detail)
            elif op == "P":
                deadline = time.monotonic() + self.timeout
                while self.mmio.read(args[0]) & args[1] != args[2]:
                    if time.monotonic() >= deadline:
                        status, error, detail = self._diagnostics()
                        raise PollTimeout(f"P 0x{args[0]:03X} timed out after {self.timeout:g} s",
                                          status, error, detail)
            elif op == "S":
                offset, count = args
                words = in_words[offset:offset + count]
                if len(words) != count:
                    raise ProgramFormatError(f"{prog}:{line_no}: S slice is outside _in.mem")
                buf = self._buffer(words)
                self.dma.sendchannel.transfer(buf)
                sends.append(buf)
            elif op == "M":
                offset, count = args
                expected = exp_words[offset:offset + count]
                if len(expected) != count:
                    raise ProgramFormatError(f"{prog}:{line_no}: M slice is outside _exp.mem")
                buf = self._buffer([0] * count)
                self.dma.recvchannel.transfer(buf)
                recvs.append((buf, offset, expected))
            else:
                join()
        if sends or recvs:
            raise ProgramFormatError(f"{prog}: outstanding DMA transfer(s); missing J")
        return received

    def classify(self, prog_path):
        prog = Path(prog_path)
        meta = json.loads(Path(str(prog.with_suffix("")) + "_meta.json").read_text(encoding="utf-8"))
        self.run_program(prog)
        classes = []
        for item in meta["logits"]:
            raw = b"".join(self._last_received[item["offset"] + i].to_bytes(8, "little")
                           for i in range(item["nbeats"]))[:item["count"]]
            logits = [byte - 256 if byte >= 128 else byte for byte in raw]
            classes.append(max(range(len(logits)), key=logits.__getitem__))
        return classes
