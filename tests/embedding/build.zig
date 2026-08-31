const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ourokit = b.dependency("ourokit", .{
        .target = target,
        .optimize = optimize,
        .fontconfig = false,
        .freetype = false,
        .vulkan = false,
    });
    const executable = b.addExecutable(.{
        .name = "ourokit-ui-consumer-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{
                .name = "ourokit_ui",
                .module = ourokit.module("ourokit_ui"),
            }},
        }),
    });
    const run = b.addRunArtifact(executable);
    const test_step = b.step("test", "Render a native titlebar through ourokit_ui");
    test_step.dependOn(&run.step);
}
