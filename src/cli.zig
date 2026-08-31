const std = @import("std");

pub const Command = union(enum) {
    help,
    version,
    run: Run,
    storybook: Storybook,
};

pub const Run = struct {
    path: []const u8,
    vulkan: ?bool = null,
    exit_after_first_frame: bool = false,
};

pub const Storybook = union(enum) {
    run: StorybookRun,
    list: List,
    snapshot: Snapshot,
};

pub const StorybookRun = struct {
    path: []const u8,
    vulkan: ?bool = null,
    exit_after_first_frame: bool = false,
};

pub const List = struct {
    path: []const u8,
    json: bool = false,
};

pub const Snapshot = struct {
    path: []const u8,
    story_id: ?[]const u8 = null,
    output_path: []const u8 = "storybook-snapshots",
    json: bool = false,
};

pub const usage =
    \\Usage:
    \\  ourokit run <application.lua> [--vulkan|--software] [--exit-after-first-frame]
    \\  ourokit storybook run <stories.lua> [--vulkan|--software] [--exit-after-first-frame]
    \\  ourokit storybook list <stories.lua> [--json]
    \\  ourokit storybook snapshot <stories.lua> [--story <id>] [--output <dir>] [--json]
    \\  ourokit help
    \\  ourokit version
    \\
;

pub fn parse(args: []const []const u8) !Command {
    if (args.len < 2) return .help;
    const command = args[1];
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or
        std.mem.eql(u8, command, "-h"))
        return if (args.len == 2) .help else error.UnexpectedArgument;
    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "--version"))
        return if (args.len == 2) .version else error.UnexpectedArgument;
    if (std.mem.eql(u8, command, "run")) return .{ .run = try parseRun(args[2..]) };
    if (std.mem.eql(u8, command, "storybook"))
        return .{ .storybook = try parseStorybook(args[2..]) };
    return error.UnknownCommand;
}

fn parseRun(args: []const []const u8) !Run {
    var result: Run = undefined;
    var path: ?[]const u8 = null;
    var vulkan: ?bool = null;
    var exit_after_first_frame = false;
    for (args) |argument| {
        if (std.mem.eql(u8, argument, "--vulkan")) {
            if (vulkan != null) return error.DuplicateOption;
            vulkan = true;
        } else if (std.mem.eql(u8, argument, "--software")) {
            if (vulkan != null) return error.DuplicateOption;
            vulkan = false;
        } else if (std.mem.eql(u8, argument, "--exit-after-first-frame")) {
            exit_after_first_frame = true;
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.UnknownOption;
        } else if (path == null) {
            path = argument;
        } else {
            return error.UnexpectedArgument;
        }
    }
    result = .{
        .path = path orelse return error.ExpectedApplicationPath,
        .vulkan = vulkan,
        .exit_after_first_frame = exit_after_first_frame,
    };
    return result;
}

fn parseStorybook(args: []const []const u8) !Storybook {
    if (args.len == 0) return error.ExpectedStorybookCommand;
    if (std.mem.eql(u8, args[0], "run")) return .{ .run = try parseStorybookRun(args[1..]) };
    if (std.mem.eql(u8, args[0], "list")) return .{ .list = try parseList(args[1..]) };
    if (std.mem.eql(u8, args[0], "snapshot")) return .{ .snapshot = try parseSnapshot(args[1..]) };
    return error.UnknownStorybookCommand;
}

fn parseStorybookRun(args: []const []const u8) !StorybookRun {
    const run = try parseRun(args);
    return .{
        .path = run.path,
        .vulkan = run.vulkan,
        .exit_after_first_frame = run.exit_after_first_frame,
    };
}

fn parseList(args: []const []const u8) !List {
    var path: ?[]const u8 = null;
    var json = false;
    for (args) |argument| {
        if (std.mem.eql(u8, argument, "--json")) {
            json = true;
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.UnknownOption;
        } else if (path == null) {
            path = argument;
        } else {
            return error.UnexpectedArgument;
        }
    }
    return .{ .path = path orelse return error.ExpectedStorybookPath, .json = json };
}

fn parseSnapshot(args: []const []const u8) !Snapshot {
    var result: Snapshot = undefined;
    var path: ?[]const u8 = null;
    var story_id: ?[]const u8 = null;
    var output_path: []const u8 = "storybook-snapshots";
    var output_set = false;
    var json = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--json")) {
            json = true;
        } else if (try optionValue(args, &index, argument, "--story")) |value| {
            if (story_id != null) return error.DuplicateOption;
            story_id = value;
        } else if (try optionValue(args, &index, argument, "--output")) |value| {
            if (output_set) return error.DuplicateOption;
            output_path = value;
            output_set = true;
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.UnknownOption;
        } else if (path == null) {
            path = argument;
        } else {
            return error.UnexpectedArgument;
        }
    }
    result = .{
        .path = path orelse return error.ExpectedStorybookPath,
        .story_id = story_id,
        .output_path = output_path,
        .json = json,
    };
    return result;
}

fn optionValue(
    args: []const []const u8,
    index: *usize,
    argument: []const u8,
    option: []const u8,
) !?[]const u8 {
    if (std.mem.eql(u8, argument, option)) {
        index.* += 1;
        if (index.* == args.len or args[index.*].len == 0) return error.ExpectedOptionValue;
        return args[index.*];
    }
    if (std.mem.startsWith(u8, argument, option) and argument.len > option.len and
        argument[option.len] == '=')
    {
        const value = argument[option.len + 1 ..];
        if (value.len == 0) return error.ExpectedOptionValue;
        return value;
    }
    return null;
}

test "CLI parses application and Storybook commands" {
    try std.testing.expectEqualDeep(Command{ .run = .{
        .path = "app.lua",
        .vulkan = true,
    } }, try parse(&.{ "ourokit", "run", "app.lua", "--vulkan" }));
    try std.testing.expectEqualDeep(Command{ .run = .{
        .path = "app.lua",
        .vulkan = false,
    } }, try parse(&.{ "ourokit", "run", "--software", "app.lua" }));
    try std.testing.expectEqualDeep(Command{ .run = .{
        .path = "app.lua",
    } }, try parse(&.{ "ourokit", "run", "app.lua" }));
    try std.testing.expectEqualDeep(Command{ .storybook = .{ .list = .{
        .path = "stories.lua",
        .json = true,
    } } }, try parse(&.{ "ourokit", "storybook", "list", "stories.lua", "--json" }));
    try std.testing.expectEqualDeep(Command{ .storybook = .{ .run = .{
        .path = "stories.lua",
        .vulkan = false,
    } } }, try parse(&.{ "ourokit", "storybook", "run", "stories.lua", "--software" }));
    try std.testing.expectEqualDeep(Command{ .storybook = .{ .snapshot = .{
        .path = "stories.lua",
        .story_id = "button/default",
        .output_path = "artifacts",
        .json = true,
    } } }, try parse(&.{
        "ourokit",  "storybook", "snapshot", "stories.lua", "--story=button/default",
        "--output", "artifacts", "--json",
    }));
}

test "CLI rejects malformed commands and options" {
    try std.testing.expectError(error.ExpectedApplicationPath, parse(&.{ "ourokit", "run" }));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "ourokit", "wat" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "ourokit", "run", "app.lua", "--wat" }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{
        "ourokit", "run", "app.lua", "--vulkan", "--software",
    }));
    try std.testing.expectError(error.ExpectedOptionValue, parse(&.{
        "ourokit", "storybook", "snapshot", "stories.lua", "--story",
    }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{
        "ourokit", "storybook", "snapshot", "stories.lua", "--story", "one", "--story", "two",
    }));
}
