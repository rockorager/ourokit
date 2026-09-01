const std = @import("std");
const c = @import("c.zig");
const core = @import("../core/root.zig");
const instance = @import("../ui/instance/tree.zig");
const input = @import("../ui/input/bindings.zig");
const semantics = @import("../ui/semantics/snapshot.zig");
const buttons = @import("../ui/widget/buttons.zig");
const text_input = @import("../ui/text_input/root.zig");
const text = @import("../text/root.zig");

pub const Handler = struct {
    id: u64,
    reference: c_int,
    kind: input.HandlerKind,

    pub fn takeReference(self: *Handler) c_int {
        const reference = self.reference;
        self.reference = c.no_reference;
        return reference;
    }
};

pub const Button = struct {
    id: u64,
    enabled: bool,
    style: buttons.Style,
};

pub const TextInput = struct {
    target_id: u64,
    content_id: u64,
    mode: text_input.ValueMode,
    behavior: text_input.Behavior,
    session: ?text_input.Session,
};

/// One candidate-owned, normalized window build. Registry references and
/// acquired shape references remain owned here until an application commit
/// transfers them into retained native UI or a failed candidate discards them.
pub const PreparedBuild = struct {
    allocator: std.mem.Allocator,
    state: *c.State,
    shapes: ?*text.ParagraphSourceCache,
    descriptor_storage: []instance.Descriptor,
    descriptor_count: usize = 0,
    semantic_storage: []semantics.Descriptor,
    semantic_count: usize = 0,
    semantic_text: []u8,
    semantic_text_count: usize = 0,
    handlers: []Handler,
    handler_count: usize = 0,
    prepared_buttons: []Button,
    button_count: usize = 0,
    text_inputs: []TextInput,
    text_input_count: usize = 0,
    owns_shapes: bool = false,
    reconcile_plan: ?instance.ReconcilePlan = null,
    size: ?core.SizeU = null,

    pub fn init(
        self: *PreparedBuild,
        allocator: std.mem.Allocator,
        state: *c.State,
        shapes: ?*text.ParagraphSourceCache,
        node_capacity: usize,
        semantic_text_capacity: usize,
    ) !void {
        if (node_capacity == 0 or semantic_text_capacity == 0)
            return error.InvalidPreparedBuildCapacity;
        const descriptor_storage = try allocator.alloc(instance.Descriptor, node_capacity);
        errdefer allocator.free(descriptor_storage);
        const semantic_storage = try allocator.alloc(semantics.Descriptor, node_capacity);
        errdefer allocator.free(semantic_storage);
        const semantic_text = try allocator.alloc(u8, semantic_text_capacity);
        errdefer allocator.free(semantic_text);
        const handlers = try allocator.alloc(Handler, node_capacity);
        errdefer allocator.free(handlers);
        const prepared_buttons = try allocator.alloc(Button, node_capacity);
        errdefer allocator.free(prepared_buttons);
        const text_inputs = try allocator.alloc(TextInput, node_capacity);
        self.* = .{
            .allocator = allocator,
            .state = state,
            .shapes = shapes,
            .descriptor_storage = descriptor_storage,
            .semantic_storage = semantic_storage,
            .semantic_text = semantic_text,
            .handlers = handlers,
            .prepared_buttons = prepared_buttons,
            .text_inputs = text_inputs,
        };
    }

    pub fn deinit(self: *PreparedBuild) void {
        self.reset();
        self.allocator.free(self.text_inputs);
        self.allocator.free(self.prepared_buttons);
        self.allocator.free(self.handlers);
        self.allocator.free(self.semantic_text);
        self.allocator.free(self.semantic_storage);
        self.allocator.free(self.descriptor_storage);
        self.* = undefined;
    }

    pub fn reset(self: *PreparedBuild) void {
        for (self.handlers[0..self.handler_count]) |handler|
            c.luaL_unref(self.state, c.registry_index, handler.reference);
        for (self.text_inputs[0..self.text_input_count]) |*text_input_value|
            if (text_input_value.session) |*session| session.deinit();
        if (self.owns_shapes) for (self.descriptor_storage[0..self.descriptor_count]) |descriptor|
            switch (descriptor.object) {
                .label => |label| self.shapes.?.release(label.source) catch unreachable,
                .text_input => |text_input_value| self.shapes.?.release(text_input_value.source) catch unreachable,
                else => {},
            };
        self.descriptor_count = 0;
        self.semantic_count = 0;
        self.semantic_text_count = 0;
        self.handler_count = 0;
        self.button_count = 0;
        self.text_input_count = 0;
        self.owns_shapes = false;
        self.reconcile_plan = null;
        self.size = null;
    }

    pub fn descriptors(self: *const PreparedBuild) []const instance.Descriptor {
        return self.descriptor_storage[0..self.descriptor_count];
    }

    pub fn semanticDescriptors(self: *const PreparedBuild) []const semantics.Descriptor {
        return self.semantic_storage[0..self.semantic_count];
    }
};
