const std = @import("std");
const api = @import("api.zig");
const itemization = @import("itemization.zig");
const line_break = @import("line_break.zig");
const line_layout = @import("line_layout.zig");
const measurement = @import("measurement.zig");
const shaped_paragraph = @import("shaped_paragraph.zig");

pub const Fixture = struct {
    utf8: []const u8,
    latin: api.Font,
    arabic: api.Font,
    candidates: [2]api.FallbackCandidate,
    itemized: itemization.ItemizedAnalysis,
    shaped: shaped_paragraph.ShapedParagraphs,
    opportunities: line_break.LineBreakAnalysis,
    measured: measurement.Measurement,
    selected: line_layout.GreedyLines,

    pub fn init(self: *Fixture, utf8: []const u8, max_width: f32) !void {
        self.utf8 = utf8;
        self.latin = try api.Font.init(@embedFile("ourokit_test_font"), 0);
        errdefer self.latin.deinit();
        self.arabic = try api.Font.init(@embedFile("ourokit_arabic_test_font"), 0);
        errdefer self.arabic.deinit();
        self.candidates = .{
            .{ .handle = .{ .slot = 1, .generation = 1 }, .font = &self.latin },
            .{ .handle = .{ .slot = 2, .generation = 1 }, .font = &self.arabic },
        };
        self.itemized = try itemization.itemizeParagraphs(
            std.testing.allocator,
            utf8,
            .auto_left_to_right,
        );
        errdefer self.itemized.deinit();
        self.shaped = try shaped_paragraph.shapeItemizedParagraphs(
            std.testing.allocator,
            utf8,
            &self.itemized,
            &self.candidates,
            "und",
            16,
        );
        errdefer self.shaped.deinit();
        self.opportunities = try line_break.analyzeLineBreaks(std.testing.allocator, utf8);
        errdefer self.opportunities.deinit();
        self.measured = try measurement.measureBreakSegments(
            std.testing.allocator,
            self.opportunities.breaks,
            &self.shaped,
        );
        errdefer self.measured.deinit();
        self.selected = try line_layout.selectGreedyLines(
            std.testing.allocator,
            utf8,
            .auto_left_to_right,
            self.opportunities.breaks,
            &self.measured,
            max_width,
        );
    }

    pub fn deinit(self: *Fixture) void {
        self.selected.deinit();
        self.measured.deinit();
        self.opportunities.deinit();
        self.shaped.deinit();
        self.itemized.deinit();
        self.arabic.deinit();
        self.latin.deinit();
        self.* = undefined;
    }
};

pub fn testPositionedLines(positionLines: anytype) !void {
    var fixture: Fixture = undefined;
    try fixture.init("Save حفظ now", 10_000);
    defer fixture.deinit();
    var positioned = try positionLines(
        std.testing.allocator,
        fixture.utf8,
        &fixture.shaped,
        &fixture.selected,
    );
    defer positioned.deinit();

    try std.testing.expectEqual(@as(usize, 1), positioned.lines.len);
    try std.testing.expect(positioned.glyphs.len != 0);
    var saw_rtl = false;
    for (positioned.lines) |line| {
        var advance: f32 = 0;
        for (positioned.spansFor(line)) |span| {
            advance += span.advance;
            saw_rtl = saw_rtl or span.direction == .right_to_left;
            try std.testing.expect(span.byte_start >= line.byte_start);
            try std.testing.expect(span.byte_start + span.byte_len <= line.byte_start + line.byte_len);
            for (positioned.glyphsFor(span)) |glyph| {
                try std.testing.expect(glyph.cluster >= span.byte_start);
                try std.testing.expect(glyph.cluster < span.byte_start + span.byte_len);
                try std.testing.expect(std.math.isFinite(glyph.origin.x));
                try std.testing.expect(std.math.isFinite(glyph.origin.y));
            }
        }
        try std.testing.expectApproxEqAbs(line.advance, advance, 0.001);
        try std.testing.expect(line.baseline > 0);
    }
    try std.testing.expect(saw_rtl);
}

pub fn testUnsafeReflow(positionLines: anytype) !void {
    const utf8 = "office";
    var font = try api.Font.init(@embedFile("ourokit_test_font"), 0);
    defer font.deinit();
    const candidates = [_]api.FallbackCandidate{.{
        .handle = .{ .slot = 1, .generation = 1 },
        .font = &font,
    }};
    var itemized = try itemization.itemizeParagraphs(
        std.testing.allocator,
        utf8,
        .auto_left_to_right,
    );
    defer itemized.deinit();
    var shaped = try shaped_paragraph.shapeItemizedParagraphs(
        std.testing.allocator,
        utf8,
        &itemized,
        &candidates,
        "en",
        16,
    );
    defer shaped.deinit();
    const breaks = [_]line_break.LineBreak{
        .{ .byte_offset = 2, .kind = .allowed },
        .{ .byte_offset = utf8.len, .kind = .mandatory },
    };
    var measured = try measurement.measureBreakSegments(
        std.testing.allocator,
        &breaks,
        &shaped,
    );
    defer measured.deinit();
    try std.testing.expect(measured.segments[0].requires_reshape);
    var selected = try line_layout.selectGreedyLines(
        std.testing.allocator,
        utf8,
        .auto_left_to_right,
        &breaks,
        &measured,
        measured.segments[0].advance,
    );
    defer selected.deinit();
    try std.testing.expectError(error.ReflowRequired, positionLines(
        std.testing.allocator,
        utf8,
        &shaped,
        &selected,
    ));
}
