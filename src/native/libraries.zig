const std = @import("std");
const registry = @import("registry.zig");
const abi = @import("root.zig").abi;

pub const Path = struct { name: []const u8, path: []const u8 };

/// Process-owned code. Reload creates new contexts but never replaces or
/// unloads a library while another source generation can still call it.
pub const Libraries = struct {
    allocator: std.mem.Allocator,
    handles: []std.DynLib,
    modules: []registry.Module,

    pub fn open(allocator: std.mem.Allocator, paths: []const Path) !Libraries {
        const handles = try allocator.alloc(std.DynLib, paths.len);
        errdefer allocator.free(handles);
        const modules = try allocator.alloc(registry.Module, paths.len);
        errdefer allocator.free(modules);
        var count: usize = 0;
        errdefer for (handles[0..count], modules[0..count]) |*handle, module| {
            handle.close();
            allocator.free(module.name);
        };
        for (paths, handles, modules, 0..) |path, *handle, *module, index| {
            const name = try allocator.dupe(u8, path.name);
            errdefer allocator.free(name);
            var library = try std.DynLib.open(path.path);
            errdefer library.close();
            const descriptor = library.lookup(*const abi.ouro_plugin_descriptor, "ouro_plugin") orelse
                return error.NativePluginEntryMissing;
            try registry.validate(.{ .name = name, .descriptor = descriptor });
            for (modules[0..index]) |previous| if (std.mem.eql(u8, previous.name, name))
                return error.DuplicateNativeModule;
            handle.* = library;
            module.* = .{ .name = name, .descriptor = descriptor };
            count += 1;
        }
        return .{ .allocator = allocator, .handles = handles, .modules = modules };
    }

    /// Only after every runtime using modules has been destroyed.
    pub fn deinit(self: *Libraries) void {
        var index = self.handles.len;
        while (index != 0) {
            index -= 1;
            self.handles[index].close();
            self.allocator.free(self.modules[index].name);
        }
        self.allocator.free(self.modules);
        self.allocator.free(self.handles);
        self.* = undefined;
    }
};
