const std = @import("std");
const ourokit = @import("ourokit");
const cli = @import("cli.zig");

const version = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "--ourokit-auth-worker")) {
        std.process.exit(@intCast(ouro_auth_worker_main()));
    }
    const command = cli.parse(args) catch |err| {
        try writeError(init, @errorName(err));
        try writeStdout(init, cli.usage);
        std.process.exit(2);
    };
    const exit_code = execute(init, command) catch |err| {
        try writeError(init, @errorName(err));
        std.process.exit(1);
    };
    if (exit_code != 0) std.process.exit(exit_code);
}

extern fn ouro_auth_worker_main() c_int;

fn execute(init: std.process.Init, command: cli.Command) !u8 {
    switch (command) {
        .help => try writeStdout(init, cli.usage),
        .version => try writeStdout(init, "ouroctl " ++ version ++ "\n"),
        .activate => |target| {
            try ourokit.app.desktop.validateId(target.path.?);
            const source = try std.fmt.allocPrint(init.gpa, "return {{id='{s}'}}", .{target.path.?});
            defer init.gpa.free(source);
            try ourokit.app.runWayland(init, source, .{ .headless = true, .desktop = .{
                .client = true,
                .uris = target.uris,
                .action = target.action,
            } });
        },
        .status => |target| try statusApplication(init, target.socket_path),
        .reload => |target| try reloadApplication(init, target.socket_path),
        .development => |options| return developmentOperation(init, options),
        .mcp_export => |options| {
            var manifest: ?ourokit.bundle.Manifest = null;
            defer if (manifest) |*value| value.deinit();
            var provider = if (std.mem.eql(u8, std.fs.path.basename(options.path), ourokit.bundle.manifest_file_name)) blk: {
                manifest = try ourokit.bundle.Manifest.load(init.io, init.gpa, options.path);
                break :blk try ourokit.bundle.SourceProvider.initDiskApplication(init.gpa, manifest.?.entry_path, manifest.?.id);
            } else try ourokit.bundle.SourceProvider.initDisk(init.gpa, options.path);
            defer provider.deinit();
            var libraries = try openNativeModules(init.gpa, manifest);
            defer libraries.deinit();
            const bytes = try ourokit.app.exportCatalogWithModules(init, &provider, libraries.modules);
            defer init.gpa.free(bytes);
            if (options.output_path) |path| {
                try writeAtomic(init, path, bytes);
            } else try writeStdout(init, bytes);
        },
        .run => |options| {
            const path = options.path orelse ourokit.bundle.manifest_file_name;
            var manifest: ?ourokit.bundle.Manifest = null;
            defer if (manifest) |*value| value.deinit();
            var provider = if (std.mem.eql(
                u8,
                std.fs.path.basename(path),
                ourokit.bundle.manifest_file_name,
            )) blk: {
                manifest = ourokit.bundle.Manifest.load(init.io, init.gpa, path) catch |err| {
                    if (options.path == null and err == error.FileNotFound)
                        return error.ApplicationManifestNotFound;
                    return err;
                };
                break :blk try ourokit.bundle.SourceProvider.initDiskApplication(
                    init.gpa,
                    manifest.?.entry_path,
                    manifest.?.id,
                );
            } else try ourokit.bundle.SourceProvider.initDisk(init.gpa, path);
            defer provider.deinit();
            var libraries = try openNativeModules(init.gpa, manifest);
            defer libraries.deinit();
            var exit_code: u8 = 0;
            var run_options: ourokit.app.WaylandRunOptions = .{
                .development = options.development,
                .mcp = options.mcp,
                .headless = options.headless,
                .desktop = .{ .dbus_activated = options.dbus_activated, .uris = options.uris, .action = options.action },
                .native_modules = libraries.modules,
                .exit_after_first_frame = options.exit_after_first_frame,
                .exit_code = &exit_code,
            };
            if (options.vulkan) |vulkan| run_options.vulkan = vulkan;
            try ourokit.app.runWaylandSource(init, &provider, run_options);
            return exit_code;
        },
        .storybook => |storybook| switch (storybook) {
            .run => |options| {
                const source = try readSource(init, options.path);
                defer init.gpa.free(source);
                const parent = std.fs.path.dirname(options.path) orelse ".";
                var asset_root = if (std.fs.path.isAbsolute(parent))
                    try std.Io.Dir.openDirAbsolute(init.io, parent, .{})
                else
                    try std.Io.Dir.cwd().openDir(init.io, parent, .{});
                defer asset_root.close(init.io);
                var run_options: ourokit.app.WaylandRunOptions = .{
                    .exit_after_first_frame = options.exit_after_first_frame,
                    .asset_root = asset_root.handle,
                };
                if (options.vulkan) |vulkan| run_options.vulkan = vulkan;
                try ourokit.app.runStorybook(init, source, run_options);
            },
            .list => |options| try listStories(init, options),
            .snapshot => |options| try snapshotStories(init, options),
        },
    }
    return 0;
}

