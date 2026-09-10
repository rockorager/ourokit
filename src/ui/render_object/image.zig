const std = @import("std");
const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const Image = @import("types.zig").Image;

pub fn validate(image: Image) !void {
    inline for (.{ image.width, image.height }) |dimension| {
        if (dimension) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidImageSize;
    }
}

/// Keep the intrinsic ratio when at least one dimension is undeclared. Parent
/// constraints win when their permitted aspect ratios exclude the image ratio.
pub fn layout(image: Image, intrinsic: ?SizeF, constraints: Constraints) SizeF {
    const size = intrinsic orelse return constraints.constrain(.{
        .width = image.width orelse 0,
        .height = image.height orelse 0,
    });
    if (image.width != null and image.height != null)
        return constraints.constrain(.{ .width = image.width.?, .height = image.height.? });

    const width: f64 = size.width;
    const height: f64 = size.height;
    const preferred = if (image.width) |value|
        value / width
    else if (image.height) |value|
        value / height
    else
        1;
    const minimum = @max(constraints.min_width / width, constraints.min_height / height);
    const maximum = @min(constraints.max_width / width, constraints.max_height / height);
    const scale = @min(@max(preferred, minimum), maximum);
    return constraints.constrain(.{
        .width = @floatCast(@min(width * scale, std.math.floatMax(f32))),
        .height = @floatCast(@min(height * scale, std.math.floatMax(f32))),
    });
}

test "image layout preserves declared pending dimensions and zero defaults" {
    try std.testing.expectEqual(SizeF{ .width = 73, .height = 29 }, layout(.{
        .width = 73,
        .height = 29,
    }, null, .{}));
    try std.testing.expectEqual(SizeF{ .width = 0, .height = 29 }, layout(.{ .height = 29 }, null, .{}));
    try std.testing.expectEqual(SizeF{ .width = 0, .height = 0 }, layout(.{}, null, .{}));
    try std.testing.expectEqual(SizeF{ .width = 50, .height = 40 }, layout(.{
        .width = 73,
        .height = 29,
    }, null, .{ .max_width = 50, .min_height = 40 }));
}

test "image layout intrinsic ratio survives one-axis sizing and constraints" {
    const intrinsic: SizeF = .{ .width = 120, .height = 40 };
    const Case = struct { image: Image = .{}, constraints: Constraints = .{}, expected: SizeF };
    const cases = [_]Case{
        .{ .expected = intrinsic },
        .{ .image = .{ .width = 60 }, .expected = .{ .width = 60, .height = 20 } },
        .{ .image = .{ .height = 30 }, .expected = .{ .width = 90, .height = 30 } },
        .{ .image = .{ .width = 60 }, .constraints = .{ .max_height = 10 }, .expected = .{ .width = 30, .height = 10 } },
        .{ .image = .{ .height = 30 }, .constraints = .{ .max_width = 45 }, .expected = .{ .width = 45, .height = 15 } },
        .{ .constraints = .{ .max_width = 90 }, .expected = .{ .width = 90, .height = 30 } },
        .{ .constraints = .{ .min_height = 50 }, .expected = .{ .width = 150, .height = 50 } },
        .{ .constraints = .{ .min_width = 90, .max_height = 20 }, .expected = .{ .width = 90, .height = 20 } },
        .{ .constraints = Constraints.tight(.{ .width = 31, .height = 47 }), .expected = .{ .width = 31, .height = 47 } },
        .{ .image = .{ .width = 71, .height = 19 }, .expected = .{ .width = 71, .height = 19 } },
        .{ .image = .{ .width = 71, .height = 19 }, .constraints = .{ .max_width = 60 }, .expected = .{ .width = 60, .height = 19 } },
        .{ .image = .{ .width = 0 }, .expected = .{ .width = 0, .height = 0 } },
    };
    for (cases) |case| try std.testing.expectEqual(case.expected, layout(case.image, intrinsic, case.constraints));
}

test "image layout rejects negative and nonfinite declarations" {
    try std.testing.expectError(error.InvalidImageSize, validate(.{ .width = -1 }));
    try std.testing.expectError(error.InvalidImageSize, validate(.{ .height = std.math.inf(f32) }));
    try std.testing.expectError(error.InvalidImageSize, validate(.{ .width = std.math.nan(f32) }));
    try validate(.{ .width = 0, .height = 0 });
}
