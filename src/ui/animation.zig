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

/// Damped oscillator in seconds. Absolute-time evaluation avoids integration
/// drift and makes skipped frames equivalent to densely sampled frames.
pub const Spring = struct {
    mass: f64 = 1,
    stiffness: f64 = 170,
    damping: f64 = 26,

    pub fn validate(self: Spring) !void {
        inline for (.{ self.mass, self.stiffness, self.damping }) |value| {
            if (!std.math.isFinite(value) or value < 1e-6 or value > 1e6) return error.InvalidSpringConfig;
        }
    }

    fn sample(self: Spring, x: f64, velocity: f64, seconds: f64) struct { displacement: f64, velocity: f64 } {
        if (seconds == 0) return .{ .displacement = x, .velocity = velocity };
        const a = self.damping / (2 * self.mass);
        const w2 = self.stiffness / self.mass;
        const difference = a * a - w2;
        if (@abs(difference) <= 1e-10 * w2) {
            const b = velocity + a * x;
            const decay = @exp(-a * seconds);
            return .{ .displacement = decay * (x + b * seconds), .velocity = decay * (velocity - a * b * seconds) };
        }
        if (difference < 0) {
            const w = @sqrt(-difference);
            const sine = @sin(w * seconds);
            const cosine = @cos(w * seconds);
            const b = (velocity + a * x) / w;
            const decay = @exp(-a * seconds);
            return .{ .displacement = decay * (x * cosine + b * sine), .velocity = decay * (velocity * cosine - (a * b + w * x) * sine) };
        }
        const q = @sqrt(difference);
        const fast = -a - q;
        const slow = -w2 / (a + q); // Avoid cancellation in -a+q.
        const b = (velocity - fast * x) / (slow - fast);
        const slow_part = b * @exp(slow * seconds);
        const fast_part = (x - b) * @exp(fast * seconds);
        return .{ .displacement = slow_part + fast_part, .velocity = slow * slow_part + fast * fast_part };
    }
};

const spring_deadline_ns = 10 * std.time.ns_per_s;

pub const Config = struct {
    duration_ns: u64 = 0,
    easing: Easing = .linear,
    loop: bool = false,
    spring: ?Spring = null,
    reduced_motion: bool = false,

    pub fn validate(self: Config) !void {
        if (self.duration_ns == 0 and self.loop) return error.InvalidAnimationConfig;
        if (self.spring) |spring| {
            try spring.validate();
            if (self.duration_ns != 0 or self.easing != .linear or self.loop) return error.InvalidSpringConfig;
        }
    }

    fn instant(self: Config) bool {
        return self.reduced_motion or (self.spring == null and self.duration_ns == 0);
    }

    fn initial(self: Config) f64 {
        return if (self.instant()) 1 else 0;
    }
};

pub const Descriptor = struct {
    id: u64,
    config: Config,
    transition: ?struct { target: f64, initial: ?f64 = null } = null,

    pub fn validate(self: Descriptor) !void {
        try self.config.validate();
        if (self.transition) |transition| {
            if (self.config.loop or !std.math.isFinite(transition.target) or
                (transition.initial != null and !std.math.isFinite(transition.initial.?)))
                return error.InvalidTransitionConfig;
            if (self.config.spring != null and (@abs(transition.target) > 1e12 or
                (transition.initial != null and @abs(transition.initial.?) > 1e12))) return error.InvalidSpringConfig;
        } else if (self.config.spring != null) return error.InvalidSpringConfig;
    }

    pub fn initial(self: Descriptor) f64 {
        if (self.transition) |transition|
            return if (self.config.instant()) transition.target else transition.initial orelse transition.target;
        return self.config.initial();
    }
};

const Track = struct {
    descriptor: Descriptor,
    origin_ns: ?u64,
    value: f64,
    from: f64,
    presented: f64,
    velocity: f64 = 0,
    from_velocity: f64 = 0,
    presented_velocity: f64 = 0,
    settled: bool = false,

    fn elapsed(self: Track, clock_ns: ?u64) u64 {
        const origin = self.origin_ns orelse return 0;
        return clock_ns.? - origin;
    }
};

