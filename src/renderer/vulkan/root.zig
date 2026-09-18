//! Vulkan renderer for the renderer-neutral scene.
//!
//! Exact headless `Target` rendering is synchronous and uses integer compute.
//! Presentation targets use an asynchronous graphics pipeline and render
//! directly into sRGB8 for proven-opaque scenes, or in linear RGBA16F before
//! alpha-correct sRGB conversion into modifier-selected BGRA8 images.

const Renderer = @This();

const std = @import("std");
const builtin = @import("builtin");
const Color = @import("../../core/color.zig").Color;
const LinearRgba16 = @import("../../core/color.zig").LinearRgba16;
const RectI = @import("../../core/geometry.zig").RectI;
const scene = @import("../../scene/root.zig");
const text = @import("../../text/root.zig");
const build_options = @import("ourokit_build_options");
const ImageCache = @import("../../image/cache.zig").Cache;
const ImagePlacement = @import("../image_sampling.zig").Placement;
const GlyphPosition = @import("../glyph_position.zig").Position;
const Phase = @import("../glyph_position.zig").Phase;

pub const has_freetype = build_options.freetype;
const RasterCache = if (has_freetype)
    @import("../software/glyph_cache.zig").GlyphCache
else
    struct {};

pub const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

const max_clip_depth = scene.max_clip_depth;
const local_size = 64;
const dmabuf_extensions = [_][*:0]const u8{
    c.VK_KHR_EXTERNAL_MEMORY_FD_EXTENSION_NAME,
    c.VK_EXT_EXTERNAL_MEMORY_DMA_BUF_EXTENSION_NAME,
    c.VK_EXT_IMAGE_DRM_FORMAT_MODIFIER_EXTENSION_NAME,
    c.VK_EXT_QUEUE_FAMILY_FOREIGN_EXTENSION_NAME,
    c.VK_EXT_PHYSICAL_DEVICE_DRM_EXTENSION_NAME,
    c.VK_KHR_EXTERNAL_SEMAPHORE_FD_EXTENSION_NAME,
};
const GetMemoryFd = *const fn (c.VkDevice, *const c.VkMemoryGetFdInfoKHR, *c_int) callconv(.c) c.VkResult;
const GetImageModifier = *const fn (
    c.VkDevice,
    c.VkImage,
    *c.VkImageDrmFormatModifierPropertiesEXT,
) callconv(.c) c.VkResult;
const GetSemaphoreFd = *const fn (c.VkDevice, *const c.VkSemaphoreGetFdInfoKHR, *c_int) callconv(.c) c.VkResult;

allocator: std.mem.Allocator,
instance: c.VkInstance,
physical_device: c.VkPhysicalDevice,
memory_properties: c.VkPhysicalDeviceMemoryProperties,
device: c.VkDevice,
queue_family: u32,
queue: c.VkQueue,
dmabuf_enabled: bool,
get_memory_fd: ?GetMemoryFd,
get_image_modifier: ?GetImageModifier,
get_semaphore_fd: ?GetSemaphoreFd,
drm_primary_device: ?u64,
drm_render_device: ?u64,
descriptor_layout: c.VkDescriptorSetLayout,
pipeline_layout: c.VkPipelineLayout,
pipeline: c.VkPipeline,
glyph_pipeline: c.VkPipeline,
atlas_descriptor_layout: c.VkDescriptorSetLayout,
presentation_render_pass: c.VkRenderPass,
presentation_pipeline_layout: c.VkPipelineLayout,
presentation_pipeline: c.VkPipeline,
presentation_glyph_pipeline_layout: c.VkPipelineLayout,
presentation_glyph_pipeline: c.VkPipeline,
presentation_erase_pipeline: c.VkPipeline,
presentation_add_pipeline: c.VkPipeline,
direct_presentation: PresentationObjects,
conversion_descriptor_layout: c.VkDescriptorSetLayout,
conversion_pipeline_layout: c.VkPipelineLayout,
conversion_pipeline: c.VkPipeline,
descriptor_pool: c.VkDescriptorPool,
command_pool: c.VkCommandPool,
command_buffer: c.VkCommandBuffer,
fence: c.VkFence,
max_pixels: u64,
max_image_pixels: u64,

const atlas_width = 2048;
const atlas_height = 2048;
const atlas_bytes = atlas_width * atlas_height;

const AtlasKey = if (has_freetype) @import("../software/glyph_cache.zig").GlyphKey else struct {};

const AtlasGlyph = struct {
    // x addresses bytes: A8 coverage or aligned linear RGBA16 color texels.
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    left: i32,
    top: i32,
    color: bool,
};

const RealGlyphCache = struct {
    allocator: std.mem.Allocator,
    renderer: *Renderer,
    raster: RasterCache,
    entries: std.AutoHashMapUnmanaged(AtlasKey, AtlasGlyph) = .empty,
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    staging_buffer: c.VkBuffer,
    staging_memory: c.VkDeviceMemory,
    mapping: *anyopaque,
    descriptor_pool: c.VkDescriptorPool,
    descriptor_set: c.VkDescriptorSet,
    next_x: u32 = 0,
    next_y: u32 = 0,
    row_height: u32 = 0,
    dirty_start: usize = atlas_bytes,
    dirty_end: usize = 0,

    pub fn init(allocator: std.mem.Allocator, fonts: *text.FontCache, renderer: *Renderer) !RealGlyphCache {
        var raster = try RasterCache.init(allocator, fonts);
        errdefer raster.deinit();
        var buffer_info: c.VkBufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = atlas_bytes,
            .usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        var buffer: c.VkBuffer = undefined;
        try vk(c.vkCreateBuffer(renderer.device, &buffer_info, null, &buffer), error.CreateAtlasBufferFailed);
        errdefer c.vkDestroyBuffer(renderer.device, buffer, null);
        var requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(renderer.device, buffer, &requirements);
        const memory_type = renderer.findMemoryType(requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse
            renderer.findMemoryType(requirements.memoryTypeBits, 0) orelse return error.DeviceMemoryUnavailable;
        var allocate_info: c.VkMemoryAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = requirements.size,
            .memoryTypeIndex = memory_type,
        };
        var memory: c.VkDeviceMemory = undefined;
        try vk(c.vkAllocateMemory(renderer.device, &allocate_info, null, &memory), error.AllocateAtlasMemoryFailed);
        errdefer c.vkFreeMemory(renderer.device, memory, null);
        try vk(c.vkBindBufferMemory(renderer.device, buffer, memory, 0), error.BindAtlasMemoryFailed);

        var staging_info = buffer_info;
        staging_info.usage = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
        var staging_buffer: c.VkBuffer = undefined;
        try vk(c.vkCreateBuffer(renderer.device, &staging_info, null, &staging_buffer), error.CreateAtlasBufferFailed);
        errdefer c.vkDestroyBuffer(renderer.device, staging_buffer, null);
        var staging_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(renderer.device, staging_buffer, &staging_requirements);
        const staging_type = renderer.findMemoryType(
            staging_requirements.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        ) orelse return error.HostVisibleMemoryUnavailable;
        allocate_info.allocationSize = staging_requirements.size;
        allocate_info.memoryTypeIndex = staging_type;
        var staging_memory: c.VkDeviceMemory = undefined;
        try vk(c.vkAllocateMemory(renderer.device, &allocate_info, null, &staging_memory), error.AllocateAtlasMemoryFailed);
        errdefer c.vkFreeMemory(renderer.device, staging_memory, null);
        try vk(c.vkBindBufferMemory(renderer.device, staging_buffer, staging_memory, 0), error.BindAtlasMemoryFailed);
        var mapping: ?*anyopaque = null;
        try vk(c.vkMapMemory(renderer.device, staging_memory, 0, atlas_bytes, 0, &mapping), error.MapAtlasMemoryFailed);
        errdefer c.vkUnmapMemory(renderer.device, staging_memory);
        @memset(@as([*]u8, @ptrCast(mapping.?))[0..atlas_bytes], 0);

        var pool_size: c.VkDescriptorPoolSize = .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 };
        var pool_info: c.VkDescriptorPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };
        var descriptor_pool: c.VkDescriptorPool = undefined;
        try vk(c.vkCreateDescriptorPool(renderer.device, &pool_info, null, &descriptor_pool), error.CreateDescriptorPoolFailed);
        errdefer c.vkDestroyDescriptorPool(renderer.device, descriptor_pool, null);
        var descriptor_allocate: c.VkDescriptorSetAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &renderer.atlas_descriptor_layout,
        };
        var descriptor_set: c.VkDescriptorSet = undefined;
        try vk(c.vkAllocateDescriptorSets(renderer.device, &descriptor_allocate, &descriptor_set), error.AllocateDescriptorSetFailed);
        var descriptor_buffer: c.VkDescriptorBufferInfo = .{ .buffer = buffer, .offset = 0, .range = atlas_bytes };
        var descriptor_write: c.VkWriteDescriptorSet = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &descriptor_buffer,
            .pTexelBufferView = null,
        };
        c.vkUpdateDescriptorSets(renderer.device, 1, &descriptor_write, 0, null);
        return .{
            .allocator = allocator,
            .renderer = renderer,
            .raster = raster,
            .buffer = buffer,
            .memory = memory,
            .staging_buffer = staging_buffer,
            .staging_memory = staging_memory,
            .mapping = mapping.?,
            .descriptor_pool = descriptor_pool,
            .descriptor_set = descriptor_set,
        };
    }

    pub fn deinit(self: *RealGlyphCache) void {
        _ = c.vkDeviceWaitIdle(self.renderer.device);
        self.entries.deinit(self.allocator);
        c.vkDestroyDescriptorPool(self.renderer.device, self.descriptor_pool, null);
        c.vkUnmapMemory(self.renderer.device, self.staging_memory);
        c.vkDestroyBuffer(self.renderer.device, self.staging_buffer, null);
        c.vkFreeMemory(self.renderer.device, self.staging_memory, null);
        c.vkDestroyBuffer(self.renderer.device, self.buffer, null);
        c.vkFreeMemory(self.renderer.device, self.memory, null);
        self.raster.deinit();
        self.* = undefined;
    }

    fn get(self: *RealGlyphCache, handle: text.FontHandle, glyph_id: u32, pixel_size: f32, phase: Phase) !AtlasGlyph {
        const key = try AtlasKey.init(handle, glyph_id, pixel_size, phase);
        if (self.entries.get(key)) |entry| return entry;
        if (self.entries.count() >= 16384) return error.GlyphAtlasFull;
        const bitmap = try self.raster.getPhase(handle, glyph_id, pixel_size, phase);
        const row_bytes = bitmap.width * bitmap.bytesPerPixel();
        var x = std.mem.alignForward(u32, self.next_x, bitmap.bytesPerPixel());
        var y = self.next_y;
        var row_height = self.row_height;
        if (row_bytes > atlas_width or bitmap.height > atlas_height) return error.GlyphAtlasFull;
        if (x + row_bytes > atlas_width) {
            x = 0;
            y += row_height;
            row_height = 0;
        }
        if (y + bitmap.height > atlas_height) return error.GlyphAtlasFull;
        const destination: [*]u8 = @ptrCast(self.mapping);
        for (0..bitmap.height) |row| {
            const offset = (y + row) * atlas_width + x;
            @memcpy(destination[offset..][0..row_bytes], bitmap.pixels[row * row_bytes ..][0..row_bytes]);
            self.dirty_start = @min(self.dirty_start, offset);
            self.dirty_end = @max(self.dirty_end, offset + row_bytes);
        }
        const entry: AtlasGlyph = .{
            .x = x,
            .y = y,
            .width = bitmap.width,
            .height = bitmap.height,
            .left = bitmap.left,
            .top = bitmap.top,
            .color = bitmap.color,
        };
        try self.entries.put(self.allocator, key, entry);
        self.next_x = x + row_bytes;
        self.next_y = y;
        self.row_height = @max(row_height, bitmap.height);
        return entry;
    }

    /// Drawing cannot allocate a new phase after the upload was recorded.
    fn prepared(self: *const RealGlyphCache, handle: text.FontHandle, glyph_id: u32, pixel_size: f32, phase: Phase) AtlasGlyph {
        const key = AtlasKey.init(handle, glyph_id, pixel_size, phase) catch unreachable;
        return self.entries.get(key) orelse unreachable;
    }

    /// Reclaim only between frames, never while building a frame's draw calls.
    /// Presentation targets can still reference old atlas/staging storage.
    fn reset(self: *RealGlyphCache) !void {
        try vk(c.vkDeviceWaitIdle(self.renderer.device), error.DeviceLost);
        self.entries.clearRetainingCapacity();
        self.next_x = 0;
        self.next_y = 0;
        self.row_height = 0;
        self.uploaded();
    }

    fn recordUpload(self: *const RealGlyphCache, command_buffer_value: c.VkCommandBuffer, destination_stage: c.VkPipelineStageFlags) bool {
        if (self.dirty_start >= self.dirty_end) return false;
        const start = self.dirty_start & ~@as(usize, 3);
        const end = std.mem.alignForward(usize, self.dirty_end, 4);
        var barrier: c.VkBufferMemoryBarrier = .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER,
            .pNext = null,
            .srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT | c.VK_ACCESS_SHADER_READ_BIT,
            .dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .buffer = self.buffer,
            .offset = start,
            .size = end - start,
        };
        // Dirty spans cover gaps between glyph rows and can overlap an earlier
        // upload even when the new glyph itself occupies unused atlas space.
        c.vkCmdPipelineBarrier(command_buffer_value, c.VK_PIPELINE_STAGE_TRANSFER_BIT | c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 1, &barrier, 0, null);
        var copy: c.VkBufferCopy = .{ .srcOffset = start, .dstOffset = start, .size = end - start };
        c.vkCmdCopyBuffer(command_buffer_value, self.staging_buffer, self.buffer, 1, &copy);
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        c.vkCmdPipelineBarrier(command_buffer_value, c.VK_PIPELINE_STAGE_TRANSFER_BIT, destination_stage, 0, 0, null, 1, &barrier, 0, null);
        return true;
    }

    fn uploaded(self: *RealGlyphCache) void {
        self.dirty_start = atlas_bytes;
        self.dirty_end = 0;
    }
};

pub const GlyphCache = if (has_freetype) RealGlyphCache else struct {};

pub const PixelFormat = enum {
    rgba8_unorm,
    bgra8_unorm,
};

pub const Target = struct {
    buffer: c.VkBuffer,
    memory: c.VkDeviceMemory,
    mapping: *anyopaque,
    width: u32,
    height: u32,
    byte_size: usize,
    format: StorageFormat,

    pub fn init(renderer: *Renderer, width: u32, height: u32) !Target {
        return initFormat(renderer, width, height, .rgba);
    }

    fn initFormat(renderer: *Renderer, width: u32, height: u32, format: StorageFormat) !Target {
        return initBuffer(renderer, width, height, format, renderer.max_pixels);
    }

    fn initBuffer(renderer: *Renderer, width: u32, height: u32, format: StorageFormat, limit: u64) !Target {
        const pixel_count = std.math.mul(u64, width, height) catch return error.InvalidExtent;
        if (pixel_count == 0 or pixel_count > limit) return error.InvalidExtent;
        const byte_size_u64 = std.math.mul(u64, pixel_count, if (format == .encoded_rgba) 4 else 8) catch return error.InvalidExtent;
        const byte_size = std.math.cast(usize, byte_size_u64) orelse return error.InvalidExtent;

        var buffer_info: c.VkBufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = byte_size,
            .usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        var buffer: c.VkBuffer = undefined;
        try vk(c.vkCreateBuffer(renderer.device, &buffer_info, null, &buffer), error.CreateBufferFailed);
        errdefer c.vkDestroyBuffer(renderer.device, buffer, null);

        var requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(renderer.device, buffer, &requirements);
        const memory_type = renderer.findMemoryType(
            requirements.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        ) orelse return error.HostVisibleMemoryUnavailable;
        var allocate_info: c.VkMemoryAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = requirements.size,
            .memoryTypeIndex = memory_type,
        };
        var memory: c.VkDeviceMemory = undefined;
        try vk(c.vkAllocateMemory(renderer.device, &allocate_info, null, &memory), error.AllocateMemoryFailed);
        errdefer c.vkFreeMemory(renderer.device, memory, null);
        try vk(c.vkBindBufferMemory(renderer.device, buffer, memory, 0), error.BindMemoryFailed);

        var mapping: ?*anyopaque = null;
        try vk(c.vkMapMemory(renderer.device, memory, 0, byte_size, 0, &mapping), error.MapMemoryFailed);
        return .{
            .buffer = buffer,
            .memory = memory,
            .mapping = mapping orelse return error.MapMemoryFailed,
            .width = width,
            .height = height,
            .byte_size = byte_size,
            .format = format,
        };
    }

    pub fn deinit(self: *Target, renderer: *Renderer) void {
        c.vkUnmapMemory(renderer.device, self.memory);
        c.vkDestroyBuffer(renderer.device, self.buffer, null);
        c.vkFreeMemory(renderer.device, self.memory, null);
        self.* = undefined;
    }

    /// Copies completed Vulkan storage into caller-owned rows. Row padding is
    /// preserved, matching the software backend's target convention.
    pub fn readPixels(self: *const Target, pixels: []u8, stride: usize, format: PixelFormat) !void {
        const row_bytes = std.math.mul(usize, self.width, 4) catch return error.InvalidReadback;
        if (stride < row_bytes) return error.InvalidReadback;
        const required = std.math.mul(usize, stride, self.height) catch return error.InvalidReadback;
        if (pixels.len < required) return error.InvalidReadback;
        const source: [*]const LinearRgba16 = @ptrCast(@alignCast(self.mapping));
        for (0..self.height) |y| {
            const destination = pixels[y * stride ..][0..row_bytes];
            for (0..self.width) |x| {
                const encoded = source[y * self.width + x].toSrgba8();
                const offset = x * 4;
                destination[offset + 0] = if (format == .rgba8_unorm) encoded.r else encoded.b;
                destination[offset + 1] = encoded.g;
                destination[offset + 2] = if (format == .rgba8_unorm) encoded.b else encoded.r;
                destination[offset + 3] = encoded.a;
            }
        }
    }
};

const StorageFormat = enum { rgba, encoded_rgba };

/// Immutable upload copies, independent of the thread-confined decode cache.
/// A dma-buf target owns these until its submission fence signals.
const ImageUploads = struct {
    entries: std.ArrayList(Entry) = .empty,
    resources: std.ArrayList(Resource) = .empty,
    byte_size: u64 = 0,

    const Entry = struct {
        resource_index: usize,
        placement: ImagePlacement,
    };

    const Resource = struct {
        pixels: Target,
        pool: c.VkDescriptorPool,
        descriptor: c.VkDescriptorSet,
    };

    fn init(renderer: *Renderer, commands: []const scene.Command, cache: ?*const ImageCache, target: ?*const Target) !ImageUploads {
        var self: ImageUploads = .{};
        errdefer self.deinit(renderer);
        var indices: std.AutoHashMapUnmanaged(@import("../../image/cache.zig").ImageHandle, usize) = .empty;
        defer indices.deinit(std.heap.page_allocator);
        const byte_limit = @min(256 * 1024 * 1024, renderer.max_image_pixels * 4);
        for (commands) |command| switch (command) {
            .image => |value| {
                const bitmap = try (cache orelse return error.ImageResourcesRequired).get(value.image);
                const index = try indices.getOrPut(std.heap.page_allocator, value.image);
                if (!index.found_existing) {
                    if (bitmap.pixels.len > byte_limit - self.byte_size) return error.ImageUploadBudgetExceeded;
                    var resource = try upload(renderer, bitmap, target);
                    errdefer {
                        c.vkDestroyDescriptorPool(renderer.device, resource.pool, null);
                        resource.pixels.deinit(renderer);
                    }
                    try self.resources.append(std.heap.page_allocator, resource);
                    index.value_ptr.* = self.resources.items.len - 1;
                    self.byte_size += bitmap.pixels.len;
                }
                try self.entries.append(std.heap.page_allocator, .{
                    .resource_index = index.value_ptr.*,
                    .placement = ImagePlacement.init(value, bitmap),
                });
            },
            else => {},
        };
        return self;
    }

    fn upload(renderer: *Renderer, bitmap: *const @import("../../image/pixels.zig").Bitmap, target: ?*const Target) !Resource {
        // Source images are storage-limited, not dispatch-limited: a
        // large image can be drawn into a much smaller destination.
        var pixels = try Target.initBuffer(renderer, bitmap.width, bitmap.height, .encoded_rgba, renderer.max_image_pixels);
        errdefer pixels.deinit(renderer);
        @memcpy(@as([*]u8, @ptrCast(pixels.mapping))[0..pixels.byte_size], bitmap.pixels);
        var pool_size: c.VkDescriptorPoolSize = .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 2 };
        var pool_info: c.VkDescriptorPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };
        var pool: c.VkDescriptorPool = undefined;
        try vk(c.vkCreateDescriptorPool(renderer.device, &pool_info, null, &pool), error.CreateDescriptorPoolFailed);
        errdefer c.vkDestroyDescriptorPool(renderer.device, pool, null);
        var layout = if (target != null) renderer.descriptor_layout else renderer.atlas_descriptor_layout;
        var allocate: c.VkDescriptorSetAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &layout,
        };
        var descriptor: c.VkDescriptorSet = undefined;
        try vk(c.vkAllocateDescriptorSets(renderer.device, &allocate, &descriptor), error.AllocateDescriptorSetFailed);
        const first = target orelse &pixels;
        var buffers = [_]c.VkDescriptorBufferInfo{
            .{ .buffer = first.buffer, .offset = 0, .range = first.byte_size },
            .{ .buffer = pixels.buffer, .offset = 0, .range = pixels.byte_size },
        };
        var writes: [2]c.VkWriteDescriptorSet = undefined;
        for (&writes, 0..) |*write, binding| write.* = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptor,
            .dstBinding = @intCast(binding),
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &buffers[binding],
        };
        c.vkUpdateDescriptorSets(renderer.device, if (target != null) 2 else 1, &writes, 0, null);
        return .{
            .pixels = pixels,
            .pool = pool,
            .descriptor = descriptor,
        };
    }

    fn deinit(self: *ImageUploads, renderer: *Renderer) void {
        for (self.resources.items) |*resource| {
            c.vkDestroyDescriptorPool(renderer.device, resource.pool, null);
            resource.pixels.deinit(renderer);
        }
        self.resources.deinit(std.heap.page_allocator);
        self.entries.deinit(std.heap.page_allocator);
        self.* = .{};
    }
};

