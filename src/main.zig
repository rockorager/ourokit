const std = @import("std");
const ourokit = @import("ourokit");
const cli = @import("cli.zig");

const version = "0.1.0";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const command = cli.parse(args) catch |err| {
        try writeError(init, @errorName(err));
        try writeStdout(init, cli.usage);
        std.process.exit(2);
    };
    execute(init, command) catch |err| {
        try writeError(init, @errorName(err));
        std.process.exit(1);
    };
}

fn execute(init: std.process.Init, command: cli.Command) !void {
    switch (command) {
        .help => try writeStdout(init, cli.usage),
        .version => try writeStdout(init, "ourokit " ++ version ++ "\n"),
        .run => |options| {
            var provider = try ourokit.bundle.SourceProvider.initDisk(init.gpa, options.path);
            defer provider.deinit();
            var run_options: ourokit.app.WaylandRunOptions = .{
                .exit_after_first_frame = options.exit_after_first_frame,
            };
            if (options.vulkan) |vulkan| run_options.vulkan = vulkan;
            try ourokit.app.runWaylandSource(init, &provider, run_options);
        },
        .storybook => |storybook| switch (storybook) {
            .run => |options| {
                const source = try readSource(init, options.path);
                defer init.gpa.free(source);
                var run_options: ourokit.app.WaylandRunOptions = .{
                    .exit_after_first_frame = options.exit_after_first_frame,
                };
                if (options.vulkan) |vulkan| run_options.vulkan = vulkan;
                try ourokit.app.runStorybook(init, source, run_options);
            },
            .list => |options| try listStories(init, options),
            .snapshot => |options| try snapshotStories(init, options),
        },
    }
}

fn listStories(init: std.process.Init, options: cli.List) !void {
    const source = try readSource(init, options.path);
    defer init.gpa.free(source);
    var description = try ourokit.app.storybook.describe(init, source);
    defer description.deinit();

    var output: std.Io.Writer.Allocating = .init(init.gpa);
    defer output.deinit();
    if (options.json) {
        var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{ .whitespace = .indent_2 } };
        try json.beginObject();
        try json.objectField("schema_version");
        try json.write(1);
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
            "{s}\t{s}\t{s}\t{d}x{d}@{d}\t{s}\n",
            .{
                story.id,
                story.group,
                story.name,
                story.viewport.width,
                story.viewport.height,
                story.viewport.scale,
                @tagName(story.color_scheme),
            },
        );
    }
    try writeStdout(init, output.written());
}

fn snapshotStories(init: std.process.Init, options: cli.Snapshot) !void {
    const source = try readSource(init, options.path);
    defer init.gpa.free(source);
    var description = try ourokit.app.storybook.describe(init, source);
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
        try json.write(1);
        try json.objectField("stories");
        try json.beginArray();
    }

    for (description.stories) |story| {
        if (options.story_id) |selected| if (!std.mem.eql(u8, story.id, selected)) continue;
        var snapshot = try ourokit.app.storybook.snapshot(init, source, story.id);
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
    try json.objectField("scale");
    try json.write(viewport.scale);
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
    const message = try std.fmt.allocPrint(init.gpa, "ourokit: {s}\n", .{name});
    defer init.gpa.free(message);
    try std.Io.File.stderr().writeStreamingAll(init.io, message);
}
