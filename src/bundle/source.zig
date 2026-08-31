const std = @import("std");

pub const max_entry_bytes = 16 * 1024 * 1024;
pub const ContentHash = [std.crypto.hash.sha2.Sha256.digest_length]u8;

const Kind = union(enum) {
    disk: []u8,
    embedded: struct {
        name: []u8,
        bytes: []u8,
    },
};

/// Process-lifetime origin for application source. Disk providers retain the
/// path so later generations can read it again; embedded providers expose the
/// same snapshot contract without promising reloadability.
pub const SourceProvider = struct {
    allocator: std.mem.Allocator,
    kind: Kind,

    pub fn initDisk(
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !SourceProvider {
        if (path.len == 0) return error.EmptySourcePath;
        return .{
            .allocator = allocator,
            .kind = .{ .disk = try allocator.dupe(u8, path) },
        };
    }

    pub fn initEmbedded(
        allocator: std.mem.Allocator,
        name: []const u8,
        bytes: []const u8,
    ) !SourceProvider {
        if (name.len == 0) return error.EmptySourceName;
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_bytes = try allocator.dupe(u8, bytes);
        return .{
            .allocator = allocator,
            .kind = .{ .embedded = .{ .name = owned_name, .bytes = owned_bytes } },
        };
    }

    pub fn deinit(self: *SourceProvider) void {
        switch (self.kind) {
            .disk => |path| self.allocator.free(path),
            .embedded => |embedded| {
                self.allocator.free(embedded.bytes);
                self.allocator.free(embedded.name);
            },
        }
        self.* = undefined;
    }

    pub fn entryName(self: *const SourceProvider) []const u8 {
        return switch (self.kind) {
            .disk => |path| path,
            .embedded => |embedded| embedded.name,
        };
    }

    pub fn reloadable(self: *const SourceProvider) bool {
        return self.kind == .disk;
    }

    /// Opens the capability root used for application module resolution. The
    /// caller owns the returned directory for the process/runtime lifetime.
    pub fn openModuleRoot(self: *const SourceProvider, io: std.Io) !?std.Io.Dir {
        return switch (self.kind) {
            .embedded => null,
            .disk => |path| blk: {
                const parent = std.fs.path.dirname(path) orelse ".";
                break :blk if (std.fs.path.isAbsolute(parent))
                    try std.Io.Dir.openDirAbsolute(io, parent, .{})
                else
                    try std.Io.Dir.cwd().openDir(io, parent, .{});
            },
        };
    }

    pub fn entryRelativeName(self: *const SourceProvider) []const u8 {
        return switch (self.kind) {
            .embedded => |embedded| embedded.name,
            .disk => |path| std.fs.path.basename(path),
        };
    }

    /// Captures one immutable entry-source generation. Module closure and
    /// filesystem identity will extend this snapshot rather than bypass it.
    pub fn snapshot(
        self: *const SourceProvider,
        io: std.Io,
        allocator: std.mem.Allocator,
    ) !SourceSnapshot {
        return switch (self.kind) {
            .disk => |path| blk: {
                const file = if (std.fs.path.isAbsolute(path))
                    try std.Io.Dir.openFileAbsolute(io, path, .{})
                else
                    try std.Io.Dir.cwd().openFile(io, path, .{});
                defer file.close(io);
                var buffer: [8192]u8 = undefined;
                var reader = file.reader(io, &buffer);
                const bytes = try reader.interface.allocRemaining(
                    allocator,
                    .limited(max_entry_bytes),
                );
                errdefer allocator.free(bytes);
                break :blk try SourceSnapshot.initOwned(allocator, path, bytes);
            },
            .embedded => |embedded| SourceSnapshot.init(
                allocator,
                embedded.name,
                embedded.bytes,
            ),
        };
    }
};

/// Immutable source bytes and origin owned by one source generation.
pub const SourceSnapshot = struct {
    allocator: std.mem.Allocator,
    entry_name: []u8,
    chunk_name: [:0]u8,
    bytes: []u8,
    content_hash: ContentHash,

    pub fn init(
        allocator: std.mem.Allocator,
        entry_name: []const u8,
        bytes: []const u8,
    ) !SourceSnapshot {
        const owned_bytes = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned_bytes);
        return initOwned(allocator, entry_name, owned_bytes);
    }

    fn initOwned(
        allocator: std.mem.Allocator,
        entry_name: []const u8,
        owned_bytes: []u8,
    ) !SourceSnapshot {
        const owned_name = try allocator.dupe(u8, entry_name);
        errdefer allocator.free(owned_name);
        const chunk_name = try allocator.allocSentinel(u8, entry_name.len + 1, 0);
        errdefer allocator.free(chunk_name);
        chunk_name[0] = '@';
        @memcpy(chunk_name[1..], entry_name);
        var content_hash: ContentHash = undefined;
        std.crypto.hash.sha2.Sha256.hash(owned_bytes, &content_hash, .{});
        return .{
            .allocator = allocator,
            .entry_name = owned_name,
            .chunk_name = chunk_name,
            .bytes = owned_bytes,
            .content_hash = content_hash,
        };
    }

    pub fn deinit(self: *SourceSnapshot) void {
        self.allocator.free(self.bytes);
        self.allocator.free(self.chunk_name);
        self.allocator.free(self.entry_name);
        self.* = undefined;
    }
};

test "embedded provider creates independent immutable snapshots" {
    var provider = try SourceProvider.initEmbedded(
        std.testing.allocator,
        "example.lua",
        "return 1",
    );
    defer provider.deinit();
    try std.testing.expect(!provider.reloadable());

    var first = try provider.snapshot(std.testing.io, std.testing.allocator);
    defer first.deinit();
    var second = try provider.snapshot(std.testing.io, std.testing.allocator);
    defer second.deinit();
    try std.testing.expectEqualStrings("example.lua", first.entry_name);
    try std.testing.expectEqualStrings("@example.lua", first.chunk_name);
    try std.testing.expectEqualStrings(first.bytes, second.bytes);
    try std.testing.expectEqual(first.content_hash, second.content_hash);
    first.bytes[0] = '-';
    try std.testing.expectEqualStrings("return 1", second.bytes);
}

test "disk provider rereads its retained entry path" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "app.lua",
        .data = "return 1",
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &temporary.sub_path,
        "app.lua",
    });
    defer std.testing.allocator.free(path);
    var provider = try SourceProvider.initDisk(std.testing.allocator, path);
    defer provider.deinit();
    try std.testing.expect(provider.reloadable());
    try std.testing.expectEqualStrings("app.lua", provider.entryRelativeName());
    const module_root = (try provider.openModuleRoot(std.testing.io)).?;
    defer module_root.close(std.testing.io);
    const entry = try module_root.openFile(std.testing.io, provider.entryRelativeName(), .{});
    defer entry.close(std.testing.io);

    var first = try provider.snapshot(std.testing.io, std.testing.allocator);
    defer first.deinit();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "app.lua",
        .data = "return 2",
    });
    var second = try provider.snapshot(std.testing.io, std.testing.allocator);
    defer second.deinit();
    try std.testing.expectEqualStrings("return 1", first.bytes);
    try std.testing.expectEqualStrings("return 2", second.bytes);
    try std.testing.expect(!std.mem.eql(u8, &first.content_hash, &second.content_hash));
}
