//! Width-independent retained paragraph inputs used by render objects.

const std = @import("std");
const api = @import("api.zig");
const paragraph = @import("paragraph.zig");
const styled = @import("styled_run.zig");
pub const StyledRun = styled.StyledRun;

pub const ParagraphSourceHandle = struct {
    slot: u32,
    generation: u32,
};

pub const ParagraphSource = struct {
    utf8: []const u8,
    base_direction: paragraph.BaseDirection,
    language: []const u8,
    logical_size: f32,
    candidates: []const api.FontHandle,
    runs: []const StyledRun,
    configuration_revision: u64,
};

/// Deduplicates immutable text and style independently from width-specific
/// paragraph layout. The font cache must outlive this cache.
pub const ParagraphSourceCache = struct {
    allocator: std.mem.Allocator,
    font_cache: *api.FontCache,
    slabs: std.ArrayListUnmanaged(*Slab) = .empty,
    index: Index = .empty,
    index_removals: usize = 0,
    free_head: u32 = invalid_slot,
    active_count: usize = 0,

    const slab_size = 16;
    const invalid_slot = std.math.maxInt(u32);

    pub const Request = struct {
        utf8: []const u8,
        base_direction: paragraph.BaseDirection = .auto_left_to_right,
        language: []const u8,
        logical_size: f32,
        candidates: []const api.FontHandle,
        runs: []const StyledRun = &.{},
        configuration_revision: u64,
    };

    const Key = struct {
        utf8: []const u8,
        base_direction: paragraph.BaseDirection,
        language: []const u8,
        logical_size_bits: u32,
        candidates: []const api.FontHandle,
        runs: []const StyledRun,
        configuration_revision: u64,
    };

    const Slot = struct {
        generation: u32 = 1,
        active: bool = false,
        references: u32 = 0,
        next_free: u32 = invalid_slot,
        source: ParagraphSource = undefined,
    };

    const Slab = [slab_size]Slot;

    const KeyContext = struct {
        pub fn hash(_: KeyContext, key: Key) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(key.utf8);
            hashValue(&hasher, @intFromEnum(key.base_direction));
            hasher.update(key.language);
            hashValue(&hasher, key.logical_size_bits);
            for (key.candidates) |candidate| {
                hashValue(&hasher, candidate.slot);
                hashValue(&hasher, candidate.generation);
            }
            hashRuns(&hasher, key.runs);
            hashValue(&hasher, key.configuration_revision);
            return hasher.final();
        }

        pub fn eql(_: KeyContext, a: Key, b: Key) bool {
            return a.base_direction == b.base_direction and
                a.logical_size_bits == b.logical_size_bits and
                a.configuration_revision == b.configuration_revision and
                std.mem.eql(u8, a.utf8, b.utf8) and
                std.mem.eql(u8, a.language, b.language) and
                handlesEqual(a.candidates, b.candidates) and runsEqual(a.runs, b.runs);
        }

        fn handlesEqual(a: []const api.FontHandle, b: []const api.FontHandle) bool {
            if (a.len != b.len) return false;
            for (a, b) |left, right|
                if (left.slot != right.slot or left.generation != right.generation) return false;
            return true;
        }

        fn hashValue(hasher: *std.hash.Wyhash, value: anytype) void {
            var copy = value;
            hasher.update(std.mem.asBytes(&copy));
        }

        fn hashRuns(hasher: *std.hash.Wyhash, runs: []const StyledRun) void {
            for (runs) |run| {
                hashValue(hasher, run.byte_start);
                hashValue(hasher, run.byte_end);
                hashValue(hasher, @as(u32, @bitCast(run.logical_size)));
                hashValue(hasher, run.candidate_start);
                hashValue(hasher, run.candidate_count);
                hashValue(hasher, if (run.color) |c| @as(u32, @bitCast(c)) else 0);
                hashValue(hasher, run.color != null);
            }
        }
        fn runsEqual(a: []const StyledRun, b: []const StyledRun) bool {
            if (a.len != b.len) return false;
            for (a, b) |x, y| if (x.byte_start != y.byte_start or x.byte_end != y.byte_end or
                @as(u32, @bitCast(x.logical_size)) != @as(u32, @bitCast(y.logical_size)) or
                x.candidate_start != y.candidate_start or x.candidate_count != y.candidate_count or
                x.color != y.color) return false;
            return true;
        }
    };

    const Index = std.HashMapUnmanaged(
        Key,
        ParagraphSourceHandle,
        KeyContext,
        std.hash_map.default_max_load_percentage,
    );

    pub fn init(allocator: std.mem.Allocator, font_cache: *api.FontCache) ParagraphSourceCache {
        return .{ .allocator = allocator, .font_cache = font_cache };
    }

    pub fn deinit(self: *ParagraphSourceCache) void {
        self.index.deinit(self.allocator);
        for (self.slabs.items) |slab| {
            for (slab) |*slot| if (slot.active) self.destroySource(&slot.source);
            self.allocator.destroy(slab);
        }
        self.slabs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn acquire(self: *ParagraphSourceCache, request: Request) !ParagraphSourceHandle {
        const key = try self.requestKey(request);
        if (self.index.get(key)) |handle| {
            try self.retain(handle);
            return handle;
        }

        const utf8 = try self.allocator.dupe(u8, key.utf8);
        errdefer self.allocator.free(utf8);
        const language = try self.allocator.dupe(u8, key.language);
        errdefer self.allocator.free(language);
        const candidates = try self.allocator.dupe(api.FontHandle, key.candidates);
        errdefer self.allocator.free(candidates);
        const runs = try self.allocator.dupe(StyledRun, key.runs);
        errdefer self.allocator.free(runs);
        var retained: usize = 0;
        errdefer for (key.candidates[0..retained]) |handle|
            self.font_cache.release(handle) catch unreachable;
        for (key.candidates) |handle| {
            try self.font_cache.retain(handle);
            retained += 1;
        }

        try self.index.ensureUnusedCapacity(self.allocator, 1);
        const slot_index = try self.takeSlot();
        const slot = self.slotAt(slot_index).?;
        slot.* = .{
            .generation = slot.generation,
            .active = true,
            .references = 1,
            .source = .{
                .utf8 = utf8,
                .base_direction = key.base_direction,
                .language = language,
                .logical_size = @bitCast(key.logical_size_bits),
                .candidates = candidates,
                .runs = runs,
                .configuration_revision = key.configuration_revision,
            },
        };
        const stored_key = keyForSource(slot.source);
        const handle: ParagraphSourceHandle = .{ .slot = slot_index, .generation = slot.generation };
        self.index.putAssumeCapacity(stored_key, handle);
        self.active_count += 1;
        return handle;
    }

    pub fn retain(self: *ParagraphSourceCache, handle: ParagraphSourceHandle) !void {
        const slot = try self.require(handle);
        if (slot.references == std.math.maxInt(u32)) return error.ReferenceOverflow;
        slot.references += 1;
    }

    pub fn validateRetain(self: *ParagraphSourceCache, handle: ParagraphSourceHandle) !void {
        const slot = try self.require(handle);
        if (slot.references == std.math.maxInt(u32)) return error.ReferenceOverflow;
    }

    pub fn release(self: *ParagraphSourceCache, handle: ParagraphSourceHandle) !void {
        const slot = try self.require(handle);
        std.debug.assert(slot.references != 0);
        slot.references -= 1;
        if (slot.references != 0) return;
        _ = self.index.remove(keyForSource(slot.source));
        // HashMap growth tracks live entries, not deleted buckets. Bound
        // tombstones under label churn without allocating or moving sources.
        self.index_removals += 1;
        if (self.index_removals >= self.index.capacity() / 8) {
            self.index.rehash(KeyContext{});
            self.index_removals = 0;
        }
        self.destroySource(&slot.source);
        slot.active = false;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.next_free = self.free_head;
        self.free_head = handle.slot;
        self.active_count -= 1;
    }

    pub fn get(self: *const ParagraphSourceCache, handle: ParagraphSourceHandle) !*const ParagraphSource {
        return &(try self.requireConst(handle)).source;
    }

    pub fn count(self: *const ParagraphSourceCache) usize {
        return self.active_count;
    }

    fn requestKey(self: *ParagraphSourceCache, request: Request) !Key {
        if (request.candidates.len == 0) return error.NoFallbackCandidates;
        if (!std.unicode.utf8ValidateSlice(request.utf8)) return error.InvalidUtf8;
        if (!std.math.isFinite(request.logical_size) or request.logical_size <= 0)
            return error.InvalidLogicalSize;
        try styled.validate(self.allocator, request.utf8, request.candidates.len, request.runs);
        return .{
            .utf8 = request.utf8,
            .base_direction = request.base_direction,
            .language = request.language,
            .logical_size_bits = @bitCast(request.logical_size),
            .candidates = request.candidates,
            .runs = request.runs,
            .configuration_revision = request.configuration_revision,
        };
    }

    fn keyForSource(source: ParagraphSource) Key {
        return .{
            .utf8 = source.utf8,
            .base_direction = source.base_direction,
            .language = source.language,
            .logical_size_bits = @bitCast(source.logical_size),
            .candidates = source.candidates,
            .runs = source.runs,
            .configuration_revision = source.configuration_revision,
        };
    }

    fn destroySource(self: *ParagraphSourceCache, source: *ParagraphSource) void {
        for (source.candidates) |handle| self.font_cache.release(handle) catch unreachable;
        self.allocator.free(source.candidates);
        self.allocator.free(source.runs);
        self.allocator.free(source.language);
        self.allocator.free(source.utf8);
    }

    fn takeSlot(self: *ParagraphSourceCache) !u32 {
        if (self.free_head != invalid_slot) {
            const index = self.free_head;
            const slot = self.slotAt(index).?;
            self.free_head = slot.next_free;
            slot.next_free = invalid_slot;
            return index;
        }
        if (self.slabs.items.len > std.math.maxInt(u32) / slab_size)
            return error.CapacityExceeded;
        const slab = try self.allocator.create(Slab);
        errdefer self.allocator.destroy(slab);
        slab.* = [_]Slot{.{}} ** slab_size;
        try self.slabs.append(self.allocator, slab);
        const first: u32 = @intCast((self.slabs.items.len - 1) * slab_size);
        var offset: usize = slab_size;
        while (offset > 1) {
            offset -= 1;
            const index = first + @as(u32, @intCast(offset));
            slab[offset].next_free = self.free_head;
            self.free_head = index;
        }
        return first;
    }

    fn require(self: *ParagraphSourceCache, handle: ParagraphSourceHandle) !*Slot {
        const slot = self.slotAt(handle.slot) orelse return error.StaleParagraphSource;
        if (!slot.active or slot.generation != handle.generation) return error.StaleParagraphSource;
        return slot;
    }

    fn requireConst(self: *const ParagraphSourceCache, handle: ParagraphSourceHandle) !*const Slot {
        const slot = self.slotAtConst(handle.slot) orelse return error.StaleParagraphSource;
        if (!slot.active or slot.generation != handle.generation) return error.StaleParagraphSource;
        return slot;
    }

    fn slotAt(self: *ParagraphSourceCache, index_value: u32) ?*Slot {
        const slab_index: usize = index_value / slab_size;
        if (slab_index >= self.slabs.items.len) return null;
        return &self.slabs.items[slab_index][index_value % slab_size];
    }

    fn slotAtConst(self: *const ParagraphSourceCache, index_value: u32) ?*const Slot {
        const slab_index: usize = index_value / slab_size;
        if (slab_index >= self.slabs.items.len) return null;
        return &self.slabs.items[slab_index][index_value % slab_size];
    }
};

