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

/// Language-neutral desired state for one ordinary Wayland toplevel. A future
/// layer-surface declaration will be a distinct type because its role and
/// configure contract are not interchangeable with xdg_toplevel.
pub const ToplevelDeclaration = struct {
    id: []const u8,
    title: []const u8,
    initial_width: u32 = 640,
    initial_height: u32 = 480,
};

/// Native platform ownership boundary used by the desired-state reconciler.
/// Implementations own every Wayring object and platform buffer associated
/// with a window. These methods are called only during reconciliation, never
/// from a protocol callback.
pub const NativeHost = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create: *const fn (*anyopaque, WindowHandle, ScopeHandle, ToplevelDeclaration) anyerror!void,
        update_title: *const fn (*anyopaque, WindowHandle, []const u8) anyerror!void,
        begin_close: *const fn (*anyopaque, WindowHandle) anyerror!void,
    };

    pub fn create(
        self: NativeHost,
        handle: WindowHandle,
        scope: ScopeHandle,
        declaration: ToplevelDeclaration,
    ) !void {
        try self.vtable.create(self.context, handle, scope, declaration);
    }

    pub fn updateTitle(self: NativeHost, handle: WindowHandle, title: []const u8) !void {
        try self.vtable.update_title(self.context, handle, title);
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

    pub fn closed(self: EventSink, handle: WindowHandle) !void {
        try self.vtable.closed(self.context, handle);
    }
};
