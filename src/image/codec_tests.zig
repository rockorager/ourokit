const std = @import("std");
const codec = @import("codec.zig");
const Color = @import("../core/color.zig").Color;
const testing = std.testing;
const png = @embedFile("codec_fixtures/rgba.png");
const webp = @embedFile("codec_fixtures/rgba.webp");
const jpeg = @embedFile("codec_fixtures/blocks.jpg");
const animated = @embedFile("codec_fixtures/animated.webp");
const svg =
    \\<svg xmlns="http://www.w3.org/2000/svg" width="3" height="2" viewBox="10 20 3 2">
    \\<path fill="#c76432" fill-opacity="0.5019608" d="M10 20h1v1h-1z"/>
    \\<path fill="#11c85b" d="M11 20h1v1h-1z"/>
    \\<path fill="#ff8040" fill-opacity="0.2509804" d="M10 21h1v1h-1z"/>
    \\<path fill="#0028fa" fill-opacity="0.7843137" d="M11 21h1v1h-1z"/>
    \\<path fill="#5a5046" d="M12 21h1v1h-1z"/></svg>
;
const expected = [_]u8{
    100, 50, 25, 128, 17, 200, 91,  255, 0,  0,  0,  0,
    64,  32, 16, 64,  0,  31,  196, 200, 90, 80, 70, 255,
};

test "codecs decode asymmetric RGBA and premultiply exactly once" {
    for ([_][]const u8{ png, webp, svg }) |encoded| {
        var bitmap = try codec.decode(testing.allocator, encoded, .{});
        defer bitmap.deinit();
        try testing.expectEqual(@as(u32, 3), bitmap.width);
        try testing.expectEqual(@as(u32, 2), bitmap.height);
        try testing.expectEqualSlices(u8, &expected, bitmap.pixels);
    }
}

test "codecs tint uses source alpha not source RGB and includes tint alpha" {
    const tinted = [_]u8{
        50, 25, 13, 64, 100, 50, 25, 128, 0,   0,  0,  0,
        25, 13, 6,  32, 78,  39, 20, 100, 100, 50, 25, 128,
    };
    for ([_][]const u8{ png, webp, svg }) |encoded| {
        var bitmap = try codec.decode(testing.allocator, encoded, .{ .tint = Color.rgba(199, 100, 50, 128) });
        defer bitmap.deinit();
        try testing.expectEqualSlices(u8, &tinted, bitmap.pixels);
    }
}

test "codecs raster sizing stays native while SVG preserves viewport and aspect ratio" {
    for ([_][]const u8{ png, webp }) |encoded| {
        var bitmap = try codec.decode(testing.allocator, encoded, .{ .width = 60, .height = 40 });
        defer bitmap.deinit();
        try testing.expectEqual(@as(u32, 3), bitmap.width);
        try testing.expectEqual(@as(u32, 2), bitmap.height);
    }
    for ([_]codec.Options{ .{ .width = 6 }, .{ .height = 4 } }) |options| {
        var bitmap = try codec.decode(testing.allocator, svg, options);
        defer bitmap.deinit();
        try testing.expectEqual(@as(u32, 6), bitmap.width);
        try testing.expectEqual(@as(u32, 4), bitmap.height);
        try testing.expectEqual(@as(u32, 3), bitmap.intrinsic_width);
        try testing.expectEqual(@as(u32, 2), bitmap.intrinsic_height);
        try testing.expectEqualSlices(u8, expected[0..4], bitmap.pixels[0..4]);
        try testing.expectEqualSlices(u8, expected[4..8], bitmap.pixels[8..12]);
    }
    var sized = try codec.decode(testing.allocator, svg, .{ .width = 6, .height = 8 });
    defer sized.deinit();
    try testing.expectEqual(@as(u32, 12), sized.width);
    try testing.expectEqual(@as(u32, 8), sized.height);
    try testing.expectEqualSlices(u8, expected[0..4], sized.pixels[0..4]);
    try testing.expectEqualSlices(u8, expected[20..24], sized.pixels[sized.pixels.len - 4 ..]);
    try testing.expectError(error.ImageTooLarge, codec.decode(testing.failing_allocator, svg, .{ .width = 6, .height = 8, .max_dimension = 8 }));
}

test "codecs SVG fallback scale preserves intrinsic size and explicit hints are already physical" {
    var scaled = try codec.decode(testing.allocator, svg, .{ .scale = 2.5 });
    defer scaled.deinit();
    try testing.expectEqual(@as(u32, 8), scaled.width);
    try testing.expectEqual(@as(u32, 5), scaled.height);
    try testing.expectEqual(@as(u32, 3), scaled.intrinsic_width);
    try testing.expectEqual(@as(u32, 2), scaled.intrinsic_height);
    var explicit = try codec.decode(testing.allocator, svg, .{ .width = 6, .scale = 2.5 });
    defer explicit.deinit();
    try testing.expectEqual(@as(u32, 6), explicit.width);
    try testing.expectEqual(@as(u32, 4), explicit.height);
    for ([_]f32{ 0, -1, std.math.inf(f32), std.math.nan(f32) }) |scale| {
        try testing.expectError(error.InvalidDimensions, codec.decode(testing.failing_allocator, svg, .{ .scale = scale }));
    }
}