pub const DmabufPlane = struct {
    offset: u32,
    stride: u32,
};

/// Private persistent linear storage. Only the BGRA8 image is shared with the
/// compositor. Presentation slots retain this allocation at a stable address,
/// including when the host moves a pool into retirement during resize.
const LinearAttachment = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    descriptor_pool: c.VkDescriptorPool,
    descriptor: c.VkDescriptorSet,
    references: usize = 1,
    initialized: bool = false,

    const range: c.VkImageSubresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
    const usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT;

    fn init(renderer: *Renderer, width: u32, height: u32) !*LinearAttachment {
        if (renderer.presentation_render_pass == null) return error.LinearAttachmentUnavailable;
        const self = try renderer.allocator.create(LinearAttachment);
        errdefer renderer.allocator.destroy(self);
        var properties: c.VkImageFormatProperties = undefined;
        try vk(c.vkGetPhysicalDeviceImageFormatProperties(renderer.physical_device, c.VK_FORMAT_R16G16B16A16_SFLOAT, c.VK_IMAGE_TYPE_2D, c.VK_IMAGE_TILING_OPTIMAL, usage, 0, &properties), error.LinearAttachmentUnavailable);
        if (width == 0 or height == 0 or width > properties.maxExtent.width or height > properties.maxExtent.height) return error.InvalidExtent;
        var info: c.VkImageCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = c.VK_FORMAT_R16G16B16A16_SFLOAT,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_OPTIMAL,
            .usage = usage,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        var image: c.VkImage = undefined;
        try vk(c.vkCreateImage(renderer.device, &info, null, &image), error.CreateLinearImageFailed);
        errdefer c.vkDestroyImage(renderer.device, image, null);
        var requirements: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(renderer.device, image, &requirements);
        const memory_type = renderer.findMemoryType(requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse return error.LinearAttachmentMemoryUnavailable;
        var allocate: c.VkMemoryAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = requirements.size, .memoryTypeIndex = memory_type };
        var memory: c.VkDeviceMemory = undefined;
        try vk(c.vkAllocateMemory(renderer.device, &allocate, null, &memory), error.AllocateMemoryFailed);
        errdefer c.vkFreeMemory(renderer.device, memory, null);
        try vk(c.vkBindImageMemory(renderer.device, image, memory, 0), error.BindMemoryFailed);
        var view_info: c.VkImageViewCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = c.VK_FORMAT_R16G16B16A16_SFLOAT,
            .subresourceRange = range,
        };
        var view: c.VkImageView = undefined;
        try vk(c.vkCreateImageView(renderer.device, &view_info, null, &view), error.CreateImageViewFailed);
        errdefer c.vkDestroyImageView(renderer.device, view, null);
        var pool_size: c.VkDescriptorPoolSize = .{ .type = c.VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, .descriptorCount = 1 };
        var pool_info: c.VkDescriptorPoolCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 1, .pPoolSizes = &pool_size };
        var pool: c.VkDescriptorPool = undefined;
        try vk(c.vkCreateDescriptorPool(renderer.device, &pool_info, null, &pool), error.CreateDescriptorPoolFailed);
        errdefer c.vkDestroyDescriptorPool(renderer.device, pool, null);
        var set_info: c.VkDescriptorSetAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = &renderer.conversion_descriptor_layout };
        var descriptor: c.VkDescriptorSet = undefined;
        try vk(c.vkAllocateDescriptorSets(renderer.device, &set_info, &descriptor), error.AllocateDescriptorFailed);
        var image_info: c.VkDescriptorImageInfo = .{ .imageView = view, .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
        var write: c.VkWriteDescriptorSet = .{ .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = descriptor, .dstBinding = 0, .descriptorCount = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT, .pImageInfo = &image_info };
        c.vkUpdateDescriptorSets(renderer.device, 1, &write, 0, null);
        self.* = .{ .image = image, .memory = memory, .view = view, .descriptor_pool = pool, .descriptor = descriptor };
        return self;
    }

    fn retain(self: *LinearAttachment) *LinearAttachment {
        self.references += 1;
        return self;
    }

    fn deinit(self: *LinearAttachment, renderer: *Renderer) void {
        self.references -= 1;
        if (self.references != 0) return;
        c.vkDestroyDescriptorPool(renderer.device, self.descriptor_pool, null);
        c.vkDestroyImageView(renderer.device, self.view, null);
        c.vkDestroyImage(renderer.device, self.image, null);
        c.vkFreeMemory(renderer.device, self.memory, null);
        renderer.allocator.destroy(self);
    }

    fn initialize(self: *const LinearAttachment, command: c.VkCommandBuffer) void {
        var barrier: c.VkImageMemoryBarrier = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
            .dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT,
            .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
            .image = self.image,
            .subresourceRange = range,
        };
        c.vkCmdPipelineBarrier(command, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);
        const clear: c.VkClearColorValue = .{ .float32 = .{ 0, 0, 0, 0 } };
        c.vkCmdClearColorImage(command, self.image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clear, 1, &range);
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        c.vkCmdPipelineBarrier(command, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, null, 0, null, 1, &barrier);
    }
};

/// Exportable BGRA render target. Command and fence state is per target;
/// slots sharing linear storage are ordered by the render-pass dependencies
/// on the renderer's single graphics queue, without a CPU wait between slots.
pub const DmabufTarget = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    framebuffer: c.VkFramebuffer,
    linear: ?*LinearAttachment,
    direct: bool = false,
    command_pool: c.VkCommandPool,
    command_buffer: c.VkCommandBuffer,
    fence: c.VkFence,
    timeline: c.VkSemaphore,
    width: u32,
    height: u32,
    modifier: u64,
    planes: [4]DmabufPlane,
    plane_count: u8,
    layout: c.VkImageLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    gpu_pending: bool = false,
    explicit_sync: bool = false,
    acquire_point: u64 = 0,
    release_point: u64 = 0,
    image_uploads: ImageUploads = .{},
    /// Optional borrowed two-query timestamp pool for the presentation probe.
    /// The caller owns it and must wait for this target before reading/freeing.
    timestamp_pool: c.VkQueryPool = null,

    pub fn init(renderer: *Renderer, width: u32, height: u32, modifier: u64) !DmabufTarget {
        return initWithLinear(renderer, width, height, modifier, null, false);
    }

    /// Direct targets require a provably opaque reconstructed scene on every
    /// submission. They allocate only the exported sRGB image, never FP16.
    pub fn initOpaque(renderer: *Renderer, width: u32, height: u32, modifier: u64) !DmabufTarget {
        return initWithLinear(renderer, width, height, modifier, null, true);
    }

    /// Adds a presentation image retaining the same high-precision contents.
    /// The source and result must use the same renderer and window generation.
    pub fn initShared(renderer: *Renderer, source: *const DmabufTarget) !DmabufTarget {
        return initWithLinear(renderer, source.width, source.height, source.modifier, source.linear, source.direct);
    }

    fn initWithLinear(renderer: *Renderer, width: u32, height: u32, modifier: u64, shared: ?*LinearAttachment, direct: bool) !DmabufTarget {
        if (!renderer.dmabuf_enabled) return error.DmabufUnavailable;
        if (direct) {
            if (!renderer.supportsDirectModifier(modifier)) return error.DmabufModifierUnavailable;
        } else if (!renderer.supportsDmabufModifier(modifier)) return error.DmabufModifierUnavailable;
        const format: c.VkFormat = if (direct) c.VK_FORMAT_B8G8R8A8_SRGB else c.VK_FORMAT_B8G8R8A8_UNORM;

        var selected_modifier = modifier;
        var modifier_info: c.VkImageDrmFormatModifierListCreateInfoEXT = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
            .pNext = null,
            .drmFormatModifierCount = 1,
            .pDrmFormatModifiers = &selected_modifier,
        };
        var external_info: c.VkExternalMemoryImageCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .pNext = &modifier_info,
            .handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };
        var image_info: c.VkImageCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = &external_info,
            .flags = 0,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        var image: c.VkImage = undefined;
        try vk(c.vkCreateImage(renderer.device, &image_info, null, &image), error.CreateDmabufImageFailed);
        errdefer c.vkDestroyImage(renderer.device, image, null);

        var requirements: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(renderer.device, image, &requirements);
        const memory_type = renderer.findMemoryType(requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse
            renderer.findMemoryType(requirements.memoryTypeBits, 0) orelse return error.DmabufMemoryUnavailable;
        var dedicated_info: c.VkMemoryDedicatedAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
            .pNext = null,
            .image = image,
            .buffer = null,
        };
        var export_info: c.VkExportMemoryAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
            .pNext = &dedicated_info,
            .handleTypes = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };
        var allocate_info: c.VkMemoryAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = &export_info,
            .allocationSize = requirements.size,
            .memoryTypeIndex = memory_type,
        };
        var memory: c.VkDeviceMemory = undefined;
        try vk(c.vkAllocateMemory(renderer.device, &allocate_info, null, &memory), error.AllocateDmabufMemoryFailed);
        errdefer c.vkFreeMemory(renderer.device, memory, null);
        try vk(c.vkBindImageMemory(renderer.device, image, memory, 0), error.BindDmabufMemoryFailed);

        var modifier_properties: c.VkImageDrmFormatModifierPropertiesEXT = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT,
            .pNext = null,
            .drmFormatModifier = undefined,
        };
        try vk(
            renderer.get_image_modifier.?(renderer.device, image, &modifier_properties),
            error.QueryDmabufModifierFailed,
        );
        const plane_count = renderer.modifierPlaneCount(modifier_properties.drmFormatModifier, format) orelse
            return error.QueryDmabufModifierFailed;
        if (plane_count == 0 or plane_count > 4) return error.UnsupportedDmabufPlaneCount;
        var planes: [4]DmabufPlane = undefined;
        for (0..plane_count) |index| {
            const plane_aspect = @as(c.VkImageAspectFlags, c.VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT) << @intCast(index);
            const subresource: c.VkImageSubresource = .{
                .aspectMask = plane_aspect,
                .mipLevel = 0,
                .arrayLayer = 0,
            };
            var image_layout: c.VkSubresourceLayout = undefined;
            c.vkGetImageSubresourceLayout(renderer.device, image, &subresource, &image_layout);
            if (image_layout.offset > std.math.maxInt(u32) or image_layout.rowPitch > std.math.maxInt(u32))
                return error.DmabufLayoutTooLarge;
            planes[index] = .{ .offset = @intCast(image_layout.offset), .stride = @intCast(image_layout.rowPitch) };
        }

        var view_info: c.VkImageViewCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = format,
            .components = .{
                .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        var view: c.VkImageView = undefined;
        try vk(c.vkCreateImageView(renderer.device, &view_info, null, &view), error.CreateDmabufViewFailed);
        errdefer c.vkDestroyImageView(renderer.device, view, null);
        const linear = if (direct) null else if (shared) |attachment| attachment.retain() else try LinearAttachment.init(renderer, width, height);
        errdefer if (linear) |attachment| attachment.deinit(renderer);
        var attachments = [_]c.VkImageView{ if (linear) |attachment| attachment.view else view, view };
        var framebuffer_info: c.VkFramebufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .renderPass = if (direct) renderer.direct_presentation.render_pass else renderer.presentation_render_pass,
            .attachmentCount = if (direct) 1 else attachments.len,
            .pAttachments = &attachments,
            .width = width,
            .height = height,
            .layers = 1,
        };
        var framebuffer: c.VkFramebuffer = undefined;
        try vk(c.vkCreateFramebuffer(renderer.device, &framebuffer_info, null, &framebuffer), error.CreateFramebufferFailed);
        errdefer c.vkDestroyFramebuffer(renderer.device, framebuffer, null);
        var command_pool_info: c.VkCommandPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = renderer.queue_family,
        };
        var command_pool: c.VkCommandPool = undefined;
        try vk(c.vkCreateCommandPool(renderer.device, &command_pool_info, null, &command_pool), error.CreateCommandPoolFailed);
        errdefer c.vkDestroyCommandPool(renderer.device, command_pool, null);
        var command_buffer_info: c.VkCommandBufferAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        var command_buffer: c.VkCommandBuffer = undefined;
        try vk(c.vkAllocateCommandBuffers(renderer.device, &command_buffer_info, &command_buffer), error.AllocateCommandBufferFailed);
        var fence_info: c.VkFenceCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        var fence: c.VkFence = undefined;
        try vk(c.vkCreateFence(renderer.device, &fence_info, null, &fence), error.CreateFenceFailed);
        errdefer c.vkDestroyFence(renderer.device, fence, null);
        var semaphore_type: c.VkSemaphoreTypeCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
            .pNext = null,
            .semaphoreType = c.VK_SEMAPHORE_TYPE_TIMELINE,
            .initialValue = 0,
        };
        var semaphore_export: c.VkExportSemaphoreCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO,
            .pNext = &semaphore_type,
            .handleTypes = c.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT,
        };
        var semaphore_info: c.VkSemaphoreCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = &semaphore_export,
            .flags = 0,
        };
        var timeline: c.VkSemaphore = undefined;
        try vk(c.vkCreateSemaphore(renderer.device, &semaphore_info, null, &timeline), error.CreateTimelineFailed);
        errdefer c.vkDestroySemaphore(renderer.device, timeline, null);
        return .{
            .image = image,
            .memory = memory,
            .view = view,
            .framebuffer = framebuffer,
            .linear = linear,
            .direct = direct,
            .command_pool = command_pool,
            .command_buffer = command_buffer,
            .fence = fence,
            .timeline = timeline,
            .width = width,
            .height = height,
            .modifier = modifier_properties.drmFormatModifier,
            .planes = planes,
            .plane_count = @intCast(plane_count),
        };
    }

    pub fn deinit(self: *DmabufTarget, renderer: *Renderer) void {
        if (self.gpu_pending)
            _ = c.vkWaitForFences(renderer.device, 1, &self.fence, c.VK_TRUE, std.math.maxInt(u64));
        self.image_uploads.deinit(renderer);
        c.vkDestroySemaphore(renderer.device, self.timeline, null);
        c.vkDestroyFence(renderer.device, self.fence, null);
        c.vkDestroyCommandPool(renderer.device, self.command_pool, null);
        c.vkDestroyFramebuffer(renderer.device, self.framebuffer, null);
        if (self.linear) |attachment| attachment.deinit(renderer);
        c.vkDestroyImageView(renderer.device, self.view, null);
        c.vkDestroyImage(renderer.device, self.image, null);
        c.vkFreeMemory(renderer.device, self.memory, null);
        self.* = undefined;
    }

    pub fn ready(self: *DmabufTarget, renderer: *Renderer) !bool {
        if (!self.gpu_pending) return true;
        return switch (c.vkGetFenceStatus(renderer.device, self.fence)) {
            c.VK_SUCCESS => blk: {
                self.gpu_pending = false;
                self.image_uploads.deinit(renderer);
                break :blk true;
            },
            c.VK_NOT_READY => false,
            else => error.DeviceLost,
        };
    }

    pub fn wait(self: *DmabufTarget, renderer: *Renderer) !void {
        if (!self.gpu_pending) return;
        try vk(c.vkWaitForFences(renderer.device, 1, &self.fence, c.VK_TRUE, std.math.maxInt(u64)), error.DeviceLost);
        self.gpu_pending = false;
        self.image_uploads.deinit(renderer);
    }

    pub fn exportSyncobjFd(self: *DmabufTarget, renderer: *Renderer) !std.posix.fd_t {
        var info: c.VkSemaphoreGetFdInfoKHR = .{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_GET_FD_INFO_KHR,
            .pNext = null,
            .semaphore = self.timeline,
            .handleType = c.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_FD_BIT,
        };
        var fd: c_int = -1;
        try vk(renderer.get_semaphore_fd.?(renderer.device, &info, &fd), error.ExportTimelineFailed);
        if (fd < 0) return error.ExportTimelineFailed;
        self.explicit_sync = true;
        return fd;
    }

    pub fn syncPoints(self: *const DmabufTarget) struct { acquire: u64, release: u64 } {
        return .{ .acquire = self.acquire_point, .release = self.release_point };
    }

    /// Returns a new owned dma-buf FD. Wayring takes ownership after the FD is
    /// successfully queued in `zwp_linux_buffer_params_v1.add`.
    pub fn exportFd(self: *const DmabufTarget, renderer: *Renderer) !std.posix.fd_t {
        var info: c.VkMemoryGetFdInfoKHR = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
            .pNext = null,
            .memory = self.memory,
            .handleType = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
        };
        var fd: c_int = -1;
        try vk(renderer.get_memory_fd.?(renderer.device, &info, &fd), error.ExportDmabufFailed);
        if (fd < 0) return error.ExportDmabufFailed;
        return fd;
    }
};

const PresentationPush = extern struct {
    background: [4]f32,
    border: [4]f32,
    target_size: [2]f32,
    corner_radius: f32,
    border_width: f32,
    bounds: [4]i32,
    has_background: u32,
    has_border: u32,
    coverage_only: u32 = 0,
};

const Push = extern struct {
    target_width: u32,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    shape_left: i32,
    shape_top: i32,
    shape_right: i32,
    shape_bottom: i32,
    padding: u32 = 0, // GLSL uvec2 has eight-byte alignment.
    background: [2]u32,
    border: [2]u32,
    corner_radius: u32,
    border_width: u32,
    flags: u32,
    source_over: u32,
};

const GlyphPush = extern struct {
    target_width: u32,
    atlas_width_value: u32,
    source: [2]u32,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    atlas_x: u32,
    atlas_y: u32,
    image_mode: u32 = 0,
    image_rows: u32 = 0,
    image_left: f32 = 0,
    image_top: f32 = 0,
    image_width: f32 = 0,
    image_height: f32 = 0,
};

const PresentationGlyphPush = extern struct {
    color: [4]f32,
    target_size: [2]f32,
    padding: [2]f32 = .{ 0, 0 },
    bounds: [4]i32,
    atlas_origin: [2]u32,
    atlas_width_value: u32,
    image_mode: u32 = 0,
    image_rows: u32 = 0,
    image_left: f32 = 0,
    image_top: f32 = 0,
    image_width: f32 = 0,
    image_height: f32 = 0,
};

const PresentationObjects = struct {
    render_pass: c.VkRenderPass,
    layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,
    glyph_layout: c.VkPipelineLayout,
    glyph_pipeline: c.VkPipeline,
    erase_pipeline: c.VkPipeline,
    add_pipeline: c.VkPipeline,
    conversion_descriptor_layout: c.VkDescriptorSetLayout,
    conversion_layout: c.VkPipelineLayout,
    conversion_pipeline: c.VkPipeline,

    fn deinit(self: PresentationObjects, device: c.VkDevice) void {
        c.vkDestroyPipeline(device, self.conversion_pipeline, null);
        c.vkDestroyPipelineLayout(device, self.conversion_layout, null);
        c.vkDestroyDescriptorSetLayout(device, self.conversion_descriptor_layout, null);
        c.vkDestroyPipeline(device, self.erase_pipeline, null);
        c.vkDestroyPipeline(device, self.add_pipeline, null);
        c.vkDestroyPipeline(device, self.glyph_pipeline, null);
        c.vkDestroyPipelineLayout(device, self.glyph_layout, null);
        c.vkDestroyPipeline(device, self.pipeline, null);
        c.vkDestroyPipelineLayout(device, self.layout, null);
        c.vkDestroyRenderPass(device, self.render_pass, null);
    }
};

