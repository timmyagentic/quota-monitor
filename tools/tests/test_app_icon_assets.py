#!/usr/bin/env python3
import pathlib
import shutil
import subprocess
import tempfile
import unittest
import zlib


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
SOURCE_ICON = REPO_ROOT / "Resources" / "AppIcon.png"
BUNDLE_ICON = REPO_ROOT / "Resources" / "AppIcon.icns"
MAKE_ICON = REPO_ROOT / "tools" / "make-icon.sh"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def png_chunk(kind: bytes, data: bytes) -> bytes:
    import struct

    return (
        struct.pack(">I", len(data))
        + kind
        + data
        + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    )


def write_rgb_png(path: pathlib.Path, size: int, color: tuple[int, int, int]) -> None:
    import struct

    rows = b"".join(b"\x00" + bytes(color) * size for _ in range(size))
    path.write_bytes(
        PNG_SIGNATURE
        + png_chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
        + png_chunk(b"IDAT", zlib.compress(rows))
        + png_chunk(b"IEND", b"")
    )


def paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


class PNGImage:
    def __init__(self, width: int, height: int, color_type: int, pixels: list[bytes]):
        self.width = width
        self.height = height
        self.color_type = color_type
        self.pixels = pixels
        self.channels = {2: 3, 6: 4}[color_type]

    def pixel(self, x: int, y: int) -> tuple[int, ...]:
        offset = x * self.channels
        return tuple(self.pixels[y][offset : offset + self.channels])


def read_png(path: pathlib.Path) -> PNGImage:
    import struct

    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise AssertionError(f"{path} is not a PNG")

    offset = len(PNG_SIGNATURE)
    width = height = bit_depth = color_type = None
    compressed = bytearray()
    while offset < len(data):
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        kind = data[offset + 4 : offset + 8]
        payload = data[offset + 8 : offset + 8 + length]
        offset += 12 + length
        if kind == b"IHDR":
            width, height, bit_depth, color_type, _, _, _ = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            compressed.extend(payload)
        elif kind == b"IEND":
            break

    if bit_depth != 8 or color_type not in (2, 6):
        raise AssertionError(f"{path} must be an 8-bit RGB/RGBA PNG")

    channels = {2: 3, 6: 4}[color_type]
    stride = width * channels
    raw = zlib.decompress(bytes(compressed))
    rows: list[bytes] = []
    cursor = 0
    previous = bytearray(stride)
    for _ in range(height):
        filter_type = raw[cursor]
        cursor += 1
        row = bytearray(raw[cursor : cursor + stride])
        cursor += stride
        for i, value in enumerate(row):
            left = row[i - channels] if i >= channels else 0
            above = previous[i]
            upper_left = previous[i - channels] if i >= channels else 0
            if filter_type == 1:
                row[i] = (value + left) & 0xFF
            elif filter_type == 2:
                row[i] = (value + above) & 0xFF
            elif filter_type == 3:
                row[i] = (value + ((left + above) // 2)) & 0xFF
            elif filter_type == 4:
                row[i] = (value + paeth(left, above, upper_left)) & 0xFF
            elif filter_type != 0:
                raise AssertionError(f"unsupported PNG filter type {filter_type}")
        rows.append(bytes(row))
        previous = row

    return PNGImage(width, height, color_type, rows)


class AppIconAssetTests(unittest.TestCase):
    def test_source_icon_preserves_transparent_corners(self):
        image = read_png(SOURCE_ICON)

        self.assertEqual(image.color_type, 6)
        self.assertEqual(image.pixel(0, 0)[3], 0)
        self.assertEqual(image.pixel(image.width - 1, 0)[3], 0)
        self.assertEqual(image.pixel(0, image.height - 1)[3], 0)
        self.assertEqual(image.pixel(image.width - 1, image.height - 1)[3], 0)
        self.assertEqual(image.pixel(image.width // 2, image.height // 2)[3], 255)

    def test_committed_icns_preserves_alpha(self):
        result = subprocess.run(
            ["sips", "-g", "hasAlpha", str(BUNDLE_ICON)],
            text=True,
            capture_output=True,
            check=True,
        )

        self.assertIn("hasAlpha: yes", result.stdout)

    def test_make_icon_rejects_sources_without_alpha(self):
        with tempfile.TemporaryDirectory() as tmp:
            repo = pathlib.Path(tmp)
            (repo / "tools").mkdir()
            (repo / "Resources").mkdir()
            shutil.copy2(MAKE_ICON, repo / "tools" / "make-icon.sh")
            source = repo / "Resources" / "AppIcon.png"
            write_rgb_png(source, size=16, color=(255, 255, 255))

            result = subprocess.run(
                [str(repo / "tools" / "make-icon.sh")],
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("source icon must preserve transparent corners", result.stderr)


if __name__ == "__main__":
    unittest.main()
