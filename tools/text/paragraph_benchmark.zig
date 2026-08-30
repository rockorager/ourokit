const std = @import("std");
const ourokit = @import("ourokit");

const iterations = 20_000;

const Workload = struct {
    name: []const u8,
    text: []const u8,
};

const workloads = [_]Workload{
    .{ .name = "latin", .text = "The quick brown fox jumps over the lazy dog." },
    .{ .name = "mixed", .text = "Status: جاهز — build 42 (successful)." },
    .{ .name = "isolates", .text = "LTR \u{2067}RTL 123\u{2069} tail \u{2066}nested\u{2069}." },
    .{ .name = "paragraphs", .text = "First paragraph.\r\nפסקה שנייה with Latin.\n第三段。" },
};

pub fn main(init: std.process.Init) !void {
    if (@import("builtin").mode == .Debug)
        std.debug.print("warning: use -Doptimize=ReleaseFast for meaningful results\n", .{});
    for (workloads) |workload| try run(init.gpa, workload);
}

fn run(allocator: std.mem.Allocator, workload: Workload) !void {
    var warmup = try ourokit.text.analyzeBidi(allocator, workload.text, .auto_left_to_right);
    const paragraphs_per_input = warmup.paragraphs.len;
    warmup.deinit();
    const started = nanoTime();
    var total_runs: usize = 0;
    for (0..iterations) |_| {
        var analysis = try ourokit.text.analyzeBidi(allocator, workload.text, .auto_left_to_right);
        total_runs += analysis.runs.len;
        analysis.deinit();
    }
    const elapsed = nanoTime() - started;
    std.mem.doNotOptimizeAway(total_runs);
    const ns_per_input = @as(f64, @floatFromInt(elapsed)) / iterations;
    const ns_per_paragraph = ns_per_input / @as(f64, @floatFromInt(paragraphs_per_input));
    const ns_per_byte = ns_per_input / @as(f64, @floatFromInt(workload.text.len));
    std.debug.print(
        "{s}: {d:.1} ns/input, {d:.1} ns/paragraph, {d:.2} ns/byte ({d} iterations)\n",
        .{ workload.name, ns_per_input, ns_per_paragraph, ns_per_byte, iterations },
    );
}

fn nanoTime() u64 {
    const linux = std.os.linux;
    var value: linux.timespec = undefined;
    std.debug.assert(linux.errno(linux.clock_gettime(.MONOTONIC, &value)) == .SUCCESS);
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.nsec));
}
