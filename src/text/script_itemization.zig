//! Pure script-run analysis above Unicode extended grapheme clusters.

const std = @import("std");
const uucode = @import("uucode");
const data = @import("script_extensions");
const Script = @import("api.zig").Script;

const UnicodeScript = data.Script;
const ScriptSet = data.ScriptSet;

pub const ScriptRun = struct {
    byte_start: usize,
    byte_len: usize,
    script: Script,
};

pub const ScriptAnalysis = struct {
    allocator: std.mem.Allocator,
    runs: []ScriptRun,

    pub fn deinit(self: *ScriptAnalysis) void {
        self.allocator.free(self.runs);
        self.* = undefined;
    }
};

const Cluster = struct {
    byte_start: usize,
    byte_len: usize,
    candidates: ScriptSet,
    preferred: ?UnicodeScript,
    resolved: ?UnicodeScript = null,
    first_codepoint: u21,
    paired: bool = false,
};

/// Resolves Unicode 17 Script and Script_Extensions values into homogeneous
/// shaping runs without splitting an extended grapheme cluster. Common and
/// Inherited clusters follow surrounding compatible text; paired brackets use
/// the script of their enclosing text and always agree with their mate.
pub fn analyzeScripts(allocator: std.mem.Allocator, utf8: []const u8) !ScriptAnalysis {
    if (!std.unicode.utf8ValidateSlice(utf8)) return error.InvalidUtf8;

    var clusters: std.ArrayList(Cluster) = .empty;
    defer clusters.deinit(allocator);
    var graphemes = uucode.grapheme.utf8Iterator(utf8);
    while (graphemes.nextGrapheme()) |grapheme| {
        try clusters.append(allocator, analyzeCluster(
            utf8[grapheme.start..grapheme.end],
            grapheme.start,
        ));
    }
    resolveContext(clusters.items);
    try resolvePairedBrackets(allocator, clusters.items);
    reresolveGenericClusters(clusters.items);

    var runs: std.ArrayList(ScriptRun) = .empty;
    errdefer runs.deinit(allocator);
    for (clusters.items) |cluster| {
        const unicode_script = cluster.resolved orelse .common;
        const resolved_script = scriptFromUnicode(unicode_script);
        if (runs.items.len != 0 and runs.items[runs.items.len - 1].script == resolved_script) {
            runs.items[runs.items.len - 1].byte_len += cluster.byte_len;
        } else {
            try runs.append(allocator, .{
                .byte_start = cluster.byte_start,
                .byte_len = cluster.byte_len,
                .script = resolved_script,
            });
        }
    }
    return .{ .allocator = allocator, .runs = try runs.toOwnedSlice(allocator) };
}

fn analyzeCluster(bytes: []const u8, byte_start: usize) Cluster {
    var iterator = uucode.utf8.Iterator.init(bytes);
    const first_codepoint = iterator.next().?;
    var candidates = explicitCandidates(data.forCodepoint(first_codepoint));
    var preferred = explicitPrimary(first_codepoint);
    while (iterator.next()) |codepoint| {
        if (preferred == null) preferred = explicitPrimary(codepoint);
        const next = explicitCandidates(data.forCodepoint(codepoint));
        if (next.count() == 0) continue;
        if (candidates.count() == 0) {
            candidates = next;
        } else {
            const intersection = candidates.intersectWith(next);
            // A malformed cross-script combining sequence remains one cluster
            // and follows its base rather than introducing an illegal split.
            if (intersection.count() != 0) candidates = intersection;
        }
    }
    return .{
        .byte_start = byte_start,
        .byte_len = bytes.len,
        .candidates = candidates,
        .preferred = preferred,
        .first_codepoint = first_codepoint,
    };
}

fn resolveContext(clusters: []Cluster) void {
    var previous: ?UnicodeScript = null;
    for (clusters) |*cluster| {
        if (previous != null and compatible(cluster.*, previous.?)) {
            cluster.resolved = previous;
        } else if (cluster.preferred) |preferred| {
            cluster.resolved = preferred;
        } else if (onlyCandidate(cluster.candidates)) |candidate| {
            cluster.resolved = candidate;
        }
        if (cluster.resolved != null) previous = cluster.resolved;
    }

    var next: ?UnicodeScript = null;
    var index = clusters.len;
    while (index != 0) {
        index -= 1;
        const cluster = &clusters[index];
        if (cluster.resolved == null and next != null and compatible(cluster.*, next.?))
            cluster.resolved = next;
        if (cluster.resolved != null) next = cluster.resolved;
    }
}

const OpenBracket = struct {
    codepoint: u21,
    cluster_index: usize,
};

fn resolvePairedBrackets(allocator: std.mem.Allocator, clusters: []Cluster) !void {
    var stack: std.ArrayList(OpenBracket) = .empty;
    defer stack.deinit(allocator);
    for (clusters, 0..) |*cluster, cluster_index| switch (uucode.get(
        .bidi_paired_bracket,
        cluster.first_codepoint,
    )) {
        .open => |close| try stack.append(allocator, .{
            .codepoint = close,
            .cluster_index = cluster_index,
        }),
        .close => {
            var match = stack.items.len;
            while (match != 0) {
                match -= 1;
                if (stack.items[match].codepoint == cluster.first_codepoint) break;
            } else continue;
            const opening = stack.items[match].cluster_index;
            clusters[opening].paired = true;
            cluster.paired = true;
            const enclosing = clusters[opening].resolved orelse inside: {
                for (clusters[opening + 1 .. cluster_index]) |inside_cluster|
                    if (inside_cluster.resolved) |resolved| break :inside resolved;
                break :inside null;
            };
            clusters[opening].resolved = enclosing;
            cluster.resolved = enclosing;
            stack.shrinkRetainingCapacity(match);
        },
        .none => {},
    };
}