fn openNativeModules(allocator: std.mem.Allocator, manifest: ?ourokit.bundle.Manifest) !ourokit.native.Libraries {
    const modules = if (manifest) |value| value.native_modules else &.{};
    const paths = try allocator.alloc(ourokit.native.LibraryPath, modules.len);
    defer allocator.free(paths);
    for (modules, paths) |module, *path| path.* = .{ .name = module.name, .path = module.path };
    return ourokit.native.Libraries.open(allocator, paths);
}

fn statusApplication(init: std.process.Init, socket_path: []const u8) !void {
    var application = try ourokit.app.control_client.findDevelopment(
        init.io,
        init.gpa,
        init.minimal.environ,
        socket_path,
    );
    defer application.deinit(init.gpa);
    var output: std.Io.Writer.Allocating = .init(init.gpa);
    defer output.deinit();
    try output.writer.print("{s}\tgeneration {d}\t{s}\n", .{
        application.status.application_id,
        application.status.generation,
        if (application.status.reloading) "reloading" else "idle",
    });
    if (application.status.diagnostic) |diagnostic| try output.writer.print(
        "last reload failed in {s} ({s}): {s}\n",
        .{ diagnostic.phase, diagnostic.source, diagnostic.message },
    );
    try writeStdout(init, output.written());
}

fn developmentOperation(init: std.process.Init, options: cli.Development) !u8 {
    const mcp = ourokit.mcp;
    var args = try std.json.parseFromSlice(mcp.Value, init.gpa, options.arguments, .{ .parse_numbers = false });
    defer args.deinit();
    if (args.value != .object) return error.ExpectedDevelopmentArgumentsObject;
    const method = try std.fmt.allocPrint(init.gpa, "runtime.{s}", .{@tagName(options.operation)});
    defer init.gpa.free(method);
    var reply = try ourokit.app.control_client.developmentAt(init.gpa, init.minimal.environ, options.socket_path, method, args.value);
    defer reply.deinit();
    const failed = try ourokit.app.control_client.failed(reply);
    const result = if (reply.rpc_error) |err| err else mcp.get(reply.result.?, "structuredContent") orelse return error.InvalidToolReply;
    if (!failed) if (options.output_path) |output| {
        const path_value = mcp.get(result, "path") orelse return error.InvalidCaptureReply;
        if (path_value != .string) return error.InvalidCaptureReply;
        const prefix = try std.fmt.allocPrint(init.gpa, "{s}-", .{options.socket_path});
        defer init.gpa.free(prefix);
        const path = path_value.string;
        if (!std.mem.startsWith(u8, path, prefix) or !std.mem.endsWith(u8, path, ".png")) return error.InvalidCaptureReply;
        for (path[prefix.len .. path.len - 4]) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidCaptureReply;
        const file = try std.Io.Dir.openFileAbsolute(init.io, path, .{});
        defer file.close(init.io);
        var buffer: [8192]u8 = undefined;
        var reader = file.reader(init.io, &buffer);
        const bytes = try reader.interface.allocRemaining(init.gpa, .limited(70 * 1024 * 1024));
        defer init.gpa.free(bytes);
        try writeAtomic(init, output, bytes);
    };
    const json = try std.json.Stringify.valueAlloc(init.gpa, result, .{ .whitespace = .indent_2 });
    defer init.gpa.free(json);
    try writeStdout(init, json);
    try writeStdout(init, "\n");
    return if (failed) 1 else 0;
}

