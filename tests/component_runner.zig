//! Black-box runner contracts. Uses only the released executable, not Python.
const std = @import("std");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;

pub fn main(init: std.process.Init) !void {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const cwd = try std.process.currentPathAlloc(init.io, a);
    const binary = try std.fs.path.resolve(a, &.{ cwd, args[1] });
    const path = try std.fmt.allocPrint(a, ".zig-cache/component-runner-{d}", .{std.os.linux.getpid()});
    try std.Io.Dir.cwd().createDirPath(init.io, path);
    defer std.Io.Dir.cwd().deleteTree(init.io, path) catch {};
    var dir = try std.Io.Dir.cwd().openDir(init.io, path, .{});
    defer dir.close(init.io);
    const root = try std.fs.path.resolve(a, &.{ cwd, path });
    const fixture: Fixture = .{ .init = init, .binary = binary, .root = root, .dir = dir };
    try dir.createDirPath(init.io, "tests/nested");
    try fixture.write("model.lua", "return {value=11}");
    try fixture.write("tests/z_test.lua",
        \\local model = require('model')
        \\return {
        \\  ['z isolated module'] = function() assert(model.value == 11); model.value = 29 end,
        \\  ['a isolated module'] = function() assert(model.value == 11); model.value = 73 end,
        \\}
    );
    try fixture.write("tests/nested/a_test.lua", "return {nested=function() assert(2+3 == 5) end}");
    try fixture.write("tests/ignored.lua", "error('must not discover helpers')");

    const all = try fixture.run(&.{}, 0);
    try equal(@as(i64, 3), all.object.get("passed").?.integer);
    const results = all.object.get("results").?.array.items;
    try strings("tests/nested/a_test.lua", results[0].object.get("file").?.string);
    try strings("a isolated module", results[1].object.get("name").?.string);
    try strings("z isolated module", results[2].object.get("name").?.string);
    const filtered = try fixture.run(&.{ "--filter", "z isolated" }, 0);
    try equal(@as(i64, 1), filtered.object.get("passed").?.integer);
    const subtree = try fixture.run(&.{"tests/nested"}, 0);
    try equal(@as(i64, 1), subtree.object.get("passed").?.integer);
    const file = try fixture.run(&.{"tests/z_test.lua"}, 0);
    try equal(@as(i64, 2), file.object.get("passed").?.integer);
    const by_path = try fixture.run(&.{"--filter=nested"}, 0);
    try equal(@as(i64, 1), by_path.object.get("passed").?.integer);
    const none = try fixture.run(&.{"--filter=nonexistent"}, 1);
    try strings("NoTestsFound", none.object.get("error_message").?.string);

    try fixture.write("tests/bad_test.lua", "return {broken=function() error('deliberate failure') end}");
    const listing = try fixture.run(&.{"--list"}, 0);
    try equal(@as(i64, 4), listing.object.get("listed").?.integer);
    try equal(@as(i64, 0), listing.object.get("passed").?.integer);
    const failed = try fixture.run(&.{}, 1);
    try equal(@as(i64, 3), failed.object.get("passed").?.integer);
    try equal(@as(i64, 1), failed.object.get("failed").?.integer);
    const detail = failed.object.get("results").?.array.items[0].object.get("diagnostic").?.string;
    try expect(std.mem.indexOf(u8, detail, "tests/bad_test.lua:1: deliberate failure") != null);
    try expect(std.mem.indexOf(u8, detail, "stack traceback:") != null);

    // A wrong runner could swallow errors, skip failed files, share module
    // state, or hang forever. Each fixture discriminates one such mistake.
    const failures = .{
        .{ "return {bad=42}", "NamedTestFunctionRequired" },
        .{ "this is not Lua", "LuaLoadFailed" },
        .{ "error('bootstrap failed')", "bootstrap failed" },
        .{ "local o=require('ouro'); return {bad=function(t) t:mount(function() return o.text{key='x',text='Hi'} end); t:node('missing') end}", "UnknownTestNode" },
        .{ "return {bad=function(t) t:mount(function() error('broken build') end) end}", "broken build" },
        .{ "local o=require('ouro'); return {bad=function(t) t:mount(function() return o.button{key='x',label='Go',on_press=function() error('broken callback') end} end); t:click('x') end}", "broken callback" },
        .{ "local o=require('ouro'); return {bad=function(t) t:mount(function() return o.button{key='x',label='Go',on_press=function() o.sleep(1) end} end); t:click('x') end}", "sleep" },
        .{ "return {bad=function() while true do end end}", "Timeout" },
        .{ "while true do end", "Timeout" },
    };
    inline for (failures) |case| {
        try fixture.write("tests/bad_test.lua", case[0]);
        const outcome = try fixture.run(&.{"--timeout-ms=2000"}, 1);
        try equal(@as(i64, 3), outcome.object.get("passed").?.integer);
        try equal(@as(i64, 1), outcome.object.get("failed").?.integer);
        const message = outcome.object.get("results").?.array.items[0].object.get("diagnostic").?.string;
        if (std.mem.indexOf(u8, message, case[1]) == null) {
            std.debug.print("expected {s}, got {s}\n", .{ case[1], message });
            return error.WrongDiagnostic;
        }
        try expect(std.mem.indexOf(u8, message, "panic") == null);
        try expect(std.mem.indexOf(u8, message, "leaked") == null);
    }
    try fixture.write("tests/bad_test.lua", "return {}");
    const empty = try fixture.run(&.{"tests/bad_test.lua"}, 1);
    try strings("NoTestsFound", empty.object.get("error_message").?.string);
    _ = try fixture.run(&.{"missing"}, 1);

    // Run an external app's compatibility test from its own source root. It
    // depends only on the installed executable, not Ourokit's tests/modules.
    try fixture.write("tests/runtime_test.lua", @embedFile("runtime_test.lua"));
    const compatibility = try fixture.run(&.{"tests/runtime_test.lua"}, 0);
    try equal(@as(i64, 1), compatibility.object.get("passed").?.integer);

    try fixture.write("app.lua",
        \\local o = require('ouro')
        \\assert(o.runtime and o.runtime.api_level >= 1, 'requires runtime API 1')
        \\o.stdout.write(o.json.encode(o.runtime)); o.exit(0)
    );
    try fixture.write("ouro.json",
        \\{"schema_version":1,"id":"dev.example.Editor","entry":"app.lua","minimum_runtime_api":1}
    );
    const app = try std.process.run(a, init.io, .{
        .argv = &.{ binary, "run", "--headless" },
        .cwd = .{ .path = root },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    try equal(std.process.Child.Term{ .exited = 0 }, app.term);
    const info = (try std.json.parseFromSlice(std.json.Value, a, app.stdout, .{})).value.object;
    try equal(@as(i64, 1), info.get("api_level").?.integer);
    const version = try std.process.run(a, init.io, .{ .argv = &.{ binary, "version" } });
    try equal(std.process.Child.Term{ .exited = 0 }, version.term);
    try strings(try std.fmt.allocPrint(a, "ouroctl {s} (runtime API 1, revision {s})\n", .{
        info.get("version").?.string, info.get("revision").?.string,
    }), version.stdout);

    // A future requirement must fail before trying either source or a library.
    try fixture.write("ouro.json",
        \\{"schema_version":1,"id":"dev.example.Editor","entry":"missing.lua","minimum_runtime_api":2,
        \\ "native_modules":[{"name":"missing","path":"missing.so"}]}
    );
    const rejected = try std.process.run(a, init.io, .{
        .argv = &.{ binary, "run", "--headless" },
        .cwd = .{ .path = root },
        .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .awake } },
    });
    try equal(std.process.Child.Term{ .exited = 1 }, rejected.term);
    try expect(std.mem.indexOf(u8, rejected.stderr, "UnsupportedRuntimeApi") != null);
    try strings("", rejected.stdout);
    try std.Io.File.stdout().writeStreamingAll(init.io, "PASS external-app runtime API and retained editor contract\n");
    try std.Io.File.stdout().writeStreamingAll(init.io, "PASS Lua runner discovery, ordering, imports, isolation, filtering, listing, JSON, failure cleanup and hard timeouts\n");
}

const Fixture = struct {
    init: std.process.Init,
    binary: []const u8,
    root: []const u8,
    dir: std.Io.Dir,

    fn write(self: Fixture, path: []const u8, source: []const u8) !void {
        try self.dir.writeFile(self.init.io, .{ .sub_path = path, .data = source });
    }

    fn run(self: Fixture, extra: []const []const u8, code: u8) !std.json.Value {
        const a = self.init.arena.allocator();
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(a, &.{ self.binary, "test", "--json" });
        try argv.appendSlice(a, extra);
        const result = try std.process.run(a, self.init.io, .{
            .argv = argv.items,
            .cwd = .{ .path = self.root },
            .timeout = .{ .duration = .{ .raw = .fromSeconds(30), .clock = .awake } },
        });
        if (result.term != .exited or result.term.exited != code) {
            std.debug.print("unexpected runner outcome {any}\n{s}\n{s}\n", .{ result.term, result.stdout, result.stderr });
            return error.WrongExitCode;
        }
        try strings("", result.stderr);
        return (try std.json.parseFromSlice(std.json.Value, a, result.stdout, .{})).value;
    }
};
