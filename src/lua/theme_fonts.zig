const std = @import("std");
const text = @import("../text/root.zig");

/// Host-owned Fontconfig candidate lists. The first usable face is loaded for
/// primary metrics; fallback files are loaded only when shaping reaches them.
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
        if (!text.has_fontconfig) return error.FontconfigDisabled;
        for (self.entries.items) |entry|
            if (entry.medium == medium and std.mem.eql(u8, entry.family, family)) return entry.handles;
        const name = try self.allocator.dupe(u8, family);
        errdefer self.allocator.free(name);
        var handles: std.ArrayList(text.FontHandle) = .empty;
        errdefer {
            for (handles.items) |handle| self.fonts.release(handle) catch unreachable;
            handles.deinit(self.allocator);
        }
        try self.appendSystemFonts(family, medium, &handles);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const owned = try handles.toOwnedSlice(self.allocator);
        self.entries.appendAssumeCapacity(.{ .family = name, .medium = medium, .handles = owned });
        return owned;
    }

    fn appendSystemFonts(self: *ThemeFonts, family: []const u8, medium: bool, handles: *std.ArrayList(text.FontHandle)) !void {
        var database = try text.discovery.Database.init();
        defer database.deinit();
        var candidates = try database.candidates(self.allocator, .{
            .family = family,
            .weight = if (medium) .medium else .regular,
        });
        defer candidates.deinit();
        try self.appendFaces(candidates.faces, handles);
    }

    fn appendFaces(self: *ThemeFonts, faces: []const text.discovery.Face, handles: *std.ArrayList(text.FontHandle)) !void {
        for (faces) |face| {
            const handle = try self.fonts.acquireFile(self.io, .{
                .file = face.file,
                .index = face.index,
                .variations = face.variations,
            });
            errdefer self.fonts.release(handle) catch unreachable;
            if (handles.items.len == 0) {
                // Keep a usable primary for empty lines and .notdef output.
                _ = self.fonts.get(handle) catch |err| switch (err) {
                    error.InvalidFont => {
                        self.fonts.release(handle) catch unreachable;
                        continue;
                    },
                    else => return err,
                };
            }
            try handles.append(self.allocator, handle);
        }
        if (handles.items.len == 0) return error.NoMatch;
    }
};

test "theme families follow Fontconfig and reuse candidate identities" {
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    {
        var themes: ThemeFonts = .{ .allocator = std.testing.allocator, .io = std.testing.io, .fonts = &fonts };
        defer themes.deinit();
        if (!text.has_fontconfig) {
            try std.testing.expectError(error.FontconfigDisabled, themes.get("sans-serif", false));
            return;
        }
        var database = try text.discovery.Database.init();
        defer database.deinit();
        for ([_][]const u8{ "sans-serif", "serif", "monospace", "Source Sans 3" }) |name| {
            for ([_]bool{ false, true }) |medium| {
                const handles = try themes.get(name, medium);
                try std.testing.expectEqual(handles.ptr, (try themes.get(name, medium)).ptr);
                var candidates = try database.candidates(std.testing.allocator, .{
                    .family = name,
                    .weight = if (medium) .medium else .regular,
                });
                defer candidates.deinit();
                // Compare the configured face identity, not a hardcoded family.
                var expected_primary: ?text.FontHandle = null;
                for (candidates.faces) |face| {
                    const expected = try fonts.acquireFile(std.testing.io, .{
                        .file = face.file,
                        .index = face.index,
                        .variations = face.variations,
                    });
                    defer fonts.release(expected) catch unreachable;
                    _ = fonts.get(expected) catch |err| switch (err) {
                        error.InvalidFont => continue,
                        else => return err,
                    };
                    expected_primary = expected;
                    break;
                }
                try std.testing.expectEqual(expected_primary.?, handles[0]);
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 0), fonts.active_count);
}

test "theme fallbacks load on demand and skip invalid faces without losing order" {
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
    try std.testing.expectEqual(@as(usize, 3), handles.items.len);
    try std.testing.expectEqualSlices(u8, latin, (try fonts.get(handles.items[0])).raster_bytes);
    try std.testing.expect(!(try fonts.isLoaded(handles.items[1])));
    try std.testing.expect(!(try fonts.isLoaded(handles.items[2])));
    const candidates = [_]text.FallbackCandidate{
        .{ .handle = handles.items[0], .cache = &fonts },
        .{ .handle = handles.items[1], .cache = &fonts },
        .{ .handle = handles.items[2], .cache = &fonts },
    };
    var hello = try text.shapeWithFallback(allocator, &candidates, .{
        .paragraph = "Hello, world!",
        .direction = .left_to_right,
        .script = .latin,
        .language = "en",
        .logical_size = 32,
    });
    defer hello.deinit();
    try std.testing.expect(!hello.has_missing_glyphs);
    try std.testing.expectEqual(handles.items[0], hello.spans[0].font);
    try std.testing.expect(!(try fonts.isLoaded(handles.items[1])));
    try std.testing.expect(!(try fonts.isLoaded(handles.items[2])));
    var arabic_run = try text.shapeWithFallback(allocator, &candidates, .{
        .paragraph = "سلام",
        .direction = .right_to_left,
        .script = .arabic,
        .language = "ar",
        .logical_size = 32,
    });
    defer arabic_run.deinit();
    try std.testing.expect(!arabic_run.has_missing_glyphs);
    try std.testing.expectEqual(@as(usize, 1), arabic_run.spans.len);
    try std.testing.expectEqual(handles.items[2], arabic_run.spans[0].font);
    try std.testing.expectEqualSlices(u8, arabic, (try fonts.get(handles.items[2])).raster_bytes);
    // Loaded and rejected faces must not be reopened on later runs.
    try temporary.dir.deleteFile(io, names[2]);
    try temporary.dir.deleteFile(io, names[3]);
    var repeated = try text.shapeWithFallback(allocator, &candidates, .{
        .paragraph = "سلام",
        .direction = .right_to_left,
        .script = .arabic,
        .language = "ar",
        .logical_size = 32,
    });
    defer repeated.deinit();
    try std.testing.expectEqual(arabic_run.advance, repeated.advance);
    for (handles.items) |handle| try fonts.release(handle);
    handles.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), fonts.active_count);

    try std.testing.expectError(error.NoMatch, themes.appendFaces(faces[0..1], &handles));
    try std.testing.expectEqual(@as(usize, 0), handles.items.len);
}

