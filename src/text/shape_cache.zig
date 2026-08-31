const std = @import("std");
const api = @import("api.zig");

pub const ShapeHandle = struct {
    slot: u32,
    generation: u32,
};

/// Cache of immutable fallback-shaped itemized runs. `font_cache` must outlive
/// this cache; every live entry retains its ordered candidate handles.
pub const ShapeCache = struct {
    allocator: std.mem.Allocator,
    font_cache: *api.FontCache,
    slabs: std.ArrayListUnmanaged(*Slab) = .empty,
    index: Index = .empty,
    free_head: u32 = invalid_slot,
    active_count: usize = 0,

    const slab_size = 16;
    const invalid_slot = std.math.maxInt(u32);

    pub const Request = struct {
        spec: api.RunSpec,
        candidates: []const api.FontHandle,
        /// Increment when Fontconfig substitutions/candidate policy changes.
        configuration_revision: u64,
    };

    const Key = struct {
        paragraph: []const u8,
        byte_start: usize,
        byte_len: usize,
        direction: api.Direction,
        script: api.Script,
        language: []const u8,
        logical_size_bits: u32,
        candidates: []const api.FontHandle,
        configuration_revision: u64,
    };

    const Entry = struct {
        key: Key,
        result: api.FallbackResult,
    };

    const Slot = struct {
        generation: u32 = 1,
        active: bool = false,
        references: u32 = 0,
        next_free: u32 = invalid_slot,
        entry: Entry = undefined,
    };

    const Slab = [slab_size]Slot;

    const KeyContext = struct {
        pub fn hash(_: KeyContext, key: Key) u64 {
            var hasher = std.hash.Wyhash.init(0);
            hasher.update(key.paragraph);
            hashValue(&hasher, key.byte_start);
            hashValue(&hasher, key.byte_len);
            hashValue(&hasher, @intFromEnum(key.direction));
            hashValue(&hasher, @intFromEnum(key.script));
            hasher.update(key.language);
            hashValue(&hasher, key.logical_size_bits);
            for (key.candidates) |candidate| {
                hashValue(&hasher, candidate.slot);
                hashValue(&hasher, candidate.generation);
            }
            hashValue(&hasher, key.configuration_revision);
            return hasher.final();
        }

        pub fn eql(_: KeyContext, a: Key, b: Key) bool {
            return a.byte_start == b.byte_start and
                a.byte_len == b.byte_len and
                a.direction == b.direction and
                a.script == b.script and
                a.logical_size_bits == b.logical_size_bits and
                a.configuration_revision == b.configuration_revision and
                std.mem.eql(u8, a.paragraph, b.paragraph) and
                std.mem.eql(u8, a.language, b.language) and
                handlesEqual(a.candidates, b.candidates);
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
    };

    const Index = std.HashMapUnmanaged(
        Key,
        ShapeHandle,
        KeyContext,
        std.hash_map.default_max_load_percentage,
    );

    pub fn init(allocator: std.mem.Allocator, font_cache: *api.FontCache) ShapeCache {
        return .{ .allocator = allocator, .font_cache = font_cache };
    }

    pub fn deinit(self: *ShapeCache) void {
        self.index.deinit(self.allocator);
        for (self.slabs.items) |slab| {
            for (slab) |*slot| if (slot.active) self.destroyEntry(&slot.entry);
            self.allocator.destroy(slab);
        }
        self.slabs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn acquire(self: *ShapeCache, request: Request) !ShapeHandle {
        if (request.candidates.len == 0) return error.NoFallbackCandidates;
        const transient_key = try requestKey(request);
        if (self.index.get(transient_key)) |handle| {
            const slot = try self.require(handle);
            if (slot.references == std.math.maxInt(u32)) return error.ReferenceOverflow;
            slot.references += 1;
            return handle;
        }

        const paragraph = try self.allocator.dupe(u8, transient_key.paragraph);
        errdefer self.allocator.free(paragraph);
        const language = try self.allocator.dupe(u8, transient_key.language);
        errdefer self.allocator.free(language);
        const candidate_handles = try self.allocator.dupe(api.FontHandle, request.candidates);
        errdefer self.allocator.free(candidate_handles);

        const fallback_candidates = try self.allocator.alloc(api.FallbackCandidate, request.candidates.len);
        defer self.allocator.free(fallback_candidates);
        var retained: usize = 0;
        errdefer for (request.candidates[0..retained]) |handle|
            self.font_cache.release(handle) catch unreachable;
        for (request.candidates, fallback_candidates) |handle, *candidate| {
            candidate.* = .{ .handle = handle, .font = try self.font_cache.get(handle) };
            try self.font_cache.retain(handle);
            retained += 1;
        }

        var result = try api.shapeWithFallback(self.allocator, fallback_candidates, request.spec);
        errdefer result.deinit();
        try self.index.ensureUnusedCapacity(self.allocator, 1);
        const slot_index = try self.takeSlot();
        const slot = self.slotAt(slot_index).?;
        const stored_key: Key = .{
            .paragraph = paragraph,
            .byte_start = transient_key.byte_start,
            .byte_len = transient_key.byte_len,
            .direction = transient_key.direction,
            .script = transient_key.script,
            .language = language,
            .logical_size_bits = transient_key.logical_size_bits,
            .candidates = candidate_handles,
            .configuration_revision = transient_key.configuration_revision,
        };
        slot.* = .{
            .generation = slot.generation,
            .active = true,
            .references = 1,
            .entry = .{ .key = stored_key, .result = result },
        };
        const handle: ShapeHandle = .{ .slot = slot_index, .generation = slot.generation };
        self.index.putAssumeCapacity(stored_key, handle);
        self.active_count += 1;
        return handle;
    }

    pub fn retain(self: *ShapeCache, handle: ShapeHandle) !void {
        const slot = try self.require(handle);
        if (slot.references == std.math.maxInt(u32)) return error.ReferenceOverflow;
        slot.references += 1;
    }

    pub fn validateRetain(self: *ShapeCache, handle: ShapeHandle) !void {
        const slot = try self.require(handle);
        if (slot.references == std.math.maxInt(u32)) return error.ReferenceOverflow;
    }

    pub fn release(self: *ShapeCache, handle: ShapeHandle) !void {
        const slot = try self.require(handle);
        std.debug.assert(slot.references != 0);
        slot.references -= 1;
        if (slot.references != 0) return;
        _ = self.index.remove(slot.entry.key);
        self.destroyEntry(&slot.entry);
        slot.active = false;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.next_free = self.free_head;
        self.free_head = handle.slot;
        self.active_count -= 1;
    }

    pub fn get(self: *const ShapeCache, handle: ShapeHandle) !*const api.FallbackResult {
        return &(try self.requireConst(handle)).entry.result;
    }

    pub fn count(self: *const ShapeCache) usize {
        return self.active_count;
    }

    fn requestKey(request: Request) !Key {
        const byte_len = request.spec.byte_len orelse request.spec.paragraph.len -| request.spec.byte_start;
        const byte_end = std.math.add(usize, request.spec.byte_start, byte_len) catch
            return error.InvalidRange;
        if (byte_end > request.spec.paragraph.len) return error.InvalidRange;
        return .{
            .paragraph = request.spec.paragraph,
            .byte_start = request.spec.byte_start,
            .byte_len = byte_len,
            .direction = request.spec.direction,
            .script = request.spec.script,
            .language = request.spec.language,
            .logical_size_bits = @bitCast(request.spec.logical_size),
            .candidates = request.candidates,
            .configuration_revision = request.configuration_revision,
        };
    }

    fn destroyEntry(self: *ShapeCache, entry: *Entry) void {
        entry.result.deinit();
        for (entry.key.candidates) |handle| self.font_cache.release(handle) catch unreachable;
        self.allocator.free(entry.key.candidates);
        self.allocator.free(entry.key.language);
        self.allocator.free(entry.key.paragraph);
    }

    fn takeSlot(self: *ShapeCache) !u32 {
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

    fn require(self: *ShapeCache, handle: ShapeHandle) !*Slot {
        const slot = self.slotAt(handle.slot) orelse return error.StaleShape;
        if (!slot.active or slot.generation != handle.generation) return error.StaleShape;
        return slot;
    }

    fn requireConst(self: *const ShapeCache, handle: ShapeHandle) !*const Slot {
        const slot = self.slotAtConst(handle.slot) orelse return error.StaleShape;
        if (!slot.active or slot.generation != handle.generation) return error.StaleShape;
        return slot;
    }

    fn slotAt(self: *ShapeCache, index_value: u32) ?*Slot {
        const slab_index: usize = index_value / slab_size;
        if (slab_index >= self.slabs.items.len) return null;
        return &self.slabs.items[slab_index][index_value % slab_size];
    }

    fn slotAtConst(self: *const ShapeCache, index_value: u32) ?*const Slot {
        const slab_index: usize = index_value / slab_size;
        if (slab_index >= self.slabs.items.len) return null;
        return &self.slabs.items[slab_index][index_value % slab_size];
    }
};

test "shape cache deduplicates full requests and owns candidate lifetimes" {
    const inter_bytes = @embedFile("ourokit_test_font");
    const arabic_bytes = @embedFile("ourokit_arabic_test_font");
    var fonts = api.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const inter = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = inter_bytes,
    });
    const arabic = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/NotoSansArabic.ttf", .index = 0 },
        .bytes = arabic_bytes,
    });

    var cache = ShapeCache.init(std.testing.allocator, &fonts);
    defer cache.deinit();
    const request: ShapeCache.Request = .{
        .spec = .{
            .paragraph = "سلام",
            .direction = .right_to_left,
            .script = .arabic,
            .language = "ar",
            .logical_size = 16,
        },
        .candidates = &.{ inter, arabic },
        .configuration_revision = 7,
    };
    const first = try cache.acquire(request);
    const result_pointer = try cache.get(first);
    const duplicate = try cache.acquire(request);
    try std.testing.expectEqual(first, duplicate);
    try std.testing.expectEqual(result_pointer, try cache.get(duplicate));
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    try std.testing.expectEqual(@as(usize, 1), result_pointer.spans.len);
    try std.testing.expectEqual(arabic, result_pointer.spans[0].font);
    try std.testing.expect(!result_pointer.has_missing_glyphs);

    // The caller can release its face references while the shaped entry keeps
    // both candidates alive for its immutable output and future cache hits.
    try fonts.release(inter);
    try fonts.release(arabic);
    try std.testing.expectEqual(@as(usize, 2), fonts.count());
    _ = try fonts.get(inter);
    _ = try fonts.get(arabic);

    try cache.release(duplicate);
    _ = try cache.get(first);
    try cache.release(first);
    try std.testing.expectEqual(@as(usize, 0), cache.count());
    try std.testing.expectEqual(@as(usize, 0), fonts.count());
    try std.testing.expectError(error.StaleShape, cache.get(first));
    try std.testing.expectError(error.StaleFont, fonts.get(inter));
    try std.testing.expectError(error.StaleFont, fonts.get(arabic));
}