/// Keyed duration and spring timelines. The caller owns time and schedules wakeups
/// using delay(); this registry owns no callbacks, UI instances, or resources.
/// Storage grows in validate, never in reconcile. Reconciliation and lookup are quadratic and linear
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
    pub fn validate(self: *Registry, descriptors: []const Descriptor) !void {
        if (descriptors.len > self.tracks.len) {
            const len = @max(descriptors.len, self.tracks.len * 2);
            self.tracks = try self.allocator.realloc(self.tracks, len);
            self.scratch = try self.allocator.realloc(self.scratch, len);
        }
        for (descriptors, 0..) |descriptor, i| {
            try descriptor.validate();
            if (descriptor.config.spring != null and @abs(self.preview(descriptor).from) > 1e12)
                return error.InvalidSpringConfig;
            for (descriptors[0..i]) |previous| {
                if (previous.id == descriptor.id) return error.DuplicateAnimationId;
            }
        }
    }

    /// Commits a complete declaration. An unchanged id and config retain their
    /// origin and sampled value regardless of order. Transitions retarget from
    /// the last committed output; unpublished clock samples never cause a jump.
    /// New tracks start at the current clock, or at the first advance.
    pub fn reconcile(self: *Registry, descriptors: []const Descriptor) !void {
        try self.validate(descriptors);
        for (descriptors, 0..) |descriptor, i| {
            self.scratch[i] = self.preview(descriptor);
            self.scratch[i].presented = self.scratch[i].value;
            self.scratch[i].presented_velocity = self.scratch[i].velocity;
        }
        std.mem.swap([]Track, &self.tracks, &self.scratch);
        self.len = descriptors.len;
    }

    /// Read-only preview for a declaration, including one not yet reconciled.
    /// The preview is exactly what reconcile will commit, without mutating a
    /// live track when a candidate build fails.
    pub fn sample(self: *const Registry, descriptor: Descriptor) f64 {
        return self.preview(descriptor).value;
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
            if (config.spring) |spring| {
                if (track.settled) continue;
                const target = track.descriptor.transition.?.target;
                const state = spring.sample(track.from - target, track.from_velocity, @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s);
                track.settled = config.reduced_motion or elapsed >= spring_deadline_ns or
                    (@abs(state.displacement) <= 0.0001 and @abs(state.velocity) <= 0.001);
                const value = if (track.settled) target else target + state.displacement;
                // Velocity changes must be committed even on a turning-point
                // sample whose position happens to equal the previous one.
                const velocity = if (track.settled) 0 else state.velocity;
                changed = changed or value != track.value or velocity != track.velocity;
                track.value = value;
                track.velocity = velocity;
                continue;
            }
            const progress: f64 = if (config.instant() or
                (!config.loop and elapsed >= config.duration_ns)) 1 else progress: {
                const phase = if (config.loop) elapsed % config.duration_ns else elapsed;
                const fraction = @as(f64, @floatFromInt(phase)) /
                    @as(f64, @floatFromInt(config.duration_ns));
                break :progress config.easing.apply(fraction);
            };
            const value = if (track.descriptor.transition) |transition| value: {
                if (progress == 1) break :value transition.target;
                if (progress == 0 or track.from == transition.target) break :value track.from;
                // Opposite-sign endpoints can overflow target-from. Same-sign
                // endpoints use a bounded difference to avoid weighted-sum overflow.
                break :value if ((track.from < 0) != (transition.target < 0))
                    track.from * (1 - progress) + transition.target * progress
                else
                    track.from + (transition.target - track.from) * progress;
            } else progress;
            changed = changed or value != track.value;
            track.value = value;
        }
        return changed;
    }

    /// Earliest wakeup: at most 16 ms, shortened to a completion or loop boundary.
    /// Completed oneshots (including zero-duration oneshots) request no work.
    pub fn delay(self: *const Registry) ?u64 {
        var result: ?u64 = null;
        for (self.tracks[0..self.len]) |track| {
            const config = track.descriptor.config;
            if (config.reduced_motion) continue;
            if (config.spring != null) {
                if (track.settled) continue;
                const next = @min(16 * std.time.ns_per_ms, spring_deadline_ns -| track.elapsed(self.clock_ns));
                result = @min(result orelse next, next);
                continue;
            }
            if (track.descriptor.transition) |transition| if (track.from == transition.target) continue;
            const elapsed = track.elapsed(self.clock_ns);
            if (config.duration_ns == 0 or (!config.loop and elapsed >= config.duration_ns)) continue;
            const phase = if (config.loop) elapsed % config.duration_ns else elapsed;
            const remaining = config.duration_ns - phase;
            const next = @min(16 * std.time.ns_per_ms, remaining);
            result = @min(result orelse next, next);
        }
        return result;
    }

    fn preview(self: *const Registry, descriptor: Descriptor) Track {
        var from = descriptor.initial();
        var velocity: f64 = 0;
        for (self.tracks[0..self.len]) |*track| {
            if (track.descriptor.id != descriptor.id) continue;
            if (descriptor.transition) |transition| {
                if (track.descriptor.transition) |previous| {
                    if (previous.target == transition.target and std.meta.eql(track.descriptor.config, descriptor.config)) {
                        var retained = track.*;
                        retained.descriptor = descriptor; // initial is mount-only.
                        return retained;
                    }
                    from = track.presented;
                    if (descriptor.config.spring != null and track.descriptor.config.spring != null)
                        velocity = track.presented_velocity;
                }
            } else if (std.meta.eql(track.descriptor, descriptor)) return track.*;
            break;
        }
        if (descriptor.config.instant()) {
            from = descriptor.initial();
            velocity = 0;
        }
        return .{
            .descriptor = descriptor,
            .origin_ns = self.clock_ns,
            .value = from,
            .from = from,
            .presented = from,
            .velocity = velocity,
            .from_velocity = velocity,
            .presented_velocity = velocity,
            .settled = if (descriptor.transition) |transition| from == transition.target and velocity == 0 else false,
        };
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
    // Validation grows storage but leaves tracks and clock alone.
    try registry.validate(&.{ a, b, .{ .id = 4, .config = .{ .duration_ns = 1 } } });
    try std.testing.expect(registry.tracks.len >= 3);
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

test "transition reversals start at committed values and retain full duration" {
    var registry = try Registry.init(std.testing.allocator, 2);
    defer registry.deinit();
    var motion: Descriptor = .{ .id = 1, .config = .{ .duration_ns = 100 }, .transition = .{ .target = 90, .initial = 10 } };
    const peer: Descriptor = .{ .id = 2, .config = .{ .duration_ns = 200 }, .transition = .{ .target = -30 } };
    try registry.reconcile(&.{ motion, peer });
    _ = registry.advance(1000);
    _ = registry.advance(1025);
    try std.testing.expectEqual(30, registry.sample(motion));
    try registry.reconcile(&.{ peer, motion }); // Publish 30, retaining origins.
    _ = registry.advance(1040); // 42 has not reached a committed UI build.
    try std.testing.expectEqual(42, registry.sample(motion));
    motion.transition.?.target = -10;
    try std.testing.expectEqual(30, registry.sample(motion));
    try registry.reconcile(&.{ motion, peer });
    try std.testing.expect(!registry.advance(1040));
    _ = registry.advance(1065);
    try std.testing.expectEqual(20, registry.sample(motion));
    try registry.reconcile(&.{ motion, peer });
    motion.transition.?.target = 60;
    try std.testing.expectEqual(20, registry.sample(motion));
    try registry.reconcile(&.{ motion, peer });
    _ = registry.advance(1090);
    try std.testing.expectEqual(30, registry.sample(motion));
    // Updating mount-only initial and rebuilding must not restart the interval.
    motion.transition.?.initial = -900;
    try registry.reconcile(&.{ motion, peer });
    _ = registry.advance(1164);
    try std.testing.expectApproxEqAbs(59.6, registry.sample(motion), 1e-12);
    try std.testing.expectEqual(@as(?u64, 1), registry.delay());
    _ = registry.advance(1165);
    try std.testing.expectEqual(60, registry.sample(motion));
    try std.testing.expectEqual(-30, registry.sample(peer));
    try std.testing.expectEqual(null, registry.delay());
    try std.testing.expect(!registry.advance(9000));
}

test "transition config changes retarget while instant equal and removed tracks stay idle" {
    var registry = try Registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    var motion: Descriptor = .{ .id = 1, .config = .{ .duration_ns = 100 }, .transition = .{ .target = 80 } };
    try registry.reconcile(&.{motion});
    try std.testing.expectEqual(80, registry.sample(motion));
    try std.testing.expectEqual(null, registry.delay());
    _ = registry.advance(0);
    motion.transition.?.target = 0;
    try registry.reconcile(&.{motion});
    _ = registry.advance(25);
    try registry.reconcile(&.{motion});
    try std.testing.expectEqual(60, registry.sample(motion));
    motion.config = .{ .duration_ns = 200, .easing = .ease_in };
    try registry.reconcile(&.{motion});
    _ = registry.advance(75);
    try std.testing.expectEqual(56.25, registry.sample(motion));
    try registry.reconcile(&.{motion});
    motion.transition.?.target = 56.25;
    try registry.reconcile(&.{motion});
    try std.testing.expectEqual(null, registry.delay());
    motion.transition.?.target = 123;
    motion.config.duration_ns = 0;
    try std.testing.expectEqual(123, registry.sample(motion));
    try registry.reconcile(&.{motion});
    try std.testing.expectEqual(null, registry.delay());
    try registry.reconcile(&.{});
    motion.config.duration_ns = 100;
    motion.transition.?.initial = 3;
    try registry.reconcile(&.{motion});
    try std.testing.expectEqual(3, registry.sample(motion));
    _ = registry.advance(100);
    try std.testing.expectEqual(10.5, registry.sample(motion)); // Retained quadratic easing at 1/4.
    registry.clear(); // Accepted reload resets, unlike ordinary rebuilds.
    try registry.reconcile(&.{motion});
    try std.testing.expectEqual(3, registry.sample(motion));
    _ = registry.advance(2000);
    try std.testing.expectEqual(3, registry.sample(motion));
}

test "transition preview and rejected declarations cannot retarget live tracks" {
    var registry = try Registry.init(std.testing.allocator, 2);
    defer registry.deinit();
    const original: Descriptor = .{ .id = 1, .config = .{ .duration_ns = 100 }, .transition = .{ .target = 40, .initial = -20 } };
    try registry.reconcile(&.{original});
    _ = registry.advance(0);
    _ = registry.advance(25);
    try registry.reconcile(&.{original});
    var replacement = original;
    replacement.transition.?.target = 100;
    try std.testing.expectEqual(-5, registry.sample(replacement));
    var invalid = replacement;
    invalid.id = 2;
    invalid.transition.?.target = std.math.nan(f64);
    try std.testing.expectError(error.InvalidTransitionConfig, registry.reconcile(&.{ replacement, invalid }));
    try std.testing.expectError(error.DuplicateAnimationId, registry.reconcile(&.{ replacement, original }));
    for ([_]f64{ std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) }) |bad| {
        invalid.transition = .{ .target = bad };
        try std.testing.expectError(error.InvalidTransitionConfig, invalid.validate());
        invalid.transition = .{ .target = 1, .initial = bad };
        try std.testing.expectError(error.InvalidTransitionConfig, invalid.validate());
    }
    invalid.transition = .{ .target = 0 };
    invalid.config.loop = true;
    try std.testing.expectError(error.InvalidTransitionConfig, invalid.validate());
    _ = registry.advance(50);
    try std.testing.expectEqual(10, registry.sample(original));
    try std.testing.expectEqual(@as(?u64, 50), registry.delay());
}

