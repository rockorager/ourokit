const std = @import("std");
const text = @import("../text/root.zig");

/// Host-owned cache. Generic and Source family names select bundled fonts;
/// other names and missing-character fallbacks use Fontconfig. Loading happens
/// at a build safe point, not during native layout.
pub const ThemeFonts = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    fonts: *text.FontCache,
    entries: std.ArrayList(Entry) = .empty,

    const Entry = struct { family: []u8, medium: bool, handles: []text.FontHandle };

    pub fn deinit(self: *ThemeFonts) void {
        for (self.entries.items) |entry| {
            for (entry.handles) |handle| self.fonts.release(handle) catch unreachable;
            self.allocator.free(entry.handles);
            self.allocator.free(entry.family);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn get(self: *ThemeFonts, family: []const u8, medium: bool) ![]const text.FontHandle {
        for (self.entries.items) |entry|
            if (entry.medium == medium and std.mem.eql(u8, entry.family, family)) return entry.handles;
        const name = try self.allocator.dupe(u8, family);
        errdefer self.allocator.free(name);
        var handles: std.ArrayList(text.FontHandle) = .empty;
        errdefer {
            for (handles.items) |handle| self.fonts.release(handle) catch unreachable;
            handles.deinit(self.allocator);
        }
        if (text.bundled.Family.fromName(family)) |bundled_family| {
            const handle = try text.bundled.acquire(self.fonts, bundled_family, if (medium) .semibold else .regular, .roman);
            errdefer self.fonts.release(handle) catch unreachable;
            try handles.append(self.allocator, handle);
        }
        if (text.has_fontconfig) {
            try self.appendSystemFonts(family, medium, &handles);
        } else if (handles.items.len == 0) return error.FontconfigDisabled;
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const owned = try handles.toOwnedSlice(self.allocator);
        self.entries.appendAssumeCapacity(.{ .family = name, .medium = medium, .handles = owned });
        return owned;
    }

    fn appendSystemFonts(self: *ThemeFonts, family: []const u8, medium: bool, handles: *std.ArrayList(text.FontHandle)) !void {
        var database = try text.discovery.Database.init();
        defer database.deinit();
        var candidates = database.candidates(self.allocator, .{
            .family = family,
            .weight = if (medium) .medium else .regular,
        }) catch |err| switch (err) {
            error.NoMatch => if (handles.items.len != 0) return else return err,
            else => return err,
        };
        defer candidates.deinit();
        for (candidates.faces) |face| {
            const file = try std.Io.Dir.openFileAbsolute(self.io, face.file, .{});
            defer file.close(self.io);
            var buffer: [8192]u8 = undefined;
            var reader = file.reader(self.io, &buffer);
            const bytes = try reader.interface.allocRemaining(self.allocator, .limited(64 * 1024 * 1024));
            defer self.allocator.free(bytes);
            const handle = try self.fonts.acquire(.{
                .key = .{ .file = face.file, .index = face.index, .variations = face.variations },
                .bytes = bytes,
            });
            errdefer self.fonts.release(handle) catch unreachable;
            try handles.append(self.allocator, handle);
        }
    }
};

test "bundled theme families lead system fallbacks and reuse cached faces" {
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    {
        var themes: ThemeFonts = .{ .allocator = std.testing.allocator, .io = std.testing.io, .fonts = &fonts };
        defer themes.deinit();
        const names = [_][]const u8{ "sans-serif", "serif", "monospace" };
        for (names, 0..) |name, index| {
            const regular = try themes.get(name, false);
            const repeated = try themes.get(name, false);
            try std.testing.expectEqual(regular.ptr, repeated.ptr);
            const medium = try themes.get(name, true);
            try std.testing.expect(!std.meta.eql(regular[0], medium[0]));
            const expected = try text.bundled.acquire(&fonts, @enumFromInt(index), .regular, .roman);
            defer fonts.release(expected) catch unreachable;
            try std.testing.expectEqual(expected, regular[0]);
            if (text.has_fontconfig) {
                var database = try text.discovery.Database.init();
                defer database.deinit();
                var candidates = try database.candidates(std.testing.allocator, .{ .family = name });
                defer candidates.deinit();
                try std.testing.expectEqual(candidates.faces.len + 1, regular.len);
            } else {
                try std.testing.expectEqual(@as(usize, 1), regular.len);
            }
        }
        const named = try themes.get("Source Serif 4", false);
        try std.testing.expectEqual((try themes.get("serif", false))[0], named[0]);
        if (!text.has_fontconfig) try std.testing.expectError(error.FontconfigDisabled, themes.get("DejaVu Sans", false));
    }
    try std.testing.expectEqual(@as(usize, 0), fonts.active_count);
}

test "bundled Latin font retains Arabic fallback shaping" {
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const primary = try text.bundled.acquire(&fonts, .sans, .regular, .roman);
    defer fonts.release(primary) catch unreachable;
    const fallback = try fonts.acquire(.{
        .key = .{ .file = "fixture:NotoSansArabic", .index = 0 },
        .bytes = @embedFile("ourokit_arabic_test_font"),
    });
    defer fonts.release(fallback) catch unreachable;
    const candidates = [_]text.FallbackCandidate{
        .{ .handle = primary, .font = try fonts.get(primary) },
        .{ .handle = fallback, .font = try fonts.get(fallback) },
    };
    var run = try text.shapeWithFallback(std.testing.allocator, &candidates, .{
        .paragraph = "سلام",
        .direction = .right_to_left,
        .script = .arabic,
        .language = "ar",
        .logical_size = 16,
    });
    defer run.deinit();
    try std.testing.expect(!run.has_missing_glyphs);
    try std.testing.expectEqual(@as(usize, 1), run.spans.len);
    try std.testing.expectEqual(fallback, run.spans[0].font);
}
