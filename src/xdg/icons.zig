const std = @import("std");

const max_index_bytes = 1024 * 1024;
const max_inheritance_depth = 64;

pub const Request = struct {
    name: []const u8,
    theme: []const u8 = "hicolor",
    size: u32 = 24,
    scale: u32 = 1,
};

pub const SearchPaths = struct {
    allocator: std.mem.Allocator,
    paths: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, environ: std.process.Environ) !SearchPaths {
        const home_value = std.process.Environ.getPosix(environ, "HOME") orelse "";
        const home: ?[]const u8 = if (validAbsolute(home_value)) home_value else null;

        var paths: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (paths.items) |path| allocator.free(path);
            paths.deinit(allocator);
        }
        if (home) |base| try appendPath(allocator, &paths, base, ".icons");

        const data_home = std.process.Environ.getPosix(environ, "XDG_DATA_HOME") orelse "";
        if (validAbsolute(data_home)) {
            try appendPath(allocator, &paths, data_home, "icons");
        } else if (home) |base| try appendPath(allocator, &paths, base, ".local/share/icons");

        const dirs_value = std.process.Environ.getPosix(environ, "XDG_DATA_DIRS");
        const dirs = if (dirs_value == null or dirs_value.?.len == 0)
            "/usr/local/share:/usr/share"
        else
            dirs_value.?;
        var parts = std.mem.splitScalar(u8, dirs, ':');
        while (parts.next()) |part| if (validAbsolute(part))
            try appendPath(allocator, &paths, part, "icons");
        try appendPath(allocator, &paths, "/usr/share", "pixmaps");
        return .{ .allocator = allocator, .paths = try paths.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *SearchPaths) void {
        for (self.paths) |path| self.allocator.free(path);
        self.allocator.free(self.paths);
        self.* = undefined;
    }
};

fn validAbsolute(path: []const u8) bool {
    return path.len != 0 and std.fs.path.isAbsolute(path) and std.mem.indexOfScalar(u8, path, 0) == null;
}

fn appendPath(allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8), base: []const u8, suffix: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ base, suffix });
    errdefer allocator.free(path);
    try paths.append(allocator, path);
}

const Kind = enum { fixed, scalable, threshold };
const Directory = struct {
    name: []const u8,
    size: u32,
    scale: u32 = 1,
    kind: Kind = .threshold,
    min: u32,
    max: u32,
    threshold: u32 = 2,
};
const Theme = struct {
    bytes: []u8,
    directories: []Directory,
    inherits: []const []const u8,
    allocator: std.mem.Allocator,
    fn deinit(self: *Theme) void {
        self.allocator.free(self.directories);
        self.allocator.free(self.inherits);
        self.allocator.free(self.bytes);
    }
};

/// Synchronous exact-name lookup. The caller owns the returned filename. Does
/// not cache filesystem state; UI consumers should call from their asset worker.
pub fn lookup(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8, request: Request) !?[]u8 {
    try validateComponent(request.name, error.InvalidIconName);
    try validateComponent(request.theme, error.InvalidThemeName);
    if (request.size == 0 or request.scale == 0) return error.InvalidIconSize;
    for (roots) |root| if (!validAbsolute(root)) return error.InvalidSearchRoot;

    var visited: std.ArrayList([]u8) = .empty;
    defer {
        for (visited.items) |name| allocator.free(name);
        visited.deinit(allocator);
    }
    if (try lookupTheme(allocator, io, roots, request, request.theme, &visited, 0)) |path| return path;
    if (!contains(visited.items, "hicolor"))
        if (try lookupTheme(allocator, io, roots, request, "hicolor", &visited, 0)) |path| return path;
    return lookupUnthemed(allocator, io, roots, request.name);
}

fn lookupTheme(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8, request: Request, name: []const u8, visited: *std.ArrayList([]u8), depth: usize) !?[]u8 {
    if (depth >= max_inheritance_depth or contains(visited.items, name)) return null;
    if (visited.items.len == 256) return error.TooManyIconThemes;
    try validateComponent(name, error.InvalidThemeMetadata);
    const owned_name = try allocator.dupe(u8, name);
    visited.append(allocator, owned_name) catch |err| {
        allocator.free(owned_name);
        return err;
    };

    var theme = (try loadTheme(allocator, io, roots, name)) orelse return null;
    defer theme.deinit();
    if (try findInTheme(allocator, io, roots, request, name, theme.directories, true)) |path| return path;
    if (try findInTheme(allocator, io, roots, request, name, theme.directories, false)) |path| return path;
    for (theme.inherits) |parent| {
        // Search all selected-theme parents before the universal fallback.
        if (std.mem.eql(u8, parent, "hicolor")) continue;
        if (try lookupTheme(allocator, io, roots, request, parent, visited, depth + 1)) |path| return path;
    }
    return null;
}

