const std = @import("std");

pub const Easing = enum {
    linear,
    ease_in,
    ease_out,
    ease_in_out,

    fn apply(self: Easing, progress: f64) f64 {
        return switch (self) {
            .linear => progress,
            .ease_in => progress * progress,
            .ease_out => progress * (2 - progress),
            .ease_in_out => progress * progress * (3 - 2 * progress),
        };
    }
};

pub const Config = struct {
    duration_ns: u64,
    easing: Easing = .linear,
    loop: bool = false,

    pub fn validate(self: Config) !void {
        if (self.duration_ns == 0 and self.loop) return error.InvalidAnimationConfig;
    }

    fn initial(self: Config) f64 {
        return if (self.duration_ns == 0) 1 else 0;
    }
};

pub const Descriptor = struct {
    id: u64,
    config: Config,
};

const Track = struct {
    descriptor: Descriptor,
    origin_ns: ?u64,
    progress: f64,

    fn elapsed(self: Track, clock_ns: ?u64) u64 {
        const origin = self.origin_ns orelse return 0;
        return clock_ns.? - origin;
    }
};

/// Keyed, duration-based timelines. The caller owns time and schedules wakeups
/// using delay(); this registry owns no callbacks, UI instances, or resources.
/// Storage is fixed at init. Reconciliation and lookup are quadratic and linear
/// respectively; advancing and finding the next delay are linear in track count.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    tracks: []Track,
    scratch: []Track,
    len: usize = 0,
    clock_ns: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Registry {
        const tracks = try allocator.alloc(Track, capacity);
        errdefer allocator.free(tracks);
        const scratch = try allocator.alloc(Track, capacity);
        return .{ .allocator = allocator, .tracks = tracks, .scratch = scratch };
    }

    pub fn deinit(self: *Registry) void {
        self.allocator.free(self.scratch);
        self.allocator.free(self.tracks);
        self.* = undefined;
    }

    pub fn count(self: *const Registry) usize {
        return self.len;
    }

    /// Drops every timeline and restores the uninitialized clock.
    pub fn clear(self: *Registry) void {
        self.len = 0;
        self.clock_ns = null;
    }

    /// Checks the complete declaration without changing clock or track state.
    pub fn validate(self: *const Registry, descriptors: []const Descriptor) !void {
        if (descriptors.len > self.tracks.len) return error.AnimationCapacityExceeded;
        for (descriptors, 0..) |descriptor, i| {
            try descriptor.config.validate();
            for (descriptors[0..i]) |previous| {
                if (previous.id == descriptor.id) return error.DuplicateAnimationId;
            }
        }
    }

    /// Commits a complete declaration. An unchanged id and config retain their
    /// origin and sampled value regardless of order. Changed or remounted tracks
    /// start at the current clock, or at the first advance if no clock is known.
    pub fn reconcile(self: *Registry, descriptors: []const Descriptor) !void {
        try self.validate(descriptors);
        for (descriptors, 0..) |descriptor, i| {
            self.scratch[i] = if (self.find(descriptor)) |track| track.* else .{
                .descriptor = descriptor,
                .origin_ns = self.clock_ns,
                .progress = descriptor.config.initial(),
            };
        }
        std.mem.swap([]Track, &self.tracks, &self.scratch);
        self.len = descriptors.len;
    }

    /// Read-only preview for a declaration, including one not yet reconciled.
    /// A new id or changed config samples its initial value, not an old track.
    pub fn sample(self: *const Registry, descriptor: Descriptor) f64 {
        return if (self.find(descriptor)) |track| track.progress else descriptor.config.initial();
    }

    /// Samples from absolute elapsed time, never accumulated frame deltas.
    /// Clock rollback is ignored. Returns whether any sampled output changed,
    /// not whether time advanced or a loop completed a whole number of cycles.
    pub fn advance(self: *Registry, now_ns: u64) bool {
        self.clock_ns = @max(self.clock_ns orelse now_ns, now_ns);
        var changed = false;
        for (self.tracks[0..self.len]) |*track| {
            if (track.origin_ns == null) track.origin_ns = self.clock_ns;
            const config = track.descriptor.config;
            const elapsed = track.elapsed(self.clock_ns);
            const progress: f64 = if (config.duration_ns == 0 or
                (!config.loop and elapsed >= config.duration_ns)) 1 else progress: {
                const phase = if (config.loop) elapsed % config.duration_ns else elapsed;
                const fraction = @as(f64, @floatFromInt(phase)) /
                    @as(f64, @floatFromInt(config.duration_ns));
                break :progress config.easing.apply(fraction);
            };
            changed = changed or progress != track.progress;
            track.progress = progress;
        }
        return changed;
    }

    /// Earliest wakeup: at most 16 ms, shortened to a completion or loop boundary.
    /// Completed oneshots (including zero-duration oneshots) request no work.
    pub fn delay(self: *const Registry) ?u64 {
        var result: ?u64 = null;
        for (self.tracks[0..self.len]) |track| {
            const config = track.descriptor.config;
            const elapsed = track.elapsed(self.clock_ns);
            if (config.duration_ns == 0 or (!config.loop and elapsed >= config.duration_ns)) continue;
            const phase = if (config.loop) elapsed % config.duration_ns else elapsed;
            const remaining = config.duration_ns - phase;
            const next = @min(16 * std.time.ns_per_ms, remaining);
            result = @min(result orelse next, next);
        }
        return result;
    }

    fn find(self: *const Registry, descriptor: Descriptor) ?*const Track {
        for (self.tracks[0..self.len]) |*track| {
            if (std.meta.eql(track.descriptor, descriptor)) return track;
        }
        return null;
    }
};

