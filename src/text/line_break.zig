//! Unicode 17 UAX #14 default line-break opportunities.
//!
//! The rule transcription is informed by `cto-af/linebreak` at commit
//! 088ff02569c5f213951e819a0578f164455f1075 (MIT, copyright Joe Hildebrand).
//! Unicode revision 55 and its official conformance data remain authoritative.

const std = @import("std");
const uucode = @import("uucode");

const Class = @TypeOf(uucode.get(.line_break, 0));
const GeneralCategory = @TypeOf(uucode.get(.general_category, 0));
const EastAsianWidth = @TypeOf(uucode.get(.east_asian_width, 0));

pub const BreakKind = enum {
    allowed,
    mandatory,
};

pub const LineBreak = struct {
    /// UTF-8 byte offset after the preceding scalar.
    byte_offset: usize,
    kind: BreakKind,
};

pub const LineBreakAnalysis = struct {
    allocator: std.mem.Allocator,
    breaks: []LineBreak,

    pub fn deinit(self: *LineBreakAnalysis) void {
        self.allocator.free(self.breaks);
        self.* = undefined;
    }
};

const Sentinel = enum { scalar, start, end };

const Character = struct {
    codepoint: u21 = 0,
    class: Class = .xx,
    category: GeneralCategory = .other_not_assigned,
    east_asian_width: EastAsianWidth = .neutral,
    extended_pictographic: bool = false,
    byte_end: usize = 0,
    source_index: usize = 0,
    sentinel: Sentinel = .scalar,
    ignored: bool = false,

    fn initialPunctuation(self: Character) bool {
        return self.sentinel == .scalar and self.category == .punctuation_initial_quote;
    }

    fn finalPunctuation(self: Character) bool {
        return self.sentinel == .scalar and self.category == .punctuation_final_quote;
    }

    fn eastAsian(self: Character) bool {
        return self.sentinel == .scalar and switch (self.east_asian_width) {
            .fullwidth, .wide, .halfwidth => true,
            else => false,
        };
    }
};

const Decision = enum { no_break, allowed, mandatory };

const State = struct {
    characters: []const Character,
    previous: Character,
    current: Character,
    next: Character,
    last_break: usize = 0,
    after_zero_width_space: bool = false,
    suppress_spaces: bool = false,
    regional_indicators: usize = 0,

    fn push(self: *State, character: Character) void {
        if (self.next.ignored) {
            self.current.byte_end = self.next.byte_end;
        } else {
            self.previous = self.current;
            self.current = self.next;
        }
        self.next = character;
    }

    fn afterNext(self: *const State, distance: usize) ?Character {
        if (self.next.sentinel == .end) return null;
        const index = self.next.source_index + distance;
        return if (index < self.characters.len) self.characters[index] else null;
    }

    fn classAfterSpaces(self: *const State) ?Class {
        if (self.next.sentinel == .end) return null;
        var index = self.next.source_index;
        while (index < self.characters.len) : (index += 1) {
            const class = if (index == self.next.source_index)
                self.next.class
            else
                self.characters[index].class;
            if (class != .sp) return class;
        }
        return null;
    }

    fn numericBefore(self: *const State, start_index: usize) bool {
        var index = start_index;
        while (classBefore(self, &index)) |class| switch (class) {
            .sy, .is => continue,
            .nu => return true,
            else => return false,
        };
        return false;
    }

    fn classBefore(self: *const State, index: *usize) ?Class {
        if (index.* == 0) return null;
        if (self.next.sentinel != .end and index.* == self.next.source_index) {
            index.* = self.current.source_index;
            return if (self.current.sentinel == .scalar) self.current.class else null;
        }
        if (self.next.sentinel == .end and index.* == self.characters.len) {
            index.* = self.current.source_index;
            return if (self.current.sentinel == .scalar) self.current.class else null;
        }
        if (self.current.sentinel == .scalar and index.* == self.current.source_index) {
            index.* = self.previous.source_index;
            return if (self.previous.sentinel == .scalar) self.previous.class else null;
        }
        index.* -= 1;
        return self.characters[index.*].class;
    }
};