fn findInTheme(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8, request: Request, theme_name: []const u8, dirs: []const Directory, exact: bool) !?[]u8 {
    var best_distance: u64 = std.math.maxInt(u64);
    var best: ?[]u8 = null;
    errdefer if (best) |path| allocator.free(path);
    for (dirs) |dir| {
        const matching = matches(dir, request);
        if (exact != matching) continue;
        const candidate_distance = distance(dir, request);
        if (!exact and candidate_distance > best_distance) continue;
        for (roots) |root| for ([_][]const u8{ "png", "svg" }) |extension| {
            const filename = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ request.name, extension });
            defer allocator.free(filename);
            const path = try std.fs.path.join(allocator, &.{ root, theme_name, dir.name, filename });
            if (fileExists(io, path)) {
                if (exact) return path;
                if (candidate_distance < best_distance) {
                    if (best) |old| allocator.free(old);
                    best = path;
                    best_distance = candidate_distance;
                } else allocator.free(path);
            } else allocator.free(path);
        };
    }
    return best;
}

fn matches(dir: Directory, request: Request) bool {
    if (dir.scale != request.scale) return false;
    return switch (dir.kind) {
        .fixed => dir.size == request.size,
        .scalable => request.size >= dir.min and request.size <= dir.max,
        .threshold => request.size >= dir.size -| dir.threshold and request.size <= @as(u64, dir.size) + dir.threshold,
    };
}

fn distance(dir: Directory, request: Request) u64 {
    const wanted: u64 = @as(u64, request.size) * request.scale;
    const low: u64 = @as(u64, switch (dir.kind) {
        .fixed => dir.size,
        .scalable => dir.min,
        .threshold => dir.size -| dir.threshold,
    }) * dir.scale;
    const high: u64 = @as(u64, switch (dir.kind) {
        .fixed => dir.size,
        .scalable => dir.max,
        .threshold => @as(u64, dir.size) + dir.threshold,
    }) *| dir.scale;
    return if (wanted < low) low - wanted else if (wanted > high) wanted - high else 0;
}

fn lookupUnthemed(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8, name: []const u8) !?[]u8 {
    for (roots) |root| for ([_][]const u8{ "png", "svg" }) |extension| {
        const filename = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ name, extension });
        defer allocator.free(filename);
        const path = try std.fs.path.join(allocator, &.{ root, filename });
        if (fileExists(io, path)) return path;
        allocator.free(path);
    };
    return null;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

fn loadTheme(allocator: std.mem.Allocator, io: std.Io, roots: []const []const u8, name: []const u8) !?Theme {
    for (roots) |root| {
        const path = try std.fs.path.join(allocator, &.{ root, name, "index.theme" });
        defer allocator.free(path);
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        if (stat.kind != .file or stat.size > max_index_bytes) return error.InvalidThemeMetadata;
        const file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => continue,
            else => return err,
        };
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        const bytes = reader.interface.allocRemaining(allocator, .limited(max_index_bytes)) catch |err| switch (err) {
            error.StreamTooLong => return error.InvalidThemeMetadata,
            else => return err,
        };
        errdefer allocator.free(bytes);
        return parseTheme(allocator, bytes) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => {
                allocator.free(bytes);
                return null;
            },
        };
    }
    return null;
}

fn parseTheme(allocator: std.mem.Allocator, bytes: []u8) !Theme {
    var directory_names: ?[]const u8 = null;
    var scaled_names: ?[]const u8 = null;
    var inherits_text: []const u8 = "";
    var section: []const u8 = "";
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = line[1 .. line.len - 1];
            continue;
        }
        const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.mem.eql(u8, section, "Icon Theme")) continue;
        const key = std.mem.trim(u8, line[0..equal], " \t");
        const value = std.mem.trim(u8, line[equal + 1 ..], " \t");
        if (std.mem.eql(u8, key, "Directories")) directory_names = value else if (std.mem.eql(u8, key, "ScaledDirectories")) scaled_names = value else if (std.mem.eql(u8, key, "Inherits")) inherits_text = value;
    }
    const names = directory_names orelse return error.InvalidThemeMetadata;
    var dirs: std.ArrayList(Directory) = .empty;
    errdefer dirs.deinit(allocator);
    try parseDirectoryList(allocator, bytes, names, &dirs);
    if (scaled_names) |scaled| try parseDirectoryList(allocator, bytes, scaled, &dirs);
    if (dirs.items.len == 0) return error.InvalidThemeMetadata;
    var parents: std.ArrayList([]const u8) = .empty;
    errdefer parents.deinit(allocator);
    var parent_it = std.mem.splitScalar(u8, inherits_text, ',');
    while (parent_it.next()) |raw| {
        const parent = std.mem.trim(u8, raw, " \t");
        if (parent.len == 0) continue;
        try validateComponent(parent, error.InvalidThemeMetadata);
        try parents.append(allocator, parent);
    }
    const directories = try dirs.toOwnedSlice(allocator);
    errdefer allocator.free(directories);
    return .{ .bytes = bytes, .directories = directories, .inherits = try parents.toOwnedSlice(allocator), .allocator = allocator };
}

