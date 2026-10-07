const std = @import("std");

pub const Command = union(enum) {
    help,
    version,
    activate: Run,
    reload: RuntimeTarget,
    status: RuntimeTarget,
    development: Development,
    run: Run,
    storybook: Storybook,
    mcp_export: Export,
    @"test": Test,
    replay: Replay,
};

pub const Replay = struct {
    log_path: []const u8,
    /// application.lua, ouro.json or a directory holding ouro.json.
    application: []const u8 = ".",
    json: bool = false,
};

pub const Test = struct {
    path: []const u8 = "tests",
    filter: ?[]const u8 = null,
    list: bool = false,
    json: bool = false,
    timeout_ms: u32 = 10_000,
};

pub const RuntimeTarget = struct {
    socket_path: []const u8,
};

pub const Development = struct {
    operation: enum { inspect, input, capture, diagnostics, metrics },
    socket_path: []const u8,
    arguments: []const u8 = "{}",
    output_path: ?[]const u8 = null,
};

pub const Export = struct {
    path: []const u8,
    output_path: ?[]const u8 = null,
};

pub const Run = struct {
    path: ?[]const u8 = null,
    vulkan: ?bool = null,
    exit_after_first_frame: bool = false,
    development: bool = false,
    mcp: bool = false,
    headless: bool = false,
    dbus_activated: bool = false,
    action: ?[]const u8 = null,
    uris: []const []const u8 = &.{},
    /// Statechart input log path (`--record`); `--dev` records by default.
    record_path: ?[]const u8 = null,
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
    \\  ouroctl run [application.lua|ouro.json] [--dev|--mcp] [--headless] [--dbus-activated]
    \\              [--vulkan|--software] [--exit-after-first-frame] [--action <name>]
    \\              [--record <log.jsonl>] [-- <URI>...]
    \\  ouroctl activate <application-id> [--action <name>] [-- <URI>...]
    \\  ouroctl dev reload <development-socket>
    \\  ouroctl dev status <development-socket>
    \\  ouroctl dev inspect|input|capture|diagnostics|metrics <development-socket> [JSON]
    \\              [--output <PNG-path>]  (capture only)
    \\  ouroctl mcp export <application.lua|ouro.json> [--output <file>]
    \\  ouroctl storybook run <stories.lua> [--vulkan|--software] [--exit-after-first-frame]
    \\  ouroctl storybook list <stories.lua> [--json]
    \\  ouroctl storybook snapshot <stories.lua> [--story <id>] [--output <dir>] [--json]
    \\  ouroctl test [file|directory] [--filter <substring>] [--list] [--json]
    \\              [--timeout-ms <milliseconds>]  (default: tests, 10000 ms per worker)
    \\  ouroctl replay <log.jsonl> [application.lua|ouro.json|directory] [--json]
    \\  ouroctl help
    \\  ouroctl version
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
    if (std.mem.eql(u8, command, "activate")) {
        const options = try parseRun(args[2..]);
        if (options.path == null) return error.ExpectedApplicationId;
        if (options.development or options.mcp or options.headless or options.dbus_activated or options.vulkan != null or options.exit_after_first_frame or options.record_path != null) return error.UnknownOption;
        return .{ .activate = options };
    }
    if (std.mem.eql(u8, command, "dev")) {
        if (args.len < 3) return error.ExpectedDevelopmentCommand;
        if (std.mem.eql(u8, args[2], "reload")) return .{ .reload = try parseRuntimeTarget(args[3..]) };
        if (std.mem.eql(u8, args[2], "status")) return .{ .status = try parseRuntimeTarget(args[3..]) };
        if (std.meta.stringToEnum(@FieldType(Development, "operation"), args[2])) |operation|
            return .{ .development = try parseDevelopment(operation, args[3..]) };
        return error.ExpectedDevelopmentCommand;
    }
    if (std.mem.eql(u8, command, "run")) return .{ .run = try parseRun(args[2..]) };
    if (std.mem.eql(u8, command, "test")) return .{ .@"test" = try parseTest(args[2..]) };
    if (std.mem.eql(u8, command, "replay")) return .{ .replay = try parseReplay(args[2..]) };
    if (std.mem.eql(u8, command, "storybook"))
        return .{ .storybook = try parseStorybook(args[2..]) };
    if (std.mem.eql(u8, command, "mcp")) {
        if (args.len < 3 or !std.mem.eql(u8, args[2], "export")) return error.ExpectedMcpExport;
        return .{ .mcp_export = try parseExport(args[3..]) };
    }
    return error.UnknownCommand;
}