fn reresolveGenericClusters(clusters: []Cluster) void {
    for (clusters) |*cluster| {
        if (!cluster.paired and cluster.candidates.count() == 0) cluster.resolved = null;
    }

    var previous: ?UnicodeScript = null;
    for (clusters) |*cluster| {
        if (cluster.resolved == null and previous != null) cluster.resolved = previous;
        if (cluster.resolved != null) previous = cluster.resolved;
    }

    var next: ?UnicodeScript = null;
    var index = clusters.len;
    while (index != 0) {
        index -= 1;
        if (clusters[index].resolved == null and next != null) clusters[index].resolved = next;
        if (clusters[index].resolved != null) next = clusters[index].resolved;
    }
}

fn explicitCandidates(source: ScriptSet) ScriptSet {
    var result = source;
    result.remove(.common);
    result.remove(.inherited);
    result.remove(.unknown);
    return result;
}

fn explicitPrimary(codepoint: u21) ?UnicodeScript {
    const primary = uucode.get(.script, codepoint);
    return switch (primary) {
        .common, .inherited, .unknown => null,
        else => primary,
    };
}

fn compatible(cluster: Cluster, candidate: UnicodeScript) bool {
    return cluster.candidates.count() == 0 or cluster.candidates.contains(candidate);
}

fn onlyCandidate(candidates: ScriptSet) ?UnicodeScript {
    if (candidates.count() != 1) return null;
    var iterator = candidates.iterator();
    return iterator.next();
}

fn scriptFromTag(tag: *const [4]u8) Script {
    return Script.fromIso15924(tag);
}

fn scriptFromUnicode(value: UnicodeScript) Script {
    const tag = data.iso15924(value);
    return Script.fromIso15924(&tag);
}

test "script itemization resolves common text and script extensions" {
    const value = "Latin あーアー العربية،";
    var analysis = try analyzeScripts(std.testing.allocator, value);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 4), analysis.runs.len);
    try std.testing.expectEqual(scriptFromTag("Latn"), analysis.runs[0].script);
    try std.testing.expectEqual(scriptFromTag("Hira"), analysis.runs[1].script);
    try std.testing.expectEqual(scriptFromTag("Kana"), analysis.runs[2].script);
    try std.testing.expectEqual(scriptFromTag("Arab"), analysis.runs[3].script);
}

test "script itemization keeps grapheme clusters intact" {
    const value = "a\u{0301}ב\u{05B0}";
    var analysis = try analyzeScripts(std.testing.allocator, value);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 2), analysis.runs.len);
    try std.testing.expectEqual(ScriptRun{
        .byte_start = 0,
        .byte_len = "a\u{0301}".len,
        .script = scriptFromTag("Latn"),
    }, analysis.runs[0]);
    try std.testing.expectEqual(scriptFromTag("Hebr"), analysis.runs[1].script);
}

test "cross-script combining marks do not split their grapheme" {
    const value = "a\u{05B0}";
    var analysis = try analyzeScripts(std.testing.allocator, value);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), analysis.runs.len);
    try std.testing.expectEqual(ScriptRun{
        .byte_start = 0,
        .byte_len = value.len,
        .script = scriptFromTag("Latn"),
    }, analysis.runs[0]);
}

test "paired brackets use the enclosing script" {
    const value = "gamma (γ) text";
    var analysis = try analyzeScripts(std.testing.allocator, value);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 3), analysis.runs.len);
    try std.testing.expectEqual(scriptFromTag("Latn"), analysis.runs[0].script);
    try std.testing.expectEqual(scriptFromTag("Grek"), analysis.runs[1].script);
    try std.testing.expectEqual(scriptFromTag("Latn"), analysis.runs[2].script);
    try std.testing.expectEqualStrings("γ", value[analysis.runs[1].byte_start..][0..analysis.runs[1].byte_len]);
}

test "leading paired brackets use their enclosed script" {
    const value = "(Ελληνικά)";
    var analysis = try analyzeScripts(std.testing.allocator, value);
    defer analysis.deinit();
    try std.testing.expectEqual(@as(usize, 1), analysis.runs.len);
    try std.testing.expectEqual(scriptFromTag("Grek"), analysis.runs[0].script);
}

test "script itemization defines empty input and rejects malformed UTF-8" {
    var empty = try analyzeScripts(std.testing.allocator, "");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.runs.len);
    try std.testing.expectError(error.InvalidUtf8, analyzeScripts(std.testing.allocator, "bad\xff"));
}

test "script itemization unwinds every caller-owned allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailure,
        .{},
    );
}

fn exerciseAllocationFailure(allocator: std.mem.Allocator) !void {
    var analysis = try analyzeScripts(allocator, "Latin (Ελληνικά) العربية، あー");
    defer analysis.deinit();
    std.mem.doNotOptimizeAway(analysis.runs.len);
}
