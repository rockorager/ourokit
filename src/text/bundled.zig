//! Pinned, unmodified CFF fonts. No filesystem or Fontconfig is required.
const std = @import("std");
const api = @import("api.zig");

pub const Family = enum {
    sans,
    serif,
    monospace,

    pub fn fromName(name: []const u8) ?Family {
        const names = [_][2][]const u8{
            .{ "sans-serif", "Source Sans 3" },
            .{ "serif", "Source Serif 4" },
            .{ "monospace", "Source Code Pro" },
        };
        for (names, 0..) |aliases, index| {
            for (aliases) |alias| {
                if (std.ascii.eqlIgnoreCase(name, alias)) return @enumFromInt(index);
            }
        }
        return null;
    }
};

pub const Weight = enum { regular, semibold, bold };
pub const Style = enum { roman, italic };

const Asset = struct { path: []const u8, bytes: []const u8 };
const assets = [_][6]Asset{
    familyAssets("SourceSans3"),
    familyAssets("SourceSerif4"),
    familyAssets("SourceCodePro"),
};

fn familyAssets(comptime prefix: []const u8) [6]Asset {
    var result: [6]Asset = undefined;
    for (.{ "Regular", "It", "Semibold", "SemiboldIt", "Bold", "BoldIt" }, 0..) |suffix, index| {
        const path = "fonts/" ++ prefix ++ "-" ++ suffix ++ ".otf";
        result[index] = .{ .path = "ourokit:bundled/" ++ path, .bytes = @embedFile(path) };
    }
    return result;
}

/// The returned handle owns one cache reference, released by the caller.
pub fn acquire(cache: *api.FontCache, family: Family, weight: Weight, style: Style) !api.FontHandle {
    const asset = assets[@intFromEnum(family)][@as(usize, @intFromEnum(weight)) * 2 + @intFromEnum(style)];
    return cache.acquire(.{ .key = .{ .file = asset.path, .index = 0 }, .bytes = asset.bytes });
}

test "bundled families resolve generic and exact names without capturing system families" {
    try std.testing.expectEqual(Family.sans, Family.fromName("sans-serif").?);
    try std.testing.expectEqual(Family.serif, Family.fromName("Source Serif 4").?);
    try std.testing.expectEqual(Family.monospace, Family.fromName("SOURCE CODE PRO").?);
    try std.testing.expectEqual(@as(?Family, null), Family.fromName("DejaVu Sans"));
}

test "bundled faces are distinct static CFF fonts with real weights and italics" {
    var cache = api.FontCache.init(std.testing.allocator);
    defer cache.deinit();
    var handles: [18]api.FontHandle = undefined;
    var count: usize = 0;
    for (assets, 0..) |family, family_index| {
        for (family, 0..) |asset, index| {
            try std.testing.expectEqualStrings("OTTO", asset.bytes[0..4]);
            const table_count = std.mem.readInt(u16, asset.bytes[4..6], .big);
            var has_cff = false;
            for (0..table_count) |table| {
                const tag = asset.bytes[12 + table * 16 ..][0..4];
                has_cff = has_cff or std.mem.eql(u8, tag, "CFF ");
                try std.testing.expect(!std.mem.eql(u8, tag, "fvar"));
                if (std.mem.eql(u8, tag, "OS/2")) {
                    const offset = std.mem.readInt(u32, asset.bytes[12 + table * 16 + 8 ..][0..4], .big);
                    const expected_weights = [_]u16{ 400, 600, 700 };
                    try std.testing.expectEqual(expected_weights[index / 2], std.mem.readInt(u16, asset.bytes[offset + 4 ..][0..2], .big));
                    const selection = std.mem.readInt(u16, asset.bytes[offset + 62 ..][0..2], .big);
                    try std.testing.expectEqual(index % 2 == 1, selection & 1 != 0);
                }
            }
            try std.testing.expect(has_cff);
            const handle = try acquire(&cache, @enumFromInt(family_index), @enumFromInt(index / 2), @enumFromInt(index % 2));
            for (handles[0..count]) |previous| try std.testing.expect(!std.meta.eql(previous, handle));
            handles[count] = handle;
            count += 1;
            const font = try cache.get(handle);
            for ([_]u21{ 'A', 'é' }) |codepoint| try std.testing.expect(font.hasGlyph(codepoint));
            // Upstream Source Code Pro italics have narrower script coverage.
            const greek_cyrillic = family_index != @intFromEnum(Family.monospace) or index % 2 == 0;
            for ([_]u21{ 'Ω', 'Ж' }) |codepoint| try std.testing.expectEqual(greek_cyrillic, font.hasGlyph(codepoint));
            try std.testing.expect(!font.hasGlyph('س'));
            var run = try font.shape(std.testing.allocator, .{
                .paragraph = "Wiil 0O1",
                .direction = .left_to_right,
                .script = .latin,
                .language = "en",
                .logical_size = 16,
            });
            defer run.deinit();
            try std.testing.expect(run.advance.x > 0);
            if (family_index == @intFromEnum(Family.monospace)) {
                for (run.glyphs) |glyph| try std.testing.expectEqual(run.glyphs[0].advance.x, glyph.advance.x);
            } else {
                try std.testing.expect(run.glyphs[0].advance.x > run.glyphs[1].advance.x);
            }
        }
    }
    for (handles) |handle| try cache.release(handle);
    try std.testing.expectEqual(@as(usize, 0), cache.active_count);
}