test "shape cache key includes text style candidates and configuration revision" {
    const bytes = @embedFile("ourokit_test_font");
    var fonts = api.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const first_font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/first.ttf", .index = 0 },
        .bytes = bytes,
    });
    defer fonts.release(first_font) catch unreachable;
    const second_font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/second.ttf", .index = 0 },
        .bytes = bytes,
    });
    defer fonts.release(second_font) catch unreachable;

    var cache = ShapeCache.init(std.testing.allocator, &fonts);
    defer cache.deinit();
    const base: ShapeCache.Request = .{
        .spec = .{
            .paragraph = "cache key",
            .direction = .left_to_right,
            .script = .latin,
            .language = "en",
            .logical_size = 16,
        },
        .candidates = &.{ first_font, second_font },
        .configuration_revision = 1,
    };
    var handles: [5]ShapeHandle = undefined;
    handles[0] = try cache.acquire(base);
    var changed = base;
    changed.spec.paragraph = "cache keys";
    handles[1] = try cache.acquire(changed);
    changed = base;
    changed.spec.logical_size = 17;
    handles[2] = try cache.acquire(changed);
    changed = base;
    changed.candidates = &.{ second_font, first_font };
    handles[3] = try cache.acquire(changed);
    changed = base;
    changed.configuration_revision = 2;
    handles[4] = try cache.acquire(changed);

    try std.testing.expectEqual(@as(usize, handles.len), cache.count());
    for (handles, 0..) |handle, index|
        for (handles[index + 1 ..]) |other|
            try std.testing.expect(handle.slot != other.slot);
    for (handles) |handle| try cache.release(handle);
}