test "easing samples asymmetric quarter points and exact endpoints" {
    const cases = [_]struct { easing: Easing, quarter: f64, three_quarters: f64 }{
        .{ .easing = .linear, .quarter = 0.25, .three_quarters = 0.75 },
        .{ .easing = .ease_in, .quarter = 0.0625, .three_quarters = 0.5625 },
        .{ .easing = .ease_out, .quarter = 0.4375, .three_quarters = 0.9375 },
        .{ .easing = .ease_in_out, .quarter = 0.15625, .three_quarters = 0.84375 },
    };
    var registry = try Registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    for (cases) |case| {
        registry.clear();
        const descriptor: Descriptor = .{ .id = 5, .config = .{ .duration_ns = 100, .easing = case.easing } };
        try registry.reconcile(&.{descriptor});
        try std.testing.expectEqual(0, registry.sample(descriptor));
        try std.testing.expect(!registry.advance(1000));
        try std.testing.expect(registry.advance(1025));
        try std.testing.expectEqual(case.quarter, registry.sample(descriptor));
        try std.testing.expect(registry.advance(1075));
        try std.testing.expectEqual(case.three_quarters, registry.sample(descriptor));
        try std.testing.expect(registry.advance(1100));
        try std.testing.expectEqual(1, registry.sample(descriptor));
        try std.testing.expectEqual(null, registry.delay());
    }
}

test "oneshot boundary skipped frames and idle completion" {
    var registry = try Registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const descriptor: Descriptor = .{ .id = 1, .config = .{ .duration_ns = 100 } };
    try registry.reconcile(&.{descriptor});
    try std.testing.expect(!registry.advance(20));
    try std.testing.expect(registry.advance(119));
    try std.testing.expectApproxEqAbs(0.99, registry.sample(descriptor), 1e-12);
    try std.testing.expectEqual(@as(?u64, 1), registry.delay());
    try std.testing.expect(!registry.advance(119));
    try std.testing.expect(registry.advance(120));
    try std.testing.expectEqual(1, registry.sample(descriptor));
    try std.testing.expectEqual(null, registry.delay());
    try std.testing.expect(!registry.advance(121));
    try std.testing.expect(!registry.advance(0));
    try std.testing.expectEqual(1, registry.sample(descriptor));

    registry.clear();
    try registry.reconcile(&.{descriptor});
    try std.testing.expect(!registry.advance(0));
    try std.testing.expect(registry.advance(10_000));
    try std.testing.expectEqual(1, registry.sample(descriptor));
    try std.testing.expectEqual(null, registry.delay());
}

