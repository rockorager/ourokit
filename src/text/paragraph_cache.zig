//! Application-owned cache of immutable, width-specific paragraph layouts.

const std = @import("std");
const api = @import("api.zig");
const paragraph = @import("paragraph.zig");
const paragraph_layout = @import("paragraph_layout.zig");
const paragraph_style = @import("paragraph_style.zig");

pub const ParagraphHandle = struct {
    slot: u32,
    generation: u32,
};

pub const ParagraphLayout = paragraph_layout.Layout;

/// Width-specific paragraph layouts. The font cache must outlive this cache;
/// every live entry retains its complete ordered fallback candidate set.
pub const ParagraphCache = struct {
    allocator: std.mem.Allocator,
    font_cache: *api.FontCache,
    slabs: std.ArrayListUnmanaged(*Slab) = .empty,
    index: Index = .empty,
    free_head: u32 = invalid_slot,
    active_count: usize = 0,

    const slab_size = 16;
    const invalid_slot = std.math.maxInt(u32);

    pub const Request = struct {
        utf8: []const u8,
        base_direction: paragraph.BaseDirection = .auto_left_to_right,
        language: []const u8,
        logical_size: f32,
        max_width: f32,
        style: paragraph_style.Style = .{},
        /// Noninteractive labels avoid extra per-grapheme storage and work.
        include_caret_stops: bool = false,
        candidates: []const api.FontHandle,
        /// Increment when Fontconfig substitutions/candidate policy changes.
        configuration_revision: u64,
    };

    const Key = struct {
        utf8: []const u8,
        base_direction: paragraph.BaseDirection,
        language: []const u8,
        logical_size_bits: u32,
        max_width_bits: u32,
        alignment: paragraph_style.Alignment,
        max_lines: u32,
        overflow: paragraph_style.Overflow,
        include_caret_stops: bool,
        candidates: []const api.FontHandle,
        configuration_revision: u64,
    };

    const Entry = struct {
        key: Key,
        layout: ParagraphLayout,
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
            hasher.update(key.utf8);
            hashValue(&hasher, @intFromEnum(key.base_direction));
            hasher.update(key.language);
            hashValue(&hasher, key.logical_size_bits);
            hashValue(&hasher, key.max_width_bits);
            hashValue(&hasher, @intFromEnum(key.alignment));
            hashValue(&hasher, key.max_lines);
            hashValue(&hasher, @intFromEnum(key.overflow));
            hashValue(&hasher, key.include_caret_stops);
            for (key.candidates) |candidate| {
                hashValue(&hasher, candidate.slot);
                hashValue(&hasher, candidate.generation);
            }
            hashValue(&hasher, key.configuration_revision);
            return hasher.final();
        }

        pub fn eql(_: KeyContext, a: Key, b: Key) bool {
            return a.base_direction == b.base_direction and
                a.logical_size_bits == b.logical_size_bits and
                a.max_width_bits == b.max_width_bits and
                a.alignment == b.alignment and
                a.max_lines == b.max_lines and
                a.overflow == b.overflow and
                a.include_caret_stops == b.include_caret_stops and
                a.configuration_revision == b.configuration_revision and
                std.mem.eql(u8, a.utf8, b.utf8) and
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
        ParagraphHandle,
        KeyContext,
        std.hash_map.default_max_load_percentage,
    );

    pub fn init(allocator: std.mem.Allocator, font_cache: *api.FontCache) ParagraphCache {
        return .{ .allocator = allocator, .font_cache = font_cache };
    }

    pub fn deinit(self: *ParagraphCache) void {
        self.index.deinit(self.allocator);
        for (self.slabs.items) |slab| {
            for (slab) |*slot| if (slot.active) self.destroyEntry(&slot.entry);
            self.allocator.destroy(slab);
        }
        self.slabs.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn acquire(self: *ParagraphCache, request: Request) !ParagraphHandle {
        const transient_key = try requestKey(request);
        if (self.index.get(transient_key)) |handle| {
            const slot = try self.require(handle);
            if (slot.references == std.math.maxInt(u32)) return error.ReferenceOverflow;
            slot.references += 1;
            return handle;
        }

        const utf8 = try self.allocator.dupe(u8, transient_key.utf8);
        errdefer self.allocator.free(utf8);
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

        var layout = try paragraph_layout.build(
            self.allocator,
            utf8,
            transient_key.base_direction,
            fallback_candidates,
            language,
            @bitCast(transient_key.logical_size_bits),
            @bitCast(transient_key.max_width_bits),
            .{
                .alignment = transient_key.alignment,
                .max_lines = if (transient_key.max_lines == 0) null else transient_key.max_lines,
                .overflow = transient_key.overflow,
            },
            transient_key.include_caret_stops,
        );
        errdefer layout.deinit();
        try self.index.ensureUnusedCapacity(self.allocator, 1);
        const slot_index = try self.takeSlot();
        const slot = self.slotAt(slot_index).?;
        const stored_key: Key = .{
            .utf8 = utf8,
            .base_direction = transient_key.base_direction,
            .language = language,
            .logical_size_bits = transient_key.logical_size_bits,
            .max_width_bits = transient_key.max_width_bits,
            .alignment = transient_key.alignment,
            .max_lines = transient_key.max_lines,
            .overflow = transient_key.overflow,
            .include_caret_stops = transient_key.include_caret_stops,
            .candidates = candidate_handles,
            .configuration_revision = transient_key.configuration_revision,
        };
        slot.* = .{
            .generation = slot.generation,
            .active = true,
            .references = 1,
            .entry = .{ .key = stored_key, .layout = layout },
        };
        const handle: ParagraphHandle = .{ .slot = slot_index, .generation = slot.generation };
        self.index.putAssumeCapacity(stored_key, handle);
        self.active_count += 1;
        return handle;
    }

    pub fn retain(self: *ParagraphCache, handle: ParagraphHandle) !void {
        const slot = try self.require(handle);
        if (slot.references == std.math.maxInt(u32)) return error.ReferenceOverflow;
        slot.references += 1;
    }

    pub fn release(self: *ParagraphCache, handle: ParagraphHandle) !void {
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

    pub fn get(self: *const ParagraphCache, handle: ParagraphHandle) !*const ParagraphLayout {
        return &(try self.requireConst(handle)).entry.layout;
    }

    pub fn count(self: *const ParagraphCache) usize {
        return self.active_count;
    }

    fn requestKey(request: Request) !Key {
        if (request.candidates.len == 0) return error.NoFallbackCandidates;
        if (!std.math.isFinite(request.logical_size) or request.logical_size <= 0)
            return error.InvalidLogicalSize;
        if (!std.math.isFinite(request.max_width) or request.max_width < 0)
            return error.InvalidWidth;
        if (request.style.max_lines == 0) return error.InvalidMaxLines;
        if (request.style.overflow == .ellipsis and request.style.max_lines == null)
            return error.EllipsisRequiresMaxLines;
        return .{
            .utf8 = request.utf8,
            .base_direction = request.base_direction,
            .language = request.language,
            .logical_size_bits = @bitCast(request.logical_size),
            .max_width_bits = @bitCast(if (request.max_width == 0) @as(f32, 0) else request.max_width),
            .alignment = request.style.alignment,
            .max_lines = request.style.max_lines orelse 0,
            .overflow = request.style.overflow,
            .include_caret_stops = request.include_caret_stops,
            .candidates = request.candidates,
            .configuration_revision = request.configuration_revision,
        };
    }

    fn destroyEntry(self: *ParagraphCache, entry: *Entry) void {
        entry.layout.deinit();
        for (entry.key.candidates) |handle| self.font_cache.release(handle) catch unreachable;
        self.allocator.free(entry.key.candidates);
        self.allocator.free(entry.key.language);
        self.allocator.free(entry.key.utf8);
    }

    fn takeSlot(self: *ParagraphCache) !u32 {
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

    fn require(self: *ParagraphCache, handle: ParagraphHandle) !*Slot {
        const slot = self.slotAt(handle.slot) orelse return error.StaleParagraph;
        if (!slot.active or slot.generation != handle.generation) return error.StaleParagraph;
        return slot;
    }

    fn requireConst(self: *const ParagraphCache, handle: ParagraphHandle) !*const Slot {
        const slot = self.slotAtConst(handle.slot) orelse return error.StaleParagraph;
        if (!slot.active or slot.generation != handle.generation) return error.StaleParagraph;
        return slot;
    }

    fn slotAt(self: *ParagraphCache, index_value: u32) ?*Slot {
        const slab_index: usize = index_value / slab_size;
        if (slab_index >= self.slabs.items.len) return null;
        return &self.slabs.items[slab_index][index_value % slab_size];
    }

    fn slotAtConst(self: *const ParagraphCache, index_value: u32) ?*const Slot {
        const slab_index: usize = index_value / slab_size;
        if (slab_index >= self.slabs.items.len) return null;
        return &self.slabs.items[slab_index][index_value % slab_size];
    }
};

test "paragraph cache owns mixed-script positioned layouts and font leases" {
    var fonts = api.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const latin = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/Inter.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_test_font"),
    });
    const arabic = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/NotoSansArabic.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_arabic_test_font"),
    });
    var cache = ParagraphCache.init(std.testing.allocator, &fonts);
    defer cache.deinit();
    const request: ParagraphCache.Request = .{
        .utf8 = "Save حفظ now",
        .language = "und",
        .logical_size = 16,
        .max_width = 80,
        .candidates = &.{ latin, arabic },
        .configuration_revision = 1,
    };
    const first = try cache.acquire(request);
    const second = try cache.acquire(request);
    try std.testing.expectEqual(first, second);
    try std.testing.expectEqual(@as(usize, 1), cache.count());
    const layout = try cache.get(first);
    try std.testing.expect(layout.positioned.lines.len >= 1);
    try std.testing.expect(layout.positioned.glyphs.len != 0);
    try std.testing.expectEqual(@as(usize, 0), layout.positioned.carets.len);
    try std.testing.expect(layout.size.width > 0);
    try std.testing.expect(layout.size.height > 0);
    const interactive = try cache.acquire(.{
        .utf8 = request.utf8,
        .language = request.language,
        .logical_size = request.logical_size,
        .max_width = request.max_width,
        .include_caret_stops = true,
        .candidates = request.candidates,
        .configuration_revision = request.configuration_revision,
    });
    try std.testing.expect(interactive.slot != first.slot);
    try std.testing.expect((try cache.get(interactive)).positioned.carets.len != 0);
    const centered = try cache.acquire(.{
        .utf8 = request.utf8,
        .language = request.language,
        .logical_size = request.logical_size,
        .max_width = request.max_width,
        .style = .{ .alignment = .center, .max_lines = 1 },
        .candidates = request.candidates,
        .configuration_revision = request.configuration_revision,
    });
    const centered_layout = try cache.get(centered);
    try std.testing.expectEqual(@as(usize, 1), centered_layout.positioned.lines.len);
    try std.testing.expect(centered_layout.positioned.truncated);
    try std.testing.expect(centered_layout.positioned.lines[0].left > 0);
    try std.testing.expectEqual(@as(usize, 3), cache.count());
    try fonts.release(latin);
    try fonts.release(arabic);
    _ = try fonts.get(latin);
    _ = try fonts.get(arabic);
    try cache.release(first);
    try cache.release(second);
    try cache.release(interactive);
    try cache.release(centered);
    try std.testing.expectError(error.StaleParagraph, cache.get(first));
    try std.testing.expectError(error.StaleFont, fonts.get(latin));
    try std.testing.expectError(error.StaleFont, fonts.get(arabic));
}

