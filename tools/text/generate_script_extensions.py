#!/usr/bin/env python3
"""Generate compact Unicode Script_Extensions lookup data for Ourokit."""

from pathlib import Path
import re
import sys


def records(path: Path):
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            yield [field.strip() for field in line.split(";")]


def zig_name(long_name: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", long_name.lower()).strip("_")


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: generate_script_extensions.py SCX ALIASES OUTPUT")
    extensions_path, aliases_path, output_path = map(Path, sys.argv[1:])
    for path in (extensions_path, aliases_path):
        if "17.0.0" not in path.read_text(encoding="utf-8", errors="strict")[:512]:
            raise ValueError(f"expected Unicode 17.0.0 data: {path}")

    aliases = {}
    for fields in records(aliases_path):
        if fields[0] == "sc":
            aliases[fields[1]] = zig_name(fields[2])

    ranges = []
    for fields in records(extensions_path):
        bounds = fields[0].split("..")
        first = int(bounds[0], 16)
        last = int(bounds[-1], 16)
        scripts = fields[1].split()
        unknown = [script for script in scripts if script not in aliases]
        if unknown:
            raise ValueError(f"unknown Script_Extensions aliases: {unknown}")
        if ranges and first <= ranges[-1][1]:
            raise ValueError("Script_Extensions ranges are unsorted or overlapping")
        ranges.append((first, last, scripts))

    lines = [
        "//! Generated from Unicode 17.0.0 ScriptExtensions.txt. Do not edit.",
        "",
        'const std = @import("std");',
        'const uucode = @import("uucode");',
        "",
        "pub const Script = uucode.types.Script;",
        "pub const ScriptSet = std.EnumSet(Script);",
        "",
        "const Range = struct { first: u21, last: u21, scripts: []const Script };",
        "const ranges = [_]Range{",
    ]
    for first, last, scripts in ranges:
        values = ", ".join(f".{aliases[script]}" for script in scripts)
        lines.append(
            f"    .{{ .first = 0x{first:X}, .last = 0x{last:X}, "
            f".scripts = &.{{ {values} }} }},"
        )
    lines.extend(
        [
            "};",
            "",
            "pub fn forCodepoint(codepoint: u21) ScriptSet {",
            "    var low: usize = 0;",
            "    var high: usize = ranges.len;",
            "    while (low < high) {",
            "        const middle = low + (high - low) / 2;",
            "        const range = ranges[middle];",
            "        if (codepoint < range.first) {",
            "            high = middle;",
            "        } else if (codepoint > range.last) {",
            "            low = middle + 1;",
            "        } else {",
            "            return ScriptSet.initMany(range.scripts);",
            "        }",
            "    }",
            "    return ScriptSet.initOne(uucode.get(.script, codepoint));",
            "}",
            "",
            "pub fn iso15924(script: Script) [4]u8 {",
            "    return switch (script) {",
        ]
    )
    for short_name, long_name in sorted(aliases.items(), key=lambda item: item[1]):
        if long_name == "katakana_or_hiragana":
            continue
        lines.append(f'        .{long_name} => "{short_name}".*,')
    lines.extend(["    };", "}", ""])
    output_path.write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