test "transition interpolation remains finite for extreme endpoints" {
    var registry = try Registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    const maximum = std.math.floatMax(f64);
    const motion: Descriptor = .{ .id = 1, .config = .{ .duration_ns = 100 }, .transition = .{ .target = maximum, .initial = -maximum } };
    try registry.reconcile(&.{motion});
    _ = registry.advance(0);
    _ = registry.advance(25);
    try std.testing.expectApproxEqRel(-maximum / 2, registry.sample(motion), 1e-15);
    _ = registry.advance(50);
    try std.testing.expectEqual(0, registry.sample(motion));
    _ = registry.advance(75);
    try std.testing.expectApproxEqRel(maximum / 2, registry.sample(motion), 1e-15);
    _ = registry.advance(100);
    try std.testing.expectEqual(maximum, registry.sample(motion));
}

test "empty capacity is valid and initialization cleans up partial allocation failures" {
    var registry = try Registry.init(std.testing.allocator, 0);
    defer registry.deinit();
    try registry.reconcile(&.{});
    try std.testing.expectEqual(null, registry.delay());
    try std.testing.expect(!registry.advance(100));
    try registry.reconcile(&.{.{ .id = 1, .config = .{ .duration_ns = 1 } }});
    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator) !void {
            var allocated = try Registry.init(allocator, 2);
            defer allocated.deinit();
        }
    }.check, .{});
}