fn createPresentationPipeline(device: c.VkDevice, atlas_layout: c.VkDescriptorSetLayout, direct: bool) !PresentationObjects {
    const attachment: c.VkAttachmentDescription = .{
        .flags = 0,
        .format = if (direct) c.VK_FORMAT_B8G8R8A8_SRGB else c.VK_FORMAT_R16G16B16A16_SFLOAT,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_LOAD,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    var attachments = [_]c.VkAttachmentDescription{ attachment, attachment };
    attachments[1].format = c.VK_FORMAT_B8G8R8A8_UNORM;
    attachments[1].loadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    var attachment_reference: c.VkAttachmentReference = .{
        .attachment = 0,
        .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    const subpass: c.VkSubpassDescription = .{
        .flags = 0,
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .inputAttachmentCount = 0,
        .pInputAttachments = null,
        .colorAttachmentCount = 1,
        .pColorAttachments = &attachment_reference,
        .pResolveAttachments = null,
        .pDepthStencilAttachment = null,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = null,
    };
    var input_reference: c.VkAttachmentReference = .{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    var export_reference: c.VkAttachmentReference = .{ .attachment = 1, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    var subpasses = [_]c.VkSubpassDescription{ subpass, subpass };
    subpasses[1].inputAttachmentCount = 1;
    subpasses[1].pInputAttachments = &input_reference;
    subpasses[1].pColorAttachments = &export_reference;
    // Also synchronize the persistent attachment against the previous frame's
    // input reads and final layout transition. Export ownership is separate.
    var dependencies = [_]c.VkSubpassDependency{
        .{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | c.VK_ACCESS_INPUT_ATTACHMENT_READ_BIT,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
        },
        .{
            .srcSubpass = 0,
            .dstSubpass = 1,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            // The last-use subpass also stores the persistent attachment,
            // even though its shader only reads it as an input attachment.
            .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_INPUT_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
        },
        .{
            .srcSubpass = 1,
            .dstSubpass = c.VK_SUBPASS_EXTERNAL,
            .srcStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = c.VK_ACCESS_INPUT_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
        },
    };
    var render_pass_info: c.VkRenderPassCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .attachmentCount = if (direct) 1 else attachments.len,
        .pAttachments = &attachments,
        .subpassCount = if (direct) 1 else subpasses.len,
        .pSubpasses = &subpasses,
        .dependencyCount = if (direct) 1 else dependencies.len,
        .pDependencies = &dependencies,
    };
    var render_pass: c.VkRenderPass = undefined;
    try vk(c.vkCreateRenderPass(device, &render_pass_info, null, &render_pass), error.CreateRenderPassFailed);
    errdefer c.vkDestroyRenderPass(device, render_pass, null);

    var push_range: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf(PresentationPush),
    };
    var layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 0,
        .pSetLayouts = null,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_range,
    };
    var layout: c.VkPipelineLayout = undefined;
    try vk(c.vkCreatePipelineLayout(device, &layout_info, null, &layout), error.CreatePipelineLayoutFailed);
    errdefer c.vkDestroyPipelineLayout(device, layout, null);

    const vertex_bytes align(@alignOf(u32)) = @embedFile("ourokit_vulkan_solid_vertex").*;
    const vertex = try createShader(device, &vertex_bytes);
    defer c.vkDestroyShaderModule(device, vertex, null);
    const fragment_bytes align(@alignOf(u32)) = @embedFile("ourokit_vulkan_solid_fragment").*;
    const fragment = try createShader(device, &fragment_bytes);
    defer c.vkDestroyShaderModule(device, fragment, null);
    var stages = [_]c.VkPipelineShaderStageCreateInfo{
        .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
            .module = vertex,
            .pName = "main",
            .pSpecializationInfo = null,
        },
        .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
            .module = fragment,
            .pName = "main",
            .pSpecializationInfo = null,
        },
    };
    var vertex_input: c.VkPipelineVertexInputStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .vertexBindingDescriptionCount = 0,
        .pVertexBindingDescriptions = null,
        .vertexAttributeDescriptionCount = 0,
        .pVertexAttributeDescriptions = null,
    };
    var input_assembly: c.VkPipelineInputAssemblyStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .primitiveRestartEnable = c.VK_FALSE,
    };
    var viewport_state: c.VkPipelineViewportStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .viewportCount = 1,
        .pViewports = null,
        .scissorCount = 1,
        .pScissors = null,
    };
    var rasterization: c.VkPipelineRasterizationStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .depthClampEnable = c.VK_FALSE,
        .rasterizerDiscardEnable = c.VK_FALSE,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .cullMode = c.VK_CULL_MODE_NONE,
        .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .depthBiasEnable = c.VK_FALSE,
        .depthBiasConstantFactor = 0,
        .depthBiasClamp = 0,
        .depthBiasSlopeFactor = 0,
        .lineWidth = 1,
    };
    var multisample: c.VkPipelineMultisampleStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
        .sampleShadingEnable = c.VK_FALSE,
        .minSampleShading = 0,
        .pSampleMask = null,
        .alphaToCoverageEnable = c.VK_FALSE,
        .alphaToOneEnable = c.VK_FALSE,
    };
    var blend_attachment: c.VkPipelineColorBlendAttachmentState = .{
        .blendEnable = c.VK_TRUE,
        .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .colorBlendOp = c.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
        .alphaBlendOp = c.VK_BLEND_OP_ADD,
        .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT |
            c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
    };
    var color_blend: c.VkPipelineColorBlendStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .logicOpEnable = c.VK_FALSE,
        .logicOp = c.VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &blend_attachment,
        .blendConstants = .{ 0, 0, 0, 0 },
    };
    var dynamics = [_]c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    var dynamic_state: c.VkPipelineDynamicStateCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .dynamicStateCount = dynamics.len,
        .pDynamicStates = &dynamics,
    };
    var pipeline_info: c.VkGraphicsPipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stageCount = stages.len,
        .pStages = &stages,
        .pVertexInputState = &vertex_input,
        .pInputAssemblyState = &input_assembly,
        .pTessellationState = null,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization,
        .pMultisampleState = &multisample,
        .pDepthStencilState = null,
        .pColorBlendState = &color_blend,
        .pDynamicState = &dynamic_state,
        .layout = layout,
        .renderPass = render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };
    var pipeline: c.VkPipeline = undefined;
    try vk(c.vkCreateGraphicsPipelines(device, null, 1, &pipeline_info, null, &pipeline), error.CreatePipelineFailed);
    errdefer c.vkDestroyPipeline(device, pipeline, null);

    // Source replaces destination according to geometric coverage, not source
    // alpha. Erase that coverage first, then add the premultiplied source.
    blend_attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_ZERO;
    blend_attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO;
    var erase_pipeline: c.VkPipeline = undefined;
    try vk(c.vkCreateGraphicsPipelines(device, null, 1, &pipeline_info, null, &erase_pipeline), error.CreatePipelineFailed);
    errdefer c.vkDestroyPipeline(device, erase_pipeline, null);
    blend_attachment.srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE;
    blend_attachment.srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
    blend_attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE;
    blend_attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE;
    var add_pipeline: c.VkPipeline = undefined;
    try vk(c.vkCreateGraphicsPipelines(device, null, 1, &pipeline_info, null, &add_pipeline), error.CreatePipelineFailed);
    errdefer c.vkDestroyPipeline(device, add_pipeline, null);
    blend_attachment.dstColorBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    blend_attachment.dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;

    var glyph_push_range: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .offset = 0,
        .size = @sizeOf(PresentationGlyphPush),
    };
    var glyph_layout_info = layout_info;
    glyph_layout_info.setLayoutCount = 1;
    glyph_layout_info.pSetLayouts = &atlas_layout;
    glyph_layout_info.pPushConstantRanges = &glyph_push_range;
    var glyph_layout: c.VkPipelineLayout = undefined;
    try vk(c.vkCreatePipelineLayout(device, &glyph_layout_info, null, &glyph_layout), error.CreatePipelineLayoutFailed);
    errdefer c.vkDestroyPipelineLayout(device, glyph_layout, null);
    const glyph_fragment_bytes align(@alignOf(u32)) = @embedFile("ourokit_vulkan_glyph_fragment").*;
    const glyph_fragment = try createShader(device, &glyph_fragment_bytes);
    defer c.vkDestroyShaderModule(device, glyph_fragment, null);
    stages[0].module = vertex;
    stages[1].module = glyph_fragment;
    pipeline_info.layout = glyph_layout;
    var glyph_pipeline: c.VkPipeline = undefined;
    try vk(c.vkCreateGraphicsPipelines(device, null, 1, &pipeline_info, null, &glyph_pipeline), error.CreatePipelineFailed);
    errdefer c.vkDestroyPipeline(device, glyph_pipeline, null);

    if (direct) return .{
        .render_pass = render_pass,
        .layout = layout,
        .pipeline = pipeline,
        .glyph_layout = glyph_layout,
        .glyph_pipeline = glyph_pipeline,
        .erase_pipeline = erase_pipeline,
        .add_pipeline = add_pipeline,
        .conversion_descriptor_layout = null,
        .conversion_layout = null,
        .conversion_pipeline = null,
    };

    var conversion_binding: c.VkDescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    var descriptor_info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &conversion_binding,
    };
    var conversion_descriptor_layout: c.VkDescriptorSetLayout = undefined;
    try vk(c.vkCreateDescriptorSetLayout(device, &descriptor_info, null, &conversion_descriptor_layout), error.CreateDescriptorLayoutFailed);
    errdefer c.vkDestroyDescriptorSetLayout(device, conversion_descriptor_layout, null);
    var conversion_layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &conversion_descriptor_layout,
    };
    var conversion_layout: c.VkPipelineLayout = undefined;
    try vk(c.vkCreatePipelineLayout(device, &conversion_layout_info, null, &conversion_layout), error.CreatePipelineLayoutFailed);
    errdefer c.vkDestroyPipelineLayout(device, conversion_layout, null);
    const conversion_bytes align(@alignOf(u32)) = @embedFile("ourokit_vulkan_conversion_fragment").*;
    const conversion_fragment = try createShader(device, &conversion_bytes);
    defer c.vkDestroyShaderModule(device, conversion_fragment, null);
    stages[1].module = conversion_fragment;
    pipeline_info.layout = conversion_layout;
    pipeline_info.subpass = 1;
    blend_attachment.blendEnable = c.VK_FALSE;
    var conversion_pipeline: c.VkPipeline = undefined;
    try vk(c.vkCreateGraphicsPipelines(device, null, 1, &pipeline_info, null, &conversion_pipeline), error.CreatePipelineFailed);
    return .{
        .render_pass = render_pass,
        .layout = layout,
        .pipeline = pipeline,
        .glyph_layout = glyph_layout,
        .glyph_pipeline = glyph_pipeline,
        .erase_pipeline = erase_pipeline,
        .add_pipeline = add_pipeline,
        .conversion_descriptor_layout = conversion_descriptor_layout,
        .conversion_layout = conversion_layout,
        .conversion_pipeline = conversion_pipeline,
    };
}

fn createShader(device: c.VkDevice, bytes: []align(@alignOf(u32)) const u8) !c.VkShaderModule {
    var info: c.VkShaderModuleCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = bytes.len,
        .pCode = @ptrCast(bytes.ptr),
    };
    var shader: c.VkShaderModule = undefined;
    try vk(c.vkCreateShaderModule(device, &info, null, &shader), error.CreateShaderFailed);
    return shader;
}

pub fn init(allocator: std.mem.Allocator) !Renderer {
    if (builtin.cpu.arch.endian() != .little) return error.UnsupportedEndian;

    var app_info: c.VkApplicationInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = "ourokit",
        .applicationVersion = 1,
        .pEngineName = "ourokit",
        .engineVersion = 1,
        .apiVersion = c.VK_API_VERSION_1_2,
    };
    var instance_info: c.VkInstanceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = 0,
        .ppEnabledExtensionNames = null,
    };
    var instance: c.VkInstance = undefined;
    try vk(c.vkCreateInstance(&instance_info, null, &instance), error.CreateInstanceFailed);
    errdefer c.vkDestroyInstance(instance, null);

    const selection = try chooseDevice(allocator, instance);
    var memory_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(selection.physical_device, &memory_properties);
    var properties: c.VkPhysicalDeviceProperties = undefined;
    c.vkGetPhysicalDeviceProperties(selection.physical_device, &properties);
    var linear_properties: c.VkFormatProperties = undefined;
    c.vkGetPhysicalDeviceFormatProperties(selection.physical_device, c.VK_FORMAT_R16G16B16A16_SFLOAT, &linear_properties);
    const required_linear_features = c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT | c.VK_FORMAT_FEATURE_TRANSFER_DST_BIT;
    var linear_image_properties: c.VkImageFormatProperties = undefined;
    const linear_supported = linear_properties.optimalTilingFeatures & required_linear_features == required_linear_features and
        c.vkGetPhysicalDeviceImageFormatProperties(selection.physical_device, c.VK_FORMAT_R16G16B16A16_SFLOAT, c.VK_IMAGE_TYPE_2D, c.VK_IMAGE_TILING_OPTIMAL, LinearAttachment.usage, 0, &linear_image_properties) == c.VK_SUCCESS;
    // Capability loss must select the host's existing SHM/software fallback,
    // not make renderer initialization fatal. Integer compute remains usable.
    const dmabuf_enabled = linear_supported and try supportsDeviceExtensions(allocator, selection.physical_device, &dmabuf_extensions);
    var drm_properties: c.VkPhysicalDeviceDrmPropertiesEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT,
        .pNext = null,
        .hasPrimary = c.VK_FALSE,
        .hasRender = c.VK_FALSE,
        .primaryMajor = 0,
        .primaryMinor = 0,
        .renderMajor = 0,
        .renderMinor = 0,
    };
    if (dmabuf_enabled) {
        var properties2: c.VkPhysicalDeviceProperties2 = .{
            .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
            .pNext = &drm_properties,
            .properties = undefined,
        };
        c.vkGetPhysicalDeviceProperties2(selection.physical_device, &properties2);
    }
    const enabled_extensions: []const [*:0]const u8 = if (dmabuf_enabled) &dmabuf_extensions else &.{};
    const priority: f32 = 1;
    var queue_info: c.VkDeviceQueueCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = selection.queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    var timeline_features: c.VkPhysicalDeviceTimelineSemaphoreFeatures = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES,
        .pNext = null,
        .timelineSemaphore = if (dmabuf_enabled) c.VK_TRUE else c.VK_FALSE,
    };
    var device_info: c.VkDeviceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = if (dmabuf_enabled) &timeline_features else null,
        .flags = 0,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = @intCast(enabled_extensions.len),
        .ppEnabledExtensionNames = if (enabled_extensions.len == 0) null else enabled_extensions.ptr,
        .pEnabledFeatures = null,
    };
    var device: c.VkDevice = undefined;
    try vk(c.vkCreateDevice(selection.physical_device, &device_info, null, &device), error.CreateDeviceFailed);
    errdefer c.vkDestroyDevice(device, null);
    var queue: c.VkQueue = undefined;
    c.vkGetDeviceQueue(device, selection.queue_family, 0, &queue);
    const get_memory_fd: ?GetMemoryFd = if (dmabuf_enabled)
        @ptrCast(c.vkGetDeviceProcAddr(device, "vkGetMemoryFdKHR") orelse return error.MissingMemoryFdFunction)
    else
        null;
    const get_image_modifier: ?GetImageModifier = if (dmabuf_enabled)
        @ptrCast(c.vkGetDeviceProcAddr(device, "vkGetImageDrmFormatModifierPropertiesEXT") orelse
            return error.MissingImageModifierFunction)
    else
        null;
    const get_semaphore_fd: ?GetSemaphoreFd = if (dmabuf_enabled)
        @ptrCast(c.vkGetDeviceProcAddr(device, "vkGetSemaphoreFdKHR") orelse
            return error.MissingSemaphoreFdFunction)
    else
        null;

    var bindings = [_]c.VkDescriptorSetLayoutBinding{
        .{
            .binding = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .pImmutableSamplers = null,
        },
        .{
            .binding = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1,
            .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .pImmutableSamplers = null,
        },
    };
    var descriptor_layout_info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = bindings.len,
        .pBindings = &bindings,
    };
    var descriptor_layout: c.VkDescriptorSetLayout = undefined;
    try vk(c.vkCreateDescriptorSetLayout(device, &descriptor_layout_info, null, &descriptor_layout), error.CreateDescriptorLayoutFailed);
    errdefer c.vkDestroyDescriptorSetLayout(device, descriptor_layout, null);

    var push_range: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
        .offset = 0,
        .size = @max(@sizeOf(Push), @sizeOf(GlyphPush)),
    };
    var pipeline_layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = 1,
        .pSetLayouts = &descriptor_layout,
        .pushConstantRangeCount = 1,
        .pPushConstantRanges = &push_range,
    };
    var pipeline_layout: c.VkPipelineLayout = undefined;
    try vk(c.vkCreatePipelineLayout(device, &pipeline_layout_info, null, &pipeline_layout), error.CreatePipelineLayoutFailed);
    errdefer c.vkDestroyPipelineLayout(device, pipeline_layout, null);

    const shader_bytes align(@alignOf(u32)) = @embedFile("ourokit_vulkan_fill").*;
    var shader_info: c.VkShaderModuleCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .codeSize = shader_bytes.len,
        .pCode = @ptrCast(&shader_bytes),
    };
    var shader: c.VkShaderModule = undefined;
    try vk(c.vkCreateShaderModule(device, &shader_info, null, &shader), error.CreateShaderFailed);
    defer c.vkDestroyShaderModule(device, shader, null);
    var pipeline_info: c.VkComputePipelineCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .stage = .{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .stage = c.VK_SHADER_STAGE_COMPUTE_BIT,
            .module = shader,
            .pName = "main",
            .pSpecializationInfo = null,
        },
        .layout = pipeline_layout,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };
    var pipeline: c.VkPipeline = undefined;
    try vk(c.vkCreateComputePipelines(device, null, 1, &pipeline_info, null, &pipeline), error.CreatePipelineFailed);
    errdefer c.vkDestroyPipeline(device, pipeline, null);

    const glyph_shader_bytes align(@alignOf(u32)) = @embedFile("ourokit_vulkan_glyph").*;
    const glyph_shader = try createShader(device, &glyph_shader_bytes);
    defer c.vkDestroyShaderModule(device, glyph_shader, null);
    pipeline_info.stage.module = glyph_shader;
    var glyph_pipeline: c.VkPipeline = undefined;
    try vk(c.vkCreateComputePipelines(device, null, 1, &pipeline_info, null, &glyph_pipeline), error.CreatePipelineFailed);
    errdefer c.vkDestroyPipeline(device, glyph_pipeline, null);

    var atlas_binding: c.VkDescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = null,
    };
    var atlas_layout_info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = 1,
        .pBindings = &atlas_binding,
    };
    var atlas_descriptor_layout: c.VkDescriptorSetLayout = undefined;
    try vk(c.vkCreateDescriptorSetLayout(device, &atlas_layout_info, null, &atlas_descriptor_layout), error.CreateDescriptorLayoutFailed);
    errdefer c.vkDestroyDescriptorSetLayout(device, atlas_descriptor_layout, null);

    const presentation = if (linear_supported)
        try createPresentationPipeline(device, atlas_descriptor_layout, false)
    else
        std.mem.zeroes(PresentationObjects);
    errdefer presentation.deinit(device);
    var srgb_properties: c.VkFormatProperties = undefined;
    c.vkGetPhysicalDeviceFormatProperties(selection.physical_device, c.VK_FORMAT_B8G8R8A8_SRGB, &srgb_properties);
    const srgb_required = c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT;
    const direct_presentation = if (linear_supported and srgb_properties.optimalTilingFeatures & srgb_required == srgb_required)
        try createPresentationPipeline(device, atlas_descriptor_layout, true)
    else
        std.mem.zeroes(PresentationObjects);
    errdefer direct_presentation.deinit(device);

    var pool_size: c.VkDescriptorPoolSize = .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 2 };
    var descriptor_pool_info: c.VkDescriptorPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .maxSets = 1,
        .poolSizeCount = 1,
        .pPoolSizes = &pool_size,
    };
    var descriptor_pool: c.VkDescriptorPool = undefined;
    try vk(c.vkCreateDescriptorPool(device, &descriptor_pool_info, null, &descriptor_pool), error.CreateDescriptorPoolFailed);
    errdefer c.vkDestroyDescriptorPool(device, descriptor_pool, null);

    var command_pool_info: c.VkCommandPoolCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = selection.queue_family,
    };
    var command_pool: c.VkCommandPool = undefined;
    try vk(c.vkCreateCommandPool(device, &command_pool_info, null, &command_pool), error.CreateCommandPoolFailed);
    errdefer c.vkDestroyCommandPool(device, command_pool, null);
    var command_buffer_info: c.VkCommandBufferAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = null,
        .commandPool = command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };
    var command_buffer: c.VkCommandBuffer = undefined;
    try vk(c.vkAllocateCommandBuffers(device, &command_buffer_info, &command_buffer), error.AllocateCommandBufferFailed);

    var fence_info: c.VkFenceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
    };
    var fence: c.VkFence = undefined;
    try vk(c.vkCreateFence(device, &fence_info, null, &fence), error.CreateFenceFailed);
    errdefer c.vkDestroyFence(device, fence, null);

    return .{
        .allocator = allocator,
        .instance = instance,
        .physical_device = selection.physical_device,
        .memory_properties = memory_properties,
        .device = device,
        .queue_family = selection.queue_family,
        .queue = queue,
        .dmabuf_enabled = dmabuf_enabled,
        .get_memory_fd = get_memory_fd,
        .get_image_modifier = get_image_modifier,
        .get_semaphore_fd = get_semaphore_fd,
        .drm_primary_device = if (drm_properties.hasPrimary == c.VK_TRUE)
            linuxDevice(@intCast(drm_properties.primaryMajor), @intCast(drm_properties.primaryMinor))
        else
            null,
        .drm_render_device = if (drm_properties.hasRender == c.VK_TRUE)
            linuxDevice(@intCast(drm_properties.renderMajor), @intCast(drm_properties.renderMinor))
        else
            null,
        .descriptor_layout = descriptor_layout,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .glyph_pipeline = glyph_pipeline,
        .atlas_descriptor_layout = atlas_descriptor_layout,
        .presentation_render_pass = presentation.render_pass,
        .presentation_pipeline_layout = presentation.layout,
        .presentation_pipeline = presentation.pipeline,
        .presentation_glyph_pipeline_layout = presentation.glyph_layout,
        .presentation_glyph_pipeline = presentation.glyph_pipeline,
        .presentation_erase_pipeline = presentation.erase_pipeline,
        .presentation_add_pipeline = presentation.add_pipeline,
        .direct_presentation = direct_presentation,
        .conversion_descriptor_layout = presentation.conversion_descriptor_layout,
        .conversion_pipeline_layout = presentation.conversion_layout,
        .conversion_pipeline = presentation.conversion_pipeline,
        .descriptor_pool = descriptor_pool,
        .command_pool = command_pool,
        .command_buffer = command_buffer,
        .fence = fence,
        .max_pixels = @min(
            @as(u64, properties.limits.maxStorageBufferRange) / 8,
            @as(u64, properties.limits.maxComputeWorkGroupCount[0]) * local_size,
        ),
        .max_image_pixels = @as(u64, properties.limits.maxStorageBufferRange) / 4,
    };
}