test "shape cache slabs keep result addresses stable beyond initial capacity" {
    const bytes = @embedFile("ourokit_test_font");
    var fonts = api.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = bytes,
    });
    defer fonts.release(font) catch unreachable;

    var cache = ShapeCache.init(std.testing.allocator, &fonts);
    defer cache.deinit();
    var handles: [17]ShapeHandle = undefined;
    var paragraphs: [17][32]u8 = undefined;
    var first_pointer: *const api.FallbackResult = undefined;
    for (&handles, &paragraphs, 0..) |*handle, *paragraph_buffer, index| {
        const paragraph = try std.fmt.bufPrint(paragraph_buffer, "stable shaped run {d}", .{index});
        handle.* = try cache.acquire(.{
            .spec = .{
                .paragraph = paragraph,
                .direction = .left_to_right,
                .script = .latin,
                .language = "en",
                .logical_size = 16,
            },
            .candidates = &.{font},
            .configuration_revision = 1,
        });
        if (index == 0) first_pointer = try cache.get(handle.*);
    }
    try std.testing.expectEqual(@as(usize, 17), cache.count());
    try std.testing.expectEqual(first_pointer, try cache.get(handles[0]));
    for (handles) |handle| try cache.release(handle);
}

fn exerciseShapeCacheAllocationFailure(
    allocator: std.mem.Allocator,
    fonts: *api.FontCache,
    candidates: [2]api.FontHandle,
) !void {
    var cache = ShapeCache.init(allocator, fonts);
    defer cache.deinit();
    const handle = try cache.acquire(.{
        .spec = .{
            .paragraph = "سلام",
            .direction = .right_to_left,
            .script = .arabic,
            .language = "ar",
            .logical_size = 16,
        },
        .candidates = &candidates,
        .configuration_revision = 1,
    });
    try cache.release(handle);
}

test "shape cache allocation failures unwind candidate ownership" {
    const inter_bytes = @embedFile("ourokit_test_font");
    const arabic_bytes = @embedFile("ourokit_arabic_test_font");
    var fonts = api.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const inter = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = inter_bytes,
    });
    defer fonts.release(inter) catch unreachable;
    const arabic = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/NotoSansArabic.ttf", .index = 0 },
        .bytes = arabic_bytes,
    });
    defer fonts.release(arabic) catch unreachable;

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseShapeCacheAllocationFailure,
        .{ &fonts, [2]api.FontHandle{ inter, arabic } },
    );
    try std.testing.expectEqual(@as(usize, 2), fonts.count());
}
