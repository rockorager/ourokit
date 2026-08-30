const std = @import("std");

/// Instantiate a stable-address, generation-checked cache for a shaping font
/// type. File bytes are supplied by the caller; this cache never performs
/// blocking I/O.
pub fn Cache(comptime Font: type, comptime Handle: type) type {
    return struct {
        allocator: std.mem.Allocator,
        slabs: std.ArrayListUnmanaged(*Slab) = .empty,
        free_head: u32 = invalid_slot,
        active_count: usize = 0,

        const Self = @This();
        const slab_size = 16;
        const invalid_slot = std.math.maxInt(u32);

        pub const FaceKey = struct {
            file: []const u8,
            index: u32,
            variations: ?[]const u8 = null,
            /// Caller-provided file identity (for example stat metadata or a
            /// content generation) prevents stale reuse after replacement.
            source_revision: u64 = 0,
        };

        pub const Load = struct {
            key: FaceKey,
            bytes: []const u8,
        };

        const Slot = struct {
            generation: u32 = 1,
            active: bool = false,
            references: u32 = 0,
            next_free: u32 = invalid_slot,
            file: []u8 = &.{},
            index: u32 = 0,
            variations: ?[]u8 = null,
            source_revision: u64 = 0,
            font: Font = undefined,
        };

        const Slab = [slab_size]Slot;

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        /// Destroy all cached faces during owner-scope teardown. Outstanding
        /// handles become invalid with the cache itself.
        pub fn deinit(self: *Self) void {
            for (self.slabs.items) |slab| {
                for (slab) |*slot| if (slot.active) self.destroySlot(slot);
                self.allocator.destroy(slab);
            }
            self.slabs.deinit(self.allocator);
            self.* = undefined;
        }

        /// Acquire an existing face or initialize it from caller-supplied
        /// bytes. Dedupe is linear over loaded faces; font loading is cold-path
        /// work and unchanged shaping resolves handles in O(1).
        pub fn acquire(self: *Self, load: Load) !Handle {
            if (load.key.file.len == 0) return error.InvalidFaceKey;
            for (self.slabs.items, 0..) |slab, slab_index| {
                for (slab, 0..) |*slot, offset| {
                    if (!slot.active or !keyMatches(slot, load.key)) continue;
                    if (slot.references == std.math.maxInt(u32)) return error.ReferenceOverflow;
                    slot.references += 1;
                    return makeHandle(slab_index, offset, slot.generation);
                }
            }

            const file = try self.allocator.dupe(u8, load.key.file);
            errdefer self.allocator.free(file);
            const variations = if (load.key.variations) |value|
                try self.allocator.dupe(u8, value)
            else
                null;
            errdefer if (variations) |value| self.allocator.free(value);
            var font = try Font.initConfigured(load.bytes, load.key.index, load.key.variations);
            errdefer font.deinit();

            const slot_index = try self.takeSlot();
            const slot = self.slotAt(slot_index).?;
            slot.* = .{
                .generation = slot.generation,
                .active = true,
                .references = 1,
                .file = file,
                .index = load.key.index,
                .variations = variations,
                .source_revision = load.key.source_revision,
                .font = font,
            };
            self.active_count += 1;
            return .{ .slot = slot_index, .generation = slot.generation };
        }

        pub fn retain(self: *Self, handle: Handle) !void {
            const slot = try self.require(handle);
            if (slot.references == std.math.maxInt(u32)) return error.ReferenceOverflow;
            slot.references += 1;
        }

        pub fn release(self: *Self, handle: Handle) !void {
            const slot = try self.require(handle);
            std.debug.assert(slot.references != 0);
            slot.references -= 1;
            if (slot.references != 0) return;
            self.destroySlot(slot);
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            slot.next_free = self.free_head;
            self.free_head = handle.slot;
            self.active_count -= 1;
        }

        pub fn get(self: *const Self, handle: Handle) !*const Font {
            return &(try self.requireConst(handle)).font;
        }

        pub fn count(self: *const Self) usize {
            return self.active_count;
        }

        fn takeSlot(self: *Self) !u32 {
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

        fn require(self: *Self, handle: Handle) !*Slot {
            const slot = self.slotAt(handle.slot) orelse return error.StaleFont;
            if (!slot.active or slot.generation != handle.generation) return error.StaleFont;
            return slot;
        }

        fn requireConst(self: *const Self, handle: Handle) !*const Slot {
            const slot = self.slotAtConst(handle.slot) orelse return error.StaleFont;
            if (!slot.active or slot.generation != handle.generation) return error.StaleFont;
            return slot;
        }

        fn slotAt(self: *Self, index: u32) ?*Slot {
            const slab_index: usize = index / slab_size;
            if (slab_index >= self.slabs.items.len) return null;
            return &self.slabs.items[slab_index][index % slab_size];
        }

        fn slotAtConst(self: *const Self, index: u32) ?*const Slot {
            const slab_index: usize = index / slab_size;
            if (slab_index >= self.slabs.items.len) return null;
            return &self.slabs.items[slab_index][index % slab_size];
        }

        fn destroySlot(self: *Self, slot: *Slot) void {
            slot.font.deinit();
            if (slot.variations) |variations| self.allocator.free(variations);
            self.allocator.free(slot.file);
            slot.active = false;
            slot.references = 0;
            slot.file = &.{};
            slot.variations = null;
        }

        fn keyMatches(slot: *const Slot, key: FaceKey) bool {
            return slot.index == key.index and
                slot.source_revision == key.source_revision and
                std.mem.eql(u8, slot.file, key.file) and
                optionalEql(slot.variations, key.variations);
        }

        fn optionalEql(a: ?[]const u8, b: ?[]const u8) bool {
            if (a == null or b == null) return a == null and b == null;
            return std.mem.eql(u8, a.?, b.?);
        }

        fn makeHandle(slab_index: usize, offset: usize, generation: u32) Handle {
            return .{
                .slot = @intCast(slab_index * slab_size + offset),
                .generation = generation,
            };
        }
    };
}