/// Returns all default UAX #14 opportunities in linear time. Input must be valid
/// UTF-8. Selection of actual lines is intentionally a separate measured-text
/// stage, allowing greedy and higher-quality algorithms to share this result.
pub fn analyzeLineBreaks(allocator: std.mem.Allocator, utf8: []const u8) !LineBreakAnalysis {
    if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;

    var characters: std.ArrayList(Character) = .empty;
    defer characters.deinit(allocator);
    var iterator = uucode.utf8.Iterator.init(utf8);
    while (iterator.next()) |codepoint| {
        const category = uucode.get(.general_category, codepoint);
        try characters.append(allocator, .{
            .codepoint = codepoint,
            .class = resolveClass(uucode.get(.line_break, codepoint), category),
            .category = category,
            .east_asian_width = uucode.get(.east_asian_width, codepoint),
            .extended_pictographic = uucode.get(.is_extended_pictographic, codepoint),
            .byte_end = iterator.i,
            .source_index = characters.items.len,
        });
    }

    const start: Character = .{ .sentinel = .start };
    var state: State = .{
        .characters = characters.items,
        .previous = start,
        .current = start,
        .next = start,
    };
    var breaks: std.ArrayList(LineBreak) = .empty;
    errdefer breaks.deinit(allocator);
    for (characters.items) |character| {
        state.push(character);
        try recordDecision(allocator, &breaks, &state, decide(&state));
    }
    state.push(.{
        .byte_end = utf8.len,
        .source_index = characters.items.len,
        .sentinel = .end,
    });
    try recordDecision(allocator, &breaks, &state, decide(&state));
    return .{ .allocator = allocator, .breaks = try breaks.toOwnedSlice(allocator) };
}

fn recordDecision(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(LineBreak),
    state: *State,
    decision: Decision,
) !void {
    const kind: BreakKind = switch (decision) {
        .no_break => return,
        .allowed => .allowed,
        .mandatory => .mandatory,
    };
    try output.append(allocator, .{ .byte_offset = state.current.byte_end, .kind = kind });
    state.last_break = state.current.byte_end;
}

fn resolveClass(class: Class, category: GeneralCategory) Class {
    return switch (class) {
        .ai, .sg, .xx => .al,
        .sa => switch (category) {
            .mark_nonspacing, .mark_spacing_combining => .cm,
            else => .al,
        },
        .cj => .ns,
        else => class,
    };
}