test "spring analytic samples under critical and over damping with nonzero velocity" {
    // Independent closed forms: e^-t(2 cos(t)+sin(t)),
    // e^-2t(3+7t), and 3e^-t-e^-2t respectively.
    const half_pi: f64 = std.math.pi / 2.0;
    const under = (Spring{ .mass = 1, .stiffness = 2, .damping = 2 }).sample(2, -1, half_pi);
    try std.testing.expectApproxEqAbs(@exp(-half_pi), under.displacement, 1e-12);
    try std.testing.expectApproxEqAbs(-3 * @exp(-half_pi), under.velocity, 1e-12);
    const critical = (Spring{ .mass = 1, .stiffness = 4, .damping = 4 }).sample(3, 1, 0.5);
    try std.testing.expectApproxEqAbs(6.5 / std.math.e, critical.displacement, 1e-12);
    try std.testing.expectApproxEqAbs(-6.0 / std.math.e, critical.velocity, 1e-12);
    const over = (Spring{ .mass = 1, .stiffness = 2, .damping = 3 }).sample(2, -1, @log(@as(f64, 2)));
    try std.testing.expectApproxEqAbs(1.25, over.displacement, 1e-12);
    try std.testing.expectApproxEqAbs(-1, over.velocity, 1e-12);
}