pub fn deinit(self: *Renderer) void {
    _ = c.vkDeviceWaitIdle(self.device);
    self.direct_presentation.deinit(self.device);
    c.vkDestroyFence(self.device, self.fence, null);
    c.vkDestroyCommandPool(self.device, self.command_pool, null);
    c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
    c.vkDestroyPipeline(self.device, self.conversion_pipeline, null);
    c.vkDestroyPipelineLayout(self.device, self.conversion_pipeline_layout, null);
    c.vkDestroyDescriptorSetLayout(self.device, self.conversion_descriptor_layout, null);
    c.vkDestroyPipeline(self.device, self.presentation_erase_pipeline, null);
    c.vkDestroyPipeline(self.device, self.presentation_add_pipeline, null);
    c.vkDestroyPipeline(self.device, self.presentation_glyph_pipeline, null);
    c.vkDestroyPipelineLayout(self.device, self.presentation_glyph_pipeline_layout, null);
    c.vkDestroyPipeline(self.device, self.presentation_pipeline, null);
    c.vkDestroyPipelineLayout(self.device, self.presentation_pipeline_layout, null);
    c.vkDestroyRenderPass(self.device, self.presentation_render_pass, null);
    c.vkDestroyPipeline(self.device, self.pipeline, null);
    c.vkDestroyPipeline(self.device, self.glyph_pipeline, null);
    c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
    c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_layout, null);
    c.vkDestroyDescriptorSetLayout(self.device, self.atlas_descriptor_layout, null);
    c.vkDestroyDevice(self.device, null);
    c.vkDestroyInstance(self.instance, null);
    self.* = undefined;
}

pub fn supportsDmabuf(self: *const Renderer) bool {
    return self.dmabuf_enabled;
}

pub fn supportsDmabufModifier(self: *const Renderer, modifier: u64) bool {
    return self.dmabuf_enabled and supportsDmabufModifierOnDevice(self.physical_device, modifier, c.VK_FORMAT_B8G8R8A8_UNORM);
}

pub fn supportsDirectModifier(self: *const Renderer, modifier: u64) bool {
    return self.dmabuf_enabled and self.direct_presentation.render_pass != null and
        supportsDmabufModifierOnDevice(self.physical_device, modifier, c.VK_FORMAT_B8G8R8A8_SRGB);
}

pub fn matchesDrmDevice(self: *const Renderer, device_bytes: []const u8) bool {
    if (device_bytes.len != @sizeOf(u64)) return false;
    const device = std.mem.readInt(u64, device_bytes[0..8], .little);
    return (self.drm_primary_device != null and self.drm_primary_device.? == device) or
        (self.drm_render_device != null and self.drm_render_device.? == device);
}

fn modifierPlaneCount(self: *const Renderer, modifier: u64, format: c.VkFormat) ?u32 {
    var properties: c.VkFormatProperties2 = .{
        .sType = c.VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
        .pNext = null,
        .formatProperties = undefined,
    };
    var count: u32 = 0;
    var list: c.VkDrmFormatModifierPropertiesListEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
        .pNext = null,
        .drmFormatModifierCount = 0,
        .pDrmFormatModifierProperties = null,
    };
    properties.pNext = &list;
    c.vkGetPhysicalDeviceFormatProperties2(self.physical_device, format, &properties);
    count = list.drmFormatModifierCount;
    if (count == 0 or count > 256) return null;
    var entries: [256]c.VkDrmFormatModifierPropertiesEXT = undefined;
    list.drmFormatModifierCount = count;
    list.pDrmFormatModifierProperties = &entries;
    c.vkGetPhysicalDeviceFormatProperties2(self.physical_device, format, &properties);
    for (entries[0..list.drmFormatModifierCount]) |entry|
        if (entry.drmFormatModifier == modifier) return entry.drmFormatModifierPlaneCount;
    return null;
}

pub fn render(self: *Renderer, list: scene.DisplayList, target: *Target) !void {
    return self.renderResources(list, target, null, null, null, null);
}

pub fn renderText(
    self: *Renderer,
    list: scene.DisplayList,
    target: *Target,
    glyphs: *GlyphCache,
    shapes: *const text.ShapeCache,
) !void {
    if (!has_freetype) return error.FreeTypeDisabled;
    return self.renderResources(list, target, glyphs, shapes, null, null);
}

pub fn renderParagraphs(
    self: *Renderer,
    list: scene.DisplayList,
    target: *Target,
    glyphs: *GlyphCache,
    paragraphs: *const text.ParagraphCache,
) !void {
    return self.renderTextResources(list, target, glyphs, null, paragraphs);
}

/// Renders a display list containing either or both text command kinds.
pub fn renderTextResources(
    self: *Renderer,
    list: scene.DisplayList,
    target: *Target,
    glyphs: *GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
) !void {
    if (!has_freetype) return error.FreeTypeDisabled;
    return self.renderResources(list, target, glyphs, shapes, paragraphs, null);
}

pub fn renderResources(
    self: *Renderer,
    list: scene.DisplayList,
    target: *Target,
    glyphs: ?*GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
    images: ?*const ImageCache,
) !void {
    try list.validate();
    try validateClipDepth(list.commands, glyphs != null and shapes != null, glyphs != null and paragraphs != null);
    if (glyphs) |cache| try prepareText(list.commands, cache, shapes, paragraphs);
    var image_uploads = try ImageUploads.init(self, list.commands, images, target);
    defer image_uploads.deinit(self);
    try vk(c.vkResetDescriptorPool(self.device, self.descriptor_pool, 0), error.ResetDescriptorPoolFailed);
    var descriptor_allocate_info: c.VkDescriptorSetAllocateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = null,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = 1,
        .pSetLayouts = &self.descriptor_layout,
    };
    var descriptor_set: c.VkDescriptorSet = undefined;
    try vk(c.vkAllocateDescriptorSets(self.device, &descriptor_allocate_info, &descriptor_set), error.AllocateDescriptorSetFailed);
    var buffer_infos = [_]c.VkDescriptorBufferInfo{
        .{ .buffer = target.buffer, .offset = 0, .range = target.byte_size },
        .{ .buffer = if (has_freetype and glyphs != null) glyphs.?.buffer else target.buffer, .offset = 0, .range = if (glyphs != null) atlas_bytes else target.byte_size },
    };
    var descriptor_writes = [_]c.VkWriteDescriptorSet{
        .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_infos[0],
            .pTexelBufferView = null,
        },
        .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .pNext = null,
            .dstSet = descriptor_set,
            .dstBinding = 1,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pImageInfo = null,
            .pBufferInfo = &buffer_infos[1],
            .pTexelBufferView = null,
        },
    };
    c.vkUpdateDescriptorSets(self.device, if (glyphs != null) 2 else 1, &descriptor_writes, 0, null);

    try vk(c.vkResetCommandPool(self.device, self.command_pool, 0), error.ResetCommandPoolFailed);
    var begin_info: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try vk(c.vkBeginCommandBuffer(self.command_buffer, &begin_info), error.BeginCommandBufferFailed);
    const atlas_uploaded = if (has_freetype and glyphs != null)
        glyphs.?.recordUpload(self.command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT)
    else
        false;
    c.vkCmdBindPipeline(self.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
    c.vkCmdBindDescriptorSets(self.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &descriptor_set, 0, null);
    var host_write_barrier: c.VkMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
    };
    c.vkCmdPipelineBarrier(
        self.command_buffer,
        c.VK_PIPELINE_STAGE_HOST_BIT,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0,
        1,
        &host_write_barrier,
        0,
        null,
        0,
        null,
    );

    const bounds: RectI = .{ .x = 0, .y = 0, .width = target.width, .height = target.height };
    switch (list.damage) {
        .full => self.renderRegion(list.commands, target, bounds, glyphs, shapes, paragraphs, &image_uploads, descriptor_set),
        .regions => |regions| for (regions) |region| {
            const clipped = RectI.intersect(region, bounds);
            if (!clipped.isEmpty()) self.renderRegion(list.commands, target, clipped, glyphs, shapes, paragraphs, &image_uploads, descriptor_set);
        },
    }
    var host_barrier: c.VkMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_HOST_READ_BIT,
    };
    c.vkCmdPipelineBarrier(
        self.command_buffer,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        c.VK_PIPELINE_STAGE_HOST_BIT,
        0,
        1,
        &host_barrier,
        0,
        null,
        0,
        null,
    );
    try vk(c.vkEndCommandBuffer(self.command_buffer), error.EndCommandBufferFailed);
    try vk(c.vkResetFences(self.device, 1, &self.fence), error.ResetFenceFailed);
    var submit_info: c.VkSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = null,
        .pWaitDstStageMask = null,
        .commandBufferCount = 1,
        .pCommandBuffers = &self.command_buffer,
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = null,
    };
    try vk(c.vkQueueSubmit(self.queue, 1, &submit_info, self.fence), error.QueueSubmitFailed);
    if (has_freetype and atlas_uploaded) glyphs.?.uploaded();
    try vk(c.vkWaitForFences(self.device, 1, &self.fence, c.VK_TRUE, std.math.maxInt(u64)), error.DeviceLost);
}

/// Records and submits direct rendering into an exportable image. The target
/// owns its fence, so this returns after queue submission rather than waiting
/// for the GPU. Slot reuse must additionally wait for `ready` and compositor
/// release.
pub fn renderDmabuf(self: *Renderer, list: scene.DisplayList, target: *DmabufTarget) !void {
    return self.renderDmabufResources(list, target, null, null, null, null);
}

pub fn renderDmabufText(
    self: *Renderer,
    list: scene.DisplayList,
    target: *DmabufTarget,
    glyphs: *GlyphCache,
    shapes: *const text.ShapeCache,
) !void {
    if (!has_freetype) return error.FreeTypeDisabled;
    return self.renderDmabufResources(list, target, glyphs, shapes, null, null);
}

pub fn renderDmabufParagraphs(
    self: *Renderer,
    list: scene.DisplayList,
    target: *DmabufTarget,
    glyphs: *GlyphCache,
    paragraphs: *const text.ParagraphCache,
) !void {
    return self.renderDmabufTextResources(list, target, glyphs, null, paragraphs);
}

pub fn renderDmabufTextResources(
    self: *Renderer,
    list: scene.DisplayList,
    target: *DmabufTarget,
    glyphs: *GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
) !void {
    if (!has_freetype) return error.FreeTypeDisabled;
    return self.renderDmabufResources(list, target, glyphs, shapes, paragraphs, null);
}

pub fn renderDmabufResources(
    self: *Renderer,
    list: scene.DisplayList,
    target: *DmabufTarget,
    glyphs: ?*GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
    images: ?*const ImageCache,
) !void {
    return self.renderGraphicsResources(list, target, glyphs, shapes, paragraphs, images, true);
}

/// The host-readback destination is used by compositor-free graphics tests.
/// Both destinations execute the same per-target asynchronous submission.
pub fn renderGraphicsResources(
    self: *Renderer,
    list: scene.DisplayList,
    target: *DmabufTarget,
    glyphs: ?*GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
    images: ?*const ImageCache,
    comptime export_image: bool,
) !void {
    try list.validate();
    if (target.direct and !list.isOpaque(.{ .x = 0, .y = 0, .width = target.width, .height = target.height })) return error.OpaqueSceneRequired;
    try validateClipDepth(list.commands, glyphs != null and shapes != null, glyphs != null and paragraphs != null);
    if (glyphs) |cache| try prepareText(list.commands, cache, shapes, paragraphs);
    if (!try target.ready(self)) return error.TargetBusy;
    var image_uploads = try ImageUploads.init(self, list.commands, images, null);
    errdefer image_uploads.deinit(self);
    try vk(c.vkResetCommandBuffer(target.command_buffer, 0), error.ResetCommandBufferFailed);
    var begin_info: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try vk(c.vkBeginCommandBuffer(target.command_buffer, &begin_info), error.BeginCommandBufferFailed);
    if (target.timestamp_pool != null) {
        c.vkCmdResetQueryPool(target.command_buffer, target.timestamp_pool, 0, 2);
        c.vkCmdWriteTimestamp(target.command_buffer, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, target.timestamp_pool, 0);
    }
    const atlas_uploaded = if (has_freetype and glyphs != null)
        glyphs.?.recordUpload(target.command_buffer, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT)
    else
        false;
    if (target.linear) |linear| {
        if (!linear.initialized) linear.initialize(target.command_buffer);
    }
    var image_barrier: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = 0,
        .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .oldLayout = target.layout,
        .newLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .srcQueueFamilyIndex = if (!export_image or target.layout == c.VK_IMAGE_LAYOUT_UNDEFINED)
            c.VK_QUEUE_FAMILY_IGNORED
        else
            c.VK_QUEUE_FAMILY_FOREIGN_EXT,
        .dstQueueFamilyIndex = if (!export_image or target.layout == c.VK_IMAGE_LAYOUT_UNDEFINED)
            c.VK_QUEUE_FAMILY_IGNORED
        else
            self.queue_family,
        .image = target.image,
        .subresourceRange = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };
    c.vkCmdPipelineBarrier(
        target.command_buffer,
        c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &image_barrier,
    );
    var render_pass_begin: c.VkRenderPassBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .pNext = null,
        .renderPass = if (target.direct) self.direct_presentation.render_pass else self.presentation_render_pass,
        .framebuffer = target.framebuffer,
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = target.width, .height = target.height },
        },
        .clearValueCount = 0,
        .pClearValues = null,
    };
    c.vkCmdBeginRenderPass(target.command_buffer, &render_pass_begin, c.VK_SUBPASS_CONTENTS_INLINE);
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, if (target.direct) self.direct_presentation.pipeline else self.presentation_pipeline);
    var viewport: c.VkViewport = .{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(target.width),
        .height = @floatFromInt(target.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    c.vkCmdSetViewport(target.command_buffer, 0, 1, &viewport);

    const bounds: RectI = .{ .x = 0, .y = 0, .width = target.width, .height = target.height };
    // A new direct slot has no contents to preserve. The opacity proof also
    // guarantees that replaying the entire scene defines every pixel.
    const damage: scene.Damage = if (target.direct and target.layout == c.VK_IMAGE_LAYOUT_UNDEFINED) .full else list.damage;
    switch (damage) {
        .full => self.renderPresentationRegion(list.commands, target, bounds, glyphs, shapes, paragraphs, &image_uploads),
        .regions => |regions| for (regions) |region| {
            const clipped = RectI.intersect(region, bounds);
            if (!clipped.isEmpty()) self.renderPresentationRegion(list.commands, target, clipped, glyphs, shapes, paragraphs, &image_uploads);
        },
    }
    if (!target.direct) self.convertPresentation(target);
    c.vkCmdEndRenderPass(target.command_buffer);

    image_barrier.srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    image_barrier.dstAccessMask = if (export_image) 0 else c.VK_ACCESS_HOST_READ_BIT;
    image_barrier.oldLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    image_barrier.newLayout = c.VK_IMAGE_LAYOUT_GENERAL;
    image_barrier.srcQueueFamilyIndex = if (export_image) self.queue_family else c.VK_QUEUE_FAMILY_IGNORED;
    image_barrier.dstQueueFamilyIndex = if (export_image) c.VK_QUEUE_FAMILY_FOREIGN_EXT else c.VK_QUEUE_FAMILY_IGNORED;
    c.vkCmdPipelineBarrier(
        target.command_buffer,
        c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        if (export_image) c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT else c.VK_PIPELINE_STAGE_HOST_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &image_barrier,
    );
    if (target.timestamp_pool != null)
        c.vkCmdWriteTimestamp(target.command_buffer, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, target.timestamp_pool, 1);
    try vk(c.vkEndCommandBuffer(target.command_buffer), error.EndCommandBufferFailed);
    try vk(c.vkResetFences(self.device, 1, &target.fence), error.ResetFenceFailed);
    const previous_release = target.release_point;
    const acquire_point = if (target.explicit_sync) previous_release + 1 else 0;
    var wait_stage: c.VkPipelineStageFlags = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    var timeline_info: c.VkTimelineSemaphoreSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .waitSemaphoreValueCount = @intFromBool(target.explicit_sync and previous_release != 0),
        .pWaitSemaphoreValues = if (target.explicit_sync and previous_release != 0) &previous_release else null,
        .signalSemaphoreValueCount = @intFromBool(target.explicit_sync),
        .pSignalSemaphoreValues = if (target.explicit_sync) &acquire_point else null,
    };
    var submit_info: c.VkSubmitInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = if (target.explicit_sync) &timeline_info else null,
        .waitSemaphoreCount = @intFromBool(target.explicit_sync and previous_release != 0),
        .pWaitSemaphores = if (target.explicit_sync and previous_release != 0) &target.timeline else null,
        .pWaitDstStageMask = if (target.explicit_sync and previous_release != 0) &wait_stage else null,
        .commandBufferCount = 1,
        .pCommandBuffers = &target.command_buffer,
        .signalSemaphoreCount = @intFromBool(target.explicit_sync),
        .pSignalSemaphores = if (target.explicit_sync) &target.timeline else null,
    };
    try vk(c.vkQueueSubmit(self.queue, 1, &submit_info, target.fence), error.QueueSubmitFailed);
    if (target.linear) |linear| linear.initialized = true;
    if (has_freetype and atlas_uploaded) glyphs.?.uploaded();
    target.image_uploads = image_uploads;
    target.layout = c.VK_IMAGE_LAYOUT_GENERAL;
    target.gpu_pending = true;
    if (target.explicit_sync) {
        target.acquire_point = acquire_point;
        target.release_point = acquire_point + 1;
    }
}