test "explicit Latin font retains Arabic fallback shaping without Fontconfig" {
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const primary = try fonts.acquire(.{
        .key = .{ .file = "fixture:Inter", .index = 0 },
        .bytes = @embedFile("ourokit_test_font_static"),
    });
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

test "paragraph and shape caches retain deferred candidates without opening unused files" {
    const allocator = std.testing.allocator;
    var fonts = text.FontCache.init(allocator);
    defer fonts.deinit();
    const primary = try fonts.acquire(.{
        .key = .{ .file = "fixture:Inter", .index = 0 },
        .bytes = @embedFile("ourokit_test_font_static"),
    });
    const unused = try fonts.acquireFile(std.testing.io, .{ .file = "/ourokit-test/unused.ttf", .index = 0 });
    var shapes = text.ShapeCache.init(allocator, &fonts);
    defer shapes.deinit();
    var paragraphs = text.ParagraphCache.init(allocator, &fonts);
    defer paragraphs.deinit();
    const candidates = [_]text.FontHandle{ primary, unused };
    const shape = try shapes.acquire(.{
        .spec = .{ .paragraph = "office", .direction = .left_to_right, .script = .latin, .language = "en", .logical_size = 20 },
        .candidates = &candidates,
        .configuration_revision = 1,
    });
    const paragraph = try paragraphs.acquire(.{
        .utf8 = "office\n\nWi",
        .language = "en",
        .logical_size = 20,
        .max_width = 200,
        .include_caret_stops = true,
        .candidates = &candidates,
        .configuration_revision = 1,
    });
    try std.testing.expect(!(try fonts.isLoaded(unused)));
    try std.testing.expectEqual(primary, (try shapes.get(shape)).spans[0].font);
    const layout = try paragraphs.get(paragraph);
    try std.testing.expect(layout.positioned.glyphs.len > 0);
    try std.testing.expect(layout.positioned.carets.len > 0);
    try std.testing.expectEqual(@as(usize, 3), layout.positioned.lines.len);
    try fonts.release(primary);
    try fonts.release(unused);
    try shapes.release(shape);
    try std.testing.expect(!(try fonts.isLoaded(unused)));
    try paragraphs.release(paragraph);
    try std.testing.expectEqual(@as(usize, 0), fonts.count());
    try std.testing.expectError(error.StaleFont, fonts.get(unused));
}
