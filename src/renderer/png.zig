const std = @import("std");

pub const EncodeError = std.mem.Allocator.Error || error{
    InvalidDimensions,
    InvalidStride,
    InvalidBufferLength,
    ImageTooLarge,
};

const signature = "\x89PNG\r\n\x1a\n";

/// Encodes straight (not premultiplied) RGBA8 pixels as a deterministic PNG.
/// The returned bytes belong to `allocator`.
pub fn encode(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    width: usize,
    height: usize,
    stride: usize,
) EncodeError![]u8 {
    if (width == 0 or height == 0 or width > std.math.maxInt(u32) or height > std.math.maxInt(u32))
        return error.InvalidDimensions;

    const row_bytes = std.math.mul(usize, width, 4) catch return error.ImageTooLarge;
    if (stride < row_bytes) return error.InvalidStride;
    const last_row = std.math.mul(usize, height - 1, stride) catch return error.ImageTooLarge;
    const required = std.math.add(usize, last_row, row_bytes) catch return error.ImageTooLarge;
    if (rgba.len < required) return error.InvalidBufferLength;

    const filtered_row = std.math.add(usize, row_bytes, 1) catch return error.ImageTooLarge;
    const raw_len = std.math.mul(usize, height, filtered_row) catch return error.ImageTooLarge;
    if (raw_len > std.math.maxInt(u32)) return error.ImageTooLarge;

    var output = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer output.deinit();
    var compressor_buffer: [std.compress.flate.max_window_len * 2]u8 = undefined;
    var compressor = std.compress.flate.Compress.init(
        &output.writer,
        &compressor_buffer,
        .zlib,
        .default,
    ) catch return error.OutOfMemory;
    for (0..height) |row| {
        compressor.writer.writeByte(0) catch return error.OutOfMemory;
        compressor.writer.writeAll(rgba[row * stride ..][0..row_bytes]) catch return error.OutOfMemory;
    }
    compressor.finish() catch return error.OutOfMemory;
    const zlib = output.written();
    const zlib_len = zlib.len;
    if (zlib_len > std.math.maxInt(u32)) return error.ImageTooLarge;

    const total_len = std.math.add(usize, zlib_len, 57) catch return error.ImageTooLarge;

    const png = try allocator.alloc(u8, total_len);
    errdefer allocator.free(png);
    var pos: usize = 0;
    put(png, &pos, signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(height), .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    writeChunk(png, &pos, "IHDR", &ihdr);

    const idat_start = pos;
    pos += 8; // length and type are filled after the zlib stream.
    put(png, &pos, zlib[0..zlib_len]);

    std.mem.writeInt(u32, png[idat_start..][0..4], @intCast(zlib_len), .big);
    png[idat_start + 4 ..][0..4].* = "IDAT".*;
    const idat_crc = std.hash.Crc32.hash(png[idat_start + 4 .. pos]);
    std.mem.writeInt(u32, png[pos..][0..4], idat_crc, .big);
    pos += 4;
    writeChunk(png, &pos, "IEND", "");
    std.debug.assert(pos == png.len);
    return png;
}

fn put(out: []u8, pos: *usize, bytes: []const u8) void {
    @memcpy(out[pos.*..][0..bytes.len], bytes);
    pos.* += bytes.len;
}

fn writeChunk(out: []u8, pos: *usize, chunk_type: *const [4]u8, data: []const u8) void {
    std.mem.writeInt(u32, out[pos.*..][0..4], @intCast(data.len), .big);
    pos.* += 4;
    const crc_start = pos.*;
    put(out, pos, chunk_type);
    put(out, pos, data);
    std.mem.writeInt(u32, out[pos.*..][0..4], std.hash.Crc32.hash(out[crc_start..pos.*]), .big);
    pos.* += 4;
}

test "PNG chunks, CRCs, and scanlines round trip" {
    const pixels = [_]u8{
        1, 2,  3,  4,  5,  6,  7,  8,  99, 99,
        9, 10, 11, 12, 13, 14, 15, 16,
    };
    const png = try encode(std.testing.allocator, &pixels, 2, 2, 10);
    defer std.testing.allocator.free(png);
    try std.testing.expectEqualSlices(u8, signature, png[0..8]);

    var at: usize = 8;
    var idat: []const u8 = undefined;
    for (0..3) |chunk_index| {
        const len = std.mem.readInt(u32, png[at..][0..4], .big);
        const kind = png[at + 4 ..][0..4];
        const data = png[at + 8 ..][0..len];
        const crc = std.mem.readInt(u32, png[at + 8 + len ..][0..4], .big);
        try std.testing.expectEqual(std.hash.Crc32.hash(png[at + 4 .. at + 8 + len]), crc);
        if (chunk_index == 0) {
            try std.testing.expectEqualSlices(u8, "IHDR", kind);
            try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, data[0..4], .big));
            try std.testing.expectEqualSlices(u8, &.{ 8, 6, 0, 0, 0 }, data[8..13]);
        } else if (chunk_index == 1) {
            try std.testing.expectEqualSlices(u8, "IDAT", kind);
            idat = data;
        } else try std.testing.expectEqualSlices(u8, "IEND", kind);
        at += 12 + len;
    }
    try std.testing.expectEqual(png.len, at);

    var input: std.Io.Reader = .fixed(idat);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflater: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    var scanlines: [18]u8 = undefined;
    try inflater.reader.readSliceAll(&scanlines);
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 9, 10, 11, 12, 13, 14, 15, 16 }, &scanlines);
}