fn parseDirectoryList(allocator: std.mem.Allocator, bytes: []const u8, list: []const u8, output: *std.ArrayList(Directory)) !void {
    var names = std.mem.splitScalar(u8, list, ',');
    while (names.next()) |raw| {
        const name = std.mem.trim(u8, raw, " \t");
        if (name.len == 0) continue;
        if (output.items.len == 1024) return error.InvalidThemeMetadata;
        try validateRelative(name);
        var dir = Directory{ .name = name, .size = 0, .min = 0, .max = 0 };
        var found = false;
        var section: []const u8 = "";
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (line[0] == '[' and line[line.len - 1] == ']') {
                section = line[1 .. line.len - 1];
                continue;
            }
            if (!std.mem.eql(u8, section, name)) continue;
            const equal = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..equal], " \t");
            const value = std.mem.trim(u8, line[equal + 1 ..], " \t");
            if (std.mem.eql(u8, key, "Size")) {
                dir.size = try std.fmt.parseInt(u32, value, 10);
                found = true;
            } else if (std.mem.eql(u8, key, "Scale")) dir.scale = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "MinSize")) dir.min = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "MaxSize")) dir.max = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "Threshold")) dir.threshold = try std.fmt.parseInt(u32, value, 10) else if (std.mem.eql(u8, key, "Type")) dir.kind = if (std.mem.eql(u8, value, "Fixed")) .fixed else if (std.mem.eql(u8, value, "Scalable")) .scalable else if (std.mem.eql(u8, value, "Threshold")) .threshold else return error.InvalidThemeMetadata;
        }
        if (!found or dir.size == 0 or dir.scale == 0) return error.InvalidThemeMetadata;
        if (dir.min == 0) dir.min = dir.size;
        if (dir.max == 0) dir.max = dir.size;
        if (dir.min > dir.max) return error.InvalidThemeMetadata;
        try output.append(allocator, dir);
    }
}

fn validateComponent(value: []const u8, comptime invalid: anyerror) !void {
    if (value.len == 0 or value.len > 255 or std.mem.indexOfScalar(u8, value, 0) != null or
        std.mem.indexOfScalar(u8, value, '/') != null or std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return invalid;
}
fn validateRelative(value: []const u8) !void {
    if (value.len == 0 or value.len > 1024 or std.fs.path.isAbsolute(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidThemeMetadata;
    var parts = std.mem.splitScalar(u8, value, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidThemeMetadata;
}
fn contains(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, needle)) return true;
    return false;
}

fn testRoot(allocator: std.mem.Allocator, temporary: *std.testing.TmpDir) ![:0]u8 {
    const relative = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path });
    defer allocator.free(relative);
    return std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, relative, allocator);
}

fn testWrite(root: []const u8, relative: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, relative });
    defer std.testing.allocator.free(path);
    const parent = std.fs.path.dirname(path).?;
    try std.Io.Dir.cwd().createDirPath(std.testing.io, parent);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

test "current theme beats inherited closer size and exact scale beats physical equivalent" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try testRoot(std.testing.allocator, &temporary);
    defer std.testing.allocator.free(root);
    try testWrite(root, "child/index.theme",
        \\[Icon Theme]
        \\Directories=16,48
        \\ScaledDirectories=24@2
        \\Inherits=parent
        \\[16]
        \\Size=16
        \\Type=Fixed
        \\[48]
        \\Size=48
        \\Type=Fixed
        \\[24@2]
        \\Size=24
        \\Scale=2
        \\Type=Fixed
    );
    try testWrite(root, "parent/index.theme", "[Icon Theme]\nDirectories=24\n[24]\nSize=24\nType=Fixed\n");
    try testWrite(root, "child/16/app.png", "x");
    try testWrite(root, "child/48/app.png", "x");
    try testWrite(root, "child/24@2/app.svg", "x");
    try testWrite(root, "parent/24/app.png", "x");

    const one = (try lookup(std.testing.allocator, std.testing.io, &.{root}, .{ .name = "app", .theme = "child", .size = 24 })).?;
    defer std.testing.allocator.free(one);
    try std.testing.expect(std.mem.endsWith(u8, one, "child/16/app.png"));
    const two = (try lookup(std.testing.allocator, std.testing.io, &.{root}, .{ .name = "app", .theme = "child", .size = 24, .scale = 2 })).?;
    defer std.testing.allocator.free(two);
    try std.testing.expect(std.mem.endsWith(u8, two, "child/24@2/app.svg"));
}