test "spring retarget retains committed velocity ignores unpublished samples and converges exactly" {
    const ms = std.time.ns_per_ms;
    var registry = try Registry.init(std.testing.allocator, 2);
    defer registry.deinit();
    var motion: Descriptor = .{ .id = 1, .config = .{ .spring = .{ .stiffness = 2, .damping = 2 } }, .transition = .{ .target = 1, .initial = 0 } };
    try registry.reconcile(&.{motion});
    _ = registry.advance(0);
    _ = registry.advance(500 * ms);
    // Unit step response 1-e^-t(cos(t)+sin(t)), velocity 2e^-t sin(t).
    const position = 1 - @exp(@as(f64, -0.5)) * (@cos(@as(f64, 0.5)) + @sin(@as(f64, 0.5)));
    const speed = 2 * @exp(@as(f64, -0.5)) * @sin(@as(f64, 0.5));
    try std.testing.expectApproxEqAbs(position, registry.sample(motion), 1e-12);
    try registry.reconcile(&.{motion});
    _ = registry.advance(800 * ms); // Not committed.
    motion.transition.?.target = -1;
    try std.testing.expectApproxEqAbs(position, registry.sample(motion), 1e-12);
    const rejected = registry.tracks[0];
    try std.testing.expectError(error.DuplicateAnimationId, registry.validate(&.{ motion, motion }));
    try std.testing.expectEqualDeep(rejected, registry.tracks[0]);
    try registry.reconcile(&.{motion});
    try std.testing.expectApproxEqAbs(speed, registry.tracks[0].velocity, 1e-12);
    _ = registry.advance(801 * ms);
    try std.testing.expect(registry.sample(motion) > position); // Still moving right.
    _ = registry.advance(1800 * ms);
    const x = position + 1;
    const expected = -1 + @exp(@as(f64, -1)) * (x * @cos(@as(f64, 1)) + (speed + x) * @sin(@as(f64, 1)));
    try std.testing.expectApproxEqAbs(expected, registry.sample(motion), 1e-12);
    _ = registry.advance(10_800 * ms);
    try std.testing.expectEqual(-1, registry.sample(motion));
    try std.testing.expectEqual(null, registry.delay());

    registry.clear();
    motion.config.spring = .{};
    try registry.reconcile(&.{motion});
    _ = registry.advance(0);
    _ = registry.advance(2000 * ms);
    try std.testing.expectEqual(-1, registry.sample(motion));
    try std.testing.expectEqual(null, registry.delay()); // Tolerance, before cap.
}