test "paragraph sources deduplicate independently of layout width" {
    var fonts = api.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font"),
    });
    var cache = ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer cache.deinit();
    const request: ParagraphSourceCache.Request = .{
        .utf8 = "A retained paragraph",
        .language = "und",
        .logical_size = 16,
        .candidates = &.{font},
        .configuration_revision = 1,
    };
    const first = try cache.acquire(request);
    const second = try cache.acquire(request);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    try fonts.release(font);
    _ = try fonts.get(font);
    try cache.release(first);
    try cache.release(second);
    try std.testing.expectError(error.StaleParagraphSource, cache.get(first));
    try std.testing.expectError(error.StaleFont, fonts.get(font));
}

test "paragraph source index churn preserves live sources and stale generations" {
    var fonts = api.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font"),
    });
    defer fonts.release(font) catch unreachable;
    var cache = ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer cache.deinit();
    var request: ParagraphSourceCache.Request = .{
        .utf8 = "retained anchor",
        .language = "und",
        .logical_size = 14,
        .candidates = &.{font},
        .configuration_revision = 3,
    };
    const anchor = try cache.acquire(request);
    const source = try cache.get(anchor);
    var handles: [40]ParagraphSourceHandle = undefined;
    var buffer: [64]u8 = undefined;
    for (0..32) |generation| {
        for (&handles, 0..) |*handle, index| {
            request.utf8 = try std.fmt.bufPrint(&buffer, "transient {d}/{d}", .{ generation, index });
            handle.* = try cache.acquire(request);
        }
        for (0..handles.len) |index| try cache.release(handles[handles.len - 1 - index]);
        try std.testing.expectEqual(@as(usize, 1), cache.count());
        try std.testing.expectEqual(@as(u32, 1), cache.index.count());
        try std.testing.expect(cache.index_removals < cache.index.capacity() / 8);
        try std.testing.expectEqual(source, try cache.get(anchor));
        try std.testing.expectEqualStrings("retained anchor", source.utf8);
        try std.testing.expectError(error.StaleParagraphSource, cache.get(handles[0]));
        request.utf8 = "retained anchor";
        const duplicate = try cache.acquire(request);
        try std.testing.expectEqual(anchor, duplicate);
        try cache.release(duplicate);
    }
    try cache.release(anchor);
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}