fn decide(state: *State) Decision {
    const previous = state.previous;
    const current = &state.current;
    const next = &state.next;

    // LB2-LB6
    if (current.sentinel == .start and next.sentinel != .end) return .no_break;
    if (next.sentinel == .end and (current.byte_end == 0 or current.byte_end != state.last_break))
        return .mandatory;
    if (current.class == .bk) return .mandatory;
    if (current.class == .cr) return if (next.class == .lf) .no_break else .mandatory;
    if (current.class == .lf or current.class == .nl) return .mandatory;
    if (next.class == .bk or next.class == .cr or next.class == .lf or next.class == .nl)
        return .no_break;

    if (current.class != .ri) state.regional_indicators = 0;
    if (state.suppress_spaces) {
        if (next.class != .sp) state.suppress_spaces = false;
        return .no_break;
    }

    // LB7-LB10
    if (next.class == .zw) return .no_break;
    if (next.class == .sp and current.class != .zw and current.class != .op and
        current.class != .qu and current.class != .cl and current.class != .cp and
        current.class != .b2) return .no_break;
    if (state.after_zero_width_space) {
        state.after_zero_width_space = false;
        return .allowed;
    } else if (current.class == .zw) {
        if (next.class == .sp) state.after_zero_width_space = true;
        return if (next.class == .sp) .no_break else .allowed;
    }
    if (current.class == .zwj) return .no_break;
    if (!isHardOrSpace(current.class) and (next.class == .cm or next.class == .zwj)) {
        next.ignored = true;
        return .no_break;
    }
    if (current.class == .cm) current.class = .al;
    if (next.class == .cm) next.class = .al;

    // LB11-LB14
    if (current.class == .wj or next.class == .wj) return .no_break;
    if (current.class == .gl) return .no_break;
    if (next.class == .gl and current.class != .sp and current.class != .ba and
        current.class != .hy and current.class != .hh) return .no_break;
    if (next.class == .cl or next.class == .cp or next.class == .ex or next.class == .sy)
        return .no_break;
    if (current.class == .op) {
        if (next.class == .sp) state.suppress_spaces = true;
        return .no_break;
    }

    // LB15a-LB17
    if (isLb15aPrefix(previous) and current.class == .qu and current.initialPunctuation()) {
        state.suppress_spaces = true;
        return .no_break;
    }
    if (next.class == .qu and next.finalPunctuation()) {
        const after = state.afterNext(1);
        if (after == null or isLb15bSuffix(after.?.class)) return .no_break;
    }
    if (current.class == .sp and next.class == .is and
        if (state.afterNext(1)) |after| after.class == .nu else false) return .allowed;
    if (next.class == .is) return .no_break;
    if (current.class == .cl or current.class == .cp) {
        if (state.classAfterSpaces() == .ns) {
            if (next.class == .sp) state.suppress_spaces = true;
            return .no_break;
        }
        if (next.class == .sp) return .no_break;
    }
    if (current.class == .b2) {
        if (state.classAfterSpaces() == .b2) {
            if (next.class == .sp) state.suppress_spaces = true;
            return .no_break;
        }
        if (next.class == .sp) return .no_break;
    }

    // LB18-LB20
    if (current.class == .sp) return .allowed;
    if (next.class == .qu and !next.initialPunctuation()) return .no_break;
    if (current.class == .qu and !current.finalPunctuation()) return .no_break;
    if (!current.eastAsian() and next.class == .qu) return .no_break;
    if (next.class == .qu) {
        const after = state.afterNext(1);
        if (after == null or !after.?.eastAsian()) return .no_break;
    }
    if (current.class == .qu and !next.eastAsian()) return .no_break;
    if ((previous.sentinel == .start or !previous.eastAsian()) and current.class == .qu)
        return .no_break;
    if (current.class == .cb or next.class == .cb) return .allowed;

    // LB20a-LB24
    if (isWordStart(previous) and (current.class == .hy or current.class == .hh) and
        (next.class == .al or next.class == .hl)) return .no_break;
    if (previous.class == .hl and (current.class == .hy or current.class == .hh) and
        next.class != .hl) return .no_break;
    if (current.class == .bb or next.class == .ba or next.class == .hh or
        next.class == .hy or next.class == .ns) return .no_break;
    if (current.class == .sy and next.class == .hl) return .no_break;
    if (next.class == .in) return .no_break;
    if ((isAlphabetic(current.class) and next.class == .nu) or
        (current.class == .nu and isAlphabetic(next.class))) return .no_break;
    if ((current.class == .pr and isIdeographicEmoji(next.class)) or
        (isIdeographicEmoji(current.class) and next.class == .po)) return .no_break;
    if ((isPrefixPostfix(current.class) and isAlphabetic(next.class)) or
        (isAlphabetic(current.class) and isPrefixPostfix(next.class))) return .no_break;

    // LB25
    if (isPrefixPostfix(next.class)) {
        const start_index = if (current.class == .cl or current.class == .cp)
            current.source_index
        else
            next.source_index;
        if (state.numericBefore(start_index)) return .no_break;
    } else if (next.class == .nu and state.numericBefore(next.source_index)) {
        return .no_break;
    }
    if (isPrefixPostfix(current.class)) {
        if (next.class == .nu) return .no_break;
        if (next.class == .op) {
            if (state.afterNext(1)) |after| {
                if (after.class == .nu) return .no_break;
                if (after.class == .is and
                    if (state.afterNext(2)) |second| second.class == .nu else false)
                    return .no_break;
            }
        }
    }
    if ((current.class == .hy or current.class == .is) and next.class == .nu)
        return .no_break;

    // LB26-LB28a
    if ((current.class == .jl and isOneOf(next.class, &.{ .jl, .jv, .h2, .h3 })) or
        (isOneOf(current.class, &.{ .jv, .h2 }) and isOneOf(next.class, &.{ .jv, .jt })) or
        (isOneOf(current.class, &.{ .jt, .h3 }) and next.class == .jt)) return .no_break;
    if ((isHangul(current.class) and next.class == .po) or
        (current.class == .pr and isHangul(next.class))) return .no_break;
    if (isAlphabetic(current.class) and isAlphabetic(next.class)) return .no_break;
    if (current.class == .ap and isAkCircleAs(next.*)) return .no_break;
    if (isAkCircleAs(current.*) and (next.class == .vf or next.class == .vi)) return .no_break;
    if (isAkCircleAs(previous) and current.class == .vi and
        (next.class == .ak or next.codepoint == 0x25cc)) return .no_break;
    if (isAkCircleAs(current.*) and isAkCircleAs(next.*) and
        if (state.afterNext(1)) |after| after.class == .vf else false) return .no_break;

    // LB29-LB31
    if (current.class == .is and isAlphabetic(next.class)) return .no_break;
    if (isOneOf(current.class, &.{ .al, .hl, .nu }) and next.class == .op and
        !next.eastAsian()) return .no_break;
    if (current.class == .cp and !current.eastAsian() and
        isOneOf(next.class, &.{ .al, .hl, .nu })) return .no_break;
    if (current.class == .ri and next.class == .ri) {
        state.regional_indicators += 1;
        if (state.regional_indicators & 1 != 0) return .no_break;
    }
    if ((current.class == .eb or
        (current.category == .other_not_assigned and current.extended_pictographic)) and
        next.class == .em) return .no_break;
    return .allowed;
}

fn isHardOrSpace(class: Class) bool {
    return isOneOf(class, &.{ .bk, .cr, .lf, .nl, .sp, .zw });
}