test "spring bounds reject nonfinite parameters and unsafe duration to spring conversion" {
    var registry = try Registry.init(std.testing.allocator, 1);
    defer registry.deinit();
    var motion: Descriptor = .{ .id = 1, .config = .{}, .transition = .{ .target = 1e100 } };
    try registry.reconcile(&.{motion});
    motion.config.spring = .{};
    motion.transition.?.target = 1;
    try std.testing.expectError(error.InvalidSpringConfig, registry.reconcile(&.{motion}));
    inline for (std.meta.fields(Spring)) |field| {
        for ([_]f64{ 0, -1, 1e-7, 1e7, std.math.inf(f64), std.math.nan(f64) }) |bad| {
            var spring: Spring = .{};
            @field(spring, field.name) = bad;
            try std.testing.expectError(error.InvalidSpringConfig, spring.validate());
        }
    }
    // Extreme accepted parameters must also produce finite samples.
    for ([_]f64{ 1e-6, 1e6 }) |mass| for ([_]f64{ 1e-6, 1e6 }) |stiffness| for ([_]f64{ 1e-6, 1e6 }) |damping| {
        const state = (Spring{ .mass = mass, .stiffness = stiffness, .damping = damping }).sample(-1e12, 1e12, 0.13);
        try std.testing.expect(std.math.isFinite(state.displacement) and std.math.isFinite(state.velocity));
    };
}

test "reduced motion settles springs and loops immediately and full restores only loops" {
    var registry = try Registry.init(std.testing.allocator, 2);
    defer registry.deinit();
    var spring: Descriptor = .{ .id = 1, .config = .{ .spring = .{} }, .transition = .{ .target = 1, .initial = 0 } };
    var loop: Descriptor = .{ .id = 2, .config = .{ .duration_ns = 100, .loop = true } };
    try registry.reconcile(&.{ spring, loop });
    _ = registry.advance(0);
    _ = registry.advance(25);
    try registry.reconcile(&.{ spring, loop });
    spring.config.reduced_motion = true;
    loop.config.reduced_motion = true;
    try registry.reconcile(&.{ spring, loop });
    try std.testing.expectEqual(1, registry.sample(spring));
    try std.testing.expectEqual(1, registry.sample(loop));
    try std.testing.expectEqual(null, registry.delay());
    try std.testing.expect(!registry.advance(999));
    spring.config.reduced_motion = false;
    loop.config.reduced_motion = false;
    try registry.reconcile(&.{ spring, loop });
    try std.testing.expectEqual(1, registry.sample(spring));
    try std.testing.expectEqual(0, registry.sample(loop));
    _ = registry.advance(1024);
    try std.testing.expectEqual(0.25, registry.sample(loop));
}
