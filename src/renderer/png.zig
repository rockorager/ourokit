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
    const blocks = std.math.divCeil(usize, raw_len, 65535) catch unreachable;
    const block_overhead = std.math.mul(usize, blocks, 5) catch return error.ImageTooLarge;
    var zlib_len = std.math.add(usize, raw_len, block_overhead) catch return error.ImageTooLarge;
    zlib_len = std.math.add(usize, zlib_len, 6) catch return error.ImageTooLarge;
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
    png[pos..][0..2].* = .{ 0x78, 0x01 }; // zlib, 32K window, fastest algorithm
    pos += 2;

    var adler: std.hash.Adler32 = .{};
    var raw_remaining = raw_len;
    var image_offset: usize = 0;
    var row_offset: usize = 0;
    while (raw_remaining != 0) {
        const block_len: u16 = @intCast(@min(raw_remaining, 65535));
        png[pos] = @intFromBool(raw_remaining == block_len);
        pos += 1;
        std.mem.writeInt(u16, png[pos..][0..2], block_len, .little);
        std.mem.writeInt(u16, png[pos + 2 ..][0..2], ~block_len, .little);
        pos += 4;

        var left: usize = block_len;
        while (left != 0) {
            if (row_offset == 0) {
                png[pos] = 0;
                adler.update(png[pos..][0..1]);
                pos += 1;
                left -= 1;
                row_offset = 1;
            } else {
                const pixel_offset = row_offset - 1;
                const n = @min(left, row_bytes - pixel_offset);
                const source = rgba[image_offset + pixel_offset ..][0..n];
                @memcpy(png[pos..][0..n], source);
                adler.update(source);
                pos += n;
                left -= n;
                row_offset += n;
                if (row_offset == filtered_row) {
                    row_offset = 0;
                    image_offset += stride;
                }
            }
        }
        raw_remaining -= block_len;
    }
    std.mem.writeInt(u32, png[pos..][0..4], adler.adler, .big);
    pos += 4;

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
