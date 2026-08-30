const std = @import("std");
const SizeU = @import("../core/geometry.zig").SizeU;

pub const Invalidation = enum {
    none,
    paint,
    layout,
};

/// Renderer- and platform-neutral state for one window's frame pipeline.
/// Invalidations coalesce until the ordered layout/scene phases consume them;
/// a scene is never eligible for submission while a newer mutation is dirty.
pub const State = struct {
    size: ?SizeU = null,
    invalidation: Invalidation = .none,
    scene_revision: u64 = 0,
    submitted_revision: u64 = 0,
    submission_requested: bool = false,

    /// Every platform configure permits another submission. A size change also
    /// requires layout; an unchanged size can reuse the current display list.
    pub fn configure(self: *State, size: SizeU) !bool {
        if (size.width == 0 or size.height == 0) return error.InvalidFrameSize;
        self.submission_requested = true;
        if (self.size != null and std.meta.eql(self.size.?, size)) return false;
        self.size = size;
        self.invalidateLayout();
        return true;
    }

    pub fn invalidateLayout(self: *State) void {
        self.invalidation = .layout;
    }

    pub fn invalidatePaint(self: *State) void {
        if (self.invalidation == .none) self.invalidation = .paint;
    }

    /// Call only after the render tree has completed layout for `size`.
    pub fn layoutComplete(self: *State) !void {
        if (self.size == null) return error.FrameNotConfigured;
        if (self.invalidation != .layout) return error.LayoutNotRequired;
        self.invalidation = .paint;
    }

    /// Publishes the display list built during the scene phase.
    pub fn sceneBuilt(self: *State) !u64 {
        if (self.size == null) return error.FrameNotConfigured;
        if (self.invalidation != .paint) return error.SceneBuildNotRequired;
        if (self.scene_revision == std.math.maxInt(u64)) return error.SceneRevisionOverflow;
        self.invalidation = .none;
        self.scene_revision += 1;
        self.submission_requested = true;
        return self.scene_revision;
    }

    pub fn needsLayout(self: *const State) bool {
        return self.invalidation == .layout;
    }

    pub fn needsScene(self: *const State) bool {
        return self.invalidation != .none;
    }

    pub fn readyForSubmission(self: *const State) bool {
        return self.invalidation == .none and self.scene_revision != 0 and
            (self.submission_requested or self.scene_revision != self.submitted_revision);
    }

    /// Call only after the backend has accepted the frame.
    pub fn submitted(self: *State) !void {
        if (!self.readyForSubmission()) return error.FrameNotReady;
        self.submitted_revision = self.scene_revision;
        self.submission_requested = false;
    }
};

test "frame state coalesces invalidation and forbids stale scene submission" {
    var state: State = .{};
    try std.testing.expect(try state.configure(.{ .width = 100, .height = 80 }));
    try std.testing.expect(state.needsLayout());
    try std.testing.expect(!state.readyForSubmission());

    state.invalidatePaint();
    try std.testing.expect(state.needsLayout());
    try state.layoutComplete();
    _ = try state.sceneBuilt();
    try std.testing.expect(state.readyForSubmission());

    state.invalidatePaint();
    try std.testing.expect(!state.readyForSubmission());
    _ = try state.sceneBuilt();
    try std.testing.expect(state.readyForSubmission());
    try state.submitted();
    try std.testing.expect(!state.readyForSubmission());
}

test "unchanged configure reuses the scene but requests submission" {
    var state: State = .{};
    _ = try state.configure(.{ .width = 32, .height = 24 });
    try state.layoutComplete();
    const revision = try state.sceneBuilt();
    try state.submitted();

    try std.testing.expect(!try state.configure(.{ .width = 32, .height = 24 }));
    try std.testing.expect(!state.needsScene());
    try std.testing.expect(state.readyForSubmission());
    try std.testing.expectEqual(revision, state.scene_revision);
}