test "codecs animated WebP decodes only first frame at its canvas offset" {
    var bitmap = try codec.decode(testing.allocator, animated, .{});
    defer bitmap.deinit();
    try testing.expectEqual(@as(u32, 6), bitmap.width);
    try testing.expectEqual(@as(u32, 4), bitmap.height);
    for (0..4) |y| {
        for (0..6) |x| {
            const want: []const u8 = if (x >= 2 and x < 5 and y >= 2) expected[((y - 2) * 3 + x - 2) * 4 ..][0..4] else &.{ 0, 0, 0, 0 };
            try testing.expectEqualSlices(u8, want, bitmap.pixels[(y * 6 + x) * 4 ..][0..4]);
        }
    }
}

test "codecs lossy WebP VP8 retains asymmetric block colors" {
    var bitmap = try codec.decode(testing.allocator, @embedFile("codec_fixtures/blocks.webp"), .{});
    defer bitmap.deinit();
    try testing.expectEqual(@as(u32, 24), bitmap.width);
    try testing.expectEqual(@as(u32, 16), bitmap.height);
    const colors = [_][3]u8{ .{ 230, 20, 40 }, .{ 30, 210, 60 }, .{ 40, 70, 220 }, .{ 210, 190, 20 }, .{ 200, 30, 180 }, .{ 20, 190, 200 } };
    for (colors, 0..) |color, block| {
        const x = (block % 3) * 8 + 4;
        const y = (block / 3) * 8 + 4;
        const pixel = bitmap.pixels[(y * 24 + x) * 4 ..][0..4];
        for (color, pixel[0..3]) |want, got| try testing.expect(@abs(@as(i16, want) - got) <= 12);
        try testing.expectEqual(@as(u8, 255), pixel[3]);
    }
}

fn exifJpeg(orientation: u16, endian: std.builtin.Endian) ![]u8 {
    const bytes = try testing.allocator.alloc(u8, jpeg.len + 36);
    bytes[0..2].* = .{ 0xff, 0xd8 };
    bytes[2..6].* = .{ 0xff, 0xe1, 0, 34 };
    @memcpy(bytes[6..12], "Exif\x00\x00");
    const tiff = bytes[12..38];
    @memset(tiff, 0);
    @memcpy(tiff[0..2], if (endian == .little) "II" else "MM");
    std.mem.writeInt(u16, tiff[2..4], 42, endian);
    std.mem.writeInt(u32, tiff[4..8], 8, endian);
    std.mem.writeInt(u16, tiff[8..10], 1, endian);
    std.mem.writeInt(u16, tiff[10..12], 0x112, endian);
    std.mem.writeInt(u16, tiff[12..14], 3, endian);
    std.mem.writeInt(u32, tiff[14..18], 1, endian);
    std.mem.writeInt(u16, tiff[18..20], orientation, endian);
    @memcpy(bytes[38..], jpeg[2..]);
    return bytes;
}

test "codecs JPEG applies all eight EXIF orientations in either byte order" {
    const colors = [_][3]u8{ .{ 230, 20, 40 }, .{ 30, 210, 60 }, .{ 40, 70, 220 }, .{ 210, 190, 20 }, .{ 200, 30, 180 }, .{ 20, 190, 200 } };
    // Expected block order, manually enumerated independently of orient().
    const orders = [_][6]u8{
        .{ 0, 1, 2, 3, 4, 5 }, .{ 2, 1, 0, 5, 4, 3 },
        .{ 5, 4, 3, 2, 1, 0 }, .{ 3, 4, 5, 0, 1, 2 },
        .{ 0, 3, 1, 4, 2, 5 }, .{ 3, 0, 4, 1, 5, 2 },
        .{ 5, 2, 4, 1, 3, 0 }, .{ 2, 5, 1, 4, 0, 3 },
    };
    for ([_]std.builtin.Endian{ .big, .little }) |endian| {
        for (orders, 1..) |order, orientation| {
            const encoded = try exifJpeg(@intCast(orientation), endian);
            defer testing.allocator.free(encoded);
            var bitmap = try codec.decode(testing.allocator, encoded, .{ .width = 1, .height = 1 });
            defer bitmap.deinit();
            const width: u32 = if (orientation < 5) 24 else 16;
            const height: u32 = if (orientation < 5) 16 else 24;
            try testing.expectEqual(width, bitmap.width);
            try testing.expectEqual(height, bitmap.height);
            try testing.expectEqual(width, bitmap.intrinsic_width);
            try testing.expectEqual(height, bitmap.intrinsic_height);
            for (order, 0..) |index, block| {
                const x = (block % (width / 8)) * 8 + 4;
                const y = (block / (width / 8)) * 8 + 4;
                const pixel = bitmap.pixels[(y * width + x) * 4 ..][0..4];
                for (colors[index], pixel[0..3]) |want, got| try testing.expect(@abs(@as(i16, want) - got) <= 3);
                try testing.expectEqual(@as(u8, 255), pixel[3]);
            }
        }
    }
}

