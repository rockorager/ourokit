#!/usr/bin/env python3
"""Import the pinned Radix Colors sRGB scales into canonical Ouro tokens."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

VERSION = "3.0.0"
ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "design" / "tokens" / "palette.json"
FAMILIES = (
    "gray", "mauve", "slate", "sage", "olive", "sand", "gold", "bronze",
    "brown", "yellow", "amber", "orange", "tomato", "red", "ruby", "crimson",
    "pink", "plum", "purple", "violet", "iris", "indigo", "blue", "cyan",
    "teal", "jade", "green", "grass", "lime", "mint", "sky",
)
HEX = re.compile(r"--[a-z]+-(?:a)?(\d+):\s*(#[0-9a-f]{6}(?:[0-9a-f]{2})?);")
RGBA = re.compile(r"--(?:black|white)-a(\d+):\s*rgba\((\d+), (\d+), (\d+), ([0-9.]+)\);")


def opaque_scales(package: Path) -> list[dict]:
    tokens: list[dict] = []
    for mode, suffix in (("light", ""), ("dark", "-dark")):
        for family in FAMILIES:
            for alpha, alpha_suffix in ((False, ""), (True, "-alpha")):
                path = package / f"{family}{suffix}{alpha_suffix}.css"
                source = path.read_text().split("@supports", 1)[0]
                values = HEX.findall(source)
                if [int(step) for step, _ in values] != list(range(1, 13)):
                    raise ValueError(f"{path}: expected exactly steps 1 through 12")
                scale = f"{family}_alpha" if alpha else family
                for step, value in values:
                    rgba = value if len(value) == 9 else value + "ff"
                    tokens.append({
                        "name": f"ouro.palette.{mode}.{scale}.{step}",
                        "type": "color",
                        "value": rgba,
                    })
    return tokens


def overlay_scales(package: Path) -> list[dict]:
    tokens: list[dict] = []
    for family in ("black", "white"):
        path = package / f"{family}-alpha.css"
        source = path.read_text().split("@supports", 1)[0]
        values = RGBA.findall(source)
        if [int(step) for step, *_ in values] != list(range(1, 13)):
            raise ValueError(f"{path}: expected exactly steps 1 through 12")
        for step, red, green, blue, alpha in values:
            alpha_byte = int(float(alpha) * 255 + 0.5)
            tokens.append({
                "name": f"ouro.palette.overlay.{family}.{step}",
                "type": "color",
                "value": f"#{int(red):02x}{int(green):02x}{int(blue):02x}{alpha_byte:02x}",
            })
    return tokens


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("package", type=Path, help="extracted @radix-ui/colors package directory")
    args = parser.parse_args()
    metadata = json.loads((args.package / "package.json").read_text())
    if metadata.get("name") != "@radix-ui/colors" or metadata.get("version") != VERSION:
        raise ValueError(f"expected @radix-ui/colors {VERSION}")
    tokens = [
        {"name": "ouro.palette.black", "type": "color", "value": "#000000ff"},
        {"name": "ouro.palette.white", "type": "color", "value": "#ffffffff"},
        {"name": "ouro.palette.transparent", "type": "color", "value": "#00000000"},
        *opaque_scales(args.package),
        *overlay_scales(args.package),
    ]
    lines = ['{', '  "namespace": "ouro",', '  "tokens": [']
    for index, token in enumerate(tokens):
        comma = "," if index + 1 < len(tokens) else ""
        lines.append(f"    {json.dumps(token, separators=(', ', ': '))}{comma}")
    lines.extend(["  ]", "}"])
    OUTPUT.write_text("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