test "compressed large padded image round trips exactly" {
    const width = 256;
    const height = 128;
    const stride = width * 4 + 17;
    const pixels = try std.testing.allocator.alloc(u8, stride * height);
    defer std.testing.allocator.free(pixels);
    for ([_]bool{ false, true }) |incompressible| {
        @memset(pixels, 0xa5);
        for (0..height) |y| for (0..width) |x| {
            const at = y * stride + x * 4;
            pixels[at..][0..4].* = if ((x / 32 + y / 16) % 2 == 0)
                .{ 24, 48, 96, 255 }
            else
                .{ 240, 240, 232, 160 };
        };
        if (incompressible) {
            var random = std.Random.DefaultPrng.init(927);
            random.random().bytes(pixels);
        }

        const png = try encode(std.testing.allocator, pixels, width, height, stride);
        defer std.testing.allocator.free(png);
        if (!incompressible) try std.testing.expect(png.len < width * height); // Well below the 131 KiB RGBA input.

        const idat_len = std.mem.readInt(u32, png[33..37], .big);
        const idat = png[41..][0..idat_len];
        const filtered_row = width * 4 + 1;
        const decoded = try std.testing.allocator.alloc(u8, filtered_row * height);
        defer std.testing.allocator.free(decoded);
        var input: std.Io.Reader = .fixed(idat);
        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var inflater: std.compress.flate.Decompress = .init(&input, .zlib, &window);
        try inflater.reader.readSliceAll(decoded);
        for (0..height) |y| {
            try std.testing.expectEqual(@as(u8, 0), decoded[y * filtered_row]);
            try std.testing.expectEqualSlices(
                u8,
                pixels[y * stride ..][0 .. width * 4],
                decoded[y * filtered_row + 1 ..][0 .. width * 4],
            );
        }
    }
}

test "input validation" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidDimensions, encode(a, "", 0, 1, 0));
    try std.testing.expectError(error.InvalidDimensions, encode(a, "", 1, 0, 4));
    try std.testing.expectError(error.InvalidStride, encode(a, "1234", 2, 1, 4));
    try std.testing.expectError(error.InvalidBufferLength, encode(a, "1234567", 1, 2, 4));
    try std.testing.expectError(
        error.ImageTooLarge,
        encode(a, "", std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(usize)),
    );
}