fn convertPresentation(self: *Renderer, target: *const DmabufTarget) void {
    c.vkCmdNextSubpass(target.command_buffer, c.VK_SUBPASS_CONTENTS_INLINE);
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.conversion_pipeline);
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.conversion_pipeline_layout, 0, 1, &target.linear.?.descriptor, 0, null);
    // Conversion rewrites the export image, but never reads it back into the
    // working image. Undamaged linear pixels survive every submission.
    var viewport: c.VkViewport = .{ .x = 0, .y = 0, .width = @floatFromInt(target.width), .height = @floatFromInt(target.height), .minDepth = 0, .maxDepth = 1 };
    var scissor: c.VkRect2D = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = target.width, .height = target.height } };
    c.vkCmdSetViewport(target.command_buffer, 0, 1, &viewport);
    c.vkCmdSetScissor(target.command_buffer, 0, 1, &scissor);
    c.vkCmdDraw(target.command_buffer, 6, 1, 0, 0);
}

fn renderPresentationRegion(
    self: *Renderer,
    commands: []const scene.Command,
    target: *const DmabufTarget,
    damage: RectI,
    glyphs: ?*GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
    images: *const ImageUploads,
) void {
    var clips: [max_clip_depth + 1]RectI = undefined;
    clips[0] = damage;
    var depth: usize = 0;
    var image_index: usize = 0;
    for (commands, 0..) |command, index| switch (command) {
        .clear => |color| if (!scene.occludedByNextDraw(commands[index + 1 ..], clips[0 .. depth + 1], damage))
            self.presentationFill(target, damage, color, .source),
        .push_clip_rect => |clip| {
            depth += 1;
            clips[depth] = RectI.intersect(clips[depth - 1], clip);
        },
        .pop_clip => depth -= 1,
        .solid_rectangle => |rectangle| {
            const bounds = RectI.intersect(rectangle.bounds, clips[depth]);
            if (!scene.occludedByNextDraw(commands[index + 1 ..], clips[0 .. depth + 1], bounds))
                self.presentationFill(target, bounds, rectangle.color, rectangle.blend);
        },
        .decorated_rectangle => |rectangle| self.presentationDecoratedRectangle(
            target,
            RectI.intersect(rectangle.bounds, clips[depth]),
            rectangle,
        ),
        .image => |value| {
            const entry = &images.entries.items[image_index];
            self.drawPresentationImage(target, RectI.intersect(value.bounds, clips[depth]), entry.placement, &images.resources.items[entry.resource_index]);
            image_index += 1;
        },
        .glyph_run => |run| self.drawPresentationGlyphRun(
            run,
            target,
            clips[depth],
            glyphs orelse unreachable,
            shapes orelse unreachable,
        ),
        .paragraph => |paragraph| self.drawPresentationParagraph(
            paragraph,
            target,
            clips[depth],
            glyphs orelse unreachable,
            paragraphs orelse unreachable,
        ),
    };
}

fn presentationFill(
    self: *Renderer,
    target: *const DmabufTarget,
    bounds: RectI,
    color: Color,
    blend: scene.BlendMode,
) void {
    if (bounds.isEmpty()) return;
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, if (target.direct) self.direct_presentation.pipeline else self.presentation_pipeline);
    const source = LinearRgba16.fromColor(color);
    const rectangle: c.VkClearRect = .{
        .rect = .{
            .offset = .{ .x = bounds.x, .y = bounds.y },
            .extent = .{ .width = bounds.width, .height = bounds.height },
        },
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
    if (blend == .source or source.a == 65535) {
        var attachment: c.VkClearAttachment = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .colorAttachment = 0,
            .clearValue = .{ .color = .{ .float32 = normalizedColor(source) } },
        };
        c.vkCmdClearAttachments(target.command_buffer, 1, &attachment, 1, &rectangle);
        return;
    }
    var scissor = rectangle.rect;
    var viewport: c.VkViewport = .{
        .x = @floatFromInt(bounds.x),
        .y = @floatFromInt(bounds.y),
        .width = @floatFromInt(bounds.width),
        .height = @floatFromInt(bounds.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    c.vkCmdSetViewport(target.command_buffer, 0, 1, &viewport);
    c.vkCmdSetScissor(target.command_buffer, 0, 1, &scissor);
    const right = @as(i64, bounds.x) + bounds.width;
    const bottom = @as(i64, bounds.y) + bounds.height;
    const push: PresentationPush = .{
        .background = normalizedColor(source),
        .border = .{ 0, 0, 0, 0 },
        .target_size = .{ @floatFromInt(target.width), @floatFromInt(target.height) },
        .corner_radius = 0,
        .border_width = 0,
        .bounds = .{ bounds.x, bounds.y, @intCast(right), @intCast(bottom) },
        .has_background = 1,
        .has_border = 0,
    };
    c.vkCmdPushConstants(
        target.command_buffer,
        self.presentation_pipeline_layout,
        c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        0,
        @sizeOf(PresentationPush),
        &push,
    );
    c.vkCmdDraw(target.command_buffer, 6, 1, 0, 0);
}

fn presentationDecoratedRectangle(
    self: *Renderer,
    target: *const DmabufTarget,
    clipped_bounds: RectI,
    rectangle: scene.DecoratedRectangle,
) void {
    if (clipped_bounds.isEmpty()) return;
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, if (target.direct) self.direct_presentation.pipeline else self.presentation_pipeline);
    var scissor: c.VkRect2D = .{
        .offset = .{ .x = clipped_bounds.x, .y = clipped_bounds.y },
        .extent = .{ .width = clipped_bounds.width, .height = clipped_bounds.height },
    };
    var viewport: c.VkViewport = .{
        .x = @floatFromInt(clipped_bounds.x),
        .y = @floatFromInt(clipped_bounds.y),
        .width = @floatFromInt(clipped_bounds.width),
        .height = @floatFromInt(clipped_bounds.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    c.vkCmdSetViewport(target.command_buffer, 0, 1, &viewport);
    c.vkCmdSetScissor(target.command_buffer, 0, 1, &scissor);
    const background = if (rectangle.background) |color| LinearRgba16.fromColor(color) else LinearRgba16.transparent;
    const border = if (rectangle.border_color) |color| LinearRgba16.fromColor(color) else LinearRgba16.transparent;
    const right = @as(i64, rectangle.bounds.x) + rectangle.bounds.width;
    const bottom = @as(i64, rectangle.bounds.y) + rectangle.bounds.height;
    var push: PresentationPush = .{
        .background = normalizedColor(background),
        .border = normalizedColor(border),
        .target_size = .{ @floatFromInt(target.width), @floatFromInt(target.height) },
        .corner_radius = @floatFromInt(rectangle.corner_radius),
        .border_width = @floatFromInt(rectangle.border_width),
        .bounds = .{ rectangle.bounds.x, rectangle.bounds.y, @intCast(right), @intCast(bottom) },
        .has_background = @intFromBool(rectangle.background != null),
        .has_border = @intFromBool(rectangle.border_color != null),
    };
    if (rectangle.blend == .source) {
        push.coverage_only = 1;
        c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, if (target.direct) self.direct_presentation.erase_pipeline else self.presentation_erase_pipeline);
        c.vkCmdPushConstants(target.command_buffer, self.presentation_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PresentationPush), &push);
        c.vkCmdDraw(target.command_buffer, 6, 1, 0, 0);
        push.coverage_only = 0;
        c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, if (target.direct) self.direct_presentation.add_pipeline else self.presentation_add_pipeline);
    }
    c.vkCmdPushConstants(
        target.command_buffer,
        self.presentation_pipeline_layout,
        c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
        0,
        @sizeOf(PresentationPush),
        &push,
    );
    c.vkCmdDraw(target.command_buffer, 6, 1, 0, 0);
}

fn validateClipDepth(
    commands: []const scene.Command,
    allow_shapes: bool,
    allow_paragraphs: bool,
) !void {
    var depth: usize = 0;
    for (commands) |command| switch (command) {
        .push_clip_rect => {
            if (depth == max_clip_depth) return error.ClipStackOverflow;
            depth += 1;
        },
        .pop_clip => depth -= 1,
        .glyph_run => if (!allow_shapes) return error.TextResourcesRequired,
        .paragraph => if (!allow_paragraphs) return error.TextResourcesRequired,
        else => {},
    };
}

fn renderRegion(
    self: *Renderer,
    commands: []const scene.Command,
    target: *const Target,
    damage: RectI,
    glyphs: ?*GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
    images: *const ImageUploads,
    descriptor: c.VkDescriptorSet,
) void {
    var clips: [max_clip_depth + 1]RectI = undefined;
    clips[0] = damage;
    var depth: usize = 0;
    var image_index: usize = 0;
    for (commands, 0..) |command, index| switch (command) {
        .clear => |color| if (!scene.occludedByNextDraw(commands[index + 1 ..], clips[0 .. depth + 1], damage))
            self.fill(target, damage, color, .source),
        .push_clip_rect => |clip| {
            depth += 1;
            clips[depth] = RectI.intersect(clips[depth - 1], clip);
        },
        .pop_clip => depth -= 1,
        .solid_rectangle => |rectangle| {
            const bounds = RectI.intersect(rectangle.bounds, clips[depth]);
            if (!scene.occludedByNextDraw(commands[index + 1 ..], clips[0 .. depth + 1], bounds))
                self.fill(target, bounds, rectangle.color, rectangle.blend);
        },
        .decorated_rectangle => |rectangle| self.decoratedRectangle(
            target,
            RectI.intersect(rectangle.bounds, clips[depth]),
            rectangle,
        ),
        .image => |value| {
            const entry = &images.entries.items[image_index];
            self.drawImage(target, RectI.intersect(value.bounds, clips[depth]), entry.placement, &images.resources.items[entry.resource_index]);
            image_index += 1;
            c.vkCmdBindDescriptorSets(self.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &descriptor, 0, null);
        },
        .glyph_run => |run| self.drawGlyphRun(
            run,
            target,
            clips[depth],
            glyphs orelse unreachable,
            shapes orelse unreachable,
        ),
        .paragraph => |paragraph| self.drawParagraph(
            paragraph,
            target,
            clips[depth],
            glyphs orelse unreachable,
            paragraphs orelse unreachable,
        ),
    };
}

fn drawImage(self: *Renderer, target: *const Target, bounds: RectI, placement: ImagePlacement, image: *const ImageUploads.Resource) void {
    if (bounds.isEmpty()) return;
    c.vkCmdBindPipeline(self.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.glyph_pipeline);
    c.vkCmdBindDescriptorSets(self.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &image.descriptor, 0, null);
    const push: GlyphPush = .{
        .target_width = target.width,
        .atlas_width_value = image.pixels.width,
        .source = .{ 0, 0 },
        .left = bounds.x,
        .top = bounds.y,
        .right = @intCast(@as(i64, bounds.x) + bounds.width),
        .bottom = @intCast(@as(i64, bounds.y) + bounds.height),
        .atlas_x = 0,
        .atlas_y = 0,
        .image_mode = 1,
        .image_rows = image.pixels.height,
        .image_left = placement.left,
        .image_top = placement.top,
        .image_width = placement.width,
        .image_height = placement.height,
    };
    c.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(GlyphPush), &push);
    const count = @as(u64, bounds.width) * bounds.height;
    c.vkCmdDispatch(self.command_buffer, @intCast((count + local_size - 1) / local_size), 1, 1);
    var barrier: c.VkMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
    };
    c.vkCmdPipelineBarrier(self.command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);
}

fn drawPresentationImage(self: *Renderer, target: *const DmabufTarget, bounds: RectI, placement: ImagePlacement, image: *const ImageUploads.Resource) void {
    if (bounds.isEmpty()) return;
    var scissor: c.VkRect2D = .{
        .offset = .{ .x = bounds.x, .y = bounds.y },
        .extent = .{ .width = bounds.width, .height = bounds.height },
    };
    var viewport: c.VkViewport = .{
        .x = @floatFromInt(bounds.x),
        .y = @floatFromInt(bounds.y),
        .width = @floatFromInt(bounds.width),
        .height = @floatFromInt(bounds.height),
        .minDepth = 0,
        .maxDepth = 1,
    };
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, if (target.direct) self.direct_presentation.glyph_pipeline else self.presentation_glyph_pipeline);
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.presentation_glyph_pipeline_layout, 0, 1, &image.descriptor, 0, null);
    c.vkCmdSetViewport(target.command_buffer, 0, 1, &viewport);
    c.vkCmdSetScissor(target.command_buffer, 0, 1, &scissor);
    const push: PresentationGlyphPush = .{
        .color = .{ 1, 1, 1, 1 },
        .target_size = .{ @floatFromInt(target.width), @floatFromInt(target.height) },
        .bounds = .{ bounds.x, bounds.y, @intCast(@as(i64, bounds.x) + bounds.width), @intCast(@as(i64, bounds.y) + bounds.height) },
        .atlas_origin = .{ 0, 0 },
        .atlas_width_value = image.pixels.width,
        .image_mode = 1,
        .image_rows = image.pixels.height,
        .image_left = placement.left,
        .image_top = placement.top,
        .image_width = placement.width,
        .image_height = placement.height,
    };
    c.vkCmdPushConstants(target.command_buffer, self.presentation_glyph_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PresentationGlyphPush), &push);
    c.vkCmdDraw(target.command_buffer, 6, 1, 0, 0);
}

fn fill(self: *Renderer, target: *const Target, bounds: RectI, color: Color, blend: scene.BlendMode) void {
    if (bounds.isEmpty()) return;
    c.vkCmdBindPipeline(self.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
    const source = LinearRgba16.fromColor(color);
    const push: Push = .{
        .target_width = target.width,
        .left = bounds.x,
        .top = bounds.y,
        .right = @intCast(@as(i64, bounds.x) + bounds.width),
        .bottom = @intCast(@as(i64, bounds.y) + bounds.height),
        .shape_left = bounds.x,
        .shape_top = bounds.y,
        .shape_right = @intCast(@as(i64, bounds.x) + bounds.width),
        .shape_bottom = @intCast(@as(i64, bounds.y) + bounds.height),
        .background = packedLinear(source),
        .border = .{ 0, 0 },
        .corner_radius = 0,
        .border_width = 0,
        .flags = 1,
        .source_over = @intFromBool(blend == .source_over and source.a != 65535),
    };
    c.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(Push), &push);
    const count = @as(u64, bounds.width) * bounds.height;
    c.vkCmdDispatch(self.command_buffer, @intCast((count + local_size - 1) / local_size), 1, 1);
    var barrier: c.VkMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
    };
    c.vkCmdPipelineBarrier(
        self.command_buffer,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0,
        1,
        &barrier,
        0,
        null,
        0,
        null,
    );
}

fn decoratedRectangle(
    self: *Renderer,
    target: *const Target,
    clipped_bounds: RectI,
    rectangle: scene.DecoratedRectangle,
) void {
    if (clipped_bounds.isEmpty()) return;
    c.vkCmdBindPipeline(self.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
    const background = if (rectangle.background) |color| LinearRgba16.fromColor(color) else LinearRgba16.fromColor(Color.rgba(0, 0, 0, 0));
    const border = if (rectangle.border_color) |color| LinearRgba16.fromColor(color) else LinearRgba16.fromColor(Color.rgba(0, 0, 0, 0));
    const push: Push = .{
        .target_width = target.width,
        .left = clipped_bounds.x,
        .top = clipped_bounds.y,
        .right = @intCast(@as(i64, clipped_bounds.x) + clipped_bounds.width),
        .bottom = @intCast(@as(i64, clipped_bounds.y) + clipped_bounds.height),
        .shape_left = rectangle.bounds.x,
        .shape_top = rectangle.bounds.y,
        .shape_right = @intCast(@as(i64, rectangle.bounds.x) + rectangle.bounds.width),
        .shape_bottom = @intCast(@as(i64, rectangle.bounds.y) + rectangle.bounds.height),
        .background = packedLinear(background),
        .border = packedLinear(border),
        .corner_radius = rectangle.corner_radius,
        .border_width = rectangle.border_width,
        .flags = @as(u32, @intFromBool(rectangle.background != null)) |
            (@as(u32, @intFromBool(rectangle.border_color != null)) << 1),
        .source_over = @intFromBool(rectangle.blend == .source_over),
    };
    c.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(Push), &push);
    const count = @as(u64, clipped_bounds.width) * clipped_bounds.height;
    c.vkCmdDispatch(self.command_buffer, @intCast((count + local_size - 1) / local_size), 1, 1);
    var barrier: c.VkMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
    };
    c.vkCmdPipelineBarrier(
        self.command_buffer,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        0,
        1,
        &barrier,
        0,
        null,
        0,
        null,
    );
}

fn packedLinear(source: LinearRgba16) [2]u32 {
    return .{
        @as(u32, source.r) | (@as(u32, source.g) << 16),
        @as(u32, source.b) | (@as(u32, source.a) << 16),
    };
}

fn normalizedColor(source: LinearRgba16) [4]f32 {
    return .{
        @as(f32, @floatFromInt(source.r)) / 65535,
        @as(f32, @floatFromInt(source.g)) / 65535,
        @as(f32, @floatFromInt(source.b)) / 65535,
        @as(f32, @floatFromInt(source.a)) / 65535,
    };
}

fn prepareText(
    commands: []const scene.Command,
    glyphs: *GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
) !void {
    if (!has_freetype) return error.FreeTypeDisabled;
    prepareTextPass(commands, glyphs, shapes, paragraphs) catch |err| {
        if (err != error.GlyphAtlasFull) return err;
        // Discard old frames' phases and pack just this frame once. A frame
        // exceeding the fixed budget fails before recording/uploading, rather
        // than evicting masks already referenced by this frame's draws.
        try glyphs.reset();
        try prepareTextPass(commands, glyphs, shapes, paragraphs);
    };
}

fn prepareTextPass(
    commands: []const scene.Command,
    glyphs: *GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
) !void {
    for (commands) |command| switch (command) {
        .glyph_run => |run| {
            const shaped = try (shapes orelse return error.TextResourcesRequired).get(run.shape);
            var pen = run.origin;
            for (shaped.spans) |span| {
                for (span.run.glyphs) |glyph| {
                    const position = GlyphPosition.init(pen.x + glyph.offset.x * run.scale, pen.y - glyph.offset.y * run.scale);
                    _ = try glyphs.get(span.font, glyph.id, shaped.logical_size * run.scale, position.phase);
                    pen.x += glyph.advance.x * run.scale;
                    pen.y -= glyph.advance.y * run.scale;
                }
            }
        },
        .paragraph => |value| {
            const layout = try (paragraphs orelse return error.TextResourcesRequired).get(value.layout);
            for (layout.positioned.lines) |line| {
                const baseline = value.origin.y + (line.top + line.baseline) * value.scale;
                for (layout.positioned.spansFor(line)) |span| for (layout.positioned.glyphsFor(span)) |glyph| {
                    const position = GlyphPosition.init(value.origin.x + (line.left + glyph.origin.x) * value.scale, baseline + glyph.origin.y * value.scale);
                    _ = try glyphs.get(span.font, glyph.id, layout.logical_size * value.scale, position.phase);
                };
            }
        },
        else => {},
    };
}

fn drawGlyphRun(
    self: *Renderer,
    command: scene.GlyphRun,
    target: *const Target,
    clip: RectI,
    cache: *GlyphCache,
    shapes: *const text.ShapeCache,
) void {
    if (!has_freetype) unreachable;
    const shaped = shapes.get(command.shape) catch unreachable;
    const source = packedLinear(LinearRgba16.fromColor(command.color));
    var pen = command.origin;
    for (shaped.spans) |span| for (span.run.glyphs) |glyph| {
        const position = GlyphPosition.init(pen.x + glyph.offset.x * command.scale, pen.y - glyph.offset.y * command.scale);
        const atlas = cache.prepared(span.font, glyph.id, shaped.logical_size * command.scale, position.phase);
        const glyph_bounds: RectI = .{
            .x = position.x + atlas.left,
            .y = position.y - atlas.top,
            .width = atlas.width,
            .height = atlas.height,
        };
        const bounds = RectI.intersect(clip, glyph_bounds);
        if (!bounds.isEmpty()) {
            c.vkCmdBindPipeline(self.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.glyph_pipeline);
            const push: GlyphPush = .{
                .target_width = target.width,
                .atlas_width_value = atlas_width,
                .source = source,
                .left = bounds.x,
                .top = bounds.y,
                .right = @intCast(@as(i64, bounds.x) + bounds.width),
                .bottom = @intCast(@as(i64, bounds.y) + bounds.height),
                .atlas_x = atlas.x + @as(u32, @intCast(bounds.x - glyph_bounds.x)) * @as(u32, if (atlas.color) 8 else 1),
                .atlas_y = atlas.y + @as(u32, @intCast(bounds.y - glyph_bounds.y)),
                .image_mode = if (atlas.color) 2 else 0,
            };
            c.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(GlyphPush), &push);
            const count = @as(u64, bounds.width) * bounds.height;
            c.vkCmdDispatch(self.command_buffer, @intCast((count + local_size - 1) / local_size), 1, 1);
            var barrier: c.VkMemoryBarrier = .{
                .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                .pNext = null,
                .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
                .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
            };
            c.vkCmdPipelineBarrier(self.command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);
        }
        pen.x += glyph.advance.x * command.scale;
        pen.y -= glyph.advance.y * command.scale;
    };
}

