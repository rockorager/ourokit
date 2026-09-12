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
        try self.appendFaces(candidates.faces, handles);
    }

    fn appendFaces(self: *ThemeFonts, faces: []const text.discovery.Face, handles: *std.ArrayList(text.FontHandle)) !void {
        for (faces) |face| {
            const file = try std.Io.Dir.openFileAbsolute(self.io, face.file, .{});
            defer file.close(self.io);
            var buffer: [8192]u8 = undefined;
            var reader = file.reader(self.io, &buffer);
            const bytes = try reader.interface.allocRemaining(self.allocator, .limited(64 * 1024 * 1024));
            defer self.allocator.free(bytes);
            const handle = self.fonts.acquire(.{
                .key = .{ .file = face.file, .index = face.index, .variations = face.variations },
                .bytes = bytes,
            }) catch |err| switch (err) {
                // Fontconfig can offer formats the shaping backend cannot
                // read, such as WOFF2. One unusable fallback must not discard
                // the bundled face or later usable system candidates.
                error.InvalidFont => continue,
                else => return err,
            };
            errdefer self.fonts.release(handle) catch unreachable;
            try handles.append(self.allocator, handle);
        }
        if (handles.items.len == 0) return error.NoMatch;
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
            if (!text.has_fontconfig) {
                try std.testing.expectEqual(@as(usize, 1), regular.len);
            }
        }
        const named = try themes.get("Source Serif 4", false);
        try std.testing.expectEqual((try themes.get("serif", false))[0], named[0]);
        if (!text.has_fontconfig) try std.testing.expectError(error.FontconfigDisabled, themes.get("DejaVu Sans", false));
    }
    try std.testing.expectEqual(@as(usize, 0), fonts.active_count);
}

test "theme fallbacks skip invalid faces without losing usable fonts or their order" {
    if (!text.has_fontconfig) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const latin = @embedFile("ourokit_test_font_static");
    const arabic = @embedFile("ourokit_arabic_test_font");
    const names = [_][]const u8{ "bad-first", "latin", "bad-middle", "arabic" };
    const contents = [_][]const u8{ "not a font", latin, "wOF2invalid compressed font", arabic };
    var faces: [4]text.discovery.Face = undefined;
    var paths: [4][:0]const u8 = undefined;
    var count: usize = 0;
    defer for (paths[0..count]) |path| allocator.free(path);
    for (names, contents, 0..) |name, bytes, index| {
        try temporary.dir.writeFile(io, .{ .sub_path = name, .data = bytes });
        paths[index] = try temporary.dir.realPathFileAlloc(io, name, allocator);
        count += 1;
        faces[index] = .{ .family = name, .file = paths[index], .index = 0, .variable = false, .variations = null, .coverage = null };
    }
    var fonts = text.FontCache.init(allocator);
    defer fonts.deinit();
    var themes: ThemeFonts = .{ .allocator = allocator, .io = io, .fonts = &fonts };
    defer themes.deinit();
    var handles: std.ArrayList(text.FontHandle) = .empty;
    defer {
        for (handles.items) |handle| fonts.release(handle) catch unreachable;
        handles.deinit(allocator);
    }
    try themes.appendFaces(&faces, &handles);
    try std.testing.expectEqual(@as(usize, 2), handles.items.len);
    try std.testing.expectEqualSlices(u8, latin, (try fonts.get(handles.items[0])).raster_bytes);
    try std.testing.expectEqualSlices(u8, arabic, (try fonts.get(handles.items[1])).raster_bytes);
    for (handles.items) |handle| try fonts.release(handle);
    handles.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), fonts.active_count);

    try std.testing.expectError(error.NoMatch, themes.appendFaces(faces[0..1], &handles));
    try std.testing.expectEqual(@as(usize, 0), handles.items.len);
    const primary = try text.bundled.acquire(&fonts, .sans, .regular, .roman);
    try handles.append(allocator, primary);
    try themes.appendFaces(faces[0..1], &handles);
    try std.testing.expectEqualSlices(text.FontHandle, &.{primary}, handles.items);
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
