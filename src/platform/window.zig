const Handle = @import("../core/handle.zig").Handle;
const PointF = @import("../core/geometry.zig").PointF;
const ScopeHandle = @import("../task/scheduler.zig").ScopeHandle;

pub const WindowHandle = Handle;

pub const LogicalPosition = PointF;

pub const PointerButtonState = enum {
    released,
    pressed,
};

pub const PointerAxis = enum {
    vertical,
    horizontal,
};

pub const PointerAxisSource = enum {
    wheel,
    finger,
    continuous,
    wheel_tilt,
};

/// Platform-neutral pointer data translated from Wayland protocol events.
/// Button values retain Linux input-event codes. Axis deltas are logical
/// surface units; `steps120` preserves high-resolution wheel detents.
pub const PointerEvent = union(enum) {
    enter: struct {
        window: WindowHandle,
        serial: u32,
        position: LogicalPosition,
    },
    leave: struct {
        window: WindowHandle,
        serial: u32,
    },
    motion: struct {
        window: WindowHandle,
        time_ms: u32,
        position: LogicalPosition,
    },
    button: struct {
        window: WindowHandle,
        serial: u32,
        time_ms: u32,
        button: u32,
        state: PointerButtonState,
    },
    axis: struct {
        window: WindowHandle,
        time_ms: u32,
        axis: PointerAxis,
        delta: f32,
    },
    axis_source: struct {
        window: WindowHandle,
        source: PointerAxisSource,
    },
    axis_stop: struct {
        window: WindowHandle,
        time_ms: u32,
        axis: PointerAxis,
    },
    axis_steps: struct {
        window: WindowHandle,
        axis: PointerAxis,
        steps: i32,
    },
    axis_steps120: struct {
        window: WindowHandle,
        axis: PointerAxis,
        steps120: i32,
    },
    frame: WindowHandle,
};

pub const LogicalKey = enum {
    unidentified,
    tab,
    enter,
    space,
    escape,
    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,
    home,
    end,
    backspace,
    delete,
    key_a,
    key_c,
    key_v,
    key_x,
};

pub const KeyState = enum { released, pressed, repeated };

pub const Modifiers = packed struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    logo: bool = false,
};

pub const TranslatedKey = struct {
    keycode: u32,
    keysym: u32 = 0,
    unicode: u32 = 0,
    logical: LogicalKey = .unidentified,
    modifiers: Modifiers = .{},
};

pub const KeyboardEvent = union(enum) {
    enter: struct { window: WindowHandle, serial: u32 },
    leave: struct { window: WindowHandle, serial: u32 },
    key: struct {
        window: WindowHandle,
        serial: u32,
        time_ms: u32,
        state: KeyState,
        translated: TranslatedKey,
    },
};

pub const TextChangeCause = enum { input_method, other };

pub const TextContentPurpose = enum {
    normal,
    alpha,
    digits,
    number,
    phone,
    url,
    email,
    name,
    password,
    pin,
    date,
    time,
    datetime,
    terminal,
};

pub const TextContentHints = packed struct(u16) {
    completion: bool = false,
    spellcheck: bool = false,
    auto_capitalization: bool = false,
    lowercase: bool = false,
    uppercase: bool = false,
    titlecase: bool = false,
    hidden_text: bool = false,
    sensitive_data: bool = false,
    latin: bool = false,
    multiline: bool = false,
    _reserved: u6 = 0,
};

pub const SurroundingText = struct {
    text: []const u8,
    /// UTF-8 byte offsets into `text`, matching the Wayland text-input-v3
    /// protocol and the platform-independent editable-text model.
    cursor: usize,
    anchor: usize,
};

pub const TextInputState = struct {
    surrounding: ?SurroundingText = null,
    change_cause: TextChangeCause = .input_method,
    content_hints: TextContentHints = .{},
    content_purpose: TextContentPurpose = .normal,
    cursor_rectangle: ?struct { x: i32, y: i32, width: i32, height: i32 } = null,

    pub fn validate(self: TextInputState) !void {
        if (self.surrounding) |surrounding| {
            if (surrounding.text.len > 4000) return error.SurroundingTextTooLong;
            if (!@import("std").unicode.utf8ValidateSlice(surrounding.text)) return error.InvalidUtf8;
            if (@import("std").mem.indexOfScalar(u8, surrounding.text, 0) != null)
                return error.EmbeddedNul;
            if (!utf8Boundary(surrounding.text, surrounding.cursor) or
                !utf8Boundary(surrounding.text, surrounding.anchor))
                return error.InvalidTextOffset;
        }
        if (self.cursor_rectangle) |rectangle|
            if (rectangle.width < 0 or rectangle.height < 0) return error.InvalidCursorRectangle;
    }
};