fn drawPresentationGlyphRun(
    self: *Renderer,
    command: scene.GlyphRun,
    target: *const DmabufTarget,
    clip: RectI,
    cache: *GlyphCache,
    shapes: *const text.ShapeCache,
) void {
    if (!has_freetype) unreachable;
    const shaped = shapes.get(command.shape) catch unreachable;
    const color = LinearRgba16.fromColor(command.color);
    var pen = command.origin;
    for (shaped.spans) |span| for (span.run.glyphs) |glyph| {
        const position = GlyphPosition.init(pen.x + glyph.offset.x * command.scale, pen.y - glyph.offset.y * command.scale);
        const atlas = cache.prepared(span.font, glyph.id, shaped.logical_size * command.scale, position.phase);
        const glyph_bounds: RectI = .{
            .x = position.x + atlas.left,
            .y = position.y - atlas.top,
            .width = atlas.width,
            .height = atlas.height,
        };
        const bounds = RectI.intersect(clip, glyph_bounds);
        if (!bounds.isEmpty()) {
            var scissor: c.VkRect2D = .{
                .offset = .{ .x = bounds.x, .y = bounds.y },
                .extent = .{ .width = bounds.width, .height = bounds.height },
            };
            c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, if (target.direct) self.direct_presentation.glyph_pipeline else self.presentation_glyph_pipeline);
            c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.presentation_glyph_pipeline_layout, 0, 1, &cache.descriptor_set, 0, null);
            var viewport: c.VkViewport = .{
                .x = @floatFromInt(bounds.x),
                .y = @floatFromInt(bounds.y),
                .width = @floatFromInt(bounds.width),
                .height = @floatFromInt(bounds.height),
                .minDepth = 0,
                .maxDepth = 1,
            };
            c.vkCmdSetViewport(target.command_buffer, 0, 1, &viewport);
            c.vkCmdSetScissor(target.command_buffer, 0, 1, &scissor);
            const push: PresentationGlyphPush = .{
                .color = normalizedColor(color),
                .target_size = .{ @floatFromInt(target.width), @floatFromInt(target.height) },
                .bounds = .{
                    glyph_bounds.x,
                    glyph_bounds.y,
                    @intCast(@as(i64, glyph_bounds.x) + glyph_bounds.width),
                    @intCast(@as(i64, glyph_bounds.y) + glyph_bounds.height),
                },
                .atlas_origin = .{ atlas.x, atlas.y },
                .atlas_width_value = atlas_width,
                .image_mode = if (atlas.color) 2 else 0,
            };
            c.vkCmdPushConstants(target.command_buffer, self.presentation_glyph_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PresentationGlyphPush), &push);
            c.vkCmdDraw(target.command_buffer, 6, 1, 0, 0);
        }
        pen.x += glyph.advance.x * command.scale;
        pen.y -= glyph.advance.y * command.scale;
    };
}

fn drawPresentationParagraph(
    self: *Renderer,
    command: scene.Paragraph,
    target: *const DmabufTarget,
    clip: RectI,
    cache: *GlyphCache,
    paragraphs: *const text.ParagraphCache,
) void {
    if (!has_freetype) unreachable;
    const layout = paragraphs.get(command.layout) catch unreachable;
    const color = LinearRgba16.fromColor(command.color);
    for (layout.positioned.lines) |line| {
        const baseline = command.origin.y + (line.top + line.baseline) * command.scale;
        for (layout.positioned.spansFor(line)) |span| for (layout.positioned.glyphsFor(span)) |glyph| {
            const position = GlyphPosition.init(command.origin.x + (line.left + glyph.origin.x) * command.scale, baseline + glyph.origin.y * command.scale);
            const atlas = cache.prepared(span.font, glyph.id, layout.logical_size * command.scale, position.phase);
            const glyph_bounds: RectI = .{
                .x = position.x + atlas.left,
                .y = position.y - atlas.top,
                .width = atlas.width,
                .height = atlas.height,
            };
            const bounds = RectI.intersect(clip, glyph_bounds);
            if (!bounds.isEmpty()) {
                var scissor: c.VkRect2D = .{
                    .offset = .{ .x = bounds.x, .y = bounds.y },
                    .extent = .{ .width = bounds.width, .height = bounds.height },
                };
                c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, if (target.direct) self.direct_presentation.glyph_pipeline else self.presentation_glyph_pipeline);
                c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.presentation_glyph_pipeline_layout, 0, 1, &cache.descriptor_set, 0, null);
                var viewport: c.VkViewport = .{
                    .x = @floatFromInt(bounds.x),
                    .y = @floatFromInt(bounds.y),
                    .width = @floatFromInt(bounds.width),
                    .height = @floatFromInt(bounds.height),
                    .minDepth = 0,
                    .maxDepth = 1,
                };
                c.vkCmdSetViewport(target.command_buffer, 0, 1, &viewport);
                c.vkCmdSetScissor(target.command_buffer, 0, 1, &scissor);
                const push: PresentationGlyphPush = .{
                    .color = normalizedColor(color),
                    .target_size = .{ @floatFromInt(target.width), @floatFromInt(target.height) },
                    .bounds = .{
                        glyph_bounds.x,
                        glyph_bounds.y,
                        @intCast(@as(i64, glyph_bounds.x) + glyph_bounds.width),
                        @intCast(@as(i64, glyph_bounds.y) + glyph_bounds.height),
                    },
                    .atlas_origin = .{ atlas.x, atlas.y },
                    .atlas_width_value = atlas_width,
                    .image_mode = if (atlas.color) 2 else 0,
                };
                c.vkCmdPushConstants(target.command_buffer, self.presentation_glyph_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PresentationGlyphPush), &push);
                c.vkCmdDraw(target.command_buffer, 6, 1, 0, 0);
            }
        };
    }
}

fn findMemoryType(self: *const Renderer, bits: u32, required: c.VkMemoryPropertyFlags) ?u32 {
    for (0..self.memory_properties.memoryTypeCount) |index| {
        const shift: u5 = @intCast(index);
        if (bits & (@as(u32, 1) << shift) != 0 and
            self.memory_properties.memoryTypes[index].propertyFlags & required == required)
            return @intCast(index);
    }
    return null;
}

const DeviceSelection = struct {
    physical_device: c.VkPhysicalDevice,
    queue_family: u32,
};

fn chooseDevice(allocator: std.mem.Allocator, instance: c.VkInstance) !DeviceSelection {
    var device_count: u32 = 0;
    try vk(c.vkEnumeratePhysicalDevices(instance, &device_count, null), error.EnumerateDevicesFailed);
    if (device_count == 0) return error.VulkanUnavailable;
    const devices = try allocator.alloc(c.VkPhysicalDevice, device_count);
    defer allocator.free(devices);
    try vk(c.vkEnumeratePhysicalDevices(instance, &device_count, devices.ptr), error.EnumerateDevicesFailed);
    for (devices[0..device_count]) |physical_device| {
        var properties: c.VkPhysicalDeviceProperties = undefined;
        c.vkGetPhysicalDeviceProperties(physical_device, &properties);
        if (properties.apiVersion < c.VK_API_VERSION_1_2) continue;
        var queue_count: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, null);
        const queues = try allocator.alloc(c.VkQueueFamilyProperties, queue_count);
        defer allocator.free(queues);
        c.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, queues.ptr);
        for (queues[0..queue_count], 0..) |queue, index| {
            if (queue.queueCount > 0 and
                queue.queueFlags & (c.VK_QUEUE_COMPUTE_BIT | c.VK_QUEUE_GRAPHICS_BIT) ==
                    (c.VK_QUEUE_COMPUTE_BIT | c.VK_QUEUE_GRAPHICS_BIT)) return .{
                .physical_device = physical_device,
                .queue_family = @intCast(index),
            };
        }
    }
    return error.GraphicsComputeQueueUnavailable;
}

fn supportsDeviceExtensions(
    allocator: std.mem.Allocator,
    physical_device: c.VkPhysicalDevice,
    required: []const [*:0]const u8,
) !bool {
    var count: u32 = 0;
    try vk(c.vkEnumerateDeviceExtensionProperties(physical_device, null, &count, null), error.EnumerateExtensionsFailed);
    const properties = try allocator.alloc(c.VkExtensionProperties, count);
    defer allocator.free(properties);
    try vk(
        c.vkEnumerateDeviceExtensionProperties(physical_device, null, &count, properties.ptr),
        error.EnumerateExtensionsFailed,
    );
    for (required) |name| {
        for (properties[0..count]) |property| {
            if (std.mem.eql(u8, std.mem.span(name), std.mem.sliceTo(&property.extensionName, 0))) break;
        } else return false;
    }
    return true;
}

fn linuxDevice(major: u64, minor: u64) u64 {
    return (minor & 0xff) | ((major & 0xfff) << 8) |
        ((minor & ~@as(u64, 0xff)) << 12) | ((major & ~@as(u64, 0xfff)) << 32);
}

fn supportsDmabufModifierOnDevice(physical_device: c.VkPhysicalDevice, modifier: u64, format: c.VkFormat) bool {
    var format_properties: c.VkFormatProperties2 = .{
        .sType = c.VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2,
        .pNext = null,
        .formatProperties = undefined,
    };
    var modifier_list: c.VkDrmFormatModifierPropertiesListEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT,
        .pNext = null,
        .drmFormatModifierCount = 0,
        .pDrmFormatModifierProperties = null,
    };
    format_properties.pNext = &modifier_list;
    c.vkGetPhysicalDeviceFormatProperties2(physical_device, format, &format_properties);
    if (modifier_list.drmFormatModifierCount == 0 or modifier_list.drmFormatModifierCount > 256) return false;
    var modifiers: [256]c.VkDrmFormatModifierPropertiesEXT = undefined;
    modifier_list.pDrmFormatModifierProperties = &modifiers;
    c.vkGetPhysicalDeviceFormatProperties2(physical_device, format, &format_properties);
    for (modifiers[0..modifier_list.drmFormatModifierCount]) |entry| {
        if (entry.drmFormatModifier != modifier) continue;
        const required = c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT;
        if (entry.drmFormatModifierTilingFeatures & required != required) return false;
        break;
    } else return false;

    var modifier_info: c.VkPhysicalDeviceImageDrmFormatModifierInfoEXT = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_DRM_FORMAT_MODIFIER_INFO_EXT,
        .pNext = null,
        .drmFormatModifier = modifier,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = null,
    };
    var external_info: c.VkPhysicalDeviceExternalImageFormatInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO,
        .pNext = &modifier_info,
        .handleType = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT,
    };
    var format_info: c.VkPhysicalDeviceImageFormatInfo2 = .{
        .sType = c.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2,
        .pNext = &external_info,
        .format = format,
        .type = c.VK_IMAGE_TYPE_2D,
        .tiling = c.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
        .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .flags = 0,
    };
    var external_properties: c.VkExternalImageFormatProperties = .{
        .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES,
        .pNext = null,
        .externalMemoryProperties = undefined,
    };
    var properties: c.VkImageFormatProperties2 = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2,
        .pNext = &external_properties,
        .imageFormatProperties = undefined,
    };
    if (c.vkGetPhysicalDeviceImageFormatProperties2(physical_device, &format_info, &properties) != c.VK_SUCCESS)
        return false;
    const external = external_properties.externalMemoryProperties;
    return external.externalMemoryFeatures & c.VK_EXTERNAL_MEMORY_FEATURE_EXPORTABLE_BIT != 0 and
        external.compatibleHandleTypes & c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT != 0;
}

fn vk(result: c.VkResult, failure: anyerror) !void {
    if (result != c.VK_SUCCESS) return failure;
}

test "Vulkan lowering bounds its clip stack" {
    var commands: [2 * (max_clip_depth + 1)]scene.Command = undefined;
    for (0..max_clip_depth + 1) |index| {
        commands[index] = .{ .push_clip_rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 } };
        commands[commands.len - index - 1] = .pop_clip;
    }
    try (scene.DisplayList{ .commands = &commands }).validate();
    try std.testing.expectError(error.ClipStackOverflow, validateClipDepth(&commands, false, false));
}

test "Vulkan backend renders exact conformance fixtures" {
    const conformance = @import("../conformance.zig");
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    for (conformance.fixtures) |fixture| {
        var target = try Target.init(&renderer, fixture.width, fixture.height);
        defer target.deinit(&renderer);
        try renderer.render(.{ .commands = fixture.commands }, &target);
        const pixels = try std.testing.allocator.alloc(u8, fixture.expected_rgba.len);
        defer std.testing.allocator.free(pixels);
        try target.readPixels(pixels, fixture.width * 4, .rgba8_unorm);
        std.testing.expectEqualSlices(u8, fixture.expected_rgba, pixels) catch |err| {
            std.debug.print("Vulkan conformance fixture failed: {s}\n", .{fixture.name});
            return err;
        };
    }
}

fn drawParagraph(
    self: *Renderer,
    command: scene.Paragraph,
    target: *const Target,
    clip: RectI,
    cache: *GlyphCache,
    paragraphs: *const text.ParagraphCache,
) void {
    if (!has_freetype) unreachable;
    const layout = paragraphs.get(command.layout) catch unreachable;
    const source = packedLinear(LinearRgba16.fromColor(command.color));
    for (layout.positioned.lines) |line| {
        const baseline = command.origin.y + (line.top + line.baseline) * command.scale;
        for (layout.positioned.spansFor(line)) |span| for (layout.positioned.glyphsFor(span)) |glyph| {
            const position = GlyphPosition.init(command.origin.x + (line.left + glyph.origin.x) * command.scale, baseline + glyph.origin.y * command.scale);
            const atlas = cache.prepared(span.font, glyph.id, layout.logical_size * command.scale, position.phase);
            const glyph_bounds: RectI = .{
                .x = position.x + atlas.left,
                .y = position.y - atlas.top,
                .width = atlas.width,
                .height = atlas.height,
            };
            const bounds = RectI.intersect(clip, glyph_bounds);
            if (!bounds.isEmpty()) {
                c.vkCmdBindPipeline(self.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.glyph_pipeline);
                const push: GlyphPush = .{
                    .target_width = target.width,
                    .atlas_width_value = atlas_width,
                    .source = source,
                    .left = bounds.x,
                    .top = bounds.y,
                    .right = @intCast(@as(i64, bounds.x) + bounds.width),
                    .bottom = @intCast(@as(i64, bounds.y) + bounds.height),
                    .atlas_x = atlas.x + @as(u32, @intCast(bounds.x - glyph_bounds.x)) * @as(u32, if (atlas.color) 8 else 1),
                    .atlas_y = atlas.y + @as(u32, @intCast(bounds.y - glyph_bounds.y)),
                    .image_mode = if (atlas.color) 2 else 0,
                };
                c.vkCmdPushConstants(self.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(GlyphPush), &push);
                const count = @as(u64, bounds.width) * bounds.height;
                c.vkCmdDispatch(self.command_buffer, @intCast((count + local_size - 1) / local_size), 1, 1);
                var barrier: c.VkMemoryBarrier = .{
                    .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                    .pNext = null,
                    .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
                    .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
                };
                c.vkCmdPipelineBarrier(self.command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);
            }
        };
    }
}

test "Vulkan glyph atlas matches exact software text rendering" {
    if (comptime !has_freetype) return error.SkipZigTest;
    const software = @import("../software/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try text.bundled.acquire(&fonts, .sans, .regular, .italic);
    const emoji = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/EmojiTest.ttf", .index = 0 },
        .bytes = @embedFile("../../text/fonts/EmojiTest.ttf"),
    });
    defer fonts.release(emoji) catch unreachable;
    var shapes = text.ShapeCache.init(std.testing.allocator, &fonts);
    defer shapes.deinit();
    const shape = try shapes.acquire(.{
        .spec = .{
            .paragraph = "🚀 Wa\u{0301}\u{0323} 👋 x\u{0302} atlas",
            .direction = .left_to_right,
            .script = .latin,
            .language = "en",
            .logical_size = 18.25,
        },
        .candidates = &.{ font, emoji },
        .configuration_revision = 1,
    });
    defer shapes.release(shape) catch unreachable;
    try fonts.release(font);
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(240, 240, 240, 255) },
        .{ .push_clip_rect = .{ .x = 8, .y = 3, .width = 140, .height = 30 } },
        .{ .glyph_run = .{
            .shape = shape,
            .origin = .{ .x = -2.296875, .y = 25.203125 },
            .scale = 1.5,
            .color = Color.rgba(20, 40, 80, 211),
        } },
        .pop_clip,
    };
    const list: scene.DisplayList = .{ .commands = &commands };
    var expected = [_]u8{0} ** (160 * 36 * 4);
    var software_glyphs = try software.GlyphCache.init(std.testing.allocator, &fonts);
    defer software_glyphs.deinit();
    try software.renderText(list, .{
        .pixels = &expected,
        .width = 160,
        .height = 36,
        .stride = 160 * 4,
        .format = .rgba8_unorm,
    }, &software_glyphs, &shapes);

    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var glyphs = try GlyphCache.init(std.testing.allocator, &fonts, &renderer);
    defer glyphs.deinit();
    var target = try Target.init(&renderer, 160, 36);
    defer target.deinit(&renderer);
    // Simulate a cache filled by previous frames, including a stale phase.
    _ = try glyphs.get(font, (try fonts.get(font)).nominalGlyph('W').?, 18.25, .{});
    glyphs.next_x = atlas_width;
    glyphs.next_y = atlas_height;
    glyphs.row_height = 0;
    try renderer.renderText(list, &target, &glyphs, &shapes);
    try std.testing.expect(glyphs.next_y < atlas_height);
    const count = glyphs.entries.count();
    try prepareText(list.commands, &glyphs, &shapes, null);
    try std.testing.expectEqual(count, glyphs.entries.count());
    try std.testing.expectEqual(@as(usize, atlas_bytes), glyphs.dirty_start);
    var actual = [_]u8{0} ** expected.len;
    try target.readPixels(&actual, 160 * 4, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    var graphics = try GraphicsReadback.init(&renderer, 160, 36);
    defer graphics.deinit(&renderer);
    var next_graphics = try GraphicsReadback.initWithLinear(&renderer, 160, 36, graphics.target.linear);
    defer next_graphics.deinit(&renderer);
    _ = try glyphs.get(font, (try fonts.get(font)).nominalGlyph('Q').?, 19.75, .{});
    try renderer.renderGraphicsResources(list, &graphics.target, &glyphs, &shapes, null, null, false);
    // Append a glyph while the previous upload/draw can still be in flight.
    // Synchronization validation checks overlapping row-span upload hazards.
    _ = try glyphs.get(font, (try fonts.get(font)).nominalGlyph('Z').?, 19.75, .{});
    try renderer.renderGraphicsResources(list, &next_graphics.target, &glyphs, &shapes, null, null, false);
    try graphics.target.wait(&renderer);
    try next_graphics.target.wait(&renderer);
    for (0..36) |y| for (0..160) |x| {
        try graphics.expectPixel(x, y, expected[(y * 160 + x) * 4 ..][0..4].*);
        try next_graphics.expectPixel(x, y, expected[(y * 160 + x) * 4 ..][0..4].*);
    };
    var direct_graphics = try GraphicsReadback.initMode(&renderer, 160, 36, null, true);
    defer direct_graphics.deinit(&renderer);
    try renderer.renderGraphicsResources(list, &direct_graphics.target, &glyphs, &shapes, null, null, false);
    try direct_graphics.target.wait(&renderer);
    for (0..36) |y| for (0..160) |x| {
        try direct_graphics.expectPixel(x, y, expected[(y * 160 + x) * 4 ..][0..4].*);
    };
    var oversized = commands;
    oversized[2].glyph_run.scale = 20;
    try std.testing.expectError(error.GlyphAtlasFull, renderer.renderText(.{ .commands = &oversized }, &target, &glyphs, &shapes));
    try target.readPixels(&actual, 160 * 4, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    try renderer.renderText(list, &target, &glyphs, &shapes);
    try target.readPixels(&actual, 160 * 4, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "Vulkan positioned paragraphs match exact software text rendering" {
    if (comptime !has_freetype) return error.SkipZigTest;
    const software = @import("../software/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const latin = try text.bundled.acquire(&fonts, .serif, .regular, .roman);
    const arabic = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/NotoSansArabic.ttf", .index = 0 },
        .bytes = @embedFile("ourokit_arabic_test_font"),
    });
    const emoji = try fonts.acquire(.{
        .key = .{ .file = "/fixtures/EmojiTest.ttf", .index = 0 },
        .bytes = @embedFile("../../text/fonts/EmojiTest.ttf"),
    });
    defer fonts.release(emoji) catch unreachable;
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const layout = try paragraphs.acquire(.{
        .utf8 = "🚀 Save حفظ a\u{0301}\u{0323} 👋 now and continue",
        .language = "und",
        .logical_size = 14.25,
        .max_width = 86,
        .candidates = &.{ latin, arabic, emoji },
        .configuration_revision = 1,
    });
    defer paragraphs.release(layout) catch unreachable;
    try fonts.release(latin);
    try fonts.release(arabic);
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(0, 0, 0, 0) },
        .{ .push_clip_rect = .{ .x = 8, .y = 3, .width = 130, .height = 66 } },
        .{ .paragraph = .{
            .layout = layout,
            .origin = .{ .x = -1.203125, .y = -2.296875 },
            .scale = 1.5,
            .color = Color.rgba(20, 40, 80, 211),
        } },
        .pop_clip,
    };
    const list: scene.DisplayList = .{ .commands = &commands };
    var expected = [_]u8{0} ** (160 * 72 * 4);
    var software_glyphs = try software.GlyphCache.init(std.testing.allocator, &fonts);
    defer software_glyphs.deinit();
    try software.renderParagraphs(list, .{
        .pixels = &expected,
        .width = 160,
        .height = 72,
        .stride = 160 * 4,
        .format = .rgba8_unorm,
    }, &software_glyphs, &paragraphs);

    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var glyphs = try GlyphCache.init(std.testing.allocator, &fonts, &renderer);
    defer glyphs.deinit();
    var target = try Target.init(&renderer, 160, 72);
    defer target.deinit(&renderer);
    try renderer.renderParagraphs(list, &target, &glyphs, &paragraphs);
    var actual = [_]u8{0} ** expected.len;
    try target.readPixels(&actual, 160 * 4, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    var graphics = try GraphicsReadback.init(&renderer, 160, 72);
    defer graphics.deinit(&renderer);
    try renderer.renderGraphicsResources(list, &graphics.target, &glyphs, null, &paragraphs, null, false);
    try graphics.target.wait(&renderer);
    for (0..72) |y| for (0..160) |x| {
        try graphics.expectPixel(x, y, expected[(y * 160 + x) * 4 ..][0..4].*);
    };
    // Direct presentation requires an opaque scene; exercise a dark background
    // as well as the transparent offscreen path above.
    var opaque_commands = commands;
    opaque_commands[0] = .{ .clear = Color.rgba(20, 30, 40, 255) };
    const opaque_list: scene.DisplayList = .{ .commands = &opaque_commands };
    try software.renderParagraphs(opaque_list, .{
        .pixels = &expected,
        .width = 160,
        .height = 72,
        .stride = 160 * 4,
        .format = .rgba8_unorm,
    }, &software_glyphs, &paragraphs);
    var direct = try GraphicsReadback.initMode(&renderer, 160, 72, null, true);
    defer direct.deinit(&renderer);
    try renderer.renderGraphicsResources(opaque_list, &direct.target, &glyphs, null, &paragraphs, null, false);
    try direct.target.wait(&renderer);
    for (0..72) |y| for (0..160) |x| {
        try direct.expectPixel(x, y, expected[(y * 160 + x) * 4 ..][0..4].*);
    };
}

test "Vulkan clipping, damage, and BGRA readback preserve untouched pixels" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var target = try Target.init(&renderer, 3, 2);
    defer target.deinit(&renderer);
    @memset(@as([*]u8, @ptrCast(target.mapping))[0..target.byte_size], 0xaa);
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(1, 2, 3, 255) },
        .{ .push_clip_rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 } },
        .{ .solid_rectangle = .{
            .bounds = .{ .x = 1, .y = 0, .width = 2, .height = 1 },
            .color = Color.rgba(20, 40, 60, 255),
        } },
        .pop_clip,
    };
    try renderer.render(.{
        .commands = &commands,
        .damage = .{ .regions = &.{.{ .x = 1, .y = 0, .width = 2, .height = 1 }} },
    }, &target);
    var pixels = [_]u8{0xcc} ** 28;
    try target.readPixels(&pixels, 14, .bgra8_unorm);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xaa, 0xaa, 0xaa, 60, 40, 20, 255, 3, 2, 1, 255 }, pixels[0..12]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xaa} ** 12), pixels[14..26]);
    try std.testing.expectEqualSlices(u8, &.{ 0xcc, 0xcc }, pixels[12..14]);
    try std.testing.expectEqualSlices(u8, &.{ 0xcc, 0xcc }, pixels[26..28]);
}

