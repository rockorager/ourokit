//! Compositor-free presentation comparison. Timings are Vulkan timestamp
//! intervals and CPU submit+wait latency, not compositor frame times.
const std = @import("std");
const ok = @import("ourokit");
const vk = ok.renderer.vulkan;
const Color = ok.core.Color;
const c = vk.c;
const samples = 60;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4 and args.len != 5) {
        std.debug.print("usage: presentation-probe OUTPUT_DIRECTORY WIDTH HEIGHT [DRM_MODIFIER]\nWithout a modifier: mapped linear images and PNG captures. With a modifier: native dma-buf allocations, no captures or compositor handoff.\n", .{});
        return error.InvalidArguments;
    }
    const width = try std.fmt.parseInt(u32, args[2], 10);
    const height = try std.fmt.parseInt(u32, args[3], 10);
    if (width < 640 or height < 400) return error.InvalidExtent;
    const modifier: ?u64 = if (args.len == 5) try std.fmt.parseInt(u64, args[4], 0) else null;
    try std.Io.Dir.cwd().createDirPath(init.io, args[1]);
    var renderer = try vk.init(init.gpa);
    defer renderer.deinit();
    var properties: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(renderer.physical_device, &properties);
    var count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(renderer.physical_device, &count, null);
    const queues = try init.gpa.alloc(c.VkQueueFamilyProperties, count);
    defer init.gpa.free(queues);
    c.vkGetPhysicalDeviceQueueFamilyProperties(renderer.physical_device, &count, queues.ptr);
    const bits = queues[renderer.queue_family].timestampValidBits;
    if (bits == 0) return error.TimestampsUnavailable;
    const mask: u64 = if (bits == 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bits)) - 1;
    std.debug.print("device={s} type={d} extent={d}x{d} timestamp_bits={d} period_ns={d}\n", .{ std.mem.sliceTo(&properties.deviceName, 0), properties.deviceType, width, height, bits, properties.limits.timestampPeriod });
    if (properties.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_CPU)
        std.debug.print("SOFTWARE VULKAN: these costs do not predict Intel GPU performance.\n", .{});
    var query_info: c.VkQueryPoolCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = c.VK_QUERY_TYPE_TIMESTAMP, .queryCount = 2 };
    var query: c.VkQueryPool = undefined;
    if (c.vkCreateQueryPool(renderer.device, &query_info, null, &query) != c.VK_SUCCESS) return error.CreateQueryPoolFailed;
    defer c.vkDestroyQueryPool(renderer.device, query, null);
    var fonts = ok.text.FontCache.init(init.gpa);
    defer fonts.deinit();
    const font = try fonts.acquire(.{ .key = .{ .file = "SourceSans3-Regular.otf", .index = 0 }, .bytes = @embedFile("probe_font") });
    defer fonts.release(font) catch unreachable;
    var paragraphs = ok.text.ParagraphCache.init(init.gpa, &fonts);
    defer paragraphs.deinit();
    const title = try paragraphs.acquire(.{ .utf8 = "Hello, world!", .language = "en", .logical_size = 48, .max_width = @floatFromInt(width), .candidates = &.{font}, .configuration_revision = 1 });
    defer paragraphs.release(title) catch unreachable;
    const label = try paragraphs.acquire(.{ .utf8 = "Source Sans 3 · Aa fi fl 0O 1Il — dark colors / text edges", .language = "en", .logical_size = 21, .max_width = @floatFromInt(width - 48), .candidates = &.{font}, .configuration_revision = 1 });
    defer paragraphs.release(label) catch unreachable;
    var glyphs = try vk.GlyphCache.init(init.gpa, &fonts, &renderer);
    defer glyphs.deinit();
    const has_direct = @hasDecl(vk.GraphicsReadback, "initMode");
    for ([_][]const u8{ "converted", "direct", "transparent" }) |name| {
        const direct = std.mem.eql(u8, name, "direct");
        if (direct and !has_direct) continue;
        if (modifier) |value| {
            const supported = if (has_direct and direct) renderer.supportsDirectModifier(value) else renderer.supportsDmabufModifier(value);
            if (!supported) {
                std.debug.print("{s}: modifier 0x{x} unsupported\n", .{ name, value });
                continue;
            }
        }
        const transparent = std.mem.eql(u8, name, "transparent");
        var commands: std.ArrayList(ok.scene.Command) = .empty;
        defer commands.deinit(init.gpa);
        try commands.appendSlice(init.gpa, &.{
            .{ .clear = if (transparent) Color.rgba(0, 0, 0, 0) else Color.rgba(254, 247, 255, 255) },
            .{ .paragraph = .{ .layout = title, .origin = .{ .x = 32.25, .y = 24.5 }, .scale = 1, .color = Color.rgba(29, 27, 32, 255) } },
            .{ .paragraph = .{ .layout = label, .origin = .{ .x = 32.25, .y = 94.5 }, .scale = 1, .color = Color.rgba(29, 27, 32, 255) } },
            .{ .solid_rectangle = .{ .bounds = .{ .x = 24, .y = 140, .width = width - 48, .height = 96 }, .color = Color.rgba(17, 23, 35, 255) } },
            .{ .paragraph = .{ .layout = label, .origin = .{ .x = 32.25, .y = 166.5 }, .scale = 1, .color = Color.rgba(245, 239, 250, 255) } },
            .{ .decorated_rectangle = .{ .bounds = .{ .x = 32, .y = 264, .width = 210, .height = 96 }, .background = Color.rgba(200, 70, 30, 128), .corner_radius = 18 } },
            .{ .decorated_rectangle = .{ .bounds = .{ .x = 144, .y = 282, .width = 210, .height = 96 }, .background = Color.rgba(25, 100, 220, 128), .border_color = Color.rgba(10, 30, 100, 90), .border_width = 2, .corner_radius = 18 } },
            .{ .solid_rectangle = .{ .bounds = .{ .x = 400, .y = 270, .width = 48, .height = 48 }, .color = Color.rgba(255, 255, 255, 128) } },
        });
        for (0..32) |value| try commands.append(init.gpa, .{ .solid_rectangle = .{ .bounds = .{ .x = @intCast(400 + value * 6), .y = 336, .width = 6, .height = 32 }, .color = Color.rgba(@intCast(value), @intCast(value), @intCast(value), 255) } });
        var mapped: [2]vk.GraphicsReadback = undefined;
        var native: [2]vk.DmabufTarget = undefined;
        var targets: [2]*vk.DmabufTarget = undefined;
        var initialized: usize = 0;
        defer for (0..initialized) |i| {
            if (modifier != null) native[i].deinit(&renderer) else mapped[i].deinit(&renderer);
        };
        for (&targets, 0..) |*target, i| {
            if (modifier) |value| {
                native[i] = if (i != 0) try vk.DmabufTarget.initShared(&renderer, targets[0]) else if (has_direct and direct) try vk.DmabufTarget.initOpaque(&renderer, width, height, value) else try vk.DmabufTarget.init(&renderer, width, height, value);
                target.* = &native[i];
            } else {
                mapped[i] = if (has_direct) try vk.GraphicsReadback.initMode(&renderer, width, height, if (i == 0) null else targets[0].linear, direct) else try vk.GraphicsReadback.initWithLinear(&renderer, width, height, if (i == 0) null else targets[0].linear);
                target.* = &mapped[i].target;
            }
            initialized += 1;
            target.*.timestamp_pool = query;
        }
        var export_bytes: u64 = 0;
        for (targets) |target| export_bytes += imageBytes(&renderer, target.image);
        const working_bytes = if (has_direct) (if (targets[0].linear) |linear| imageBytes(&renderer, linear.image) else 0) else imageBytes(&renderer, targets[0].linear.image);
        std.debug.print("{s}: export_bytes={d} shared_working_bytes={d} slots=2 tiling={s}\n", .{ name, export_bytes, working_bytes, if (modifier != null) "DRM_MODIFIER" else "LINEAR" });
        for ([_]bool{ false, true }) |partial| {
            var gpu: [samples]f64 = undefined;
            var wall: [samples]f64 = undefined;
            for (0..samples + 8) |iteration| {
                const target = targets[iteration % 2];
                const damage: ok.scene.Damage = if (!partial or iteration < 2) .full else .{ .regions = &.{.{ .x = 128, .y = 280, .width = 128, .height = 64 }} };
                const start = nanoTime();
                try renderer.renderGraphicsResources(.{ .commands = commands.items, .damage = damage }, target, &glyphs, null, &paragraphs, null, false);
                try target.wait(&renderer);
                const elapsed = nanoTime() - start;
                var stamps: [2]u64 = undefined;
                if (c.vkGetQueryPoolResults(renderer.device, query, 0, 2, @sizeOf(@TypeOf(stamps)), &stamps, @sizeOf(u64), c.VK_QUERY_RESULT_64_BIT | c.VK_QUERY_RESULT_WAIT_BIT) != c.VK_SUCCESS) return error.TimestampReadFailed;
                if (iteration >= 8) {
                    gpu[iteration - 8] = @as(f64, @floatFromInt((stamps[1] -% stamps[0]) & mask)) * properties.limits.timestampPeriod / 1e6;
                    wall[iteration - 8] = @as(f64, @floatFromInt(elapsed)) / 1e6;
                }
            }
            std.mem.sort(f64, &gpu, {}, std.sort.asc(f64));
            std.mem.sort(f64, &wall, {}, std.sort.asc(f64));
            std.debug.print("{s} {s}: timestamp_ms median={d:.3} p95={d:.3}; submit_wait_ms median={d:.3} p95={d:.3} n={d}\n", .{ name, if (partial) "128x64" else "full", gpu[samples / 2], gpu[samples * 95 / 100], wall[samples / 2], wall[samples * 95 / 100], samples });
        }
        if (modifier == null) {
            const pixels = try init.gpa.alloc(u8, width * height * 4);
            defer init.gpa.free(pixels);
            for (0..height) |y| for (0..width) |x| {
                const p = mapped[0].pixel(x, y);
                // Visualize untagged desktop bytes as sRGB, including the old
                // baseline's gamma-2.2 bytes. This intentionally differs from
                // baseline PNG interchange export, which applied a transfer.
                const out = pixels[(y * width + x) * 4 ..][0..4];
                for (0..3) |channel| out[channel] = if (p[3] == 0) 0 else @intCast(@min(255, (@as(u32, p[channel]) * 255 + p[3] / 2) / p[3]));
                out[3] = p[3];
            };
            const png = try ok.renderer.png.encode(init.gpa, pixels, width, height, width * 4);
            defer init.gpa.free(png);
            const path = try std.fmt.allocPrint(init.gpa, "{s}/{s}.png", .{ args[1], name });
            defer init.gpa.free(path);
            var file = try std.Io.Dir.cwd().createFile(init.io, path, .{});
            defer file.close(init.io);
            try file.writeStreamingAll(init.io, png);
            std.debug.print("capture={s} white50={any}\n", .{ path, mapped[0].pixel(410, 280) });
        }
    }
}

fn imageBytes(renderer: *vk, image: c.VkImage) u64 {
    var requirements: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(renderer.device, image, &requirements);
    return requirements.size;
}

fn nanoTime() u64 {
    var value: std.os.linux.timespec = undefined;
    std.debug.assert(std.os.linux.errno(std.os.linux.clock_gettime(.MONOTONIC, &value)) == .SUCCESS);
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.nsec));
}