fn exerciseSourceAllocationFailure(
    allocator: std.mem.Allocator,
    fonts: *api.FontCache,
    candidates: [2]api.FontHandle,
) !void {
    var cache = ParagraphSourceCache.init(allocator, fonts);
    defer cache.deinit();
    const handle = try cache.acquire(.{
        .utf8 = "Save حفظ",
        .language = "und",
        .logical_size = 16,
        .candidates = &candidates,
        .runs = &.{
            .{ .byte_start = 0, .byte_end = 5, .logical_size = 12, .candidate_start = 0, .candidate_count = 1 },
            .{ .byte_start = 5, .byte_end = "Save حفظ".len, .logical_size = 24, .candidate_start = 1, .candidate_count = 1 },
        },
        .configuration_revision = 1,
    });
    try cache.release(handle);
}

test "paragraph source allocation failures unwind font leases" {
    var fonts = api.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const latin = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font"),
    });
    defer fonts.release(latin) catch unreachable;
    const arabic = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/NotoSansArabic.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_arabic_test_font"),
    });
    defer fonts.release(arabic) catch unreachable;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseSourceAllocationFailure,
        .{ &fonts, [2]api.FontHandle{ latin, arabic } },
    );
    try std.testing.expectEqual(@as(usize, 2), fonts.count());
}