test "base root and metadata order plus png precedence are deterministic" {
    var first = std.testing.tmpDir(.{});
    defer first.cleanup();
    var second = std.testing.tmpDir(.{});
    defer second.cleanup();
    const root1 = try testRoot(std.testing.allocator, &first);
    defer std.testing.allocator.free(root1);
    const root2 = try testRoot(std.testing.allocator, &second);
    defer std.testing.allocator.free(root2);
    const index = "[Icon Theme]\nDirectories=large,small,\n[large]\nSize=48\nType=Fixed\n[small]\nSize=24\nType=Fixed\n";
    try testWrite(root1, "theme/index.theme", index);
    // Only the first index governs a theme split across search roots.
    try testWrite(root2, "theme/index.theme", "[Icon Theme]\nDirectories=wrong\n[wrong]\nSize=24\n");
    try testWrite(root2, "theme/wrong/icon.png", "x");
    try testWrite(root1, "theme/large/icon.svg", "x");
    try testWrite(root1, "theme/large/icon.png", "x");
    try testWrite(root2, "theme/large/icon.png", "x");
    try testWrite(root2, "theme/small/icon.png", "x");
    const path = (try lookup(std.testing.allocator, std.testing.io, &.{ root1, root2 }, .{ .name = "icon", .theme = "theme", .size = 24 })).?;
    defer std.testing.allocator.free(path);
    // Exact-sized small wins over all non-exact entries, regardless of root.
    try std.testing.expect(std.mem.startsWith(u8, path, root2));
    try std.testing.expect(std.mem.endsWith(u8, path, "small/icon.png"));

    const large = (try lookup(std.testing.allocator, std.testing.io, &.{ root1, root2 }, .{ .name = "icon", .theme = "theme", .size = 48 })).?;
    defer std.testing.allocator.free(large);
    try std.testing.expect(std.mem.startsWith(u8, large, root1));
    try std.testing.expect(std.mem.endsWith(u8, large, ".png"));
}

test "inheritance cycles terminate then hicolor and unthemed fallbacks work" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try testRoot(std.testing.allocator, &temporary);
    defer std.testing.allocator.free(root);
    try testWrite(root, "a/index.theme", "[Icon Theme]\nDirectories=d\nInherits=hicolor,b\n[d]\nSize=24\n");
    try testWrite(root, "b/index.theme", "[Icon Theme]\nDirectories=d\nInherits=a\n[d]\nSize=24\n");
    try testWrite(root, "hicolor/index.theme", "[Icon Theme]\nDirectories=d\n[d]\nSize=24\n");
    try testWrite(root, "hicolor/d/fallback.svg", "x");
    try testWrite(root, "hicolor/d/inherited.png", "x");
    try testWrite(root, "b/d/inherited.svg", "x");
    try temporary.dir.symLink(std.testing.io, "inherited.svg", "b/d/link.svg", .{});
    const inherited = (try lookup(std.testing.allocator, std.testing.io, &.{root}, .{ .name = "inherited", .theme = "a" })).?;
    defer std.testing.allocator.free(inherited);
    try std.testing.expect(std.mem.endsWith(u8, inherited, "b/d/inherited.svg"));
    const linked = (try lookup(std.testing.allocator, std.testing.io, &.{root}, .{ .name = "link", .theme = "a" })).?;
    defer std.testing.allocator.free(linked);
    try std.testing.expect(std.mem.endsWith(u8, linked, "b/d/link.svg"));
    try testWrite(root, "plain.png", "x");
    const themed = (try lookup(std.testing.allocator, std.testing.io, &.{root}, .{ .name = "fallback", .theme = "a" })).?;
    defer std.testing.allocator.free(themed);
    try std.testing.expect(std.mem.endsWith(u8, themed, "hicolor/d/fallback.svg"));
    const plain = (try lookup(std.testing.allocator, std.testing.io, &.{root}, .{ .name = "plain", .theme = "a" })).?;
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.endsWith(u8, plain, "plain.png"));
    try std.testing.expect((try lookup(std.testing.allocator, std.testing.io, &.{root}, .{ .name = "absent", .theme = "a" })) == null);
}

