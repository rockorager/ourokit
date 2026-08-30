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

const pixman_sources = &.{
    "pixman/pixman.c",
    "pixman/pixman-access.c",
    "pixman/pixman-access-accessors.c",
    "pixman/pixman-arm.c",
    "pixman/pixman-bits-image.c",
    "pixman/pixman-combine32.c",
    "pixman/pixman-combine-float.c",
    "pixman/pixman-conical-gradient.c",
    "pixman/pixman-edge.c",
    "pixman/pixman-edge-accessors.c",
    "pixman/pixman-fast-path.c",
    "pixman/pixman-filter.c",
    "pixman/pixman-glyph.c",
    "pixman/pixman-general.c",
    "pixman/pixman-gradient-walker.c",
    "pixman/pixman-image.c",
    "pixman/pixman-implementation.c",
    "pixman/pixman-linear-gradient.c",
    "pixman/pixman-matrix.c",
    "pixman/pixman-mips.c",
    "pixman/pixman-noop.c",
    "pixman/pixman-ppc.c",
    "pixman/pixman-radial-gradient.c",
    "pixman/pixman-region16.c",
    "pixman/pixman-region32.c",
    "pixman/pixman-region64f.c",
    "pixman/pixman-riscv.c",
    "pixman/pixman-solid-fill.c",
    "pixman/pixman-timer.c",
    "pixman/pixman-trap.c",
    "pixman/pixman-utils.c",
    "pixman/pixman-x86.c",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_fontconfig = b.option(
        bool,
        "fontconfig",
        "Enable native Linux font discovery through system Fontconfig",
    ) orelse (target.query.isNative() and target.result.os.tag == .linux);
    const enable_freetype = b.option(
        bool,
        "freetype",
        "Enable software glyph rasterization through system FreeType",
    ) orelse (target.query.isNative() and target.result.os.tag == .linux);
    const wayring = b.dependency("wayring", .{
        .target = target,
        .optimize = optimize,
    });
    const wayring_host = b.dependency("wayring", .{});
    const lua = b.dependency("lua", .{});
    const harfbuzz = b.dependency("harfbuzz", .{});
    const uucode = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{ "grapheme_break", "script" }),
    });
    const wayland_protocol = addWaylandProtocol(b, target, optimize, wayring, wayring_host);

    const ourokit = b.addModule("ourokit", .{
        .root_source_file = b.path("src/ourokit.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "wayring", .module = wayring.module("wayring") },
            .{ .name = "wayland_protocol", .module = wayland_protocol },
            .{ .name = "uucode", .module = uucode.module("uucode") },
        },
    });
    addLua(ourokit, lua);
    addHarfBuzz(ourokit, harfbuzz);
    const ourokit_options = b.addOptions();
    ourokit_options.addOption(bool, "fontconfig", enable_fontconfig);
    ourokit_options.addOption(bool, "freetype", enable_freetype);
    ourokit.addOptions("ourokit_build_options", ourokit_options);
    if (enable_fontconfig) {
        ourokit.linkSystemLibrary("fontconfig", .{});
        ourokit.link_libc = true;
    }
    if (enable_freetype) {
        ourokit.linkSystemLibrary("freetype2", .{});
        ourokit.link_libc = true;
    }

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

    addWaylandExample(b, target, optimize, ourokit);
    addRendererBenchmark(b, target, optimize, ourokit);

    const test_font = b.lazyDependency("inter", .{}) orelse return;
    ourokit.addAnonymousImport("ourokit_test_font", .{
        .root_source_file = test_font.path("InterVariable.ttf"),
    });
    ourokit.addAnonymousImport("ourokit_test_font_static", .{
        .root_source_file = test_font.path("extras/ttf/Inter-Regular.ttf"),
    });
    const arabic_test_font = b.lazyDependency("noto_sans_arabic", .{}) orelse return;
    ourokit.addAnonymousImport("ourokit_arabic_test_font", .{
        .root_source_file = arabic_test_font.path("NotoSansArabic/unhinted/slim-variable-ttf/NotoSansArabic[wght].ttf"),
    });
    const tests = b.addTest(.{ .root_module = ourokit });
    const run_tests = b.addRunArtifact(tests);
    run_tests.step.dependOn(&token_check.step);
    const test_step = b.step("test", "Run all deterministic and integration tests");
    test_step.dependOn(&run_tests.step);
}

