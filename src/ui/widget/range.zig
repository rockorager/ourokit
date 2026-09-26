const std = @import("std");

/// Bounded, stepped numeric state shared by native value widgets.
///
/// Call `validate` before using the value-transform methods. Transformations
/// return requested values and never mutate the range.
pub const Range = struct {
    value: f64,
    min: f64,
    max: f64,
    step: f64,

    pub fn validate(self: Range) !void {
        if (!std.math.isFinite(self.min) or !std.math.isFinite(self.max) or
            self.min >= self.max)
            return error.InvalidBounds;
        if (!std.math.isFinite(self.value) or self.value < self.min or self.value > self.max)
            return error.InvalidValue;
        if (!std.math.isFinite(self.step) or self.step <= 0)
            return error.InvalidStep;

        const span = self.max - self.min;
        if (!std.math.isFinite(span) or !std.math.isFinite(span / self.step))
            return error.UnrepresentableRange;
    }

    /// Clamp and snap a candidate to steps anchored at `min`.
    pub fn normalize(self: Range, candidate: f64) f64 {
        if (std.math.isNan(candidate)) return self.value;
        if (candidate <= self.min) return self.min;
        if (candidate >= self.max) return self.max;

        const steps = @round((candidate - self.min) / self.step);
        const offset = steps * self.step;
        if (!std.math.isFinite(offset)) return if (steps < 0) self.min else self.max;
        const snapped = self.min + offset;
        if (!std.math.isFinite(snapped)) return if (offset < 0) self.min else self.max;
        return std.math.clamp(snapped, self.min, self.max);
    }

    pub fn fraction(self: Range) f64 {
        return std.math.clamp((self.value - self.min) / (self.max - self.min), 0, 1);
    }

    pub fn atFraction(self: Range, requested: f64) f64 {
        if (std.math.isNan(requested)) return self.normalize(self.value);
        const clamped = std.math.clamp(requested, 0, 1);
        if (clamped == 1) return self.max;
        return self.normalize(self.min + clamped * (self.max - self.min));
    }

    /// Request `delta` steps from the current value without mutating it.
    pub fn increment(self: Range, delta: f64) f64 {
        if (std.math.isNan(delta)) return self.normalize(self.value);
        const offset = delta * self.step;
        if (!std.math.isFinite(offset)) return if (delta < 0) self.min else self.max;
        const candidate = self.value + offset;
        if (!std.math.isFinite(candidate)) return if (offset < 0) self.min else self.max;
        return self.normalize(candidate);
    }
};

test "range snaps fractional steps around an asymmetric negative minimum" {
    const range = Range{ .value = -0.25, .min = -2.25, .max = 3.0, .step = 0.5 };
    try range.validate();
    try std.testing.expectEqual(@as(f64, -1.25), range.normalize(-1.1));
    try std.testing.expectEqual(@as(f64, 0.25), range.increment(1));
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 5.25), range.fraction(), 1e-15);
    try std.testing.expectEqual(@as(f64, -0.25), range.atFraction(0.4));
}

test "range retains an off-grid maximum endpoint and clamps requests" {
    const range = Range{ .value = 0, .min = -1, .max = 1, .step = 0.6 };
    try range.validate();
    try std.testing.expectEqual(@as(f64, 1), range.normalize(1));
    try std.testing.expectEqual(@as(f64, 1), range.atFraction(1));
    try std.testing.expectEqual(@as(f64, -1), range.atFraction(-10));
    try std.testing.expectEqual(@as(f64, 1), range.increment(std.math.inf(f64)));
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), range.normalize(0.3), 1e-15);
}

test "range rejects invalid numbers bounds and unusable arithmetic" {
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    try std.testing.expectError(error.InvalidBounds, (Range{ .value = 0, .min = nan, .max = 1, .step = 1 }).validate());
    try std.testing.expectError(error.InvalidBounds, (Range{ .value = 0, .min = 1, .max = 1, .step = 1 }).validate());
    try std.testing.expectError(error.InvalidValue, (Range{ .value = inf, .min = 0, .max = 1, .step = 1 }).validate());
    try std.testing.expectError(error.InvalidValue, (Range{ .value = 2, .min = 0, .max = 1, .step = 1 }).validate());
    try std.testing.expectError(error.InvalidStep, (Range{ .value = 0, .min = 0, .max = 1, .step = 0 }).validate());
    try std.testing.expectError(error.InvalidStep, (Range{ .value = 0, .min = 0, .max = 1, .step = inf }).validate());
    try std.testing.expectError(error.UnrepresentableRange, (Range{ .value = 0, .min = -1.0e308, .max = 1.0e308, .step = 1 }).validate());
    try std.testing.expectError(error.UnrepresentableRange, (Range{ .value = 0, .min = 0, .max = 1, .step = 1.0e-320 }).validate());
}

test "range transformations do not produce NaN for nonfinite requests" {
    const range = Range{ .value = 0.25, .min = 0, .max = 1, .step = 0.25 };
    try range.validate();
    try std.testing.expectEqual(@as(f64, 0.25), range.normalize(std.math.nan(f64)));
    try std.testing.expectEqual(@as(f64, 0.25), range.atFraction(std.math.nan(f64)));
    try std.testing.expectEqual(@as(f64, 0), range.increment(-std.math.inf(f64)));
}