test "threshold and scalable defaults and unsafe metadata" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root = try testRoot(std.testing.allocator, &temporary);
    defer std.testing.allocator.free(root);
    try testWrite(root, "good/index.theme", "[Icon Theme]\nDirectories=threshold,vector\n[threshold]\nSize=24\n[vector]\nSize=48\nType=Scalable\n");
    try testWrite(root, "good/threshold/x.png", "x");
    try testWrite(root, "good/vector/y.svg", "x");
    const threshold = (try lookup(std.testing.allocator, std.testing.io, &.{root}, .{ .name = "x", .theme = "good", .size = 26 })).?;
    defer std.testing.allocator.free(threshold);
    try std.testing.expect(std.mem.endsWith(u8, threshold, "threshold/x.png"));
    const scalable = (try lookup(std.testing.allocator, std.testing.io, &.{root}, .{ .name = "y", .theme = "good", .size = 48 })).?;
    defer std.testing.allocator.free(scalable);
    try std.testing.expect(std.mem.endsWith(u8, scalable, "vector/y.svg"));
    try testWrite(root, "bad/index.theme", "[Icon Theme]\nDirectories=../escape\n[../escape]\nSize=24\n");
    try testWrite(root, "escape/x.png", "x");
    try std.testing.expect((try lookup(std.testing.allocator, std.testing.io, &.{root}, .{ .name = "x", .theme = "bad" })) == null);
    try std.testing.expectError(error.InvalidIconName, lookup(std.testing.allocator, std.testing.io, &.{root}, .{ .name = "../x" }));
}

test "search paths apply defaults and ignore invalid entries" {
    var map: std.process.Environ.Map = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("HOME", "/home/tester");
    try map.put("XDG_DATA_HOME", "");
    try map.put("XDG_DATA_DIRS", "relative::/opt/share");
    const environ: std.process.Environ = .{ .block = try map.createPosixBlock(std.testing.allocator, .{}) };
    defer environ.block.deinit(std.testing.allocator);
    var paths = try SearchPaths.init(std.testing.allocator, environ);
    defer paths.deinit();
    try std.testing.expectEqual(@as(usize, 4), paths.paths.len);
    try std.testing.expectEqualStrings("/home/tester/.icons", paths.paths[0]);
    try std.testing.expectEqualStrings("/home/tester/.local/share/icons", paths.paths[1]);
    try std.testing.expectEqualStrings("/opt/share/icons", paths.paths[2]);
    try std.testing.expectEqualStrings("/usr/share/pixmaps", paths.paths[3]);

    var defaults = try SearchPaths.init(std.testing.allocator, .empty);
    defer defaults.deinit();
    try std.testing.expectEqual(@as(usize, 3), defaults.paths.len);
    try std.testing.expectEqualStrings("/usr/local/share/icons", defaults.paths[0]);
    try std.testing.expectEqualStrings("/usr/share/icons", defaults.paths[1]);
}

test "size matching and physical distance respect both interval boundaries" {
    const threshold: Directory = .{ .name = "t", .size = 24, .scale = 2, .min = 24, .max = 24 };
    for ([_]u32{ 21, 22, 26, 27 }, [_]bool{ false, true, true, false }, [_]u64{ 2, 0, 0, 2 }) |size, exact, pixels| {
        const request: Request = .{ .name = "x", .size = size, .scale = 2 };
        try std.testing.expectEqual(exact, matches(threshold, request));
        try std.testing.expectEqual(pixels, distance(threshold, request));
    }
    const scalable: Directory = .{ .name = "s", .size = 24, .kind = .scalable, .scale = 2, .min = 16, .max = 48 };
    for ([_]u32{ 15, 16, 48, 50 }, [_]bool{ false, true, true, false }, [_]u64{ 2, 0, 0, 4 }) |size, exact, pixels| {
        const request: Request = .{ .name = "x", .size = size, .scale = 2 };
        try std.testing.expectEqual(exact, matches(scalable, request));
        try std.testing.expectEqual(pixels, distance(scalable, request));
    }
    const physical_equivalent: Request = .{ .name = "x", .size = 48, .scale = 1 };
    try std.testing.expect(!matches(threshold, physical_equivalent));
    try std.testing.expectEqual(@as(u64, 0), distance(threshold, physical_equivalent));
}
