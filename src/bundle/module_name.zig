const std = @import("std");

pub const Paths = struct {
    allocator: std.mem.Allocator,
    canonical: []u8,
    file: [:0]u8,
    init: [:0]u8,

    pub fn deinit(self: *Paths) void {
        self.allocator.free(self.init);
        self.allocator.free(self.file);
        self.allocator.free(self.canonical);
        self.* = undefined;
    }
};

/// Validates one canonical application module name and produces the only two
/// source-root-relative paths Ourokit will try. Filesystem syntax is not
/// accepted as module syntax, so names cannot smuggle traversal or separators
/// into the capability-relative open.
pub fn paths(allocator: std.mem.Allocator, name: []const u8) !Paths {
    try validate(name);
    const canonical = try allocator.dupe(u8, name);
    errdefer allocator.free(canonical);
    const stem = try allocator.alloc(u8, name.len);
    defer allocator.free(stem);
    for (name, stem) |character, *output|
        output.* = if (character == '.') '/' else character;

    const file = try allocator.allocSentinel(u8, stem.len + ".lua".len, 0);
    errdefer allocator.free(file);
    @memcpy(file[0..stem.len], stem);
    @memcpy(file[stem.len..], ".lua");
    const init = try allocator.allocSentinel(u8, stem.len + "/init.lua".len, 0);
    @memcpy(init[0..stem.len], stem);
    @memcpy(init[stem.len..], "/init.lua");
    return .{ .allocator = allocator, .canonical = canonical, .file = file, .init = init };
}

pub fn validate(name: []const u8) !void {
    if (name.len == 0) return error.EmptyModuleName;
    var segment_start = true;
    for (name) |character| {
        if (character == '.') {
            if (segment_start) return error.InvalidModuleName;
            segment_start = true;
            continue;
        }
        if (segment_start) {
            if (!isAsciiLetter(character) and character != '_')
                return error.InvalidModuleName;
            segment_start = false;
        } else if (!isAsciiLetter(character) and !std.ascii.isDigit(character) and character != '_') {
            return error.InvalidModuleName;
        }
    }
    if (segment_start) return error.InvalidModuleName;
}

fn isAsciiLetter(character: u8) bool {
    return std.ascii.isAlphabetic(character);
}

test "canonical module names map to bounded source-root paths" {
    var result = try paths(std.testing.allocator, "model.format_v2");
    defer result.deinit();
    try std.testing.expectEqualStrings("model.format_v2", result.canonical);
    try std.testing.expectEqualStrings("model/format_v2.lua", result.file);
    try std.testing.expectEqualStrings("model/format_v2/init.lua", result.init);
}

test "module names reject traversal filesystem syntax and empty segments" {
    const rejected = [_][]const u8{
        "",     ".foo", "foo.",    "foo..bar", "../foo", "foo/bar", "foo\\bar",
        "/foo", "1foo", "foo-bar",
    };
    for (rejected) |name|
        try std.testing.expectError(if (name.len == 0) error.EmptyModuleName else error.InvalidModuleName, validate(name));
}
