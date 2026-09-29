const std = @import("std");
const core = @import("../core/root.zig");
const api = @import("api.zig");

/// One authored style range. Non-empty run lists densely partition the UTF-8
/// source and refer into the request's flat fallback candidate list.
pub const StyledRun = struct {
    byte_start: usize,
    byte_end: usize,
    logical_size: f32,
    candidate_start: usize,
    candidate_count: usize,
    color: ?core.Color = null,
};

pub fn validate(allocator: std.mem.Allocator, utf8: []const u8, candidates_len: usize, runs: []const StyledRun) !void {
    if (runs.len == 0) return;
    const graphemes = try api.graphemes(allocator, utf8);
    defer allocator.free(graphemes);
    var cursor: usize = 0;
    var boundary: usize = 0;
    for (runs) |run| {
        if (run.byte_start != cursor or run.byte_end <= run.byte_start or run.byte_end > utf8.len)
            return error.InvalidStyledRuns;
        if (!std.math.isFinite(run.logical_size) or run.logical_size <= 0)
            return error.InvalidLogicalSize;
        if (run.candidate_count == 0 or run.candidate_start > candidates_len or
            run.candidate_count > candidates_len - run.candidate_start)
            return error.InvalidCandidateRange;
        while (boundary < graphemes.len and graphemes[boundary].byte_end < run.byte_end) : (boundary += 1) {}
        if (boundary == graphemes.len or graphemes[boundary].byte_end != run.byte_end)
            return error.StyledRunSplitsGrapheme;
        cursor = run.byte_end;
    }
    if (cursor != utf8.len) return error.InvalidStyledRuns;
}

test "styled ranges reject split graphemes gaps and invalid candidate slices" {
    const allocator = std.testing.allocator;
    var runs = [_]StyledRun{
        .{ .byte_start = 0, .byte_end = 3, .logical_size = 12, .candidate_start = 0, .candidate_count = 1 },
        .{ .byte_start = 3, .byte_end = 4, .logical_size = 24, .candidate_start = 1, .candidate_count = 1 },
    };
    try validate(allocator, "e\u{301}x", 2, &runs);
    runs[0].byte_end = 1;
    runs[1].byte_start = 1;
    try std.testing.expectError(error.StyledRunSplitsGrapheme, validate(allocator, "e\u{301}x", 2, &runs));
    runs[0].byte_end = 3;
    try std.testing.expectError(error.InvalidStyledRuns, validate(allocator, "e\u{301}x", 2, &runs));
    runs[1].byte_start = 3;
    runs[1].candidate_start = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidCandidateRange, validate(allocator, "e\u{301}x", 2, &runs));
    runs[1].candidate_start = 1;
    runs[1].logical_size = std.math.nan(f32);
    try std.testing.expectError(error.InvalidLogicalSize, validate(allocator, "e\u{301}x", 2, &runs));
}