fn isLb15aPrefix(character: Character) bool {
    return character.sentinel == .start or isOneOf(character.class, &.{
        .bk, .cr, .lf, .nl, .op, .qu, .gl, .sp, .zw,
    });
}

fn isLb15bSuffix(class: Class) bool {
    return isOneOf(class, &.{
        .sp, .gl, .wj, .cl, .qu, .cp, .ex, .is, .sy, .bk, .cr, .lf, .nl, .zw,
    });
}

fn isWordStart(character: Character) bool {
    return character.sentinel == .start or isOneOf(character.class, &.{
        .bk, .cr, .lf, .nl, .sp, .zw, .cb, .gl,
    });
}

fn isAlphabetic(class: Class) bool {
    return class == .al or class == .hl;
}

fn isIdeographicEmoji(class: Class) bool {
    return class == .id or class == .eb or class == .em;
}

fn isPrefixPostfix(class: Class) bool {
    return class == .pr or class == .po;
}

fn isHangul(class: Class) bool {
    return isOneOf(class, &.{ .jl, .jv, .jt, .h2, .h3 });
}

fn isAkCircleAs(character: Character) bool {
    return character.class == .ak or character.codepoint == 0x25cc or character.class == .as;
}

fn isOneOf(class: Class, comptime values: []const Class) bool {
    inline for (values) |value| if (class == value) return true;
    return false;
}

test "line breaks identify optional and mandatory UTF-8 boundaries" {
    const value = "hello world\nnext";
    var analysis = try analyzeLineBreaks(std.testing.allocator, value);
    defer analysis.deinit();
    try std.testing.expectEqualSlices(LineBreak, &.{
        .{ .byte_offset = 6, .kind = .allowed },
        .{ .byte_offset = 12, .kind = .mandatory },
        .{ .byte_offset = value.len, .kind = .mandatory },
    }, analysis.breaks);
}

test "line breaking rejects malformed UTF-8 and defines empty input" {
    try std.testing.expectError(error.InvalidUtf8, analyzeLineBreaks(std.testing.allocator, "x\xff"));
    var empty = try analyzeLineBreaks(std.testing.allocator, "");
    defer empty.deinit();
    try std.testing.expectEqualSlices(LineBreak, &.{.{
        .byte_offset = 0,
        .kind = .mandatory,
    }}, empty.breaks);
}

test "Unicode 17 default line breaking conformance" {
    var lines = std.mem.splitScalar(u8, @embedFile("unicode_line_break_tests"), '\n');
    var line_number: usize = 0;
    while (lines.next()) |raw_line| {
        line_number += 1;
        const body = std.mem.trim(u8, raw_line[0 .. std.mem.indexOfScalar(u8, raw_line, '#') orelse raw_line.len], " \t\r");
        if (body.len == 0) continue;

        var utf8: std.ArrayList(u8) = .empty;
        defer utf8.deinit(std.testing.allocator);
        var expected: std.ArrayList(usize) = .empty;
        defer expected.deinit(std.testing.allocator);
        var tokens = std.mem.tokenizeAny(u8, body, " \t");
        _ = tokens.next() orelse return error.InvalidConformanceData;
        while (tokens.next()) |codepoint_text| {
            const codepoint = try std.fmt.parseInt(u21, codepoint_text, 16);
            var encoded: [4]u8 = undefined;
            const encoded_len = try std.unicode.utf8Encode(codepoint, &encoded);
            try utf8.appendSlice(std.testing.allocator, encoded[0..encoded_len]);
            const marker = tokens.next() orelse return error.InvalidConformanceData;
            if (std.mem.eql(u8, marker, "÷"))
                try expected.append(std.testing.allocator, utf8.items.len);
        }

        var actual = try analyzeLineBreaks(std.testing.allocator, utf8.items);
        defer actual.deinit();
        if (actual.breaks.len != expected.items.len) {
            std.debug.print("LineBreakTest line {d}: expected {any}, actual {any}\n", .{
                line_number,
                expected.items,
                actual.breaks,
            });
            return error.LineBreakConformanceFailure;
        }
        for (actual.breaks, expected.items) |actual_break, expected_offset| {
            if (actual_break.byte_offset != expected_offset) {
                std.debug.print("LineBreakTest line {d}: expected {any}, actual {any}\n", .{
                    line_number,
                    expected.items,
                    actual.breaks,
                });
                return error.LineBreakConformanceFailure;
            }
        }
    }
}

test "line breaking unwinds every caller-owned allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailure,
        .{},
    );
}

fn exerciseAllocationFailure(allocator: std.mem.Allocator) !void {
    var analysis = try analyzeLineBreaks(allocator, "Latin العربية 日本語 👩🏽‍🚀");
    defer analysis.deinit();
    std.mem.doNotOptimizeAway(analysis.breaks.len);
}