test "loop modulo boundaries long jumps and unchanged cycle samples" {
    var registry = try Registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const descriptor: Descriptor = .{ .id = 9, .config = .{ .duration_ns = 100, .loop = true } };
    try registry.reconcile(&.{descriptor});
    try std.testing.expect(!registry.advance(13));
    try std.testing.expect(registry.advance(112));
    try std.testing.expectApproxEqAbs(0.99, registry.sample(descriptor), 1e-12);
    try std.testing.expectEqual(@as(?u64, 1), registry.delay());
    try std.testing.expect(registry.advance(113));
    try std.testing.expectEqual(0, registry.sample(descriptor));
    try std.testing.expectEqual(@as(?u64, 100), registry.delay());
    try std.testing.expect(registry.advance(114));
    try std.testing.expectApproxEqAbs(0.01, registry.sample(descriptor), 1e-12);
    try std.testing.expect(registry.advance(10_000_088));
    try std.testing.expectEqual(0.75, registry.sample(descriptor));
    try std.testing.expect(!registry.advance(10_000_388));
    try std.testing.expect(!registry.advance(10_000_050));
    try std.testing.expectEqual(0.75, registry.sample(descriptor));
    try std.testing.expectEqual(@as(?u64, 25), registry.delay());
}

test "zero duration oneshot completes immediately but cannot loop" {
    var registry = try Registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const descriptor: Descriptor = .{ .id = 0, .config = .{ .duration_ns = 0 } };
    try descriptor.config.validate();
    try std.testing.expectEqual(1, registry.sample(descriptor));
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try registry.reconcile(&.{descriptor});
    try std.testing.expectEqual(1, registry.sample(descriptor));
    try std.testing.expectEqual(null, registry.delay());
    try std.testing.expect(!registry.advance(99));
    try std.testing.expect(!registry.advance(999));
    try std.testing.expectError(error.InvalidAnimationConfig, (Config{ .duration_ns = 0, .loop = true }).validate());
    try (Config{ .duration_ns = 1, .loop = true }).validate();
}

test "reorder replacement and removal preserve matches until the new table is complete" {
    var registry = try Registry.init(std.testing.allocator, 3);
    defer registry.deinit();
    const a: Descriptor = .{ .id = 1, .config = .{ .duration_ns = 100 } };
    const b: Descriptor = .{ .id = 2, .config = .{ .duration_ns = 200 } };
    const c: Descriptor = .{ .id = 3, .config = .{ .duration_ns = 400 } };
    const d: Descriptor = .{ .id = 4, .config = .{ .duration_ns = 100 } };
    try registry.reconcile(&.{ a, b, c });
    _ = registry.advance(10);
    _ = registry.advance(60);
    try registry.reconcile(&.{ c, a, b });
    try std.testing.expectEqual(0.5, registry.sample(a));
    try std.testing.expectEqual(0.25, registry.sample(b));
    try std.testing.expectEqual(0.125, registry.sample(c));
    try registry.reconcile(&.{ d, b, a });
    try std.testing.expectEqual(0, registry.sample(d));
    try std.testing.expectEqual(0.5, registry.sample(a));
    try std.testing.expectEqual(0.25, registry.sample(b));
    try std.testing.expectEqual(0, registry.sample(c));
    _ = registry.advance(85);
    try std.testing.expectEqual(0.75, registry.sample(a));
    try std.testing.expectEqual(0.375, registry.sample(b));
    try std.testing.expectEqual(0.25, registry.sample(d));
    try registry.reconcile(&.{c});
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expectEqual(0, registry.sample(c));
    _ = registry.advance(185);
    try std.testing.expectEqual(0.25, registry.sample(c));
    try registry.reconcile(&.{});
    try std.testing.expectEqual(null, registry.delay());
    try registry.reconcile(&.{c});
    _ = registry.advance(285);
    try std.testing.expectEqual(0.25, registry.sample(c));
}

