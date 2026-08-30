const std = @import("std");

const lua_sources = &.{
    "src/lapi.c",
    "src/lcode.c",
    "src/lctype.c",
    "src/ldebug.c",
    "src/ldo.c",
    "src/ldump.c",
    "src/lfunc.c",
    "src/lgc.c",
    "src/llex.c",
    "src/lmem.c",
    "src/lobject.c",
    "src/lopcodes.c",
    "src/lparser.c",
    "src/lstate.c",
    "src/lstring.c",
    "src/ltable.c",
    "src/ltm.c",
    "src/lundump.c",
    "src/lvm.c",
    "src/lzio.c",
    "src/lauxlib.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wayring = b.dependency("wayring", .{
        .target = target,
        .optimize = optimize,
    });
    const lua = b.dependency("lua", .{});

    const ourokit = b.addModule("ourokit", .{
        .root_source_file = b.path("src/ourokit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring.module("wayring") }},
    });
    addLua(ourokit, lua);

    const library = b.addLibrary(.{
        .name = "ourokit",
        .root_module = ourokit,
    });
    b.installArtifact(library);

    const token_check = b.addSystemCommand(&.{ "python3", "tools/design/generate_tokens.py", "--check" });
    const token_step = b.step("tokens", "Validate tokens and check generated Zig data");
    token_step.dependOn(&token_check.step);
    b.getInstallStep().dependOn(&token_check.step);

    const token_generate = b.addSystemCommand(&.{ "python3", "tools/design/generate_tokens.py" });
    const generate_step = b.step("generate-tokens", "Validate tokens and regenerate Zig data");
    generate_step.dependOn(&token_generate.step);

    addWaylandExample(b, target, optimize, ourokit, wayring);

    const tests = b.addTest(.{ .root_module = ourokit });
    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(&token_check.step);
    const test_step = b.step("test", "Run all deterministic and integration tests");
    test_step.dependOn(&run_tests.step);
}

fn addWaylandExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ourokit: *std.Build.Module,
    wayring: *std.Build.Dependency,
) void {
    const wayland = b.lazyDependency("wayland", .{}) orelse return;
    const wayland_protocols = b.lazyDependency("wayland_protocols", .{}) orelse return;
    const scanner = wayring.artifact("wayring-scanner");
    const generate = b.addRunArtifact(scanner);
    generate.addFileArg(wayland.path("protocol/wayland.xml"));
    generate.addFileArg(wayland_protocols.path("stable/xdg-shell/xdg-shell.xml"));
    const generated = generate.addOutputFileArg("ourokit-wayland-protocol.zig");
    const protocol = b.createModule(.{
        .root_source_file = generated,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring.module("wayring") }},
    });

    const example = b.addExecutable(.{
        .name = "ourokit-wayland-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/wayland.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ourokit", .module = ourokit },
                .{ .name = "wayring", .module = wayring.module("wayring") },
                .{ .name = "wayland_protocol", .module = protocol },
            },
        }),
    });
    const run = b.addRunArtifact(example);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run-wayland-example", "Open the software-rendered Wayland example");
    run_step.dependOn(&run.step);
}

fn addLua(module: *std.Build.Module, lua: *std.Build.Dependency) void {
    module.addCSourceFiles(.{
        .root = lua.path(""),
        .files = lua_sources,
        .flags = &.{ "-std=c99", "-DLUA_USE_LINUX" },
    });
    module.addIncludePath(lua.path("src"));
    module.link_libc = true;
}
