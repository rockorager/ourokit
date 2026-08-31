#!/usr/bin/env python3
"""Generate Ourokit's uucode config with Unicode 17 Line_Break data."""

from pathlib import Path
import re
import sys


def records(path: Path):
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            yield [field.strip() for field in line.split(";")]


def zig_name(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.lower()).strip("_")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: generate_uucode_config.py LINEBREAK OUTPUT")
    source_path, output_path = map(Path, sys.argv[1:])
    if "17.0.0" not in source_path.read_text(encoding="utf-8")[:1024]:
        raise ValueError(f"expected Unicode 17.0.0 data: {source_path}")

    source = list(records(source_path))
    classes = sorted({fields[1] for fields in source})
    ranges = []
    previous_end = -1
    for fields in source:
        values = fields[0].split("..")
        first = int(values[0], 16)
        last = int(values[-1], 16)
        if first <= previous_end:
            raise ValueError("LineBreak ranges are unsorted or overlapping")
        previous_end = last
        ranges.append((first, last, zig_name(fields[1])))

    enum_fields = "\n".join(f"    {zig_name(value)}," for value in classes)
    range_values = "\n".join(
        f"    .{{ .first = 0x{first:X}, .last = 0x{last:X}, .class = .{value} }},"
        for first, last, value in ranges
    )
    output = f'''//! Generated Ourokit uucode configuration. Do not edit.

const std = @import("std");
const config = @import("config.zig");

const LineBreak = enum(u6) {{
{enum_fields}
}};

pub const fields = &config.mergeFields(config.fields, &.{{
    .{{ .name = "line_break", .type = LineBreak }},
}});

pub const build_components = &config.mergeComponents(config.build_components, &.{{
    .{{
        .Impl = LineBreakComponent,
        .fields = &.{{"line_break"}},
    }},
}});

pub const get_components = config.get_components;

pub const tables: []const config.Table = &.{{
    .{{
        .fields = &.{{ "grapheme_break", "script", "bidi_paired_bracket" }},
    }},
    .{{
        .fields = &.{{
            "line_break",
            "general_category",
            "east_asian_width",
            "is_extended_pictographic",
        }},
    }},
}};

const Range = struct {{ first: u21, last: u21, class: LineBreak }};
const ranges = [_]Range{{
{range_values}
}};

const LineBreakComponent = struct {{
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {{
        _ = allocator;
        _ = io;
        _ = backing;
        _ = tracking;
        rows.len = config.num_code_points;
        const output_items = rows.items(.line_break);
        @memset(output_items, .xx);
        _ = inputs;

        for (ranges) |range|
            @memset(output_items[range.first..][0 .. range.last - range.first + 1], range.class);
    }}
}};
'''
    output_path.write_text(output, encoding="utf-8")


if __name__ == "__main__":
    main()