fn parseTest(args: []const []const u8) !Test {
    var result: Test = .{};
    var path_set = false;
    var timeout_set = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--list")) {
            if (result.list) return error.DuplicateOption;
            result.list = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            if (result.json) return error.DuplicateOption;
            result.json = true;
        } else if (try optionValue(args, &index, arg, "--filter")) |value| {
            if (result.filter != null) return error.DuplicateOption;
            if (std.mem.startsWith(u8, value, "--")) return error.ExpectedOptionValue;
            result.filter = value;
        } else if (try optionValue(args, &index, arg, "--timeout-ms")) |value| {
            if (timeout_set) return error.DuplicateOption;
            result.timeout_ms = std.fmt.parseInt(u32, value, 10) catch return error.InvalidTestTimeout;
            if (result.timeout_ms == 0) return error.InvalidTestTimeout;
            timeout_set = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else if (!path_set and arg.len != 0) {
            result.path = arg;
            path_set = true;
        } else return error.UnexpectedArgument;
    }
    return result;
}

fn parseReplay(args: []const []const u8) !Replay {
    var log: ?[]const u8 = null;
    var application: ?[]const u8 = null;
    var json = false;
    for (args) |argument| {
        if (std.mem.eql(u8, argument, "--json")) {
            if (json) return error.DuplicateOption;
            json = true;
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.UnknownOption;
        } else if (argument.len == 0) {
            return error.ExpectedReplayLog;
        } else if (log == null) {
            log = argument;
        } else if (application == null) {
            application = argument;
        } else return error.UnexpectedArgument;
    }
    return .{ .log_path = log orelse return error.ExpectedReplayLog, .application = application orelse ".", .json = json };
}

fn parseExport(args: []const []const u8) !Export {
    var path: ?[]const u8 = null;
    var output: ?[]const u8 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (try optionValue(args, &index, argument, "--output")) |value| {
            if (output != null) return error.DuplicateOption;
            if (std.mem.startsWith(u8, value, "--")) return error.ExpectedOptionValue;
            output = value;
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.UnknownOption;
        } else if (argument.len == 0) {
            return error.ExpectedApplicationPath;
        } else if (path == null) {
            path = argument;
        } else return error.UnexpectedArgument;
    }
    return .{ .path = path orelse return error.ExpectedApplicationPath, .output_path = output };
}

fn parseRuntimeTarget(args: []const []const u8) !RuntimeTarget {
    if (args.len == 0) return error.ExpectedDevelopmentEndpoint;
    if (args.len != 1) return error.UnexpectedArgument;
    if (args[0].len == 0 or std.mem.startsWith(u8, args[0], "--"))
        return error.ExpectedDevelopmentEndpoint;
    return .{ .socket_path = args[0] };
}

fn parseDevelopment(operation: @FieldType(Development, "operation"), args: []const []const u8) !Development {
    if (args.len == 0) return error.ExpectedDevelopmentEndpoint;
    const target = try parseRuntimeTarget(args[0..1]);
    var result: Development = .{ .operation = operation, .socket_path = target.socket_path };
    var arguments_set = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (try optionValue(args, &index, args[index], "--output")) |path| {
            if (operation != .capture) return error.UnknownOption;
            if (result.output_path != null) return error.DuplicateOption;
            if (path.len == 0 or std.mem.startsWith(u8, path, "--")) return error.ExpectedOptionValue;
            result.output_path = path;
        } else if (std.mem.startsWith(u8, args[index], "--")) {
            return error.UnknownOption;
        } else if (arguments_set) {
            return error.UnexpectedArgument;
        } else {
            result.arguments = args[index];
            arguments_set = true;
        }
    }
    return result;
}