fn reloadApplication(init: std.process.Init, socket_path: []const u8) !void {
    var application = try ourokit.app.control_client.findDevelopment(
        init.io,
        init.gpa,
        init.minimal.environ,
        socket_path,
    );
    defer application.deinit(init.gpa);
    var result = try ourokit.app.control_client.reloadAt(init.gpa, application.path);
    defer result.deinit(init.gpa);
    switch (result) {
        .committed => |generation| {
            const message = try std.fmt.allocPrint(
                init.gpa,
                "reloaded {s} as generation {d}\n",
                .{ socket_path, generation },
            );
            defer init.gpa.free(message);
            try writeStdout(init, message);
        },
        .failed => |diagnostic| {
            const message = try std.fmt.allocPrint(
                init.gpa,
                "reload failed in {s} ({s}): {s}\n",
                .{ diagnostic.phase, diagnostic.source, diagnostic.message },
            );
            defer init.gpa.free(message);
            try std.Io.File.stderr().writeStreamingAll(init.io, message);
            std.process.exit(1);
        },
    }
}

fn listStories(init: std.process.Init, options: cli.List) !void {
    const source = try readSource(init, options.path);
    defer init.gpa.free(source);
    const parent = std.fs.path.dirname(options.path) orelse ".";
    var module_root = if (std.fs.path.isAbsolute(parent))
        try std.Io.Dir.openDirAbsolute(init.io, parent, .{})
    else
        try std.Io.Dir.cwd().openDir(init.io, parent, .{});
    defer module_root.close(init.io);
    const chunk_name = try std.fmt.allocPrintSentinel(init.gpa, "@{s}", .{std.fs.path.basename(options.path)}, 0);
    defer init.gpa.free(chunk_name);
    var description = try ourokit.app.storybook.describeAt(init, source, module_root.handle, chunk_name);
    defer description.deinit();

    var output: std.Io.Writer.Allocating = .init(init.gpa);
    defer output.deinit();
    if (options.json) {
        var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{ .whitespace = .indent_2 } };
        try json.beginObject();
        try json.objectField("schema_version");
        try json.write(2);
        try json.objectField("title");
        try json.write(description.title);
        try json.objectField("stories");
        try json.beginArray();
        for (description.stories) |story| try writeStoryJson(&json, story);
        try json.endArray();
        try json.endObject();
        try output.writer.writeByte('\n');
    } else {
        for (description.stories) |story| try output.writer.print(
            "{s}\t{s}\t{s}\t{d}x{d}\tsnapshot@{d}\t{s}\n",
            .{
                story.id,
                story.group,
                story.name,
                story.viewport.width,
                story.viewport.height,
                story.snapshot_scale,
                @tagName(story.color_scheme),
            },
        );
    }
    try writeStdout(init, output.written());
}