test "ellipsis is shaped in paragraph context and maps to a source boundary" {
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
    var cache = ParagraphCache.init(std.testing.allocator, &fonts);
    defer cache.deinit();
    const source = "Save this document then continue to the next workflow step";
    const handle = try cache.acquire(.{
        .utf8 = source,
        .language = "und",
        .logical_size = 16,
        .max_width = 130,
        .style = .{ .max_lines = 1, .overflow = .ellipsis },
        .candidates = &.{ latin, arabic },
        .configuration_revision = 1,
    });
    defer cache.release(handle) catch unreachable;
    const layout = try cache.get(handle);
    try std.testing.expectEqual(@as(usize, 1), layout.positioned.lines.len);
    try std.testing.expect(layout.positioned.truncated);
    try std.testing.expectEqual(source.len, layout.positioned.source_byte_len);
    const insertion = layout.positioned.ellipsis_byte_offset.?;
    try std.testing.expect(insertion > 0 and insertion < source.len);
    try std.testing.expect(std.unicode.utf8ByteSequenceLength(source[insertion]) catch 0 != 0);
    var synthetic_count: usize = 0;
    for (layout.positioned.glyphs) |glyph| {
        if (glyph.synthetic) {
            synthetic_count += 1;
            try std.testing.expectEqual(insertion, glyph.cluster);
        } else {
            try std.testing.expect(glyph.cluster < insertion);
        }
    }
    try std.testing.expect(synthetic_count != 0);
    for (layout.positioned.spans) |span|
        try std.testing.expect(span.byte_start + span.byte_len <= insertion);

    const rtl_source = "احفظ هذا المستند ثم تابع إلى خطوة سير العمل التالية";
    const rtl_handle = try cache.acquire(.{
        .utf8 = rtl_source,
        .language = "ar",
        .logical_size = 16,
        .max_width = 130,
        .style = .{ .max_lines = 1, .overflow = .ellipsis },
        .candidates = &.{ latin, arabic },
        .configuration_revision = 1,
    });
    defer cache.release(rtl_handle) catch unreachable;
    const rtl_layout = try cache.get(rtl_handle);
    try std.testing.expectEqual(@as(usize, 1), rtl_layout.positioned.lines.len);
    try std.testing.expect(rtl_layout.positioned.truncated);
    var synthetic_x = std.math.inf(f32);
    var source_x = std.math.inf(f32);
    for (rtl_layout.positioned.glyphs) |glyph| {
        if (glyph.synthetic)
            synthetic_x = @min(synthetic_x, glyph.origin.x)
        else
            source_x = @min(source_x, glyph.origin.x);
    }
    try std.testing.expect(std.math.isFinite(synthetic_x));
    try std.testing.expect(std.math.isFinite(source_x));
    try std.testing.expect(synthetic_x < source_x);

    const justified_handle = try cache.acquire(.{
        .utf8 = "Save حفظ this document then continue متابعة to the next workflow step",
        .language = "und",
        .logical_size = 16,
        .max_width = 130,
        .style = .{ .alignment = .justify },
        .candidates = &.{ latin, arabic },
        .configuration_revision = 1,
    });
    defer cache.release(justified_handle) catch unreachable;
    const justified = try cache.get(justified_handle);
    try std.testing.expect(justified.positioned.lines.len > 1);
    try std.testing.expectApproxEqAbs(
        @as(f32, 130),
        justified.positioned.lines[0].advance,
        0.001,
    );
    try std.testing.expect(justified.positioned.lines[justified.positioned.lines.len - 1].advance < 130);

    try std.testing.expectError(error.EllipsisRequiresMaxLines, cache.acquire(.{
        .utf8 = source,
        .language = "und",
        .logical_size = 16,
        .max_width = 130,
        .style = .{ .overflow = .ellipsis },
        .candidates = &.{latin},
        .configuration_revision = 1,
    }));
}

fn exerciseParagraphAllocationFailure(
    allocator: std.mem.Allocator,
    fonts: *api.FontCache,
    candidates: [2]api.FontHandle,
) !void {
    var cache = ParagraphCache.init(allocator, fonts);
    defer cache.deinit();
    const handle = try cache.acquire(.{
        .utf8 = "Save حفظ now and continue to the next workflow step",
        .language = "und",
        .logical_size = 16,
        .max_width = 80,
        .style = .{ .max_lines = 1, .overflow = .ellipsis },
        .candidates = &candidates,
        .configuration_revision = 1,
    });
    try cache.release(handle);
}

test "paragraph layout allocation failures unwind font leases" {
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
        exerciseParagraphAllocationFailure,
        .{ &fonts, [2]api.FontHandle{ latin, arabic } },
    );
    try std.testing.expectEqual(@as(usize, 2), fonts.count());
}
