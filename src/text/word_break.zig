//! Unicode Standard Annex #29 default word-boundary analysis.

const std = @import("std");
const uucode = @import("uucode");

pub const Analysis = struct {
    allocator: std.mem.Allocator,
    boundaries: []usize,

    pub fn deinit(self: *Analysis) void {
        self.allocator.free(self.boundaries);
        self.* = undefined;
    }
};

const Property = uucode.TypeOf(.word_break);

const Unit = struct {
    start: usize,
    end: usize,
    property: Property,
    extended_pictographic: bool,
};

pub fn analyze(allocator: std.mem.Allocator, text: []const u8) !Analysis {
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    var boundaries: std.ArrayList(usize) = .empty;
    errdefer boundaries.deinit(allocator);
    try boundaries.ensureTotalCapacity(allocator, text.len + 1);
    appendAssumeCapacity(text, &boundaries);
    return .{
        .allocator = allocator,
        .boundaries = try boundaries.toOwnedSlice(allocator),
    };
}

/// Appends every UAX #29 boundary without allocating. `boundaries` must have
/// room for at least `text.len + 1` entries and `text` must be valid UTF-8.
pub fn appendAssumeCapacity(text: []const u8, boundaries: *std.ArrayList(usize)) void {
    std.debug.assert(std.unicode.utf8ValidateSlice(text));
    std.debug.assert(boundaries.capacity >= boundaries.items.len + text.len + 1);
    boundaries.appendAssumeCapacity(0);
    if (text.len == 0) return;
    const first = unitAt(text, 0);
    var offset = first.end;
    var regional_indicator_count: usize = if (first.property == .regional_indicator) 1 else 0;
    while (offset < text.len) {
        const unit = unitAt(text, offset);
        if (breaksAt(text, offset, regional_indicator_count))
            boundaries.appendAssumeCapacity(offset);
        offset = unit.end;
        if (!isIgnored(unit.property)) regional_indicator_count =
            if (unit.property == .regional_indicator) regional_indicator_count + 1 else 0;
    }
    boundaries.appendAssumeCapacity(text.len);
}

/// Distinguishes word-like segments from separators and punctuation after UAX
/// #29 has established their boundaries. This policy drives editor movement;
/// it does not alter Unicode boundary conformance.
pub fn isWordSegment(text: []const u8) bool {
    var offset: usize = 0;
    while (offset < text.len) {
        const unit = unitAt(text, offset);
        offset = unit.end;
        if (isIgnored(unit.property)) continue;
        return isAhLetter(unit.property) or unit.property == .numeric or
            unit.property == .katakana or unit.property == .extendnumlet or
            unit.property == .regional_indicator or unit.extended_pictographic;
    }
    return false;
}

fn breaksAt(text: []const u8, offset: usize, regional_indicator_count: usize) bool {
    const immediate_left = previousUnit(text, offset).?;
    const right = unitAt(text, offset);

    // WB3-WB3d are evaluated before format/extend characters are ignored.
    if (immediate_left.property == .cr and right.property == .lf) return false;
    if (isNewline(immediate_left.property) or isNewline(right.property)) return true;
    if (immediate_left.property == .zwj and right.extended_pictographic) return false;
    if (immediate_left.property == .wsegspace and right.property == .wsegspace) return false;

    // WB4. Ignored characters attach to the preceding significant character.
    // At start-of-text or after a hard boundary they form their own segment,
    // as required by WB1/WB3a rather than being ignored across that boundary.
    if (isIgnored(right.property)) return false;
    const left = previousSignificant(text, offset) orelse return true;
    if (isIgnored(immediate_left.property) and isNewline(left.property)) return true;

    const previous = previousSignificant(text, left.start);
    const next = nextSignificant(text, right.end);
    const left_ah = isAhLetter(left.property);
    const right_ah = isAhLetter(right.property);

    // WB5-WB7c.
    if (left_ah and right_ah) return false;
    if (left_ah and isMidLetter(right.property) and
        next != null and isAhLetter(next.?.property)) return false;
    if (previous != null and isAhLetter(previous.?.property) and
        isMidLetter(left.property) and right_ah) return false;
    if (left.property == .hebrew_letter and right.property == .single_quote) return false;
    if (left.property == .hebrew_letter and right.property == .double_quote and
        next != null and next.?.property == .hebrew_letter) return false;
    if (previous != null and previous.?.property == .hebrew_letter and
        left.property == .double_quote and right.property == .hebrew_letter) return false;

    // WB8-WB12.
    if (left.property == .numeric and right.property == .numeric) return false;
    if (left_ah and right.property == .numeric) return false;
    if (left.property == .numeric and right_ah) return false;
    if (previous != null and previous.?.property == .numeric and
        isMidNumber(left.property) and right.property == .numeric) return false;
    if (left.property == .numeric and isMidNumber(right.property) and
        next != null and next.?.property == .numeric) return false;

    // WB13-WB13b.
    if (left.property == .katakana and right.property == .katakana) return false;
    if (isExtendNumLetLeft(left.property) and right.property == .extendnumlet) return false;
    if (left.property == .extendnumlet and isExtendNumLetRight(right.property)) return false;

    // WB15-WB16. Ignored characters do not affect RI parity.
    if (left.property == .regional_indicator and right.property == .regional_indicator and
        regional_indicator_count & 1 == 1) return false;

    return true; // WB999
}