fn parseRun(args: []const []const u8) !Run {
    var result: Run = .{};
    var path: ?[]const u8 = null;
    var vulkan: ?bool = null;
    var exit_after_first_frame = false;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--vulkan")) {
            if (vulkan != null) return error.DuplicateOption;
            vulkan = true;
        } else if (std.mem.eql(u8, argument, "--software")) {
            if (vulkan != null) return error.DuplicateOption;
            vulkan = false;
        } else if (std.mem.eql(u8, argument, "--exit-after-first-frame")) {
            exit_after_first_frame = true;
        } else if (std.mem.eql(u8, argument, "--dev")) {
            if (result.development or result.mcp) return error.DuplicateOption;
            result.development = true;
        } else if (std.mem.eql(u8, argument, "--mcp")) {
            if (result.development or result.mcp) return error.DuplicateOption;
            result.mcp = true;
        } else if (std.mem.eql(u8, argument, "--headless")) {
            result.headless = true;
        } else if (std.mem.eql(u8, argument, "--dbus-activated")) {
            result.dbus_activated = true;
        } else if (try optionValue(args, &index, argument, "--action")) |value| {
            if (result.action != null) return error.DuplicateOption;
            result.action = value;
        } else if (try optionValue(args, &index, argument, "--record")) |value| {
            if (result.record_path != null) return error.DuplicateOption;
            if (value.len == 0 or std.mem.startsWith(u8, value, "--")) return error.ExpectedOptionValue;
            result.record_path = value;
        } else if (std.mem.eql(u8, argument, "--")) {
            result.uris = args[index + 1 ..];
            break;
        } else if (std.mem.startsWith(u8, argument, "--")) {
            return error.UnknownOption;
        } else if (path == null) {
            path = argument;
        } else {
            return error.UnexpectedArgument;
        }
    }
    if (result.action != null and result.uris.len != 0) return error.ConflictingActivationArguments;
    if (result.dbus_activated and (result.development or result.action != null or result.uris.len != 0)) return error.ConflictingActivationArguments;
    result.path = path;
    result.vulkan = vulkan;
    result.exit_after_first_frame = exit_after_first_frame;
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
    if (run.development or run.mcp or run.headless or run.dbus_activated or run.action != null or run.uris.len != 0) return error.UnknownOption;
    return .{
        .path = run.path orelse return error.ExpectedStorybookPath,
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
    } }, try parse(&.{ "ouroctl", "run", "app.lua", "--vulkan" }));
    try std.testing.expectEqualDeep(Command{ .run = .{
        .path = "app.lua",
        .vulkan = false,
    } }, try parse(&.{ "ouroctl", "run", "--software", "app.lua" }));
    try std.testing.expectEqualDeep(Command{ .run = .{
        .path = "app.lua",
    } }, try parse(&.{ "ouroctl", "run", "app.lua" }));
    try std.testing.expectEqualDeep(Command{ .run = .{} }, try parse(&.{ "ouroctl", "run" }));
    try std.testing.expectEqualDeep(
        Command{ .reload = .{ .socket_path = "/runtime/ourokit/dev/0123456789abcdef0123456789abcdef" } },
        try parse(&.{ "ouroctl", "dev", "reload", "/runtime/ourokit/dev/0123456789abcdef0123456789abcdef" }),
    );
    try std.testing.expectEqualDeep(
        Command{ .status = .{ .socket_path = "/runtime/ourokit/dev/0123456789abcdef0123456789abcdef" } },
        try parse(&.{ "ouroctl", "dev", "status", "/runtime/ourokit/dev/0123456789abcdef0123456789abcdef" }),
    );
    try std.testing.expectEqualDeep(Command{ .storybook = .{ .list = .{
        .path = "stories.lua",
        .json = true,
    } } }, try parse(&.{ "ouroctl", "storybook", "list", "stories.lua", "--json" }));
    try std.testing.expectEqualDeep(Command{ .storybook = .{ .run = .{
        .path = "stories.lua",
        .vulkan = false,
    } } }, try parse(&.{ "ouroctl", "storybook", "run", "stories.lua", "--software" }));
    try std.testing.expectEqualDeep(Command{ .storybook = .{ .snapshot = .{
        .path = "stories.lua",
        .story_id = "button/default",
        .output_path = "artifacts",
        .json = true,
    } } }, try parse(&.{
        "ouroctl",  "storybook", "snapshot", "stories.lua", "--story=button/default",
        "--output", "artifacts", "--json",
    }));
}

test "CLI development operations retain JSON and limit output to capture" {
    try std.testing.expectEqualDeep(Command{ .development = .{ .operation = .inspect, .socket_path = "/private/dev/socket" } }, try parse(&.{ "ouroctl", "dev", "inspect", "/private/dev/socket" }));
    const arguments = "{\"window\":\"secondary\",\"token\":\"1:9:3:4:5\"}";
    try std.testing.expectEqualDeep(Command{ .development = .{ .operation = .capture, .socket_path = "/private/dev/socket", .arguments = arguments, .output_path = "frame.png" } }, try parse(&.{ "ouroctl", "dev", "capture", "/private/dev/socket", "--output=frame.png", arguments }));
    try std.testing.expectError(error.ExpectedDevelopmentEndpoint, parse(&.{ "ouroctl", "dev", "input" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "ouroctl", "dev", "metrics", "/private/dev/socket", "{}", "{}" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "ouroctl", "dev", "inspect", "/private/dev/socket", "--output=wrong.png" }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{ "ouroctl", "dev", "capture", "/private/dev/socket", "--output=a.png", "--output=b.png" }));
}

