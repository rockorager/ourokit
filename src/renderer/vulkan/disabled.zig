//! Type-compatible disabled Vulkan capability used by software-only builds.

const Renderer = @This();
const std = @import("std");
const scene = @import("../../scene/root.zig");
const text = @import("../../text/root.zig");

pub const GlyphCache = struct {
    pub fn init(_: std.mem.Allocator, _: *text.FontCache, _: *Renderer) !GlyphCache {
        return error.VulkanDisabled;
    }

    pub fn deinit(_: *GlyphCache) void {}
};

pub const DmabufPlane = struct {
    offset: u32 = 0,
    stride: u32 = 0,
};

pub const DmabufTarget = struct {
    planes: [4]DmabufPlane = [_]DmabufPlane{.{}} ** 4,
    plane_count: u32 = 0,
    modifier: u64 = 0,
    gpu_pending: bool = false,

    pub fn init(_: *Renderer, _: u32, _: u32, _: u64) !DmabufTarget {
        return error.VulkanDisabled;
    }

    pub fn deinit(_: *DmabufTarget, _: *Renderer) void {}

    pub fn ready(_: *DmabufTarget, _: *Renderer) !bool {
        return error.VulkanDisabled;
    }

    pub fn wait(_: *DmabufTarget, _: *Renderer) !void {
        return error.VulkanDisabled;
    }

    pub fn exportSyncobjFd(_: *DmabufTarget, _: *Renderer) !std.posix.fd_t {
        return error.VulkanDisabled;
    }

    pub fn syncPoints(_: *const DmabufTarget) struct { acquire: u64, release: u64 } {
        return .{ .acquire = 0, .release = 0 };
    }

    pub fn exportFd(_: *const DmabufTarget, _: *Renderer) !std.posix.fd_t {
        return error.VulkanDisabled;
    }
};

pub fn init(_: std.mem.Allocator) !Renderer {
    return error.VulkanDisabled;
}

pub fn deinit(_: *Renderer) void {}

pub fn renderDmabufText(
    _: *Renderer,
    _: scene.DisplayList,
    _: *DmabufTarget,
    _: *GlyphCache,
    _: *const text.ShapeCache,
) !void {
    return error.VulkanDisabled;
}

pub fn renderDmabufParagraphs(
    _: *Renderer,
    _: scene.DisplayList,
    _: *DmabufTarget,
    _: *GlyphCache,
    _: *const text.ParagraphCache,
) !void {
    return error.VulkanDisabled;
}

pub fn renderDmabufTextResources(
    _: *Renderer,
    _: scene.DisplayList,
    _: *DmabufTarget,
    _: *GlyphCache,
    _: ?*const text.ShapeCache,
    _: ?*const text.ParagraphCache,
) !void {
    return error.VulkanDisabled;
}

pub fn supportsDmabuf(_: *const Renderer) bool {
    return false;
}

pub fn supportsDmabufModifier(_: *const Renderer, _: u64) bool {
    return false;
}

pub fn matchesDrmDevice(_: *const Renderer, _: []const u8) bool {
    return false;
}
