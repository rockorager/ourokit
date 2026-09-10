const std = @import("std");
const text = @import("../text/root.zig");

/// Host-owned cache. Family names select installed fonts, never application
/// paths; loading happens at a build safe point, not during native layout.
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
        if (!text.has_fontconfig) return error.FontconfigDisabled;
        var database = try text.discovery.Database.init();
        defer database.deinit();
        var candidates = try database.candidates(self.allocator, .{
            .family = family,
            .weight = if (medium) .medium else .regular,
        });
        defer candidates.deinit();
        const name = try self.allocator.dupe(u8, family);
        errdefer self.allocator.free(name);
        const handles = try self.allocator.alloc(text.FontHandle, candidates.faces.len);
        var loaded: usize = 0;
        errdefer {
            for (handles[0..loaded]) |handle| self.fonts.release(handle) catch unreachable;
            self.allocator.free(handles);
        }
        for (candidates.faces, handles) |face, *handle| {
            const file = try std.Io.Dir.openFileAbsolute(self.io, face.file, .{});
            defer file.close(self.io);
            var buffer: [8192]u8 = undefined;
            var reader = file.reader(self.io, &buffer);
            const bytes = try reader.interface.allocRemaining(self.allocator, .limited(64 * 1024 * 1024));
            defer self.allocator.free(bytes);
            handle.* = try self.fonts.acquire(.{
                .key = .{ .file = face.file, .index = face.index, .variations = face.variations },
                .bytes = bytes,
            });
            loaded += 1;
        }
        try self.entries.append(self.allocator, .{ .family = name, .medium = medium, .handles = handles });
        return handles;
    }
};