test "each config field restarts and sampling changed or new declarations is read-only" {
    var registry = try Registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const original: Descriptor = .{ .id = 7, .config = .{ .duration_ns = 100 } };
    const replacements = [_]Config{
        .{ .duration_ns = 200 },
        .{ .duration_ns = 100, .easing = .ease_in },
        .{ .duration_ns = 100, .loop = true },
    };
    for (replacements) |config| {
        registry.clear();
        try registry.reconcile(&.{original});
        _ = registry.advance(1000);
        _ = registry.advance(1050);
        const replacement: Descriptor = .{ .id = original.id, .config = config };
        try std.testing.expectEqual(0, registry.sample(replacement));
        try std.testing.expectEqual(0, registry.sample(.{ .id = 8, .config = original.config }));
        try std.testing.expectEqual(1, registry.sample(.{ .id = 7, .config = .{ .duration_ns = 0 } }));
        try std.testing.expectEqual(0.5, registry.sample(original));
        try std.testing.expectEqual(@as(usize, 1), registry.count());
        try registry.reconcile(&.{replacement});
        try std.testing.expectEqual(0, registry.sample(replacement));
        try std.testing.expect(!registry.advance(1050));
        _ = registry.advance(1075);
        const expected: f64 = if (config.duration_ns == 200) 0.125 else if (config.easing == .ease_in) 0.0625 else 0.25;
        try std.testing.expectEqual(expected, registry.sample(replacement));
    }
}

test "validation and failed reconciliation leave tracks and clock unchanged" {
    var registry = try Registry.init(std.testing.allocator, 2);
    defer registry.deinit();
    const a: Descriptor = .{ .id = 1, .config = .{ .duration_ns = 100 } };
    const b: Descriptor = .{ .id = 2, .config = .{ .duration_ns = 200 } };
    const invalid: Descriptor = .{ .id = 3, .config = .{ .duration_ns = 0, .loop = true } };
    const changed: Descriptor = .{ .id = 1, .config = .{ .duration_ns = 400 } };
    try registry.reconcile(&.{ a, b });
    _ = registry.advance(100);
    _ = registry.advance(150);
    try registry.validate(&.{changed});
    try std.testing.expectError(error.AnimationCapacityExceeded, registry.reconcile(&.{ a, b, changed }));
    try std.testing.expectError(error.InvalidAnimationConfig, registry.reconcile(&.{ changed, invalid }));
    try std.testing.expectError(error.DuplicateAnimationId, registry.reconcile(&.{ changed, a }));
    try std.testing.expectEqual(@as(usize, 2), registry.count());
    try std.testing.expectEqual(0.5, registry.sample(a));
    try std.testing.expectEqual(0.25, registry.sample(b));
    try std.testing.expectEqual(@as(?u64, 50), registry.delay());
    _ = registry.advance(175);
    try std.testing.expectEqual(0.75, registry.sample(a));
    try std.testing.expectEqual(0.375, registry.sample(b));
}

test "first advance sets origins clear resets clock and new tracks use the current clock" {
    var registry = try Registry.init(std.testing.allocator, 2);
    defer registry.deinit();
    const a: Descriptor = .{ .id = 1, .config = .{ .duration_ns = 100 } };
    const b: Descriptor = .{ .id = 2, .config = .{ .duration_ns = 200 } };
    try registry.reconcile(&.{a});
    try registry.reconcile(&.{ b, a });
    try std.testing.expectEqual(@as(?u64, 100), registry.delay());
    try std.testing.expect(!registry.advance(9_000_000));
    _ = registry.advance(9_000_025);
    try std.testing.expectEqual(0.25, registry.sample(a));
    try std.testing.expectEqual(0.125, registry.sample(b));
    registry.clear();
    try std.testing.expectEqual(@as(usize, 0), registry.count());
    try std.testing.expectEqual(null, registry.delay());
    try registry.reconcile(&.{a});
    try std.testing.expect(!registry.advance(3));
    _ = registry.advance(28);
    try std.testing.expectEqual(0.25, registry.sample(a));
    try registry.reconcile(&.{ a, b });
    try std.testing.expect(!registry.advance(8));
    _ = registry.advance(78);
    try std.testing.expectEqual(0.75, registry.sample(a));
    try std.testing.expectEqual(0.25, registry.sample(b));

    registry.clear();
    try std.testing.expect(!registry.advance(50));
    try registry.reconcile(&.{a});
    _ = registry.advance(75);
    try std.testing.expectEqual(0.25, registry.sample(a));
}