test "Vulkan renders and exports a linear dma-buf image and syncobj timeline" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    if (!renderer.dmabuf_enabled) return error.SkipZigTest;
    var target = try DmabufTarget.init(&renderer, 2, 1, 0);
    defer target.deinit(&renderer);
    const sync_fd = try target.exportSyncobjFd(&renderer);
    defer _ = std.os.linux.close(sync_fd);
    try renderer.renderDmabuf(.{ .commands = &.{
        .{ .clear = Color.rgba(1, 2, 3, 255) },
        .{ .solid_rectangle = .{
            .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
            .color = Color.rgba(200, 100, 50, 128),
        } },
    } }, &target);
    try target.wait(&renderer);
    try std.testing.expectEqual(@as(u64, 1), target.syncPoints().acquire);
    try std.testing.expectEqual(@as(u64, 2), target.syncPoints().release);
    const fd = try target.exportFd(&renderer);
    defer _ = std.os.linux.close(fd);
    try std.testing.expect(target.planes[0].stride >= 8);
}

test "graphics image sampling matches software and upload copies outlive source cache" {
    const software = @import("../software/root.zig");
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    // A host-visible linear color attachment exercises the dma-buf graphics
    // pipeline even on drivers without external-memory export support.
    var format_properties: c.VkFormatProperties = undefined;
    c.vkGetPhysicalDeviceFormatProperties(renderer.physical_device, c.VK_FORMAT_B8G8R8A8_UNORM, &format_properties);
    if (format_properties.linearTilingFeatures & c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT == 0) return error.SkipZigTest;
    var image_info: c.VkImageCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = c.VK_IMAGE_TYPE_2D,
        .format = c.VK_FORMAT_B8G8R8A8_UNORM,
        .extent = .{ .width = 32, .height = 12, .depth = 1 },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .tiling = c.VK_IMAGE_TILING_LINEAR,
        .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
    };
    var image: c.VkImage = undefined;
    try vk(c.vkCreateImage(renderer.device, &image_info, null, &image), error.CreateImageFailed);
    defer c.vkDestroyImage(renderer.device, image, null);
    var requirements: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(renderer.device, image, &requirements);
    const memory_type = renderer.findMemoryType(requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return error.SkipZigTest;
    var allocate: c.VkMemoryAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = requirements.size, .memoryTypeIndex = memory_type };
    var memory: c.VkDeviceMemory = undefined;
    try vk(c.vkAllocateMemory(renderer.device, &allocate, null, &memory), error.AllocateMemoryFailed);
    defer c.vkFreeMemory(renderer.device, memory, null);
    try vk(c.vkBindImageMemory(renderer.device, image, memory, 0), error.BindMemoryFailed);
    var mapping: ?*anyopaque = null;
    try vk(c.vkMapMemory(renderer.device, memory, 0, requirements.size, 0, &mapping), error.MapMemoryFailed);
    defer c.vkUnmapMemory(renderer.device, memory);
    const range: c.VkImageSubresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
    var view_info: c.VkImageViewCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = c.VK_FORMAT_B8G8R8A8_UNORM,
        .subresourceRange = range,
    };
    var view: c.VkImageView = undefined;
    try vk(c.vkCreateImageView(renderer.device, &view_info, null, &view), error.CreateImageViewFailed);
    defer c.vkDestroyImageView(renderer.device, view, null);
    const linear = try LinearAttachment.init(&renderer, 32, 12);
    defer linear.deinit(&renderer);
    var attachments = [_]c.VkImageView{ linear.view, view };
    var framebuffer_info: c.VkFramebufferCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .renderPass = renderer.presentation_render_pass,
        .attachmentCount = attachments.len,
        .pAttachments = &attachments,
        .width = 32,
        .height = 12,
        .layers = 1,
    };
    var framebuffer: c.VkFramebuffer = undefined;
    try vk(c.vkCreateFramebuffer(renderer.device, &framebuffer_info, null, &framebuffer), error.CreateFramebufferFailed);
    defer c.vkDestroyFramebuffer(renderer.device, framebuffer, null);
    var cache = try ImageCache.init(std.testing.allocator, 1);
    defer cache.deinit();
    const handle = try @import("../image_test.zig").insertFixture(&cache);
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(20, 40, 60, 255) },
        .{ .image = .{ .image = handle, .bounds = .{ .x = 1, .y = 1, .width = 8, .height = 9 }, .fit = .contain } },
        .{ .push_clip_rect = .{ .x = 12, .y = 2, .width = 7, .height = 8 } },
        .{ .image = .{ .image = handle, .bounds = .{ .x = 11, .y = 1, .width = 8, .height = 9 }, .fit = .cover } },
        .pop_clip,
        .{ .image = .{ .image = handle, .bounds = .{ .x = 21, .y = 1, .width = 8, .height = 9 }, .fit = .fill } },
        .{ .image = .{ .image = handle, .bounds = .{ .x = 27, .y = 9, .width = 2, .height = 1 }, .fit = .fill } },
    };
    var expected: [32 * 12 * 4]u8 = undefined;
    try software.renderResources(.{ .commands = &commands }, .{ .pixels = &expected, .width = 32, .height = 12, .stride = 128, .format = .bgra8_unorm }, null, null, null, &cache);
    var direct = try GraphicsReadback.initMode(&renderer, 32, 12, null, true);
    defer direct.deinit(&renderer);
    try renderer.renderGraphicsResources(.{ .commands = &commands }, &direct.target, null, null, null, &cache, false);
    try direct.target.wait(&renderer);
    for (0..12) |y| for (0..32) |x| {
        const p = expected[(y * 32 + x) * 4 ..][0..4];
        try direct.expectPixel(x, y, .{ p[2], p[1], p[0], p[3] });
    };
    var uploads = try ImageUploads.init(&renderer, &commands, &cache, null);
    defer uploads.deinit(&renderer);
    try std.testing.expectEqual(@as(usize, 4), uploads.entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), uploads.resources.items.len);
    try std.testing.expectEqual(@as(u64, 24), uploads.byte_size);
    try std.testing.expectEqual(@as(f32, 1), uploads.entries.items[0].placement.left);
    try std.testing.expectEqual(@as(f32, 21), uploads.entries.items[2].placement.left);
    for (uploads.entries.items) |entry| try std.testing.expectEqual(@as(usize, 0), entry.resource_index);
    try cache.release(handle);
    try std.testing.expectError(error.StaleImageHandle, cache.get(handle));
    // Only the graphics target and command buffer fields are consumed here.
    const target: DmabufTarget = .{
        .image = image,
        .memory = memory,
        .view = view,
        .framebuffer = framebuffer,
        .linear = linear,
        .command_pool = renderer.command_pool,
        .command_buffer = renderer.command_buffer,
        .fence = renderer.fence,
        .timeline = null,
        .width = 32,
        .height = 12,
        .modifier = 0,
        .planes = undefined,
        .plane_count = 0,
    };
    try vk(c.vkResetCommandPool(renderer.device, renderer.command_pool, 0), error.ResetCommandPoolFailed);
    var begin: c.VkCommandBufferBeginInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    try vk(c.vkBeginCommandBuffer(renderer.command_buffer, &begin), error.BeginCommandBufferFailed);
    linear.initialize(renderer.command_buffer);
    var barrier: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = range,
    };
    c.vkCmdPipelineBarrier(renderer.command_buffer, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, null, 0, null, 1, &barrier);
    var pass: c.VkRenderPassBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = renderer.presentation_render_pass,
        .framebuffer = framebuffer,
        .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 32, .height = 12 } },
    };
    c.vkCmdBeginRenderPass(renderer.command_buffer, &pass, c.VK_SUBPASS_CONTENTS_INLINE);
    renderer.renderPresentationRegion(&commands, &target, .{ .x = 0, .y = 0, .width = 32, .height = 12 }, null, null, null, &uploads);
    renderer.convertPresentation(&target);
    c.vkCmdEndRenderPass(renderer.command_buffer);
    barrier.srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_HOST_READ_BIT;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_GENERAL;
    c.vkCmdPipelineBarrier(renderer.command_buffer, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, c.VK_PIPELINE_STAGE_HOST_BIT, 0, 0, null, 0, null, 1, &barrier);
    try vk(c.vkEndCommandBuffer(renderer.command_buffer), error.EndCommandBufferFailed);
    var submit: c.VkSubmitInfo = .{ .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &renderer.command_buffer };
    try vk(c.vkResetFences(renderer.device, 1, &renderer.fence), error.ResetFenceFailed);
    try vk(c.vkQueueSubmit(renderer.queue, 1, &submit, renderer.fence), error.QueueSubmitFailed);
    try vk(c.vkWaitForFences(renderer.device, 1, &renderer.fence, c.VK_TRUE, std.math.maxInt(u64)), error.DeviceLost);
    var subresource: c.VkImageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .arrayLayer = 0 };
    var layout: c.VkSubresourceLayout = undefined;
    c.vkGetImageSubresourceLayout(renderer.device, image, &subresource, &layout);
    const bytes: [*]const u8 = @ptrCast(mapping.?);
    for (0..12) |y| for (0..128) |x| {
        const actual = bytes[layout.offset + y * layout.rowPitch + x];
        // FP16 working storage and final UNORM conversion can differ by one.
        try std.testing.expect(@abs(@as(i16, actual) - @as(i16, expected[y * 128 + x])) <= 1);
    };
}

/// Host-visible export substitute, with the same private working attachment
/// and per-slot command/fence resources as a dma-buf target.
pub const GraphicsReadback = struct {
    target: DmabufTarget,
    mapping: [*]const u8,
    layout: c.VkSubresourceLayout,

    pub fn init(renderer: *Renderer, width: u32, height: u32) !GraphicsReadback {
        return initWithLinear(renderer, width, height, null);
    }

    fn initWithLinear(renderer: *Renderer, width: u32, height: u32, shared: ?*LinearAttachment) !GraphicsReadback {
        return initMode(renderer, width, height, shared, false);
    }

    pub fn initMode(renderer: *Renderer, width: u32, height: u32, shared: ?*LinearAttachment, direct: bool) !GraphicsReadback {
        const pass = if (direct) renderer.direct_presentation.render_pass else renderer.presentation_render_pass;
        if (pass == null) return error.SkipZigTest;
        const format: c.VkFormat = if (direct) c.VK_FORMAT_B8G8R8A8_SRGB else c.VK_FORMAT_B8G8R8A8_UNORM;
        var properties: c.VkFormatProperties = undefined;
        c.vkGetPhysicalDeviceFormatProperties(renderer.physical_device, format, &properties);
        const required = c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT;
        if (properties.linearTilingFeatures & required != required) return error.SkipZigTest;
        var image_info: c.VkImageCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_LINEAR,
            .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        var image: c.VkImage = undefined;
        try vk(c.vkCreateImage(renderer.device, &image_info, null, &image), error.CreateImageFailed);
        errdefer c.vkDestroyImage(renderer.device, image, null);
        var requirements: c.VkMemoryRequirements = undefined;
        c.vkGetImageMemoryRequirements(renderer.device, image, &requirements);
        const memory_type = renderer.findMemoryType(requirements.memoryTypeBits, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) orelse return error.SkipZigTest;
        var allocate: c.VkMemoryAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = requirements.size, .memoryTypeIndex = memory_type };
        var memory: c.VkDeviceMemory = undefined;
        try vk(c.vkAllocateMemory(renderer.device, &allocate, null, &memory), error.AllocateMemoryFailed);
        errdefer c.vkFreeMemory(renderer.device, memory, null);
        try vk(c.vkBindImageMemory(renderer.device, image, memory, 0), error.BindMemoryFailed);
        var mapping: ?*anyopaque = null;
        try vk(c.vkMapMemory(renderer.device, memory, 0, requirements.size, 0, &mapping), error.MapMemoryFailed);
        errdefer c.vkUnmapMemory(renderer.device, memory);
        var view_info: c.VkImageViewCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = image, .viewType = c.VK_IMAGE_VIEW_TYPE_2D, .format = format, .subresourceRange = LinearAttachment.range };
        var view: c.VkImageView = undefined;
        try vk(c.vkCreateImageView(renderer.device, &view_info, null, &view), error.CreateImageViewFailed);
        errdefer c.vkDestroyImageView(renderer.device, view, null);
        const linear = if (direct) null else if (shared) |attachment| attachment.retain() else try LinearAttachment.init(renderer, width, height);
        errdefer if (linear) |attachment| attachment.deinit(renderer);
        var attachments = [_]c.VkImageView{ if (linear) |attachment| attachment.view else view, view };
        var framebuffer_info: c.VkFramebufferCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = pass, .attachmentCount = if (direct) 1 else attachments.len, .pAttachments = &attachments, .width = width, .height = height, .layers = 1 };
        var framebuffer: c.VkFramebuffer = undefined;
        try vk(c.vkCreateFramebuffer(renderer.device, &framebuffer_info, null, &framebuffer), error.CreateFramebufferFailed);
        errdefer c.vkDestroyFramebuffer(renderer.device, framebuffer, null);
        var pool_info: c.VkCommandPoolCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = renderer.queue_family };
        var pool: c.VkCommandPool = undefined;
        try vk(c.vkCreateCommandPool(renderer.device, &pool_info, null, &pool), error.CreateCommandPoolFailed);
        errdefer c.vkDestroyCommandPool(renderer.device, pool, null);
        var command_info: c.VkCommandBufferAllocateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
        var command: c.VkCommandBuffer = undefined;
        try vk(c.vkAllocateCommandBuffers(renderer.device, &command_info, &command), error.AllocateCommandBufferFailed);
        var fence_info: c.VkFenceCreateInfo = .{ .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
        var fence: c.VkFence = undefined;
        try vk(c.vkCreateFence(renderer.device, &fence_info, null, &fence), error.CreateFenceFailed);
        const subresource: c.VkImageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .arrayLayer = 0 };
        var layout: c.VkSubresourceLayout = undefined;
        c.vkGetImageSubresourceLayout(renderer.device, image, &subresource, &layout);
        return .{
            .target = .{ .image = image, .memory = memory, .view = view, .framebuffer = framebuffer, .linear = linear, .direct = direct, .command_pool = pool, .command_buffer = command, .fence = fence, .timeline = null, .width = width, .height = height, .modifier = 0, .planes = undefined, .plane_count = 0 },
            .mapping = @ptrCast(mapping.?),
            .layout = layout,
        };
    }

    pub fn deinit(self: *GraphicsReadback, renderer: *Renderer) void {
        self.target.wait(renderer) catch {};
        c.vkUnmapMemory(renderer.device, self.target.memory);
        self.target.deinit(renderer);
    }

    pub fn pixel(self: *const GraphicsReadback, x: usize, y: usize) [4]u8 {
        const bytes = self.mapping[self.layout.offset + y * self.layout.rowPitch + x * 4 ..][0..4];
        return .{ bytes[2], bytes[1], bytes[0], bytes[3] };
    }

    fn expectPixel(self: *const GraphicsReadback, x: usize, y: usize, expected: [4]u8) !void {
        const actual = self.pixel(x, y);
        for (actual, expected) |a, e| {
            if (@abs(@as(i16, a) - @as(i16, e)) > 1) {
                std.debug.print("graphics pixel ({d},{d}): expected {any}, actual {any}\n", .{ x, y, expected, actual });
                return error.TestExpectedEqual;
            }
        }
    }
};

