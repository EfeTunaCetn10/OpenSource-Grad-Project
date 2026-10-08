#!/usr/bin/env python3
"""Generate one 28x28 coordinate-coded word plane per frame."""
from pathlib import Path
from act_buffer_ref import byte_address, coded_byte


def main() -> None:
    out = Path(__file__).resolve().parent.parent / "sim" / "vectors"
    out.mkdir(parents=True, exist_ok=True)
    for frame in range(2):
        words = [0] * (28 * 28)
        for h in range(28):
            for w in range(28):
                for c in range(8):
                    addr = byte_address(c, h, w, 28, 28)
                    value = coded_byte(c, h, w, frame) if c < 6 else 0
                    words[addr >> 3] |= value << ((addr & 7) * 8)
        (out / f"actbuf_frame{frame}.mem").write_text(
            "".join(f"{word:016X}\n" for word in words), encoding="ascii"
        )


if __name__ == "__main__":
    main()
