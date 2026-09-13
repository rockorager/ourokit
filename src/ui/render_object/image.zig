const std = @import("std");
const SizeF = @import("../../core/geometry.zig").SizeF;
const Constraints = @import("../layout/constraints.zig").Constraints;
const Image = @import("types.zig").Image;

pub fn validate(image: Image) !void {
    inline for (.{ image.width, image.height }) |dimension| {
        if (dimension) |value| if (!std.math.isFinite(value) or value < 0)
            return error.InvalidImageSize;
    }
    if ((image.width != null and image.fill_width) or (image.height != null and image.fill_height))
        return error.ConflictingExtent;
}

/// Keep the intrinsic ratio when at least one dimension is undeclared. Parent
/// constraints win when their permitted aspect ratios exclude the image ratio.
/// Fill resolves bounded axes at layout time; unbounded fill remains intrinsic.
pub fn layout(image: Image, intrinsic: ?SizeF, incoming: Constraints) SizeF {
    var constraints = incoming;
    const declared_width = if (image.fill_width and constraints.hasBoundedWidth()) constraints.max_width else image.width;
    const declared_height = if (image.fill_height and constraints.hasBoundedHeight()) constraints.max_height else image.height;
    if (image.fill_width and constraints.hasBoundedWidth()) constraints.min_width = constraints.max_width;
    if (image.fill_height and constraints.hasBoundedHeight()) constraints.min_height = constraints.max_height;
    const size = intrinsic orelse return constraints.constrain(.{
        .width = declared_width orelse 0,
        .height = declared_height orelse 0,
    });
    if (declared_width != null and declared_height != null)
        return constraints.constrain(.{ .width = declared_width.?, .height = declared_height.? });

    const width: f64 = size.width;
    const height: f64 = size.height;
    const preferred = if (declared_width) |value|
        value / width
    else if (declared_height) |value|
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
    try std.testing.expectError(error.ConflictingExtent, validate(.{ .width = 0, .fill_width = true }));
    try std.testing.expectError(error.ConflictingExtent, validate(.{ .height = 10, .fill_height = true }));
    try validate(.{ .width = 0, .height = 0 });
}

test "image fill resolves each bounded axis for pending and loaded images" {
    const intrinsic: SizeF = .{ .width = 120, .height = 40 };
    const bounds: Constraints = .{ .max_width = 210, .max_height = 95 };
    const both: Image = .{ .fill_width = true, .fill_height = true };
    try std.testing.expectEqual(SizeF{ .width = 210, .height = 95 }, layout(both, null, bounds));
    try std.testing.expectEqual(SizeF{ .width = 210, .height = 95 }, layout(both, intrinsic, bounds));
    try std.testing.expectEqual(SizeF{ .width = 210, .height = 70 }, layout(.{ .fill_width = true }, intrinsic, bounds));
    try std.testing.expectEqual(SizeF{ .width = 210, .height = 23 }, layout(.{ .fill_width = true, .height = 23 }, intrinsic, bounds));
    try std.testing.expectEqual(SizeF{ .width = 17, .height = 95 }, layout(.{ .width = 17, .fill_height = true }, intrinsic, bounds));
    try std.testing.expectEqual(SizeF{ .width = 210, .height = 30 }, layout(.{ .fill_width = true }, intrinsic, .{ .max_width = 210, .max_height = 30 }));
    try std.testing.expectEqual(intrinsic, layout(both, intrinsic, .{}));
    try std.testing.expectEqual(SizeF{ .width = 0, .height = 0 }, layout(both, null, .{}));
    try std.testing.expectEqual(SizeF{ .width = 285, .height = 95 }, layout(both, intrinsic, .{ .max_height = 95 }));
    try std.testing.expectEqual(SizeF{ .width = 0, .height = 0 }, layout(both, intrinsic, Constraints.tight(.{ .width = 0, .height = 0 })));
}