test "direct sRGB graphics preserve dark colors and reconstruct damaged opaque scenes" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var first = try GraphicsReadback.initMode(&renderer, 256, 3, null, true);
    defer first.deinit(&renderer);
    var second = try GraphicsReadback.initMode(&renderer, 256, 3, null, true);
    defer second.deinit(&renderer);
    try std.testing.expect(first.target.linear == null and second.target.linear == null);
    var commands: [259]scene.Command = undefined;
    commands[0] = .{ .clear = Color.rgba(20, 40, 60, 255) };
    for (commands[1..257], 0..) |*command, x| command.* = .{ .solid_rectangle = .{
        .bounds = .{ .x = @intCast(x), .y = 0, .width = 1, .height = 1 },
        .color = Color.rgba(@intCast(x), @intCast(x), @intCast(x), 255),
    } };
    commands[257] = .{ .solid_rectangle = .{
        .bounds = .{ .x = 3, .y = 1, .width = 7, .height = 1 },
        .color = Color.rgba(200, 100, 50, 128),
    } };
    commands[258] = .{ .solid_rectangle = .{
        .bounds = .{ .x = 5, .y = 1, .width = 3, .height = 1 },
        .color = Color.rgba(0, 0, 0, 64),
    } };
    const list: scene.DisplayList = .{ .commands = &commands };
    try renderer.renderGraphicsResources(list, &first.target, null, null, null, null, false);
    // New slots must repair their undefined pixels even with empty damage.
    try renderer.renderGraphicsResources(.{ .commands = &commands, .damage = .{ .regions = &.{} } }, &second.target, null, null, null, null, false);
    try first.target.wait(&renderer);
    try second.target.wait(&renderer);
    for (0..256) |x| {
        const value: u8 = @intCast(x);
        try first.expectPixel(x, 0, .{ value, value, value, 255 });
        try std.testing.expectEqual(first.pixel(x, 0), second.pixel(x, 0));
    }
    try first.expectPixel(3, 1, .{ 147, 77, 55, 255 });
    // Independently calculated sRGB encode of two linear source-over draws.
    try first.expectPixel(6, 1, .{ 129, 67, 47, 255 });
    const overlap = first.pixel(6, 1);
    const untouched = first.pixel(200, 0);
    for (0..30) |_| {
        try renderer.renderGraphicsResources(.{ .commands = &commands, .damage = .{ .regions = &.{.{ .x = 3, .y = 1, .width = 7, .height = 1 }} } }, &first.target, null, null, null, null, false);
        try first.target.wait(&renderer);
        try std.testing.expectEqual(overlap, first.pixel(6, 1));
        try std.testing.expectEqual(untouched, first.pixel(200, 0));
    }
    commands[0].clear.a = 254;
    try std.testing.expectError(error.OpaqueSceneRequired, renderer.renderGraphicsResources(list, &first.target, null, null, null, null, false));
    commands[0].clear.a = 255;
    commands[258].solid_rectangle.blend = .source;
    try std.testing.expectError(error.OpaqueSceneRequired, renderer.renderGraphicsResources(list, &first.target, null, null, null, null, false));
    try std.testing.expectEqual(overlap, first.pixel(6, 1));
    commands[258].solid_rectangle.blend = .source_over;
    commands[0] = .{ .solid_rectangle = .{ .bounds = .{ .x = 0, .y = 0, .width = 256, .height = 3 }, .color = Color.rgba(20, 40, 60, 255) } };
    try renderer.renderGraphicsResources(list, &first.target, null, null, null, null, false);
    try first.target.wait(&renderer);
    try std.testing.expectEqual(overlap, first.pixel(6, 1));
    // Sub-code blends expose implementation-dependent fixed-function sRGB
    // precision: these twenty draws produce 255 on llvmpipe and 251 on Intel
    // Lunar Lake (FP16 exports 246). Test reconstruction, not one driver's
    // rounding result: rendering another frame must not accumulate more paint.
    commands[0] = .{ .clear = Color.rgba(255, 255, 255, 255) };
    for (commands[1..21]) |*command| command.* = .{ .solid_rectangle = .{
        .bounds = .{ .x = 0, .y = 2, .width = 1, .height = 1 },
        .color = Color.rgba(0, 0, 0, 1),
    } };
    try renderer.renderGraphicsResources(.{ .commands = commands[0..21] }, &first.target, null, null, null, null, false);
    try first.target.wait(&renderer);
    const faint_result = first.pixel(0, 2);
    try std.testing.expectEqual(@as(u8, 255), faint_result[3]);
    try first.expectPixel(1, 2, .{ 255, 255, 255, 255 });
    for (0..20) |_| {
        try renderer.renderGraphicsResources(.{ .commands = commands[0..21] }, &first.target, null, null, null, null, false);
        try first.target.wait(&renderer);
        try std.testing.expectEqual(faint_result, first.pixel(0, 2));
    }
}

test "Vulkan graphics shared working image preserves queued partial frames and precision" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var first = try GraphicsReadback.init(&renderer, 7, 3);
    var first_live = true;
    defer if (first_live) first.deinit(&renderer);
    var second = try GraphicsReadback.initWithLinear(&renderer, 7, 3, first.target.linear);
    defer second.deinit(&renderer);
    var third = try GraphicsReadback.initWithLinear(&renderer, 7, 3, first.target.linear);
    defer third.deinit(&renderer);
    try std.testing.expectEqual(@as(usize, 3), first.target.linear.?.references);
    try std.testing.expect(first.target.image != second.target.image);
    try std.testing.expect(first.target.linear == second.target.linear and second.target.linear == third.target.linear);

    try renderer.renderGraphicsResources(.{ .commands = &.{
        .{ .clear = Color.rgba(255, 255, 255, 255) },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 5, .y = 2, .width = 2, .height = 1 }, .color = Color.rgba(255, 0, 0, 255) } },
    } }, &first.target, null, null, null, null, false);
    const patch = [_]RectI{.{ .x = 1, .y = 0, .width = 2, .height = 2 }};
    // No CPU waits between slots. Initializing a new presentation image must
    // neither clear the shared working image nor overwrite the previous export.
    try renderer.renderGraphicsResources(.{
        .commands = &.{.{ .clear = Color.rgba(255, 255, 255, 128) }},
        .damage = .{ .regions = &patch },
    }, &second.target, null, null, null, null, false);
    try renderer.renderGraphicsResources(.{
        .commands = &.{.{ .clear = Color.rgba(0, 0, 0, 0) }},
        .damage = .{ .regions = &.{} },
    }, &third.target, null, null, null, null, false);
    try first.target.wait(&renderer);
    try second.target.wait(&renderer);
    try third.target.wait(&renderer);
    try first.expectPixel(1, 0, .{ 255, 255, 255, 255 });
    for ([_]*GraphicsReadback{ &second, &third }) |slot| {
        try slot.expectPixel(1, 0, .{ 128, 128, 128, 128 });
        try slot.expectPixel(2, 1, .{ 128, 128, 128, 128 });
        try slot.expectPixel(3, 1, .{ 255, 255, 255, 255 });
        try slot.expectPixel(6, 2, .{ 255, 0, 0, 255 });
    }

    const faint = [_]scene.Command{.{ .solid_rectangle = .{
        .bounds = .{ .x = 0, .y = 2, .width = 1, .height = 1 },
        .color = Color.rgba(0, 0, 0, 1),
    } }};
    // Destroy the original owner while another slot can still be executing.
    try renderer.renderGraphicsResources(.{ .commands = &faint }, &second.target, null, null, null, null, false);
    first.deinit(&renderer);
    first_live = false;
    try std.testing.expectEqual(@as(usize, 2), second.target.linear.?.references);
    for (1..20) |index| {
        const slot = if (index % 2 == 0) &second else &third;
        try slot.target.wait(&renderer);
        try renderer.renderGraphicsResources(.{ .commands = &faint }, &slot.target, null, null, null, null, false);
    }
    try third.target.wait(&renderer);
    // Encode((254/255)^20) = 246.334. Per-slot storage would accumulate
    // only ten blends; reimporting BGRA8 would round each blend back to white.
    try third.expectPixel(0, 2, .{ 246, 246, 246, 255 });
    try third.expectPixel(1, 2, .{ 255, 255, 255, 255 });
    try third.expectPixel(1, 0, .{ 128, 128, 128, 128 });
    try third.expectPixel(6, 2, .{ 255, 0, 0, 255 });
}

test "Vulkan graphics linear light, transparent encoding and persistent damaged slots" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var first = try GraphicsReadback.init(&renderer, 6, 2);
    defer first.deinit(&renderer);
    var second = try GraphicsReadback.init(&renderer, 6, 2);
    defer second.deinit(&renderer);
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(0, 0, 0, 0) },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .color = Color.rgba(0, 0, 0, 255) } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .color = Color.rgba(255, 255, 255, 128) } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 1, .y = 0, .width = 1, .height = 1 }, .color = Color.rgba(255, 255, 255, 255) } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 1, .y = 0, .width = 1, .height = 1 }, .color = Color.rgba(0, 0, 0, 128) } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 2, .y = 0, .width = 1, .height = 1 }, .color = Color.rgba(17, 84, 211, 255) } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 2, .y = 0, .width = 1, .height = 1 }, .color = Color.rgba(0, 0, 0, 128), .blend = .source } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 3, .y = 0, .width = 1, .height = 1 }, .color = Color.rgba(255, 255, 255, 128) } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 4, .y = 0, .width = 1, .height = 1 }, .color = Color.rgba(200, 100, 50, 128) } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 5, .y = 0, .width = 1, .height = 1 }, .color = Color.rgba(20, 40, 60, 255) } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 5, .y = 0, .width = 1, .height = 1 }, .color = Color.rgba(200, 100, 50, 128) } },
    };
    try renderer.renderGraphicsResources(.{ .commands = &commands }, &first.target, null, null, null, null, false);
    // Submit a different slot before waiting: no renderer-global command,
    // descriptor, working attachment or fence may be reused between them.
    try renderer.renderGraphicsResources(.{ .commands = &.{.{ .clear = Color.rgba(11, 43, 97, 255) }} }, &second.target, null, null, null, null, false);
    try std.testing.expect(first.target.gpu_pending and second.target.gpu_pending);
    try first.target.wait(&renderer);
    try second.target.wait(&renderer);
    const expected = [_][4]u8{ .{ 188, 188, 188, 255 }, .{ 187, 187, 187, 255 }, .{ 0, 0, 0, 128 }, .{ 128, 128, 128, 128 }, .{ 100, 50, 25, 128 }, .{ 147, 77, 55, 255 } };
    for (expected, 0..) |pixel, x| try first.expectPixel(x, 0, pixel);
    try first.expectPixel(0, 1, .{ 0, 0, 0, 0 });
    try second.expectPixel(4, 1, .{ 11, 43, 97, 255 });

    const untouched = first.pixel(5, 0);
    const damage = [_]RectI{.{ .x = 1, .y = 0, .width = 2, .height = 2 }};
    const update = [_]scene.Command{
        .{ .clear = Color.rgba(255, 255, 255, 128) },
        .{ .push_clip_rect = .{ .x = 2, .y = 1, .width = 1, .height = 1 } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 0, .y = 0, .width = 6, .height = 2 }, .color = Color.rgba(0, 0, 0, 0), .blend = .source } },
        .pop_clip,
    };
    try renderer.renderGraphicsResources(.{ .commands = &update, .damage = .{ .regions = &damage } }, &first.target, null, null, null, null, false);
    try first.target.wait(&renderer);
    try first.expectPixel(1, 0, .{ 128, 128, 128, 128 });
    try first.expectPixel(2, 1, .{ 0, 0, 0, 0 });
    try std.testing.expectEqual(untouched, first.pixel(5, 0));
    try second.expectPixel(4, 1, .{ 11, 43, 97, 255 });
    // An empty damage list still converts from the persistent attachment.
    try renderer.renderGraphicsResources(.{ .commands = &commands, .damage = .{ .regions = &.{} } }, &first.target, null, null, null, null, false);
    try first.target.wait(&renderer);
    try first.expectPixel(1, 0, .{ 128, 128, 128, 128 });
    try std.testing.expectEqual(untouched, first.pixel(5, 0));

    // Integer compute must expose the same encoded-premultiplied contract.
    var compute = try Target.init(&renderer, 6, 2);
    defer compute.deinit(&renderer);
    try renderer.render(.{ .commands = &commands }, &compute);
    var bytes: [48]u8 = undefined;
    try compute.readPixels(&bytes, 24, .rgba8_unorm);
    for (expected, 0..) |pixel, x| try std.testing.expectEqualSlices(u8, &pixel, bytes[x * 4 ..][0..4]);

    try renderer.renderGraphicsResources(.{ .commands = &.{.{ .clear = Color.rgba(255, 255, 255, 255) }} }, &second.target, null, null, null, null, false);
    const faint = [_]scene.Command{.{ .solid_rectangle = .{
        .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .color = Color.rgba(0, 0, 0, 1),
    } }};
    for (0..20) |_| {
        try second.target.wait(&renderer);
        try renderer.renderGraphicsResources(.{ .commands = &faint }, &second.target, null, null, null, null, false);
    }
    try second.target.wait(&renderer);
    // Encode((254/255)^20) = 246.334. Reimporting the 8-bit export after
    // every submission would round each faint blend back to 255 instead.
    try second.expectPixel(0, 0, .{ 246, 246, 246, 255 });
    try second.expectPixel(1, 0, .{ 255, 255, 255, 255 });
}

test "Vulkan graphics decorated source replaces by coverage rather than alpha" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var target = try GraphicsReadback.init(&renderer, 9, 5);
    defer target.deinit(&renderer);
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(255, 255, 255, 255) },
        .{ .decorated_rectangle = .{
            .bounds = .{ .x = 0, .y = 0, .width = 5, .height = 5 },
            .background = Color.rgba(0, 0, 0, 0),
            .corner_radius = 2,
            .blend = .source,
        } },
        .{ .decorated_rectangle = .{
            .bounds = .{ .x = 5, .y = 0, .width = 4, .height = 5 },
            .background = Color.rgba(200, 100, 50, 128),
            .border_color = Color.rgba(0, 0, 0, 64),
            .border_width = 1,
            .blend = .source,
        } },
    };
    try renderer.renderGraphicsResources(.{ .commands = &commands }, &target.target, null, null, null, null, false);
    try target.target.wait(&renderer);
    try target.expectPixel(2, 2, .{ 0, 0, 0, 0 });
    // Outer coverage = 2.5 - sqrt(4.5); the unfilled white destination
    // contributes (1-coverage)*255 = 158.44 to RGB and alpha.
    try target.expectPixel(0, 0, .{ 158, 158, 158, 158 });
    try target.expectPixel(5, 2, .{ 0, 0, 0, 64 });
    try target.expectPixel(6, 2, .{ 100, 50, 25, 128 });

    // Compute retains the CPU's integer radius clamp for odd extents.
    var compute = try Target.init(&renderer, 3, 3);
    defer compute.deinit(&renderer);
    try renderer.render(.{ .commands = &.{
        .{ .clear = Color.rgba(255, 255, 255, 255) },
        .{ .decorated_rectangle = .{ .bounds = .{ .x = 0, .y = 0, .width = 3, .height = 3 }, .background = Color.rgba(0, 0, 0, 0), .corner_radius = 99, .blend = .source } },
    } }, &compute);
    var bytes: [36]u8 = undefined;
    try compute.readPixels(&bytes, 12, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &.{ 53, 53, 53, 53 }, bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[16..20]);
}

test "Vulkan graphics decodes transparent image texels before filtering" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var target = try GraphicsReadback.init(&renderer, 4, 1);
    defer target.deinit(&renderer);
    var cache = try ImageCache.init(std.testing.allocator, 1);
    defer cache.deinit();
    const pixels = try std.testing.allocator.dupe(u8, &.{ 0, 0, 0, 255, 128, 64, 0, 128 });
    const handle = try cache.insert(.{ .allocator = std.testing.allocator, .pixels = pixels, .width = 2, .height = 1, .intrinsic_width = 2, .intrinsic_height = 1 });
    const commands = [_]scene.Command{.{ .image = .{ .image = handle, .bounds = .{ .x = 0, .y = 0, .width = 3, .height = 1 }, .fit = .fill } }};
    try renderer.renderGraphicsResources(.{ .commands = &commands }, &target.target, null, null, null, &cache, false);
    try cache.release(handle); // In-flight uploads own copies, not cache leases.
    try target.target.wait(&renderer);
    try target.expectPixel(0, 0, .{ 0, 0, 0, 255 });
    // At the midpoint alpha is 191.5/255 and straight linear RGB is
    // (64/191.5, sRGB-decode(0.5)*64/191.5, 0), then sRGB encoded
    // and premultiplied. The one-byte tolerance covers FP16 rounding.
    try target.expectPixel(1, 0, .{ 116, 58, 0, 192 });
    try target.expectPixel(2, 0, .{ 128, 64, 0, 128 });
    try target.expectPixel(3, 0, .{ 0, 0, 0, 0 });
}

test "image uploads deduplicate repeated handles and bound unique bytes per submission" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var target = try Target.init(&renderer, 1, 1);
    defer target.deinit(&renderer);
    var cache = try ImageCache.init(std.testing.allocator, 2);
    defer cache.deinit();
    const first = try @import("../image_test.zig").insertFixture(&cache);
    const second = try @import("../image_test.zig").insertFixture(&cache);
    var commands: [256]scene.Command = undefined;
    for (&commands, 0..) |*command, index| command.* = .{ .image = .{
        .image = if (index % 2 == 0) first else second,
        .bounds = .{ .x = @intCast(index), .y = 3, .width = 6, .height = 4 },
        .fit = .fill,
    } };
    // A smaller synthetic native storage limit lets the test exercise both
    // sides of the byte budget without allocating hundreds of megabytes.
    renderer.max_image_pixels = 11; // 44 bytes: each 24-byte image fits alone.
    for ([_]?*const Target{ &target, null }) |destination| {
        try std.testing.expectError(error.ImageUploadBudgetExceeded, ImageUploads.init(&renderer, &commands, &cache, destination));
        renderer.max_image_pixels = 12; // Exactly 48 unique bytes, not 256 * 24.
        var uploads = try ImageUploads.init(&renderer, &commands, &cache, destination);
        defer uploads.deinit(&renderer);
        try std.testing.expectEqual(@as(usize, 256), uploads.entries.items.len);
        try std.testing.expectEqual(@as(usize, 2), uploads.resources.items.len);
        try std.testing.expectEqual(@as(u64, 48), uploads.byte_size);
        for (uploads.entries.items, 0..) |entry, index| {
            try std.testing.expectEqual(index % 2, entry.resource_index);
            try std.testing.expectEqual(@as(f32, @floatFromInt(index)), entry.placement.left);
            const resource = uploads.resources.items[entry.resource_index];
            const bytes: [*]const u8 = @ptrCast(resource.pixels.mapping);
            try std.testing.expectEqualSlices(u8, (try cache.get(commands[index].image.image)).pixels, bytes[0..24]);
        }
        uploads.deinit(&renderer);
        try std.testing.expectEqual(@as(usize, 0), uploads.resources.items.len);
        try std.testing.expectEqual(@as(usize, 0), uploads.entries.items.len);
        try std.testing.expectEqual(@as(u64, 0), uploads.byte_size);
        renderer.max_image_pixels = 11;
    }
    // Failed and successful uploads must not acquire or leak cache leases.
    try cache.release(first);
    try cache.release(second);
    try std.testing.expectError(error.StaleImageHandle, cache.get(first));
    try std.testing.expectError(error.StaleImageHandle, cache.get(second));
}

test "Vulkan scene damage matches full graphics rendering after move and removal" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var partial = try GraphicsReadback.init(&renderer, 40, 16);
    defer partial.deinit(&renderer);
    var full = try GraphicsReadback.init(&renderer, 40, 16);
    defer full.deinit(&renderer);
    var tracker = try scene.DamageTracker.init(std.testing.allocator, 4);
    defer tracker.deinit();
    const viewport: RectI = .{ .x = 0, .y = 0, .width = 40, .height = 16 };
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(0, 0, 0, 0) },
        .{ .push_clip_rect = .{ .x = 4, .y = 2, .width = 30, .height = 12 } },
        .{ .decorated_rectangle = .{
            .bounds = .{ .x = 2, .y = 3, .width = 8, .height = 7 },
            .background = Color.rgba(80, 120, 200, 128),
            .border_color = Color.rgba(200, 40, 60, 180),
            .border_width = 1,
            .corner_radius = 2,
        } },
        .pop_clip,
    };
    for ([_]i32{ 2, 23, 23 }, 0..) |x, index| {
        commands[2].decorated_rectangle.bounds.x = x;
        const current = if (index == 2) commands[0..1] else &commands;
        const damage = try tracker.compare(current, viewport);
        if (index != 0) try std.testing.expect(damage == .regions and damage.regions[0].width < viewport.width);
        try renderer.renderGraphicsResources(.{ .commands = current, .damage = damage }, &partial.target, null, null, null, null, false);
        try renderer.renderGraphicsResources(.{ .commands = current }, &full.target, null, null, null, null, false);
        try partial.target.wait(&renderer);
        try full.target.wait(&renderer);
        for (0..16) |y| for (0..40) |pixel_x|
            try partial.expectPixel(pixel_x, y, full.pixel(pixel_x, y));
        tracker.submitted();
    }
}