test "styled paragraph sources copy runs and distinguish style only changes" {
    const Color = @import("../core/color.zig").Color;
    var fonts = api.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font"),
    });
    defer fonts.release(font) catch unreachable;
    var cache = ParagraphSourceCache.init(std.testing.allocator, &fonts);
    defer cache.deinit();
    var runs = [_]StyledRun{.{ .byte_start = 0, .byte_end = 1, .logical_size = 12, .candidate_start = 0, .candidate_count = 1 }};
    const request: ParagraphSourceCache.Request = .{ .utf8 = "X", .language = "en", .logical_size = 16, .candidates = &.{font}, .runs = &runs, .configuration_revision = 1 };
    const first = try cache.acquire(request);
    defer cache.release(first) catch unreachable;
    const same = try cache.acquire(request);
    defer cache.release(same) catch unreachable;
    try std.testing.expectEqual(first, same);
    runs[0].logical_size = 27;
    runs[0].color = Color.rgba(210, 40, 70, 255);
    const changed = try cache.acquire(request);
    defer cache.release(changed) catch unreachable;
    try std.testing.expect(!std.meta.eql(first, changed));
    try std.testing.expectEqual(@as(f32, 12), (try cache.get(first)).runs[0].logical_size);
    try std.testing.expectEqual(@as(?Color, null), (try cache.get(first)).runs[0].color);
    try std.testing.expectEqual(runs[0], (try cache.get(changed)).runs[0]);
}