fn isIgnored(property: Property) bool {
    return property == .extend or property == .format or property == .zwj;
}

fn isNewline(property: Property) bool {
    return property == .cr or property == .lf or property == .newline;
}

fn isAhLetter(property: Property) bool {
    return property == .aletter or property == .hebrew_letter;
}

fn isMidLetter(property: Property) bool {
    return property == .midletter or property == .midnumlet or
        property == .single_quote;
}

fn isMidNumber(property: Property) bool {
    return property == .midnum or property == .midnumlet or
        property == .single_quote;
}

fn isExtendNumLetLeft(property: Property) bool {
    return isAhLetter(property) or property == .numeric or property == .katakana or
        property == .extendnumlet;
}

fn isExtendNumLetRight(property: Property) bool {
    return isAhLetter(property) or property == .numeric or property == .katakana;
}

fn previousSignificant(text: []const u8, before: usize) ?Unit {
    var cursor = before;
    while (previousUnit(text, cursor)) |unit| {
        if (!isIgnored(unit.property)) return unit;
        cursor = unit.start;
    }
    return null;
}

fn nextSignificant(text: []const u8, after: usize) ?Unit {
    var cursor = after;
    while (cursor < text.len) {
        const unit = unitAt(text, cursor);
        if (!isIgnored(unit.property)) return unit;
        cursor = unit.end;
    }
    return null;
}

fn previousUnit(text: []const u8, before: usize) ?Unit {
    if (before == 0) return null;
    var start = before - 1;
    while (start != 0 and text[start] & 0xc0 == 0x80) start -= 1;
    return unitAt(text, start);
}

fn unitAt(text: []const u8, start: usize) Unit {
    const length = std.unicode.utf8ByteSequenceLength(text[start]) catch unreachable;
    const end = start + length;
    const codepoint = std.unicode.utf8Decode(text[start..end]) catch unreachable;
    return .{
        .start = start,
        .end = end,
        .property = uucode.get(.word_break, codepoint),
        .extended_pictographic = uucode.get(.is_extended_pictographic, codepoint),
    };
}

test "Unicode 17 default word breaking conformance" {
    var lines = std.mem.splitScalar(u8, @embedFile("unicode_word_break_tests"), '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const comment = std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len;
        const body = std.mem.trim(u8, raw_line[0..comment], " \t\r");
        if (body.len == 0) continue;

        var utf8: std.ArrayList(u8) = .empty;
        defer utf8.deinit(std.testing.allocator);
        var expected: std.ArrayList(usize) = .empty;
        defer expected.deinit(std.testing.allocator);
        var tokens = std.mem.tokenizeAny(u8, body, " \t");
        const initial = tokens.next() orelse return error.InvalidConformanceData;
        if (!std.mem.eql(u8, initial, "÷")) return error.InvalidConformanceData;
        try expected.append(std.testing.allocator, 0);
        while (tokens.next()) |codepoint_text| {
            const codepoint = try std.fmt.parseInt(u21, codepoint_text, 16);
            var encoded: [4]u8 = undefined;
            const encoded_len = try std.unicode.utf8Encode(codepoint, &encoded);
            try utf8.appendSlice(std.testing.allocator, encoded[0..encoded_len]);
            const marker = tokens.next() orelse return error.InvalidConformanceData;
            if (std.mem.eql(u8, marker, "÷"))
                try expected.append(std.testing.allocator, utf8.items.len);
        }

        var actual = try analyze(std.testing.allocator, utf8.items);
        defer actual.deinit();
        if (!std.mem.eql(usize, expected.items, actual.boundaries)) {
            std.debug.print("WordBreakTest line {d}: expected {any}, actual {any}\n", .{
                line_number,
                expected.items,
                actual.boundaries,
            });
            return error.WordBreakConformanceFailure;
        }
    }
}

test "word analysis rejects malformed UTF-8 and unwinds allocations" {
    try std.testing.expectError(error.InvalidUtf8, analyze(std.testing.allocator, "x\xff"));
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailure,
        .{},
    );
}

fn exerciseAllocationFailure(allocator: std.mem.Allocator) !void {
    var result = try analyze(allocator, "can't stop 世界 👩🏽‍🚀");
    result.deinit();
}