test "delay selects earliest boundary and caps frame intervals at sixteen milliseconds" {
    const ms = std.time.ns_per_ms;
    var registry = try Registry.init(std.testing.allocator, 2);
    defer registry.deinit();
    const a: Descriptor = .{ .id = 1, .config = .{ .duration_ns = 50 * ms } };
    const b: Descriptor = .{ .id = 2, .config = .{ .duration_ns = 70 * ms, .loop = true } };
    try std.testing.expectEqual(null, registry.delay());
    try registry.reconcile(&.{ a, b });
    try std.testing.expectEqual(@as(?u64, 16 * ms), registry.delay());
    _ = registry.advance(0);
    _ = registry.advance(40 * ms);
    try std.testing.expectEqual(@as(?u64, 10 * ms), registry.delay());
    _ = registry.advance(50 * ms);
    try std.testing.expectEqual(@as(?u64, 16 * ms), registry.delay());
    _ = registry.advance(65 * ms);
    try std.testing.expectEqual(@as(?u64, 5 * ms), registry.delay());
    _ = registry.advance(70 * ms);
    try std.testing.expectEqual(@as(?u64, 16 * ms), registry.delay());
}

test "large timestamps avoid deadline overflow and modulo precedes float conversion" {
    const maximum = std.math.maxInt(u64);
    var registry = try Registry.init(std.testing.allocator, 2);
    defer registry.deinit();
    const a: Descriptor = .{ .id = 1, .config = .{ .duration_ns = 100 } };
    const b: Descriptor = .{ .id = 2, .config = .{ .duration_ns = 200 } };
    _ = registry.advance(maximum - 100);
    try registry.reconcile(&.{ a, b });
    _ = registry.advance(maximum - 25);
    try std.testing.expectEqual(0.75, registry.sample(a));
    try std.testing.expectEqual(0.375, registry.sample(b));
    _ = registry.advance(maximum);
    try std.testing.expectEqual(1, registry.sample(a));
    try std.testing.expectEqual(0.5, registry.sample(b));
    try std.testing.expectEqual(@as(?u64, 100), registry.delay());
    try std.testing.expect(!registry.advance(0));
    try std.testing.expectEqual(0.5, registry.sample(b));

    registry.clear();
    const looping: Descriptor = .{ .id = 3, .config = .{ .duration_ns = 100, .loop = true } };
    const long: Descriptor = .{ .id = 4, .config = .{ .duration_ns = maximum } };
    try registry.reconcile(&.{ looping, long });
    _ = registry.advance(0);
    _ = registry.advance(maximum - 1);
    try std.testing.expectApproxEqAbs(0.14, registry.sample(looping), 1e-12);
    // A rounded f64 sample may reach 1 early; completion must use integer time.
    try std.testing.expectEqual(@as(?u64, 1), registry.delay());
    _ = registry.advance(maximum);
    try std.testing.expectApproxEqAbs(0.15, registry.sample(looping), 1e-12);
    try std.testing.expectEqual(1, registry.sample(long));
    try std.testing.expectEqual(@as(?u64, 85), registry.delay());
}

test "empty capacity is valid and initialization cleans up partial allocation failures" {
    var registry = try Registry.init(std.testing.allocator, 0);
    defer registry.deinit();
    try registry.reconcile(&.{});
    try std.testing.expectEqual(null, registry.delay());
    try std.testing.expect(!registry.advance(100));
    try std.testing.expectError(error.AnimationCapacityExceeded, registry.reconcile(&.{.{ .id = 1, .config = .{ .duration_ns = 1 } }}));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator) !void {
            var allocated = try Registry.init(allocator, 2);
            defer allocated.deinit();
        }
    }.check, .{});
}
