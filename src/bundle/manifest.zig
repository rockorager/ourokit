const std = @import("std");

pub const file_name = "ouro.json";
const max_manifest_bytes = 64 * 1024;

pub const NativeModule = struct { name: []const u8, path: []const u8 };

const Document = struct {
    schema_version: u32,
    id: []const u8,
    entry: []const u8,
    native_modules: []const NativeModule = &.{},
};

/// Package identity needed before application Lua is evaluated. Socket
/// activation, service discovery, and capability policy must not depend on
/// executing mutable application source to learn this information.
pub const Manifest = struct {
    allocator: std.mem.Allocator,
    id: []u8,
    entry_path: []u8,
    native_modules: []NativeModule,

    pub fn load(
        io: std.Io,
        allocator: std.mem.Allocator,
        path: []const u8,
    ) !Manifest {
        const file = if (std.fs.path.isAbsolute(path))
            try std.Io.Dir.openFileAbsolute(io, path, .{})
        else
            try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(io, &buffer);
        const bytes = try reader.interface.allocRemaining(
            allocator,
            .limited(max_manifest_bytes),
        );
        defer allocator.free(bytes);
        const parsed = std.json.parseFromSlice(Document, allocator, bytes, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = false,
        }) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return error.InvalidApplicationManifest,
        };
        defer parsed.deinit();
        if (parsed.value.schema_version != 1) return error.UnsupportedManifestVersion;
        try validateApplicationId(parsed.value.id);
        try validateEntry(parsed.value.entry);
        const id = try allocator.dupe(u8, parsed.value.id);
        errdefer allocator.free(id);
        const parent = std.fs.path.dirname(path) orelse ".";
        const modules = try allocator.alloc(NativeModule, parsed.value.native_modules.len);
        errdefer allocator.free(modules);
        var count: usize = 0;
        errdefer for (modules[0..count]) |module| {
            allocator.free(module.name);
            allocator.free(module.path);
        };
        for (parsed.value.native_modules, modules, 0..) |module, *owned, index| {
            try @import("module_name.zig").validate(module.name);
            if (std.mem.eql(u8, module.name, "ouro")) return error.ReservedNativeModule;
            try validateEntry(module.path);
            for (modules[0..index]) |previous| if (std.mem.eql(u8, previous.name, module.name))
                return error.DuplicateNativeModule;
            const name = try allocator.dupe(u8, module.name);
            errdefer allocator.free(name);
            owned.* = .{ .name = name, .path = try std.fs.path.join(allocator, &.{ parent, module.path }) };
            count += 1;
        }
        return .{
            .allocator = allocator,
            .id = id,
            .entry_path = try std.fs.path.join(allocator, &.{ parent, parsed.value.entry }),
            .native_modules = modules,
        };
    }

    pub fn deinit(self: *Manifest) void {
        for (self.native_modules) |module| {
            self.allocator.free(module.path);
            self.allocator.free(module.name);
        }
        self.allocator.free(self.native_modules);
        self.allocator.free(self.entry_path);
        self.allocator.free(self.id);
        self.* = undefined;
    }
};

pub fn validateApplicationId(id: []const u8) !void {
    if (id.len == 0 or id.len > 255) return error.InvalidApplicationId;
    var segment_length: usize = 0;
    for (id) |byte| {
        if (byte == '.') {
            if (segment_length == 0) return error.InvalidApplicationId;
            segment_length = 0;
            continue;
        }
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-')
            return error.InvalidApplicationId;
        segment_length += 1;
    }
    if (segment_length == 0 or std.mem.indexOfScalar(u8, id, '.') == null)
        return error.InvalidApplicationId;
}

fn validateEntry(entry: []const u8) !void {
    if (entry.len == 0 or std.fs.path.isAbsolute(entry) or
        std.mem.indexOfScalar(u8, entry, 0) != null)
        return error.InvalidApplicationEntry;
    var components = std.mem.splitScalar(u8, entry, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
            return error.InvalidApplicationEntry;
    }
}

test "manifest owns pre-Lua identity and resolves its entry" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data =
        \\{"schema_version":1,"id":"dev.ouro.contacts","entry":"src/app.lua"}
        ,
    });
    const path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache",
        "tmp",
        &temporary.sub_path,
        file_name,
    });
    defer std.testing.allocator.free(path);
    var manifest = try Manifest.load(std.testing.io, std.testing.allocator, path);
    defer manifest.deinit();
    try std.testing.expectEqualStrings("dev.ouro.contacts", manifest.id);
    try std.testing.expect(std.mem.endsWith(u8, manifest.entry_path, "src/app.lua"));
}

test "manifest rejects unsafe identity and entry metadata" {
    try std.testing.expectError(error.InvalidApplicationId, validateApplicationId("contacts"));
    try std.testing.expectError(error.InvalidApplicationId, validateApplicationId("dev..contacts"));
    try std.testing.expectError(error.InvalidApplicationEntry, validateEntry("../app.lua"));
    try std.testing.expectError(error.InvalidApplicationEntry, validateEntry("/app.lua"));
}

test "manifest resolves explicit native modules without executing libraries" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const path = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path, file_name });
    defer std.testing.allocator.free(path);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = file_name,
        .data =
        \\{"schema_version":1,"id":"dev.ouro.native","entry":"src/app.lua",
        \\ "native_modules":[{"name":"example.counter","path":"lib/counter.so"}]}
        ,
    });
    var manifest = try Manifest.load(std.testing.io, std.testing.allocator, path);
    defer manifest.deinit();
    try std.testing.expectEqual(1, manifest.native_modules.len);
    try std.testing.expectEqualStrings("example.counter", manifest.native_modules[0].name);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ ".zig-cache", "tmp", &temporary.sub_path, "lib/counter.so" });
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, manifest.native_modules[0].path);

    const invalid = .{
        .{ "[{\"name\":\"ouro\",\"path\":\"a.so\"}]", error.ReservedNativeModule },
        .{ "[{\"name\":\"x\",\"path\":\"../a.so\"}]", error.InvalidApplicationEntry },
        .{ "[{\"name\":\"x\",\"path\":\"a.so\"},{\"name\":\"x\",\"path\":\"b.so\"}]", error.DuplicateNativeModule },
    };
    inline for (invalid) |case| {
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = file_name,
            .data = "{\"schema_version\":1,\"id\":\"dev.ouro.native\",\"entry\":\"app.lua\",\"native_modules\":" ++ case[0] ++ "}",
        });
        try std.testing.expectError(case[1], Manifest.load(std.testing.io, std.testing.allocator, path));
    }
}