fn snapshotStories(init: std.process.Init, options: cli.Snapshot) !void {
    const source = try readSource(init, options.path);
    defer init.gpa.free(source);
    const parent = std.fs.path.dirname(options.path) orelse ".";
    var asset_root = if (std.fs.path.isAbsolute(parent))
        try std.Io.Dir.openDirAbsolute(init.io, parent, .{})
    else
        try std.Io.Dir.cwd().openDir(init.io, parent, .{});
    defer asset_root.close(init.io);
    const chunk_name = try std.fmt.allocPrintSentinel(init.gpa, "@{s}", .{std.fs.path.basename(options.path)}, 0);
    defer init.gpa.free(chunk_name);
    var description = try ourokit.app.storybook.describeAt(init, source, asset_root.handle, chunk_name);
    defer description.deinit();
    if (options.story_id) |id| {
        var found = false;
        for (description.stories) |story| if (std.mem.eql(u8, story.id, id)) {
            found = true;
            break;
        };
        if (!found) return error.UnknownStory;
    }

    var output: std.Io.Writer.Allocating = .init(init.gpa);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{ .whitespace = .indent_2 } };
    if (options.json) {
        try json.beginObject();
        try json.objectField("schema_version");
        try json.write(2);
        try json.objectField("stories");
        try json.beginArray();
    }

    for (description.stories) |story| {
        if (options.story_id) |selected| if (!std.mem.eql(u8, story.id, selected)) continue;
        var snapshot = try ourokit.app.storybook.snapshotNamed(init, source, story.id, asset_root.handle, chunk_name);
        defer snapshot.deinit();
        const file_name = try std.fmt.allocPrint(init.gpa, "{s}.png", .{snapshot.id});
        defer init.gpa.free(file_name);
        const path = try std.fs.path.join(init.gpa, &.{ options.output_path, file_name });
        defer init.gpa.free(path);
        try writeAtomic(init, path, snapshot.png);

        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(snapshot.png, &digest, .{});
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (options.json) {
            try json.beginObject();
            try json.objectField("id");
            try json.write(snapshot.id);
            try json.objectField("path");
            try json.write(path);
            try json.objectField("sha256");
            try json.write(&hash);
            try json.objectField("viewport");
            try writeViewportJson(&json, snapshot.viewport);
            try json.objectField("snapshot_scale");
            try json.write(snapshot.snapshot_scale);
            try json.objectField("color_scheme");
            try json.write(@tagName(snapshot.color_scheme));
            try json.objectField("pixel_width");
            try json.write(snapshot.pixel_width);
            try json.objectField("pixel_height");
            try json.write(snapshot.pixel_height);
            try json.endObject();
        } else {
            try output.writer.print("{s} -> {s}  {s}\n", .{ snapshot.id, path, hash });
        }
    }
    if (options.json) {
        try json.endArray();
        try json.endObject();
        try output.writer.writeByte('\n');
    }
    try writeStdout(init, output.written());
}

fn writeStoryJson(json: *std.json.Stringify, story: ourokit.app.storybook.StoryDescription) !void {
    try json.beginObject();
    try json.objectField("id");
    try json.write(story.id);
    try json.objectField("group");
    try json.write(story.group);
    try json.objectField("name");
    try json.write(story.name);
    try json.objectField("viewport");
    try writeViewportJson(json, story.viewport);
    try json.objectField("snapshot_scale");
    try json.write(story.snapshot_scale);
    try json.objectField("color_scheme");
    try json.write(@tagName(story.color_scheme));
    try json.objectField("action_count");
    try json.write(story.action_count);
    try json.endObject();
}

fn writeViewportJson(json: *std.json.Stringify, viewport: ourokit.lua.StorybookViewport) !void {
    try json.beginObject();
    try json.objectField("width");
    try json.write(viewport.width);
    try json.objectField("height");
    try json.write(viewport.height);
    try json.endObject();
}

fn readSource(init: std.process.Init, path: []const u8) ![]u8 {
    const file = if (std.fs.path.isAbsolute(path))
        try std.Io.Dir.openFileAbsolute(init.io, path, .{})
    else
        try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);
    var buffer: [8192]u8 = undefined;
    var reader = file.reader(init.io, &buffer);
    return reader.interface.allocRemaining(init.gpa, .limited(16 * 1024 * 1024));
}

fn writeAtomic(init: std.process.Init, path: []const u8, bytes: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(init.io, parent);
    const temporary = try std.fmt.allocPrint(
        init.gpa,
        "{s}.tmp-{d}",
        .{ path, std.os.linux.getpid() },
    );
    defer init.gpa.free(temporary);
    errdefer std.Io.Dir.cwd().deleteFile(init.io, temporary) catch {};
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = temporary, .data = bytes });
    try std.Io.Dir.rename(.cwd(), temporary, .cwd(), path, init.io);
}

fn writeStdout(init: std.process.Init, bytes: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, bytes);
}

fn writeError(init: std.process.Init, name: []const u8) !void {
    const message = try std.fmt.allocPrint(init.gpa, "ouroctl: {s}\n", .{name});
    defer init.gpa.free(message);
    try std.Io.File.stderr().writeStreamingAll(init.io, message);
}