/// One atomic text-input-v3 edit batch. Protocol callbacks may borrow these
/// slices only for the duration of `EventSink.textInput`; sinks must copy them
/// before returning. Consumers apply the fields in protocol order: remove the
/// old preedit, delete surrounding bytes, insert committed text, then install
/// the new preedit and its cursor.
pub const TextInputBatch = struct {
    window: WindowHandle,
    serial: u32,
    serial_matches_state: bool,
    delete_surrounding: ?struct {
        before_bytes: u32,
        after_bytes: u32,
    },
    commit: ?struct { text: ?[]const u8 },
    preedit: ?struct {
        text: ?[]const u8,
        cursor_begin: i32,
        cursor_end: i32,
    },
};

pub const TextInputEvent = union(enum) {
    enter: WindowHandle,
    leave: WindowHandle,
    batch: TextInputBatch,
};

fn utf8Boundary(text: []const u8, offset: usize) bool {
    if (offset > text.len) return false;
    return offset == text.len or (text[offset] & 0xc0) != 0x80;
}

/// Language-neutral desired state for one ordinary Wayland toplevel.
pub const ToplevelDeclaration = struct {
    id: []const u8,
    title: []const u8,
    initial_width: u32 = 640,
    initial_height: u32 = 480,
    min_width: u32 = 0,
    min_height: u32 = 0,
};

pub const Layer = enum { background, bottom, top, overlay };
pub const KeyboardInteractivity = enum { none, exclusive, on_demand };
pub const Edge = enum { top, bottom, left, right };

pub const Anchors = struct {
    top: bool = false,
    bottom: bool = false,
    left: bool = false,
    right: bool = false,
};

pub const Margins = struct {
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
    left: i32 = 0,
};

/// Language-neutral desired state for one wlr-layer-shell surface. Output is
/// deliberately compositor-selected until Ourokit exposes stable output
/// identities at the application boundary.
pub const LayerSurfaceDeclaration = struct {
    id: []const u8,
    namespace: []const u8,
    width: u32,
    height: u32,
    layer: Layer,
    anchors: Anchors = .{},
    exclusive_zone: i32 = 0,
    exclusive_edge: ?Edge = null,
    margins: Margins = .{},
    keyboard_interactivity: KeyboardInteractivity = .none,

    pub fn validate(self: LayerSurfaceDeclaration) !void {
        if (self.id.len == 0) return error.EmptyWindowId;
        if (self.namespace.len == 0) return error.EmptyLayerSurfaceNamespace;
        if (self.width == 0 and !(self.anchors.left and self.anchors.right))
            return error.InvalidLayerSurfaceSize;
        if (self.height == 0 and !(self.anchors.top and self.anchors.bottom))
            return error.InvalidLayerSurfaceSize;
        if (self.exclusive_zone < -1) return error.InvalidExclusiveZone;
        if (self.exclusive_edge) |edge| {
            const anchored = switch (edge) {
                .top => self.anchors.top,
                .bottom => self.anchors.bottom,
                .left => self.anchors.left,
                .right => self.anchors.right,
            };
            if (!anchored) return error.InvalidExclusiveEdge;
        }
    }
};

/// Surface roles remain distinct because their configure and update contracts
/// are not interchangeable.
pub const SurfaceDeclaration = union(enum) {
    toplevel: ToplevelDeclaration,
    layer_surface: LayerSurfaceDeclaration,

    pub fn id(self: SurfaceDeclaration) []const u8 {
        return switch (self) {
            inline else => |declaration| declaration.id,
        };
    }

    pub fn initialWidth(self: SurfaceDeclaration) u32 {
        return switch (self) {
            .toplevel => |declaration| declaration.initial_width,
            .layer_surface => |declaration| declaration.width,
        };
    }

    pub fn initialHeight(self: SurfaceDeclaration) u32 {
        return switch (self) {
            .toplevel => |declaration| declaration.initial_height,
            .layer_surface => |declaration| declaration.height,
        };
    }
};

