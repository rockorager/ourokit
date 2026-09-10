"""Regenerate original codec fixtures (Pillow 12.1.1, libwebp-enabled wheel).

Run: uv run --with pillow==12.1.1 tools/image/generate_fixtures.py
These tiny test images are authored for Ourokit and covered by its MIT license.
"""
from pathlib import Path
import struct
from PIL import Image

dest = Path(__file__).resolve().parents[2] / "src/image/codec_fixtures"
dest.mkdir(parents=True, exist_ok=True)
pixels = [
    (199, 100, 50, 128), (17, 200, 91, 255), (220, 30, 90, 0),
    (255, 128, 64, 64), (0, 40, 250, 200), (90, 80, 70, 255),
]
image = Image.new("RGBA", (3, 2))
image.putdata(pixels)
image.save(dest / "rgba.png")
image.save(dest / "rgba.webp", lossless=True, exact=True)

# Six asymmetric blocks: JPEG is lossy, so tests sample block centers with a
# small tolerance rather than using decoder-generated expected bytes.
colors = [(230, 20, 40), (30, 210, 60), (40, 70, 220),
          (210, 190, 20), (200, 30, 180), (20, 190, 200)]
jpeg = Image.new("RGB", (24, 16))
for index, color in enumerate(colors):
    x, y = (index % 3) * 8, (index // 3) * 8
    jpeg.paste(color, (x, y, x + 8, y + 8))
jpeg.save(dest / "blocks.jpg", quality=100, subsampling=0)
jpeg.save(dest / "blocks.webp", quality=100, lossless=False)

def chunk(tag, data):
    return tag + struct.pack("<I", len(data)) + data + b"\0" * (len(data) % 2)

def u24(value):
    return value.to_bytes(3, "little")

def frame(payload, x, y, width, height):
    # Offset units are two pixels; no blend means replace the frame rectangle.
    header = u24(x // 2) + u24(y // 2) + u24(width - 1) + u24(height - 1) + u24(100) + b"\x02"
    return chunk(b"ANMF", header + payload)

# First frame occupies only part of a larger transparent canvas. A fully opaque
# second frame catches implementations that decode the last frame instead.
first = (dest / "rgba.webp").read_bytes()[12:]
from io import BytesIO
buffer = BytesIO()
Image.new("RGBA", (6, 4), (255, 0, 0, 255)).save(buffer, format="WEBP", lossless=True)
second = buffer.getvalue()[12:]
body = (b"WEBP" + chunk(b"VP8X", b"\x12\0\0\0" + u24(5) + u24(3))
        + chunk(b"ANIM", b"\xff\xff\xff\xff\0\0")
        + frame(first, 2, 2, 3, 2) + frame(second, 0, 0, 6, 4))
(dest / "animated.webp").write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)