test "codecs ignore malformed EXIF offsets without losing the JPEG" {
    const encoded = try exifJpeg(6, .big);
    defer testing.allocator.free(encoded);
    @memset(encoded[16..20], 0xff);
    var bitmap = try codec.decode(testing.allocator, encoded, .{});
    defer bitmap.deinit();
    try testing.expectEqual(@as(u32, 24), bitmap.width);
    try testing.expectEqual(@as(u32, 16), bitmap.height);
}

test "codecs enforce dimension and byte boundaries before output allocation" {
    for ([_][]const u8{ png, webp, svg }) |encoded| {
        var bitmap = try codec.decode(testing.allocator, encoded, .{ .max_dimension = 3, .max_decoded_bytes = 24 });
        defer bitmap.deinit();
        try testing.expectError(error.ImageTooLarge, codec.decode(testing.failing_allocator, encoded, .{ .max_dimension = 2 }));
        try testing.expectError(error.ImageTooLarge, codec.decode(testing.failing_allocator, encoded, .{ .max_decoded_bytes = 23 }));
        try testing.expectError(error.OutOfMemory, codec.decode(testing.failing_allocator, encoded, .{}));
    }
    try testing.expectError(error.InvalidDimensions, codec.decode(testing.failing_allocator, svg, .{ .width = 0, .height = 2 }));
    try testing.expectError(error.ImageTooLarge, codec.decode(testing.failing_allocator, svg, .{ .width = 8193 }));
    try testing.expectError(error.ImageTooLarge, codec.decode(testing.failing_allocator, svg, .{ .width = 0xffffffff, .height = 0xffffffff, .max_dimension = 0xffffffff, .max_decoded_bytes = std.math.maxInt(usize) }));
    const huge = "<svg xmlns='http://www.w3.org/2000/svg' width='1000000000' height='2'/>";
    try testing.expectError(error.ImageTooLarge, codec.decode(testing.failing_allocator, huge, .{ .width = 1, .height = 1 }));
}

test "codecs reject invalid and truncated data" {
    for ([_][]const u8{ "", "not an image", "<svg", png[0..24], webp[0..24], jpeg[0..24], animated[0..24] }) |encoded| {
        try testing.expectError(error.InvalidImage, codec.decode(testing.allocator, encoded, .{}));
    }
    // Header is valid; the failure happens after allocation while decoding IDAT.
    var corrupt = png.*;
    corrupt[41] ^= 0xff;
    try testing.expectError(error.InvalidImage, codec.decode(testing.allocator, &corrupt, .{}));
}

test "codecs SVG disables image resources and text but keeps local fragments" {
    const references =
        \\<svg xmlns="http://www.w3.org/2000/svg" width="4" height="2">
        \\<image href="src/image/codec_fixtures/external.svg" width="4" height="2"/>
        \\<image href="https://example.invalid/image.png" width="4" height="2"/>
        \\<image href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='4' height='2'%3E%3Cpath fill='red' d='M0 0h4v2H0z'/%3E%3C/svg%3E" width="4" height="2"/>
        \\<text x="0" y="2" font-size="2">X</text>
        \\<defs><path id="shape" fill="#123456" d="M0 0h1v1H0z"/></defs>
        \\<use href="#shape" x="3" y="1"/></svg>
    ;
    var bitmap = try codec.decode(testing.allocator, references, .{});
    defer bitmap.deinit();
    try testing.expect(std.mem.allEqual(u8, bitmap.pixels[0..28], 0));
    try testing.expectEqualSlices(u8, &.{ 18, 52, 86, 255 }, bitmap.pixels[28..32]);
}

test "codecs free allocator buffers on orientation allocation failure" {
    const encoded = try exifJpeg(6, .little);
    defer testing.allocator.free(encoded);
    try testing.checkAllAllocationFailures(testing.allocator, decodeAndFree, .{encoded});
}

fn decodeAndFree(allocator: std.mem.Allocator, encoded: []const u8) !void {
    var bitmap = try codec.decode(allocator, encoded, .{});
    defer bitmap.deinit();
}
