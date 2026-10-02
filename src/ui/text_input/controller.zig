const std = @import("std");
const model = @import("model.zig");
const Registry = @import("registry.zig").Registry;
const Handle = @import("../../core/handle.zig").Handle;

/// A retained capability, not a borrowed Model pointer. Mounts and Lua each
/// own a reference. Removing the last mount makes every operation unavailable.
pub const Controller = struct {
    allocator: std.mem.Allocator,
    references: usize = 1,
    generation: u64 = 0,
    mounts: ?*Mount = null,

    pub const Host = struct {
        context: *anyopaque,
        validate: *const fn (*anyopaque, Handle) anyerror!void,
        changed: *const fn (*anyopaque, Handle, bool) anyerror!void,
    };
    pub const Mount = struct {
        controller: *Controller,
        registry: *Registry,
        target: Handle,
        next: ?*Mount = null,
    };
    pub const Token = struct { generation: u64, session: u64, composition: u64, revision: u64 };
    pub const State = struct { token: Token, selection: model.Selection, bytes: usize };

    pub fn create(allocator: std.mem.Allocator) !*Controller {
        const self = try allocator.create(Controller);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn retain(self: *Controller) void {
        self.references += 1;
    }

    pub fn release(self: *Controller) void {
        self.references -= 1;
        if (self.references == 0) {
            std.debug.assert(self.mounts == null);
            self.allocator.destroy(self);
        }
    }

    pub fn attach(self: *Controller, mount: *Mount) void {
        self.retain();
        mount.next = self.mounts;
        self.mounts = mount;
        self.generation +%= 1;
    }

    pub fn detach(self: *Controller, mount: *Mount) void {
        var link = &self.mounts;
        while (link.*) |current| {
            if (current == mount) {
                link.* = current.next;
                self.generation +%= 1;
                self.release();
                return;
            }
            link = &current.next;
        }
        unreachable;
    }

    fn mounted(self: *Controller) !*Mount {
        const mount = self.mounts orelse return error.EditorNotMounted;
        if (mount.next != null) return error.EditorControllerAmbiguous;
        const host = mount.registry.controller_host orelse return error.EditorControllerUnavailable;
        try host.validate(host.context, mount.target);
        const session = try mount.registry.session(mount.target);
        if (session.model.isSecret()) return error.SecureInputProtected;
        if (session.preedit() != null or session.isSelecting()) return error.EditorInputInProgress;
        const behavior = try mount.registry.getBehavior(mount.target);
        if (!behavior.enabled) return error.EditorDisabled;
        return mount;
    }

    pub fn state(self: *Controller) !State {
        const mount = try self.mounted();
        const session = try mount.registry.session(mount.target);
        const value = &session.model;
        return .{
            .token = .{ .generation = self.generation, .session = try mount.registry.sessionGeneration(mount.target), .composition = session.revision, .revision = value.revision },
            .selection = value.selection,
            .bytes = value.byteLen(),
        };
    }

    fn validate(self: *Controller, token: Token, edit: bool) !*Mount {
        const current = try self.state();
        if (!std.meta.eql(token, current.token)) return error.StaleEditorRevision;
        const mount = self.mounts.?;
        if (edit and (try mount.registry.getBehavior(mount.target)).read_only) return error.EditorReadOnly;
        return mount;
    }

    fn validateRange(value: *const model.Model, range: model.Range) !void {
        if (range.start > range.end or range.end > value.byteLen()) return error.InvalidTextRange;
        if (!value.isBoundary(range.start) or !value.isBoundary(range.end)) return error.InvalidGraphemeBoundary;
    }

    /// Borrowed only until the next model edit; language bindings copy it.
    pub fn read(self: *Controller, token: Token, range: model.Range) ![]const u8 {
        const mount = try self.validate(token, false);
        const value = &(try mount.registry.session(mount.target)).model;
        try validateRange(value, range);
        return value.text()[range.start..range.end];
    }

    pub fn select(self: *Controller, token: Token, selection: model.Selection) !State {
        const mount = try self.validate(token, false);
        const session = try mount.registry.session(mount.target);
        if (try session.model.setSelection(selection)) {
            session.preferred_x = null;
            const host = mount.registry.controller_host.?;
            try host.changed(host.context, mount.target, false);
        }
        return self.state();
    }

    pub fn replace(self: *Controller, token: Token, range: model.Range, text: []const u8) !State {
        const mount = try self.validate(token, true);
        const session = try mount.registry.session(mount.target);
        try validateRange(&session.model, range);
        if (try session.model.replaceRange(range, text)) {
            session.preferred_x = null;
            const host = mount.registry.controller_host.?;
            try host.changed(host.context, mount.target, true);
        }
        return self.state();
    }

    pub fn undoGroup(self: *Controller, token: Token, begin: bool) !State {
        const mount = try self.validate(token, true);
        const value = &(try mount.registry.session(mount.target)).model;
        if (begin) value.beginUndoGroup() else value.breakUndoGroup();
        return self.state();
    }
};