test "CLI rejects malformed commands and options" {
    try std.testing.expectError(error.ExpectedStorybookPath, parse(&.{ "ouroctl", "storybook", "run" }));
    try std.testing.expectError(error.ExpectedDevelopmentEndpoint, parse(&.{ "ouroctl", "dev", "reload" }));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "ouroctl", "wat" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "ouroctl", "run", "app.lua", "--wat" }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{
        "ouroctl", "run", "app.lua", "--vulkan", "--software",
    }));
    try std.testing.expectError(error.ExpectedOptionValue, parse(&.{
        "ouroctl", "storybook", "snapshot", "stories.lua", "--story",
    }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{
        "ouroctl", "storybook", "snapshot", "stories.lua", "--story", "one", "--story", "two",
    }));
}

test "CLI parses explicit MCP catalog exports and rejects ambiguous output" {
    try std.testing.expectEqualDeep(Command{ .mcp_export = .{ .path = "app.lua" } }, try parse(&.{ "ouroctl", "mcp", "export", "app.lua" }));
    try std.testing.expectEqualDeep(Command{ .mcp_export = .{ .path = "ouro.json", .output_path = "app.json" } }, try parse(&.{ "ouroctl", "mcp", "export", "--output=app.json", "ouro.json" }));
    try std.testing.expectError(error.ExpectedMcpExport, parse(&.{ "ouroctl", "mcp" }));
    try std.testing.expectError(error.ExpectedApplicationPath, parse(&.{ "ouroctl", "mcp", "export" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "ouroctl", "mcp", "export", "app.lua", "--json" }));
    try std.testing.expectError(error.ExpectedOptionValue, parse(&.{ "ouroctl", "mcp", "export", "app.lua", "--output" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "ouroctl", "mcp", "export", "a.lua", "b.lua" }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{ "ouroctl", "mcp", "export", "a.lua", "--output=a.json", "--output=b.json" }));
}

test "CLI parses component test selection and rejects invalid timeouts" {
    try std.testing.expectEqualDeep(Command{ .@"test" = .{} }, try parse(&.{ "ouroctl", "test" }));
    try std.testing.expectEqualDeep(Command{ .@"test" = .{
        .path = "tests/counter_test.lua",
        .filter = "increment",
        .list = true,
        .json = true,
        .timeout_ms = 250,
    } }, try parse(&.{ "ouroctl", "test", "--filter=increment", "tests/counter_test.lua", "--list", "--json", "--timeout-ms", "250" }));
    try std.testing.expectError(error.InvalidTestTimeout, parse(&.{ "ouroctl", "test", "--timeout-ms=0" }));
    try std.testing.expectError(error.InvalidTestTimeout, parse(&.{ "ouroctl", "test", "--timeout-ms=-1" }));
    try std.testing.expectError(error.ExpectedOptionValue, parse(&.{ "ouroctl", "test", "--filter", "--list" }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{ "ouroctl", "test", "--filter=a", "--filter=b" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "ouroctl", "test", "--wat" }));
    try std.testing.expectError(error.UnexpectedArgument, parse(&.{ "ouroctl", "test", "a", "b" }));
}

test "CLI separates development production and standard activation" {
    try std.testing.expectEqualDeep(Command{ .run = .{ .path = "app.lua", .development = true, .headless = true } }, try parse(&.{ "ouroctl", "run", "app.lua", "--dev", "--headless" }));
    try std.testing.expectEqualDeep(Command{ .run = .{ .path = "app.lua", .mcp = true } }, try parse(&.{ "ouroctl", "run", "app.lua", "--mcp" }));
    try std.testing.expectEqualDeep(Command{ .activate = .{ .path = "org.example.App", .uris = &.{ "file:///tmp/a%20b", "https://example.test/doc" } } }, try parse(&.{ "ouroctl", "activate", "org.example.App", "--", "file:///tmp/a%20b", "https://example.test/doc" }));
    try std.testing.expectEqualDeep(Command{ .activate = .{ .path = "org.example.App", .action = "NewWindow" } }, try parse(&.{ "ouroctl", "activate", "org.example.App", "--action", "NewWindow" }));
    try std.testing.expectError(error.DuplicateOption, parse(&.{ "ouroctl", "run", "--mcp", "--dev" }));
    try std.testing.expectError(error.ConflictingActivationArguments, parse(&.{ "ouroctl", "run", "--dev", "--dbus-activated" }));
    try std.testing.expectError(error.ConflictingActivationArguments, parse(&.{ "ouroctl", "activate", "org.example.App", "--action", "New", "--", "file:///tmp/a" }));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "ouroctl", "activate", "org.example.App", "--mcp" }));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "ouroctl", "reload", "org.example.App" }));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "ouroctl", "status", "org.example.App" }));
}