fn addRendererBenchmark(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ourokit: *std.Build.Module,
) void {
    if (target.result.os.tag != .linux or
        (target.result.cpu.arch != .x86_64 and target.result.cpu.arch != .aarch64)) return;
    const pixman = b.lazyDependency("pixman", .{}) orelse return;
    const pixman_module = b.createModule(.{ .target = target, .optimize = optimize });
    pixman_module.addIncludePath(pixman.path("pixman"));
    pixman_module.addIncludePath(b.path("tools/rendering"));
    const common_flags = [_][]const u8{
        "-std=c99",
        "-DHAVE_CONFIG_H",
        "-fno-strict-aliasing",
        "-fvisibility=hidden",
        "-ftrapping-math",
    };
    pixman_module.addCSourceFiles(.{
        .root = pixman.path(""),
        .files = pixman_sources,
        .flags = switch (target.result.cpu.arch) {
            .x86_64 => &(common_flags ++ [_][]const u8{ "-DUSE_X86_MMX=1", "-DUSE_SSE2=1", "-DUSE_SSSE3=1" }),
            .aarch64 => &(common_flags ++ [_][]const u8{"-DUSE_ARM_A64_NEON=1"}),
            else => &common_flags,
        },
    });
    switch (target.result.cpu.arch) {
        .x86_64 => {
            pixman_module.addCSourceFiles(.{
                .root = pixman.path("pixman"),
                .files = &.{"pixman-mmx.c"},
                .flags = &(common_flags ++ [_][]const u8{ "-DUSE_X86_MMX=1", "-DUSE_SSE2=1", "-DUSE_SSSE3=1", "-mmmx", "-Winline" }),
            });
            pixman_module.addCSourceFiles(.{
                .root = pixman.path("pixman"),
                .files = &.{"pixman-sse2.c"},
                .flags = &(common_flags ++ [_][]const u8{ "-DUSE_X86_MMX=1", "-DUSE_SSE2=1", "-DUSE_SSSE3=1", "-msse2", "-Winline" }),
            });
            pixman_module.addCSourceFiles(.{
                .root = pixman.path("pixman"),
                .files = &.{"pixman-ssse3.c"},
                .flags = &(common_flags ++ [_][]const u8{ "-DUSE_X86_MMX=1", "-DUSE_SSE2=1", "-DUSE_SSSE3=1", "-mssse3", "-Winline" }),
            });
        },
        .aarch64 => pixman_module.addCSourceFiles(.{
            .root = pixman.path("pixman"),
            .files = &.{
                "pixman-arm-neon.c",
                "pixman-arma64-neon-asm.S",
                "pixman-arma64-neon-asm-bilinear.S",
            },
            .flags = &(common_flags ++ [_][]const u8{"-DUSE_ARM_A64_NEON=1"}),
        }),
        else => {},
    }
    pixman_module.link_libc = true;
    pixman_module.linkSystemLibrary("m", .{});
    const pixman_library = b.addLibrary(.{ .name = "ourokit-benchmark-pixman", .root_module = pixman_module });

    const benchmark_module = b.createModule(.{
        .root_source_file = b.path("tools/rendering/benchmark.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "ourokit", .module = ourokit }},
    });
    benchmark_module.addIncludePath(pixman.path("pixman"));
    benchmark_module.addIncludePath(b.path("tools/rendering"));
    benchmark_module.linkLibrary(pixman_library);
    benchmark_module.link_libc = true;
    const benchmark = b.addExecutable(.{ .name = "ourokit-renderer-benchmark", .root_module = benchmark_module });
    const build_step = b.step("build-renderer-benchmark", "Build the Ourokit/Pixman comparison without running it");
    build_step.dependOn(&benchmark.step);
    const run = b.addRunArtifact(benchmark);
    const step = b.step("bench-renderers", "Compare Ourokit direct rendering with pinned Pixman");
    step.dependOn(&run.step);
}

fn addWaylandExample(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ourokit: *std.Build.Module,
) void {
    const example = b.addExecutable(.{
        .name = "ourokit-wayland-example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/wayland.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "ourokit", .module = ourokit }},
        }),
    });
    const run = b.addRunArtifact(example);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run-wayland-example", "Open the software-rendered Wayland example");
    run_step.dependOn(&run.step);

    const install_benchmark = b.addInstallArtifact(example, .{
        .dest_dir = .{ .override = .{ .custom = "benchmark-apps" } },
        .dest_sub_path = "ourokit",
    });
    const benchmark_step = b.step(
        "build-application-benchmark",
        "Build the Ourokit application used by the GTK/Qt comparison",
    );
    benchmark_step.dependOn(&install_benchmark.step);
}

fn addWaylandProtocol(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wayring: *std.Build.Dependency,
    wayring_host: *std.Build.Dependency,
) *std.Build.Module {
    const wayland = b.dependency("wayland", .{});
    const wayland_protocols = b.dependency("wayland_protocols", .{});
    const scanner = wayring_host.artifact("wayring-scanner");
    const generate = b.addRunArtifact(scanner);
    generate.addFileArg(wayland.path("protocol/wayland.xml"));
    generate.addFileArg(wayland_protocols.path("stable/xdg-shell/xdg-shell.xml"));
    const generated = generate.addOutputFileArg("ourokit-wayland-protocol.zig");
    return b.createModule(.{
        .root_source_file = generated,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring.module("wayring") }},
    });
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

fn addHarfBuzz(module: *std.Build.Module, harfbuzz: *std.Build.Dependency) void {
    module.addCSourceFiles(.{
        .root = harfbuzz.path(""),
        .files = &.{"src/harfbuzz.cc"},
        .flags = &.{ "-std=c++17", "-DHB_NO_FEATURES_H" },
    });
    module.addIncludePath(harfbuzz.path("src"));
    module.link_libcpp = true;
}
