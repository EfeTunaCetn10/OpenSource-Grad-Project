"""Pure padded tile-major address and coordinate-coded data reference."""


def byte_address(c_out: int, h: int, w: int, height: int, width: int) -> int:
    if min(c_out, h, w) < 0 or h >= height or w >= width:
        raise ValueError("coordinate outside tensor")
    return (((c_out >> 3) * height + h) * width + w) * 8 + (c_out & 7)


def coded_byte(c_out: int, h: int, w: int, frame: int) -> int:
    return (c_out * 37 + h * 29 + w * 13 + frame * 71 + 1) & 255
