#!/usr/bin/env python3
"""Validate Ourokit token sources and deterministically generate Zig data."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOKENS = ROOT / "design" / "tokens"
OUTPUT = ROOT / "src" / "design" / "generated" / "tokens.zig"
NAME = re.compile(r"^ouro\.(?:foundation|semantic)\.[a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+$")
REF = re.compile(r"^\{(ouro\..+)\}$")
HEX = re.compile(r"^#[0-9a-fA-F]{8}$")
TYPES = {"dimension", "font_size", "font_family", "color"}


def load(name: str) -> list[dict]:
    document = json.loads((TOKENS / name).read_text())
    if set(document) != {"namespace", "tokens"} or document["namespace"] != "ouro":
        raise ValueError(f"{name}: invalid document shape or namespace")
    seen: set[str] = set()
    for token in document["tokens"]:
        if set(token) != {"name", "type", "value"}:
            raise ValueError(f"{name}: invalid token shape")
        token_name = token["name"]
        if not NAME.fullmatch(token_name):
            raise ValueError(f"{name}: invalid token name {token_name!r}")
        if token_name in seen:
            raise ValueError(f"{name}: duplicate role {token_name}")
        seen.add(token_name)
        if token["type"] not in TYPES:
            raise ValueError(f"{name}: invalid type for {token_name}")
        value = token["value"]
        if token["type"] in {"dimension", "font_size"}:
            if not isinstance(value, (int, float)) or isinstance(value, bool) or value < 0:
                raise ValueError(f"{name}: {token_name} requires a non-negative number")
        elif token["type"] == "color":
            if not isinstance(value, str) or not (HEX.fullmatch(value) or REF.fullmatch(value)):
                raise ValueError(f"{name}: {token_name} requires #RRGGBBAA or a reference")
        elif not isinstance(value, str) or not value or value != value.strip():
            raise ValueError(f"{name}: {token_name} requires a non-empty font family")
    return document["tokens"]


def identifier(name: str, prefix: str) -> str:
    return name.removeprefix(prefix).replace(".", "_")


def color_literal(value: str, values: dict[str, dict]) -> str:
    match = REF.fullmatch(value)
    if match:
        target = match.group(1)
        if target not in values:
            raise ValueError(f"unresolved reference {target}")
        target_token = values[target]
        if target_token["type"] != "color":
            raise ValueError(f"color reference {target} has incompatible type")
        return color_literal(target_token["value"], values)
    if not HEX.fullmatch(value):
        raise ValueError(f"invalid color {value}")
    channels = [int(value[i : i + 2], 16) for i in (1, 3, 5, 7)]
    return "Color.rgba({}, {}, {}, {})".format(*channels)


def generate() -> str:
    foundation = load("foundation.json")
    light = load("semantic-light.json")
    dark = load("semantic-dark.json")
    if {t["name"] for t in light} != {t["name"] for t in dark}:
        raise ValueError("light and dark themes must define exactly the same semantic roles")
    if any(t["type"] != "color" for t in light + dark):
        raise ValueError("semantic roles must be colors in this schema version")
    all_values = {t["name"]: t for t in foundation + light}
    for token in foundation + light + dark:
        if isinstance(token["value"], str) and (match := REF.fullmatch(token["value"])):
            if match.group(1) not in all_values:
                raise ValueError(f"unresolved reference {match.group(1)}")

    lines = [
        "// GENERATED FILE: do not edit.",
        "// Source: design/tokens/*.json; generator: tools/design/generate_tokens.py",
        'const Color = @import("../../core/color.zig").Color;',
        "",
        "pub const foundation = struct {",
    ]
    for token in sorted(foundation, key=lambda item: item["name"]):
        name = identifier(token["name"], "ouro.foundation.")
        if token["type"] == "color":
            value = color_literal(token["value"], all_values)
            lines.append(f"    pub const {name}: Color = {value};")
        elif token["type"] == "font_family":
            lines.append(f"    pub const {name}: []const u8 = {json.dumps(token['value'])};")
        else:
            lines.append(f"    pub const {name}: f32 = {float(token['value']):.1f};")
    lines.extend(["};", "", "pub const Theme = struct {"])
    for token in sorted(light, key=lambda item: item["name"]):
        lines.append(f"    {identifier(token['name'], 'ouro.semantic.')}: Color,")
    lines.extend(["};", ""])
    for theme_name, tokens in (("light", light), ("dark", dark)):
        values = {**all_values, **{t["name"]: t for t in tokens}}
        lines.append(f"pub const {theme_name}: Theme = .{{")
        for token in sorted(tokens, key=lambda item: item["name"]):
            role = identifier(token["name"], "ouro.semantic.")
            lines.append(f"    .{role} = {color_literal(token['value'], values)},")
        lines.extend(["};", ""])
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    try:
        generated = generate()
    except (OSError, json.JSONDecodeError, ValueError) as error:
        print(f"token validation failed: {error}", file=sys.stderr)
        return 1
    if args.check:
        if not OUTPUT.exists() or OUTPUT.read_text() != generated:
            print("generated tokens are stale; run `zig build generate-tokens`", file=sys.stderr)
            return 1
        return 0
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(generated)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
