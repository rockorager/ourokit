const std = @import("std");
const Insets = @import("../../core/geometry.zig").Insets;
const SizeF = @import("../../core/geometry.zig").SizeF;

/// Flutter-style one-way box constraints in logical units. Infinity is valid
/// only for maxima. A render object must always return a finite constrained
/// size.
pub const Constraints = struct {
    min_width: f32 = 0,
    max_width: f32 = std.math.inf(f32),
    min_height: f32 = 0,
    max_height: f32 = std.math.inf(f32),

    pub fn tight(size: SizeF) Constraints {
        return .{
            .min_width = size.width,
            .max_width = size.width,
            .min_height = size.height,
            .max_height = size.height,
        };
    }

    pub fn validate(self: Constraints) !void {
        if (!validMinimum(self.min_width) or !validMinimum(self.min_height) or
            !validMaximum(self.max_width) or !validMaximum(self.max_height) or
            self.min_width > self.max_width or self.min_height > self.max_height)
            return error.InvalidConstraints;
    }

    pub fn constrain(self: Constraints, size: SizeF) SizeF {
        return .{
            .width = std.math.clamp(size.width, self.min_width, self.max_width),
            .height = std.math.clamp(size.height, self.min_height, self.max_height),
        };
    }

    pub fn loosen(self: Constraints) Constraints {
        return .{ .max_width = self.max_width, .max_height = self.max_height };
    }

    pub fn deflate(self: Constraints, insets: Insets) Constraints {
        const horizontal = @max(insets.horizontal(), 0);
        const vertical = @max(insets.vertical(), 0);
        return .{
            .min_width = @max(0, self.min_width - horizontal),
            .max_width = @max(0, self.max_width - horizontal),
            .min_height = @max(0, self.min_height - vertical),
            .max_height = @max(0, self.max_height - vertical),
        };
    }

    pub fn hasBoundedWidth(self: Constraints) bool {
        return std.math.isFinite(self.max_width);
    }

    pub fn hasBoundedHeight(self: Constraints) bool {
        return std.math.isFinite(self.max_height);
    }
};

fn validMinimum(value: f32) bool {
    return std.math.isFinite(value) and value >= 0;
}

fn validMaximum(value: f32) bool {
    return !std.math.isNan(value) and value >= 0;
}

test "constraints validate, deflate, and constrain logical sizes" {
    const constraints: Constraints = .{
        .min_width = 10,
        .max_width = 100,
        .min_height = 20,
        .max_height = 80,
    };
    try constraints.validate();
    try std.testing.expectEqual(
        SizeF{ .width = 100, .height = 20 },
        constraints.constrain(.{ .width = 120, .height = 4 }),
    );
    try std.testing.expectEqual(
        Constraints{ .min_width = 4, .max_width = 94, .min_height = 12, .max_height = 72 },
        constraints.deflate(.{ .left = 2, .right = 4, .top = 3, .bottom = 5 }),
    );
    try std.testing.expectError(error.InvalidConstraints, (Constraints{
        .min_width = 20,
        .max_width = 10,
    }).validate());
}