/// Native platform ownership boundary used by the desired-state reconciler.
/// Implementations own every Wayring object and platform buffer associated
/// with a window. These methods are called only during reconciliation, never
/// from a protocol callback.
pub const NativeHost = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create: *const fn (*anyopaque, WindowHandle, ScopeHandle, SurfaceDeclaration) anyerror!void,
        update_title: *const fn (*anyopaque, WindowHandle, []const u8) anyerror!void,
        update_minimum_size: *const fn (*anyopaque, WindowHandle, u32, u32) anyerror!void,
        update_layer_surface: *const fn (*anyopaque, WindowHandle, LayerSurfaceDeclaration) anyerror!void,
        begin_close: *const fn (*anyopaque, WindowHandle) anyerror!void,
    };

    pub fn create(
        self: NativeHost,
        handle: WindowHandle,
        scope: ScopeHandle,
        declaration: SurfaceDeclaration,
    ) !void {
        try self.vtable.create(self.context, handle, scope, declaration);
    }

    pub fn updateTitle(self: NativeHost, handle: WindowHandle, title: []const u8) !void {
        try self.vtable.update_title(self.context, handle, title);
    }

    pub fn updateMinimumSize(
        self: NativeHost,
        handle: WindowHandle,
        width: u32,
        height: u32,
    ) !void {
        try self.vtable.update_minimum_size(self.context, handle, width, height);
    }

    pub fn updateLayerSurface(
        self: NativeHost,
        handle: WindowHandle,
        declaration: LayerSurfaceDeclaration,
    ) !void {
        try self.vtable.update_layer_surface(self.context, handle, declaration);
    }

    pub fn beginClose(self: NativeHost, handle: WindowHandle) !void {
        try self.vtable.begin_close(self.context, handle);
    }
};

/// State-only sink used by protocol dispatch and platform maintenance. The
/// implementation may queue data and cancellation, but must never execute an
/// application-language callback.
pub const EventSink = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        close_requested: *const fn (*anyopaque, WindowHandle) anyerror!void,
        configured: *const fn (*anyopaque, WindowHandle, u32, u32) anyerror!void,
        pointer: *const fn (*anyopaque, PointerEvent) anyerror!void,
        keyboard: *const fn (*anyopaque, KeyboardEvent) anyerror!void,
        text_input: *const fn (*anyopaque, TextInputEvent) anyerror!void,
        closed: *const fn (*anyopaque, WindowHandle) anyerror!void,
    };

    pub fn closeRequested(self: EventSink, handle: WindowHandle) !void {
        try self.vtable.close_requested(self.context, handle);
    }

    pub fn configured(self: EventSink, handle: WindowHandle, width: u32, height: u32) !void {
        try self.vtable.configured(self.context, handle, width, height);
    }

    pub fn pointer(self: EventSink, event: PointerEvent) !void {
        try self.vtable.pointer(self.context, event);
    }

    pub fn keyboard(self: EventSink, event: KeyboardEvent) !void {
        try self.vtable.keyboard(self.context, event);
    }

    pub fn textInput(self: EventSink, event: TextInputEvent) !void {
        try self.vtable.text_input(self.context, event);
    }

    pub fn closed(self: EventSink, handle: WindowHandle) !void {
        try self.vtable.closed(self.context, handle);
    }
};

test "text input state validates UTF-8 protocol offsets" {
    try (TextInputState{ .surrounding = .{
        .text = "AéB",
        .cursor = 3,
        .anchor = 1,
    } }).validate();
    try @import("std").testing.expectError(error.InvalidTextOffset, (TextInputState{ .surrounding = .{
        .text = "AéB",
        .cursor = 2,
        .anchor = 1,
    } }).validate());
    try @import("std").testing.expectError(error.InvalidUtf8, (TextInputState{ .surrounding = .{
        .text = &.{0xff},
        .cursor = 0,
        .anchor = 0,
    } }).validate());
}

test "layer surface dimensions validate against opposing anchors" {
    const panel: LayerSurfaceDeclaration = .{
        .id = "panel",
        .namespace = "ouro-shell",
        .width = 0,
        .height = 32,
        .layer = .top,
        .anchors = .{ .top = true, .left = true, .right = true },
    };
    try panel.validate();

    var invalid = panel;
    invalid.anchors.right = false;
    try @import("std").testing.expectError(error.InvalidLayerSurfaceSize, invalid.validate());
    invalid = panel;
    invalid.exclusive_zone = -2;
    try @import("std").testing.expectError(error.InvalidExclusiveZone, invalid.validate());
    invalid = panel;
    invalid.exclusive_edge = .bottom;
    try @import("std").testing.expectError(error.InvalidExclusiveEdge, invalid.validate());
}
