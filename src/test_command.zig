const std = @import("std");
const Options = @import("cli.zig").Test;

const Result = struct {
    file: []const u8,
    name: ?[]const u8,
    status: enum { passed, failed, listed },
    diagnostic: ?[]const u8 = null,
};

pub fn run(init: std.process.Init, options: Options) !u8 {
    const a = init.arena.allocator();
    var files: std.ArrayList([]const u8) = .empty;
    var results: std.ArrayList(Result) = .empty;
    discover(init, options.path, &files) catch |err| {
        try results.append(a, .{ .file = options.path, .name = null, .status = .failed, .diagnostic = @errorName(err) });
    };
    std.mem.sort([]const u8, files.items, {}, lessThan);
    const executable = try std.process.executablePathAlloc(init.io, a);
    var matched: usize = 0;
    for (files.items) |file| {
        const listing = worker(init, executable, file, null, options.timeout_ms) catch |err| {
            try results.append(a, .{ .file = file, .name = null, .status = .failed, .diagnostic = @errorName(err) });
            continue;
        };
        if (!succeeded(listing.term)) {
            try results.append(a, .{ .file = file, .name = null, .status = .failed, .diagnostic = try failure(a, listing) });
            continue;
        }
        const names = std.json.parseFromSlice([][]const u8, a, listing.stdout, .{ .allocate = .alloc_always }) catch |err| {
            try results.append(a, .{ .file = file, .name = null, .status = .failed, .diagnostic = @errorName(err) });
            continue;
        };
        for (names.value) |name| {
            if (options.filter) |filter| {
                if (std.mem.indexOf(u8, file, filter) == null and std.mem.indexOf(u8, name, filter) == null) continue;
            }
            matched += 1;
            if (options.list) {
                try results.append(a, .{ .file = file, .name = name, .status = .listed });
                continue;
            }
            const result = worker(init, executable, file, name, options.timeout_ms) catch |err| {
                try results.append(a, .{ .file = file, .name = name, .status = .failed, .diagnostic = @errorName(err) });
                continue;
            };
            try results.append(a, .{
                .file = file,
                .name = name,
                .status = if (succeeded(result.term)) .passed else .failed,
                .diagnostic = if (succeeded(result.term)) null else try failure(a, result),
            });
        }
    }
    var passed: usize = 0;
    var failed: usize = 0;
    for (results.items) |result| switch (result.status) {
        .passed => passed += 1,
        .failed => failed += 1,
        .listed => {},
    };
    const no_tests = matched == 0 and failed == 0;
    var output: std.Io.Writer.Allocating = .init(a);
    if (options.json) {
        try std.json.Stringify.value(.{
            .schema_version = 1,
            .results = results.items,
            .passed = passed,
            .failed = failed,
            .listed = if (options.list) matched else 0,
            .error_message = if (no_tests) @as(?[]const u8, "NoTestsFound") else null,
        }, .{ .whitespace = .indent_2 }, &output.writer);
        try output.writer.writeByte('\n');
    } else {
        for (results.items) |result| {
            const label = switch (result.status) {
                .passed => "PASS",
                .failed => "FAIL",
                .listed => "TEST",
            };
            try output.writer.print("{s} {s} :: {s}\n", .{ label, result.file, result.name orelse "<load>" });
            if (result.diagnostic) |message| try output.writer.print("     {s}\n", .{message});
        }
        if (no_tests) try output.writer.writeAll("No matching tests found.\n");
        if (options.list) try output.writer.print("\n{d} tests listed, {d} failures\n", .{ matched, failed }) else try output.writer.print("\n{d} passed, {d} failed\n", .{ passed, failed });
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, output.written());
    return if (failed != 0 or no_tests) 1 else 0;
}

fn discover(init: std.process.Init, path: []const u8, files: *std.ArrayList([]const u8)) !void {
    const a = init.arena.allocator();
    var dir = std.Io.Dir.cwd().openDir(init.io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.NotDir => {
            const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
            defer file.close(init.io);
            if ((try file.stat(init.io)).kind != .file) return error.TestFileRequired;
            try files.append(a, path);
            return;
        },
        else => return err,
    };
    defer dir.close(init.io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    while (try walker.next(init.io)) |entry| {
        if (entry.kind == .file and (std.mem.endsWith(u8, entry.basename, "_test.lua") or
            std.mem.endsWith(u8, entry.basename, "_test.jsonl")))
            try files.append(a, try std.fs.path.join(a, &.{ path, entry.path }));
    }
}

fn worker(init: std.process.Init, executable: []const u8, file: []const u8, name: ?[]const u8, timeout_ms: u32) !std.process.RunResult {
    const argv = [_][]const u8{ executable, "--ourokit-test-worker", file, name orelse "" };
    const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } };
    return std.process.run(init.arena.allocator(), init.io, .{
        .argv = argv[0..if (name == null) @as(usize, 3) else 4],
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
        .timeout = timeout.toDeadline(init.io),
    });
}

fn succeeded(term: std.process.Child.Term) bool {
    return term == .exited and term.exited == 0;
}

fn failure(a: std.mem.Allocator, result: std.process.RunResult) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}worker terminated: {any}", .{ result.stderr, result.term });
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}
