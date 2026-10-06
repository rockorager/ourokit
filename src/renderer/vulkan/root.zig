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
const path = @import("../../path/root.zig");
const shadow = @import("../../shadow/root.zig");
const paint = @import("../../paint/root.zig");
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
gradient_descriptor_layout: c.VkDescriptorSetLayout,
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
path_masks: path.MaskCache,
shadow_masks: shadow.MaskCache,

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
    origin: [2]i32 = .{ 0, 0 },
    command_buffer: c.VkCommandBuffer = null,

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

    fn upload(renderer: *Renderer, bitmap: *const @import("../../image/pixels.zig").Bitmap, _: ?*const Target) !Resource {
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
        var layout = renderer.atlas_descriptor_layout;
        var allocate: c.VkDescriptorSetAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &layout,
        };
        var descriptor: c.VkDescriptorSet = undefined;
        try vk(c.vkAllocateDescriptorSets(renderer.device, &allocate, &descriptor), error.AllocateDescriptorSetFailed);
        var buffers = [_]c.VkDescriptorBufferInfo{
            .{ .buffer = pixels.buffer, .offset = 0, .range = pixels.byte_size },
        };
        var writes: [1]c.VkWriteDescriptorSet = undefined;
        for (&writes, 0..) |*write, binding| write.* = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptor,
            .dstBinding = @intCast(binding),
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &buffers[binding],
        };
        c.vkUpdateDescriptorSets(renderer.device, 1, &writes, 0, null);
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

/// Submission-owned A8 copies. Cache pixels are borrowed only until the next
/// get, so copy each unique mask before asking the CPU cache for another one.
const CoverageUploads = struct {
    entries: std.ArrayList(Entry) = .empty,
    resources: std.ArrayList(Resource) = .empty,
    byte_size: u64 = 0,

    const Key = union(enum) { path: path.Key, shadow: shadow.Key };
    const Entry = struct {
        resource_index: ?usize,
        bounds: RectI,
    };
    const Resource = struct {
        pixels: Target,
        pool: c.VkDescriptorPool,
        descriptor: c.VkDescriptorSet,
    };

    fn init(renderer: *Renderer, commands: []const scene.Command, target: ?*const Target) !CoverageUploads {
        var self: CoverageUploads = .{};
        errdefer self.deinit(renderer);
        var indices: std.AutoHashMapUnmanaged(Key, usize) = .empty;
        defer indices.deinit(renderer.allocator);
        const byte_limit = @min(32 * 1024 * 1024, renderer.max_image_pixels * 4);
        for (commands) |command| {
            const mask: struct { key: Key, bounds: RectI, pixels: []const u8 } = switch (command) {
                .path => |value| blk: {
                    const mask = try renderer.path_masks.get(value.path, value.origin, value.scale);
                    break :blk .{ .key = .{ .path = mask.key }, .bounds = mask.bounds, .pixels = mask.pixels };
                },
                .shadow => |value| blk: {
                    const mask = try renderer.shadow_masks.get(value.shape);
                    break :blk .{ .key = .{ .shadow = mask.key }, .bounds = mask.bounds, .pixels = mask.pixels };
                },
                else => continue,
            };
            var resource_index: ?usize = null;
            if (!mask.bounds.isEmpty()) {
                const index = try indices.getOrPut(renderer.allocator, mask.key);
                if (!index.found_existing) {
                    // uint shader loads include up to three bytes after the
                    // final texel, including when the row width is odd.
                    const padded_size = std.mem.alignForward(usize, mask.pixels.len, 4);
                    if (padded_size > byte_limit - self.byte_size) return error.CoverageUploadBudgetExceeded;
                    var resource = try upload(renderer, mask.pixels, padded_size, target);
                    errdefer {
                        c.vkDestroyDescriptorPool(renderer.device, resource.pool, null);
                        resource.pixels.deinit(renderer);
                    }
                    try self.resources.append(renderer.allocator, resource);
                    index.value_ptr.* = self.resources.items.len - 1;
                    self.byte_size += padded_size;
                }
                resource_index = index.value_ptr.*;
            }
            // Even empty masks occupy an entry in scene command order.
            try self.entries.append(renderer.allocator, .{ .resource_index = resource_index, .bounds = mask.bounds });
        }
        return self;
    }

    fn upload(renderer: *Renderer, mask: []const u8, padded_size: usize, _: ?*const Target) !Resource {
        // Target's encoded format allocates four bytes per element; these are
        // raw A8 words, not encoded image texels. Drawing uses mask bounds for
        // the byte stride instead of this buffer's word count.
        var pixels = try Target.initBuffer(renderer, @intCast(padded_size / 4), 1, .encoded_rgba, renderer.max_image_pixels);
        errdefer pixels.deinit(renderer);
        const bytes = @as([*]u8, @ptrCast(pixels.mapping))[0..padded_size];
        @memcpy(bytes[0..mask.len], mask);
        @memset(bytes[mask.len..], 0);
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
        var layout = renderer.atlas_descriptor_layout;
        var allocate: c.VkDescriptorSetAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &layout,
        };
        var descriptor: c.VkDescriptorSet = undefined;
        try vk(c.vkAllocateDescriptorSets(renderer.device, &allocate, &descriptor), error.AllocateDescriptorSetFailed);
        var buffers = [_]c.VkDescriptorBufferInfo{
            .{ .buffer = pixels.buffer, .offset = 0, .range = pixels.byte_size },
        };
        var writes: [1]c.VkWriteDescriptorSet = undefined;
        for (&writes, 0..) |*write, binding| write.* = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptor,
            .dstBinding = @intCast(binding),
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &buffers[binding],
        };
        c.vkUpdateDescriptorSets(renderer.device, 1, &writes, 0, null);
        return .{ .pixels = pixels, .pool = pool, .descriptor = descriptor };
    }

    fn deinit(self: *CoverageUploads, renderer: *Renderer) void {
        for (self.resources.items) |*resource| {
            c.vkDestroyDescriptorPool(renderer.device, resource.pool, null);
            resource.pixels.deinit(renderer);
        }
        self.resources.deinit(renderer.allocator);
        self.entries.deinit(renderer.allocator);
        self.* = .{};
    }
};

const DrawIndexes = struct {
    image: usize = 0,
    coverage: usize = 0,
    gradient: u32 = 0,
    rounded: u32 = 0,
    group: usize = 0,

    fn advance(self: *DrawIndexes, command: scene.Command) void {
        if (commandGradient(command) != null) self.gradient += 1;
        switch (command) {
            .image => self.image += 1,
            .path, .shadow => self.coverage += 1,
            .push_clip_rounded => self.rounded += 1,
            .push_opacity => self.group += 1,
            else => {},
        }
    }
};

const DrawRange = struct {
    begin: usize = 0,
    end: usize,
    indexes: DrawIndexes = .{},
};

/// Cropped integer GPU surfaces, computed bottom-up once per submission. No
/// scene pointers or borrowed CPU pixels survive recording. Both descriptors
/// address the same storage, once as a compute destination and once as a source.
const OpacityLayers = struct {
    entries: []Entry = &.{},
    pool: c.VkDescriptorPool = null,
    byte_size: usize = 0,
    damage: scene.DamageRegions = .{},

    const Entry = struct {
        group: scene.opacity.Group,
        body: DrawRange,
        after: DrawIndexes = .{},
        pixels: ?Target = null,
        destination: c.VkDescriptorSet = null,
        source: c.VkDescriptorSet = null,
    };

    fn init(renderer: *Renderer, commands: []const scene.Command, viewport: RectI, damage: scene.Damage) !OpacityLayers {
        var regions: scene.DamageRegions = .{};
        switch (damage) {
            .full => regions.add(viewport),
            .regions => |values| for (values) |value| regions.add(RectI.intersect(value, viewport)),
        }
        var plan = try scene.opacity.Plan.initDamaged(renderer.allocator, commands, viewport, .{ .regions = regions.slice() });
        defer plan.deinit();
        var self: OpacityLayers = .{ .byte_size = plan.byte_size, .damage = regions };
        self.entries = try renderer.allocator.alloc(Entry, plan.groups.len);
        for (self.entries, plan.groups) |*entry, group| entry.* = .{
            .group = group,
            .body = .{ .begin = group.begin + 1, .end = group.end },
        };
        errdefer self.deinit(renderer);
        var indexes: DrawIndexes = .{};
        var stack: [scene.max_opacity_depth]usize = undefined;
        var depth: usize = 0;
        for (commands) |command| {
            const group_index = indexes.group;
            indexes.advance(command);
            switch (command) {
                .push_opacity => {
                    self.entries[group_index].body.indexes = indexes;
                    stack[depth] = group_index;
                    depth += 1;
                },
                .pop_opacity => {
                    depth -= 1;
                    self.entries[stack[depth]].after = indexes;
                },
                else => {},
            }
        }
        var count: u32 = 0;
        for (plan.groups) |group| if (!group.bounds.isEmpty()) {
            // Check every extent before allocating any Vulkan object.
            if (@as(u64, group.bounds.width) * group.bounds.height > renderer.max_pixels) return error.InvalidExtent;
            count += 1;
        };
        if (count == 0) return self;
        var size: c.VkDescriptorPoolSize = .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = count * 2 };
        var info: c.VkDescriptorPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = count * 2,
            .poolSizeCount = 1,
            .pPoolSizes = &size,
        };
        try vk(c.vkCreateDescriptorPool(renderer.device, &info, null, &self.pool), error.CreateDescriptorPoolFailed);
        for (self.entries) |*entry| {
            const bounds = entry.group.bounds;
            if (bounds.isEmpty()) continue;
            entry.pixels = try Target.init(renderer, bounds.width, bounds.height);
            const pixels = &entry.pixels.?;
            pixels.origin = .{ bounds.x, bounds.y };
            const bytes = @as([*]u8, @ptrCast(pixels.mapping))[0..pixels.byte_size];
            for (self.damage.slice()) |region| {
                const clipped = RectI.intersect(region, bounds);
                if (clipped.isEmpty()) continue;
                const left: usize = @intCast(clipped.x - bounds.x);
                const top: usize = @intCast(clipped.y - bounds.y);
                for (top..top + clipped.height) |y| {
                    const start = (y * bounds.width + left) * 8;
                    @memset(bytes[start..][0 .. @as(usize, clipped.width) * 8], 0);
                }
            }
            var layouts = [_]c.VkDescriptorSetLayout{ renderer.descriptor_layout, renderer.atlas_descriptor_layout };
            var allocate: c.VkDescriptorSetAllocateInfo = .{
                .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                .descriptorPool = self.pool,
                .descriptorSetCount = 2,
                .pSetLayouts = &layouts,
            };
            var descriptors: [2]c.VkDescriptorSet = undefined;
            try vk(c.vkAllocateDescriptorSets(renderer.device, &allocate, &descriptors), error.AllocateDescriptorSetFailed);
            entry.destination = descriptors[0];
            entry.source = descriptors[1];
            var buffer: c.VkDescriptorBufferInfo = .{ .buffer = pixels.buffer, .offset = 0, .range = pixels.byte_size };
            var writes: [2]c.VkWriteDescriptorSet = undefined;
            for (&writes, descriptors) |*write, descriptor| write.* = .{
                .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = descriptor,
                .dstBinding = 0,
                .descriptorCount = 1,
                .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .pBufferInfo = &buffer,
            };
            c.vkUpdateDescriptorSets(renderer.device, 2, &writes, 0, null);
        }
        return self;
    }

    fn deinit(self: *OpacityLayers, renderer: *Renderer) void {
        if (self.pool != null) c.vkDestroyDescriptorPool(renderer.device, self.pool, null);
        for (self.entries) |*entry| if (entry.pixels) |*pixels| pixels.deinit(renderer);
        renderer.allocator.free(self.entries);
        self.* = .{};
    }

    fn record(self: *OpacityLayers, renderer: *Renderer, command_buffer: c.VkCommandBuffer, commands: []const scene.Command, glyphs: ?*GlyphCache, shapes: ?*const text.ShapeCache, paragraphs: ?*const text.ParagraphCache, images: *const ImageUploads, coverage: *const CoverageUploads, gradients: *const TableUpload, rounded: *const TableUpload) void {
        if (self.byte_size == 0) return;
        var barrier: c.VkMemoryBarrier = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
            .srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT,
            .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
        };
        c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_HOST_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);
        var remaining = self.entries.len;
        while (remaining != 0) {
            remaining -= 1;
            const entry = &self.entries[remaining];
            if (entry.pixels) |*pixels| {
                pixels.command_buffer = command_buffer;
                for (self.damage.slice()) |region| {
                    const clipped = RectI.intersect(region, entry.group.bounds);
                    if (!clipped.isEmpty()) renderer.renderRegion(commands, pixels, clipped, glyphs, shapes, paragraphs, images, coverage, gradients, rounded, entry.destination, self, entry.body);
                }
            }
        }
        barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT | c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);
    }
};

pub const DmabufPlane = struct {
    offset: u32,
    stride: u32,
};

/// std430 record shared by all compute and graphics gradient samplers.
const GradientRecord = extern struct {
    start: [2]f32,
    direction: [2]f32,
    count: u32,
    padding: [3]u32 = @splat(0),
    stops: [8][4]u32,

    fn init(value: paint.Prepared) GradientRecord {
        var result: GradientRecord = .{
            .start = .{ value.start.x, value.start.y },
            .direction = .{ value.direction.x, value.direction.y },
            .count = value.count,
            .stops = undefined,
        };
        for (value.stops, &result.stops) |stop, *output| {
            const color = packedLinear(stop.color);
            output.* = .{ stop.offset, color[0], color[1], 0 };
        }
        return result;
    }
};

fn commandGradient(command: scene.Command) ?paint.LinearGradient {
    return switch (command) {
        .decorated_rectangle => |value| value.background_gradient,
        .path => |value| value.gradient,
        else => null,
    };
}

/// std430 record; parent is the one-based index of the next rounded ancestor.
const ClipRecord = extern struct {
    origin: [2]i32,
    size: [2]u32,
    radius: u32,
    parent: u32,
    padding: [2]u32 = @splat(0),
};

// This word is independent of each pipeline's draw push constants, so clip
// state survives all draws until traversal changes it at a push/pop boundary.
const clip_push_offset = 96;
const origin_push_offset = 104;
const draw_push_size = origin_push_offset + @sizeOf([2]i32);
comptime {
    std.debug.assert(max_clip_depth == 64); // clip.glsl ancestor array.
    std.debug.assert(@sizeOf(Push) <= clip_push_offset);
    std.debug.assert(@sizeOf(GlyphPush) <= clip_push_offset);
    std.debug.assert(@sizeOf(PresentationPush) <= clip_push_offset);
    std.debug.assert(@sizeOf(PresentationGlyphPush) <= clip_push_offset);
}

/// Immutable per-submission analytic tables. Index zero means no gradient/clip;
/// nonzero indexes are one-based. Each table owns its storage until the fence.
const TableUpload = struct {
    pixels: ?Target = null,
    pool: c.VkDescriptorPool = null,
    descriptor: c.VkDescriptorSet = null,

    fn gradients(renderer: *Renderer, commands: []const scene.Command) !TableUpload {
        const byte_limit = @min(4 * 1024 * 1024, renderer.max_image_pixels * 4);
        var count: usize = 0;
        for (commands) |command| if (commandGradient(command) != null) {
            if (count == byte_limit / @sizeOf(GradientRecord)) return error.GradientUploadBudgetExceeded;
            count += 1;
        };
        // Even solid-only submissions bind a valid table: a dynamically skipped
        // SSBO remains a statically used descriptor in the shared shaders.
        const byte_size = @max(count, 1) * @sizeOf(GradientRecord);
        if (byte_size > byte_limit) return error.GradientUploadBudgetExceeded;
        const records = try renderer.allocator.alloc(GradientRecord, @max(count, 1));
        defer renderer.allocator.free(records);
        @memset(records, std.mem.zeroes(GradientRecord));
        var index: usize = 0;
        for (commands) |command| if (commandGradient(command)) |gradient| {
            records[index] = GradientRecord.init(try gradient.prepare());
            index += 1;
        };
        return upload(renderer, std.mem.sliceAsBytes(records));
    }

    fn clips(renderer: *Renderer, commands: []const scene.Command) !TableUpload {
        const byte_limit = @min(4 * 1024 * 1024, renderer.max_image_pixels * 4);
        var count: usize = 0;
        for (commands) |command| if (command == .push_clip_rounded) {
            if (count == byte_limit / @sizeOf(ClipRecord)) return error.ClipUploadBudgetExceeded;
            count += 1;
        };
        if (@max(count, 1) * @sizeOf(ClipRecord) > byte_limit) return error.ClipUploadBudgetExceeded;
        const records = try renderer.allocator.alloc(ClipRecord, @max(count, 1));
        defer renderer.allocator.free(records);
        @memset(records, std.mem.zeroes(ClipRecord));
        var parents: [max_clip_depth + 1]u32 = undefined;
        parents[0] = 0;
        var depth: usize = 0;
        var index: u32 = 0;
        var opacity_parents: [scene.max_opacity_depth]u32 = undefined;
        var opacity_depth: usize = 0;
        for (commands) |command| switch (command) {
            .push_opacity => {
                opacity_parents[opacity_depth] = parents[depth];
                opacity_depth += 1;
                parents[depth] = 0;
            },
            .pop_opacity => {
                opacity_depth -= 1;
                parents[depth] = opacity_parents[opacity_depth];
            },
            .push_clip_rect => {
                parents[depth + 1] = parents[depth];
                depth += 1;
            },
            .push_clip_rounded => |clip| {
                records[index] = .{
                    .origin = .{ clip.bounds.x, clip.bounds.y },
                    .size = .{ clip.bounds.width, clip.bounds.height },
                    .radius = clip.corner_radius,
                    .parent = parents[depth],
                };
                index += 1;
                depth += 1;
                parents[depth] = index;
            },
            .pop_clip => depth -= 1,
            else => {},
        };
        return upload(renderer, std.mem.sliceAsBytes(records));
    }

    fn upload(renderer: *Renderer, bytes: []const u8) !TableUpload {
        const byte_size = bytes.len;
        var pixels = try Target.initBuffer(renderer, @intCast(byte_size / 4), 1, .encoded_rgba, renderer.max_image_pixels);
        errdefer pixels.deinit(renderer);
        @memcpy(@as([*]u8, @ptrCast(pixels.mapping))[0..byte_size], bytes);
        var pool_size: c.VkDescriptorPoolSize = .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 };
        var pool_info: c.VkDescriptorPoolCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .maxSets = 1,
            .poolSizeCount = 1,
            .pPoolSizes = &pool_size,
        };
        var pool: c.VkDescriptorPool = undefined;
        try vk(c.vkCreateDescriptorPool(renderer.device, &pool_info, null, &pool), error.CreateDescriptorPoolFailed);
        errdefer c.vkDestroyDescriptorPool(renderer.device, pool, null);
        var allocate: c.VkDescriptorSetAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &renderer.gradient_descriptor_layout,
        };
        var descriptor: c.VkDescriptorSet = undefined;
        try vk(c.vkAllocateDescriptorSets(renderer.device, &allocate, &descriptor), error.AllocateDescriptorSetFailed);
        var buffer: c.VkDescriptorBufferInfo = .{ .buffer = pixels.buffer, .offset = 0, .range = byte_size };
        var write: c.VkWriteDescriptorSet = .{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptor,
            .dstBinding = 0,
            .descriptorCount = 1,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .pBufferInfo = &buffer,
        };
        c.vkUpdateDescriptorSets(renderer.device, 1, &write, 0, null);
        return .{ .pixels = pixels, .pool = pool, .descriptor = descriptor };
    }

    fn deinit(self: *TableUpload, renderer: *Renderer) void {
        c.vkDestroyDescriptorPool(renderer.device, self.pool, null);
        if (self.pixels) |*pixels| pixels.deinit(renderer);
        self.* = .{};
    }
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
    coverage_uploads: CoverageUploads = .{},
    gradient_uploads: TableUpload = .{},
    clip_uploads: TableUpload = .{},
    opacity_layers: OpacityLayers = .{},
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
        self.coverage_uploads.deinit(renderer);
        self.gradient_uploads.deinit(renderer);
        self.clip_uploads.deinit(renderer);
        self.opacity_layers.deinit(renderer);
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
                self.coverage_uploads.deinit(renderer);
                self.gradient_uploads.deinit(renderer);
                self.clip_uploads.deinit(renderer);
                self.opacity_layers.deinit(renderer);
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
        self.coverage_uploads.deinit(renderer);
        self.gradient_uploads.deinit(renderer);
        self.clip_uploads.deinit(renderer);
        self.opacity_layers.deinit(renderer);
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
    gradient_index: u32 = 0,
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
    gradient_index: u32 = 0,
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
    gradient_index: u32 = 0,
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
    gradient_index: u32 = 0,
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

fn createPresentationPipeline(device: c.VkDevice, atlas_layout: c.VkDescriptorSetLayout, gradient_layout: c.VkDescriptorSetLayout, direct: bool) !PresentationObjects {
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
        .size = draw_push_size,
    };
    // Identical layouts/ranges keep tables bound across solid, glyph and image
    // pipelines, while their existing set-0 atlas descriptors can change.
    var set_layouts = [_]c.VkDescriptorSetLayout{ atlas_layout, gradient_layout, gradient_layout };
    var layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = set_layouts.len,
        .pSetLayouts = &set_layouts,
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

    var glyph_layout: c.VkPipelineLayout = undefined;
    try vk(c.vkCreatePipelineLayout(device, &layout_info, null, &glyph_layout), error.CreatePipelineLayoutFailed);
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

    var gradient_binding: c.VkDescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT,
    };
    var gradient_layout_info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &gradient_binding,
    };
    var gradient_descriptor_layout: c.VkDescriptorSetLayout = undefined;
    try vk(c.vkCreateDescriptorSetLayout(device, &gradient_layout_info, null, &gradient_descriptor_layout), error.CreateDescriptorLayoutFailed);
    errdefer c.vkDestroyDescriptorSetLayout(device, gradient_descriptor_layout, null);
    var compute_set_layouts = [_]c.VkDescriptorSetLayout{ descriptor_layout, gradient_descriptor_layout, gradient_descriptor_layout, gradient_descriptor_layout };
    var push_range: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
        .offset = 0,
        .size = draw_push_size,
    };
    var pipeline_layout_info: c.VkPipelineLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .setLayoutCount = compute_set_layouts.len,
        .pSetLayouts = &compute_set_layouts,
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
        .stageFlags = c.VK_SHADER_STAGE_FRAGMENT_BIT | c.VK_SHADER_STAGE_COMPUTE_BIT,
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
        try createPresentationPipeline(device, atlas_descriptor_layout, gradient_descriptor_layout, false)
    else
        std.mem.zeroes(PresentationObjects);
    errdefer presentation.deinit(device);
    var srgb_properties: c.VkFormatProperties = undefined;
    c.vkGetPhysicalDeviceFormatProperties(selection.physical_device, c.VK_FORMAT_B8G8R8A8_SRGB, &srgb_properties);
    const srgb_required = c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | c.VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BLEND_BIT;
    const direct_presentation = if (linear_supported and srgb_properties.optimalTilingFeatures & srgb_required == srgb_required)
        try createPresentationPipeline(device, atlas_descriptor_layout, gradient_descriptor_layout, true)
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
        .gradient_descriptor_layout = gradient_descriptor_layout,
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
        .path_masks = path.MaskCache.init(allocator),
        .shadow_masks = shadow.MaskCache.init(allocator),
    };
}

pub fn deinit(self: *Renderer) void {
    _ = c.vkDeviceWaitIdle(self.device);
    self.path_masks.deinit();
    self.shadow_masks.deinit();
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
    c.vkDestroyDescriptorSetLayout(self.device, self.gradient_descriptor_layout, null);
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
    const bounds: RectI = .{ .x = 0, .y = 0, .width = target.width, .height = target.height };
    var opacity_layers = try OpacityLayers.init(self, list.commands, bounds, list.damage);
    defer opacity_layers.deinit(self);
    if (glyphs) |cache| try prepareText(list.commands, bounds, cache, shapes, paragraphs);
    var image_uploads = try ImageUploads.init(self, list.commands, images, target);
    defer image_uploads.deinit(self);
    var coverage_uploads = try CoverageUploads.init(self, list.commands, target);
    defer coverage_uploads.deinit(self);
    var gradient_uploads = try TableUpload.gradients(self, list.commands);
    defer gradient_uploads.deinit(self);
    var clip_uploads = try TableUpload.clips(self, list.commands);
    defer clip_uploads.deinit(self);
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
    };
    c.vkUpdateDescriptorSets(self.device, 1, &descriptor_writes, 0, null);

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

    opacity_layers.record(self, self.command_buffer, list.commands, glyphs, shapes, paragraphs, &image_uploads, &coverage_uploads, &gradient_uploads, &clip_uploads);
    target.command_buffer = self.command_buffer;
    const range: DrawRange = .{ .end = list.commands.len };
    switch (list.damage) {
        .full => self.renderRegion(list.commands, target, bounds, glyphs, shapes, paragraphs, &image_uploads, &coverage_uploads, &gradient_uploads, &clip_uploads, descriptor_set, &opacity_layers, range),
        .regions => |regions| for (regions) |region| {
            const clipped = RectI.intersect(region, bounds);
            if (!clipped.isEmpty()) self.renderRegion(list.commands, target, clipped, glyphs, shapes, paragraphs, &image_uploads, &coverage_uploads, &gradient_uploads, &clip_uploads, descriptor_set, &opacity_layers, range);
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
    const bounds: RectI = .{ .x = 0, .y = 0, .width = target.width, .height = target.height };
    if (glyphs) |cache| try prepareText(list.commands, bounds, cache, shapes, paragraphs);
    if (!try target.ready(self)) return error.TargetBusy;
    // A new direct slot must also build complete opacity layers, even if the
    // caller requested partial damage against a different presentation slot.
    const damage: scene.Damage = if (target.direct and target.layout == c.VK_IMAGE_LAYOUT_UNDEFINED) .full else list.damage;
    var opacity_layers = try OpacityLayers.init(self, list.commands, bounds, damage);
    errdefer opacity_layers.deinit(self);
    var image_uploads = try ImageUploads.init(self, list.commands, images, null);
    errdefer image_uploads.deinit(self);
    var coverage_uploads = try CoverageUploads.init(self, list.commands, null);
    errdefer coverage_uploads.deinit(self);
    var gradient_uploads = try TableUpload.gradients(self, list.commands);
    errdefer gradient_uploads.deinit(self);
    var clip_uploads = try TableUpload.clips(self, list.commands);
    errdefer clip_uploads.deinit(self);
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
        glyphs.?.recordUpload(target.command_buffer, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT)
    else
        false;
    opacity_layers.record(self, target.command_buffer, list.commands, glyphs, shapes, paragraphs, &image_uploads, &coverage_uploads, &gradient_uploads, &clip_uploads);
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

    // A new direct slot has no contents to preserve. The opacity proof also
    // guarantees that replaying the entire scene defines every pixel.
    switch (damage) {
        .full => self.renderPresentationRegion(list.commands, target, bounds, glyphs, shapes, paragraphs, &image_uploads, &coverage_uploads, &gradient_uploads, &clip_uploads, &opacity_layers),
        .regions => |regions| for (regions) |region| {
            const clipped = RectI.intersect(region, bounds);
            if (!clipped.isEmpty()) self.renderPresentationRegion(list.commands, target, clipped, glyphs, shapes, paragraphs, &image_uploads, &coverage_uploads, &gradient_uploads, &clip_uploads, &opacity_layers);
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
    target.coverage_uploads = coverage_uploads;
    target.gradient_uploads = gradient_uploads;
    target.clip_uploads = clip_uploads;
    target.opacity_layers = opacity_layers;
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
    coverage: *const CoverageUploads,
    gradients: *const TableUpload,
    rounded: *const TableUpload,
    layers: *const OpacityLayers,
) void {
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.presentation_pipeline_layout, 1, 1, &gradients.descriptor, 0, null);
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.presentation_pipeline_layout, 2, 1, &rounded.descriptor, 0, null);
    var clips: [max_clip_depth + 1]RectI = undefined;
    clips[0] = damage;
    var rounded_indexes: [max_clip_depth + 1]u32 = undefined;
    rounded_indexes[0] = 0;
    var depth: usize = 0;
    var indexes: DrawIndexes = .{};
    var index: usize = 0;
    while (index < commands.len) : (index += 1) {
        const command = commands[index];
        const before = indexes;
        indexes.advance(command);
        const has_gradient = commandGradient(command) != null;
        const current_gradient = if (has_gradient) indexes.gradient else 0;
        const current_clip = rounded_indexes[depth];
        c.vkCmdPushConstants(target.command_buffer, self.presentation_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, clip_push_offset, @sizeOf(u32), &current_clip);
        switch (command) {
            .push_opacity => {
                const entry = &layers.entries[before.group];
                self.drawPresentationLayer(target, clips[depth], entry);
                indexes = entry.after;
                index = entry.group.end;
            },
            .pop_opacity => unreachable,
            .clear => |color| if (!scene.occludedByNextDraw(commands[index + 1 ..], clips[0 .. depth + 1], damage))
                self.presentationFill(target, damage, color, .source),
            .push_clip_rect => |clip| {
                depth += 1;
                clips[depth] = RectI.intersect(clips[depth - 1], clip);
                rounded_indexes[depth] = rounded_indexes[depth - 1];
            },
            .push_clip_rounded => |clip| {
                depth += 1;
                clips[depth] = RectI.intersect(clips[depth - 1], clip.bounds);
                rounded_indexes[depth] = indexes.rounded;
            },
            .pop_clip => depth -= 1,
            .solid_rectangle => |rectangle| {
                const bounds = RectI.intersect(rectangle.bounds, clips[depth]);
                // Attachment clears bypass fragment coverage. Rounded-clipped
                // solids use the ordinary decorated source/erase-add path.
                if (current_clip != 0) {
                    self.presentationDecoratedRectangle(target, bounds, .{
                        .bounds = rectangle.bounds,
                        .background = rectangle.color,
                        .blend = rectangle.blend,
                    }, 0);
                } else if (!scene.occludedByNextDraw(commands[index + 1 ..], clips[0 .. depth + 1], bounds))
                    self.presentationFill(target, bounds, rectangle.color, rectangle.blend);
            },
            .decorated_rectangle => |rectangle| self.presentationDecoratedRectangle(
                target,
                RectI.intersect(rectangle.bounds, clips[depth]),
                rectangle,
                current_gradient,
            ),
            .image => |value| {
                const entry = &images.entries.items[before.image];
                self.drawPresentationImage(target, RectI.intersect(value.bounds, clips[depth]), entry.placement, &images.resources.items[entry.resource_index]);
            },
            inline .path, .shadow => |value| {
                const entry = coverage.entries.items[before.coverage];
                if (entry.resource_index) |resource_index|
                    self.drawPresentationCoverage(target, RectI.intersect(value.bounds, clips[depth]), value.color, entry.bounds, &coverage.resources.items[resource_index], current_gradient);
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
        }
    }
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
    gradient_index: u32,
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
        .has_background = @intFromBool(rectangle.background != null or gradient_index != 0),
        .has_border = @intFromBool(rectangle.border_color != null),
        .gradient_index = gradient_index,
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
        .push_clip_rect, .push_clip_rounded => {
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
    coverage: *const CoverageUploads,
    gradients: *const TableUpload,
    rounded: *const TableUpload,
    descriptor: c.VkDescriptorSet,
    layers: *const OpacityLayers,
    range: DrawRange,
) void {
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &descriptor, 0, null);
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 1, 1, &gradients.descriptor, 0, null);
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 2, 1, &rounded.descriptor, 0, null);
    c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, origin_push_offset, @sizeOf([2]i32), &target.origin);
    var clips: [max_clip_depth + 1]RectI = undefined;
    clips[0] = damage;
    var rounded_indexes: [max_clip_depth + 1]u32 = undefined;
    rounded_indexes[0] = 0;
    var depth: usize = 0;
    var indexes = range.indexes;
    var index = range.begin;
    while (index < range.end) : (index += 1) {
        const command = commands[index];
        const before = indexes;
        indexes.advance(command);
        const has_gradient = commandGradient(command) != null;
        const current_gradient = if (has_gradient) indexes.gradient else 0;
        const current_clip = rounded_indexes[depth];
        c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, clip_push_offset, @sizeOf(u32), &current_clip);
        switch (command) {
            .push_opacity => {
                const entry = &layers.entries[before.group];
                self.drawLayer(target, clips[depth], entry);
                indexes = entry.after;
                index = entry.group.end;
            },
            .pop_opacity => unreachable,
            .clear => |color| if (!scene.occludedByNextDraw(commands[index + 1 ..], clips[0 .. depth + 1], damage))
                self.fill(target, damage, color, .source),
            .push_clip_rect => |clip| {
                depth += 1;
                clips[depth] = RectI.intersect(clips[depth - 1], clip);
                rounded_indexes[depth] = rounded_indexes[depth - 1];
            },
            .push_clip_rounded => |clip| {
                depth += 1;
                clips[depth] = RectI.intersect(clips[depth - 1], clip.bounds);
                rounded_indexes[depth] = indexes.rounded;
            },
            .pop_clip => depth -= 1,
            .solid_rectangle => |rectangle| {
                const bounds = RectI.intersect(rectangle.bounds, clips[depth]);
                if (current_clip != 0 or !scene.occludedByNextDraw(commands[index + 1 ..], clips[0 .. depth + 1], bounds))
                    self.fill(target, bounds, rectangle.color, rectangle.blend);
            },
            .decorated_rectangle => |rectangle| self.decoratedRectangle(
                target,
                RectI.intersect(rectangle.bounds, clips[depth]),
                rectangle,
                current_gradient,
            ),
            .image => |value| {
                const entry = &images.entries.items[before.image];
                self.drawImage(target, RectI.intersect(value.bounds, clips[depth]), entry.placement, &images.resources.items[entry.resource_index]);
            },
            inline .path, .shadow => |value| {
                const entry = coverage.entries.items[before.coverage];
                if (entry.resource_index) |resource_index|
                    self.drawCoverage(target, RectI.intersect(value.bounds, clips[depth]), value.color, entry.bounds, &coverage.resources.items[resource_index], current_gradient);
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
        }
    }
}

fn drawLayer(self: *Renderer, target: *const Target, clip: RectI, entry: *const OpacityLayers.Entry) void {
    const bounds = RectI.intersect(clip, entry.group.bounds);
    if (bounds.isEmpty()) return;
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.glyph_pipeline);
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 3, 1, &entry.source, 0, null);
    const push: GlyphPush = .{
        .target_width = target.width,
        .atlas_width_value = entry.group.bounds.width * 8,
        .source = .{ 0, @as(u32, entry.group.opacity) << 16 },
        .left = bounds.x,
        .top = bounds.y,
        .right = @intCast(@as(i64, bounds.x) + bounds.width),
        .bottom = @intCast(@as(i64, bounds.y) + bounds.height),
        .atlas_x = @as(u32, @intCast(bounds.x - entry.group.bounds.x)) * 8,
        .atlas_y = @intCast(bounds.y - entry.group.bounds.y),
        .image_mode = 3,
    };
    c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(GlyphPush), &push);
    const count = @as(u64, bounds.width) * bounds.height;
    c.vkCmdDispatch(target.command_buffer, @intCast((count + local_size - 1) / local_size), 1, 1);
    var barrier: c.VkMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
    };
    c.vkCmdPipelineBarrier(target.command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);
}

fn drawPresentationLayer(self: *Renderer, target: *const DmabufTarget, clip: RectI, entry: *const OpacityLayers.Entry) void {
    const bounds = RectI.intersect(clip, entry.group.bounds);
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
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.presentation_glyph_pipeline_layout, 0, 1, &entry.source, 0, null);
    c.vkCmdSetViewport(target.command_buffer, 0, 1, &viewport);
    c.vkCmdSetScissor(target.command_buffer, 0, 1, &scissor);
    const push: PresentationGlyphPush = .{
        .color = .{ 0, 0, 0, @as(f32, @floatFromInt(entry.group.opacity)) / 65535 },
        .target_size = .{ @floatFromInt(target.width), @floatFromInt(target.height) },
        .bounds = .{ bounds.x, bounds.y, @intCast(@as(i64, bounds.x) + bounds.width), @intCast(@as(i64, bounds.y) + bounds.height) },
        .atlas_origin = .{ @as(u32, @intCast(bounds.x - entry.group.bounds.x)) * 8, @intCast(bounds.y - entry.group.bounds.y) },
        .atlas_width_value = entry.group.bounds.width * 8,
        .image_mode = 3,
    };
    c.vkCmdPushConstants(target.command_buffer, self.presentation_glyph_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PresentationGlyphPush), &push);
    c.vkCmdDraw(target.command_buffer, 6, 1, 0, 0);
}

fn drawCoverage(self: *Renderer, target: *const Target, clip: RectI, color: Color, mask_bounds: RectI, resource: *const CoverageUploads.Resource, gradient_index: u32) void {
    const bounds = RectI.intersect(clip, mask_bounds);
    if (bounds.isEmpty()) return;
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.glyph_pipeline);
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 3, 1, &resource.descriptor, 0, null);
    const push: GlyphPush = .{
        .target_width = target.width,
        .atlas_width_value = mask_bounds.width,
        .source = packedLinear(LinearRgba16.fromColor(color)),
        .left = bounds.x,
        .top = bounds.y,
        .right = @intCast(@as(i64, bounds.x) + bounds.width),
        .bottom = @intCast(@as(i64, bounds.y) + bounds.height),
        .atlas_x = @intCast(@as(i64, bounds.x) - mask_bounds.x),
        .atlas_y = @intCast(@as(i64, bounds.y) - mask_bounds.y),
        .gradient_index = gradient_index,
    };
    c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(GlyphPush), &push);
    const count = @as(u64, bounds.width) * bounds.height;
    c.vkCmdDispatch(target.command_buffer, @intCast((count + local_size - 1) / local_size), 1, 1);
    var barrier: c.VkMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
    };
    c.vkCmdPipelineBarrier(target.command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);
}

fn drawPresentationCoverage(self: *Renderer, target: *const DmabufTarget, clip: RectI, color: Color, mask_bounds: RectI, resource: *const CoverageUploads.Resource, gradient_index: u32) void {
    const bounds = RectI.intersect(clip, mask_bounds);
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
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.presentation_glyph_pipeline_layout, 0, 1, &resource.descriptor, 0, null);
    c.vkCmdSetViewport(target.command_buffer, 0, 1, &viewport);
    c.vkCmdSetScissor(target.command_buffer, 0, 1, &scissor);
    const push: PresentationGlyphPush = .{
        .color = normalizedColor(LinearRgba16.fromColor(color)),
        .target_size = .{ @floatFromInt(target.width), @floatFromInt(target.height) },
        .bounds = .{ bounds.x, bounds.y, @intCast(@as(i64, bounds.x) + bounds.width), @intCast(@as(i64, bounds.y) + bounds.height) },
        .atlas_origin = .{ @intCast(@as(i64, bounds.x) - mask_bounds.x), @intCast(@as(i64, bounds.y) - mask_bounds.y) },
        .atlas_width_value = mask_bounds.width,
        .gradient_index = gradient_index,
    };
    c.vkCmdPushConstants(target.command_buffer, self.presentation_glyph_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PresentationGlyphPush), &push);
    c.vkCmdDraw(target.command_buffer, 6, 1, 0, 0);
}

fn drawImage(self: *Renderer, target: *const Target, bounds: RectI, placement: ImagePlacement, image: *const ImageUploads.Resource) void {
    if (bounds.isEmpty()) return;
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.glyph_pipeline);
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 3, 1, &image.descriptor, 0, null);
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
    c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(GlyphPush), &push);
    const count = @as(u64, bounds.width) * bounds.height;
    c.vkCmdDispatch(target.command_buffer, @intCast((count + local_size - 1) / local_size), 1, 1);
    var barrier: c.VkMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
    };
    c.vkCmdPipelineBarrier(target.command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);
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
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
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
    c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(Push), &push);
    const count = @as(u64, bounds.width) * bounds.height;
    c.vkCmdDispatch(target.command_buffer, @intCast((count + local_size - 1) / local_size), 1, 1);
    var barrier: c.VkMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
    };
    c.vkCmdPipelineBarrier(
        target.command_buffer,
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
    gradient_index: u32,
) void {
    if (clipped_bounds.isEmpty()) return;
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
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
        .flags = @as(u32, @intFromBool(rectangle.background != null or gradient_index != 0)) |
            (@as(u32, @intFromBool(rectangle.border_color != null)) << 1),
        .source_over = @intFromBool(rectangle.blend == .source_over),
        .gradient_index = gradient_index,
    };
    c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(Push), &push);
    const count = @as(u64, clipped_bounds.width) * clipped_bounds.height;
    c.vkCmdDispatch(target.command_buffer, @intCast((count + local_size - 1) / local_size), 1, 1);
    var barrier: c.VkMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
    };
    c.vkCmdPipelineBarrier(
        target.command_buffer,
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
    bounds: RectI,
    glyphs: *GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
) !void {
    if (!has_freetype) return error.FreeTypeDisabled;
    prepareTextPass(commands, bounds, glyphs, shapes, paragraphs) catch |err| {
        if (err != error.GlyphAtlasFull) return err;
        // Discard old frames' phases and pack just this frame once. A frame
        // exceeding the fixed budget fails before recording/uploading, rather
        // than evicting masks already referenced by this frame's draws.
        try glyphs.reset();
        try prepareTextPass(commands, bounds, glyphs, shapes, paragraphs);
    };
}

fn prepareTextPass(
    commands: []const scene.Command,
    bounds: RectI,
    glyphs: *GlyphCache,
    shapes: ?*const text.ShapeCache,
    paragraphs: ?*const text.ParagraphCache,
) !void {
    // Use the full target, not damage: opacity layers render their complete
    // cropped bounds. Rounded clips use conservative rectangular bounds.
    var clips: [max_clip_depth + 1]RectI = undefined;
    clips[0] = bounds;
    var depth: usize = 0;
    for (commands) |command| switch (command) {
        .push_clip_rect, .push_clip_rounded => {
            const clip = if (command == .push_clip_rect) command.push_clip_rect else command.push_clip_rounded.bounds;
            clips[depth + 1] = RectI.intersect(clips[depth], clip);
            depth += 1;
        },
        .pop_clip => depth -= 1,
        .glyph_run => |run| {
            const shaped = try (shapes orelse return error.TextResourcesRequired).get(run.shape);
            if (clips[depth].isEmpty()) continue;
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
            if (clips[depth].isEmpty()) continue;
            for (layout.positioned.lines) |line| {
                const baseline = value.origin.y + (line.top + line.baseline) * value.scale;
                for (layout.positioned.spansFor(line)) |span| for (layout.positioned.glyphsFor(span)) |glyph| {
                    const position = GlyphPosition.init(value.origin.x + (line.left + glyph.origin.x) * value.scale, baseline + glyph.origin.y * value.scale);
                    _ = try glyphs.get(span.font, glyph.id, (span.logical_size orelse layout.logical_size) * value.scale, position.phase);
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
    if (clip.isEmpty()) return;
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 3, 1, &cache.descriptor_set, 0, null);
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
            c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.glyph_pipeline);
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
            c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(GlyphPush), &push);
            const count = @as(u64, bounds.width) * bounds.height;
            c.vkCmdDispatch(target.command_buffer, @intCast((count + local_size - 1) / local_size), 1, 1);
            var barrier: c.VkMemoryBarrier = .{
                .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                .pNext = null,
                .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
                .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
            };
            c.vkCmdPipelineBarrier(target.command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);
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
    if (clip.isEmpty()) return;
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
    if (clip.isEmpty()) return;
    const layout = paragraphs.get(command.layout) catch unreachable;
    for (layout.positioned.lines) |line| {
        const baseline = command.origin.y + (line.top + line.baseline) * command.scale;
        for (layout.positioned.spansFor(line)) |span| for (layout.positioned.glyphsFor(span)) |glyph| {
            const color = LinearRgba16.fromColor(span.color orelse command.color);
            const position = GlyphPosition.init(command.origin.x + (line.left + glyph.origin.x) * command.scale, baseline + glyph.origin.y * command.scale);
            const atlas = cache.prepared(span.font, glyph.id, (span.logical_size orelse layout.logical_size) * command.scale, position.phase);
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
    try std.testing.expectError(error.ClipStackOverflow, (scene.DisplayList{ .commands = &commands }).validate());
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
    if (clip.isEmpty()) return;
    c.vkCmdBindDescriptorSets(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 3, 1, &cache.descriptor_set, 0, null);
    const layout = paragraphs.get(command.layout) catch unreachable;
    for (layout.positioned.lines) |line| {
        const baseline = command.origin.y + (line.top + line.baseline) * command.scale;
        for (layout.positioned.spansFor(line)) |span| for (layout.positioned.glyphsFor(span)) |glyph| {
            const source = packedLinear(LinearRgba16.fromColor(span.color orelse command.color));
            const position = GlyphPosition.init(command.origin.x + (line.left + glyph.origin.x) * command.scale, baseline + glyph.origin.y * command.scale);
            const atlas = cache.prepared(span.font, glyph.id, (span.logical_size orelse layout.logical_size) * command.scale, position.phase);
            const glyph_bounds: RectI = .{
                .x = position.x + atlas.left,
                .y = position.y - atlas.top,
                .width = atlas.width,
                .height = atlas.height,
            };
            const bounds = RectI.intersect(clip, glyph_bounds);
            if (!bounds.isEmpty()) {
                c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.glyph_pipeline);
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
                c.vkCmdPushConstants(target.command_buffer, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(GlyphPush), &push);
                const count = @as(u64, bounds.width) * bounds.height;
                c.vkCmdDispatch(target.command_buffer, @intCast((count + local_size - 1) / local_size), 1, 1);
                var barrier: c.VkMemoryBarrier = .{
                    .sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER,
                    .pNext = null,
                    .srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT,
                    .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT,
                };
                c.vkCmdPipelineBarrier(target.command_buffer, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &barrier, 0, null, 0, null);
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
        // Both clips are nonempty, but their intersection is empty. A
        // distinct scale must not enter the atlas, including inside opacity.
        .{ .push_clip_rounded = .{ .bounds = .{ .x = 150, .y = 3, .width = 10, .height = 30 }, .corner_radius = 2 } },
        .{ .push_opacity = 32768 },
        .{ .glyph_run = .{ .shape = shape, .origin = .{ .x = 0, .y = 25 }, .scale = 2, .color = Color.rgba(255, 0, 0, 255) } },
        .pop_opacity,
        .pop_clip,
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
    try std.testing.expect(!glyphs.entries.contains(try AtlasKey.init(font, (try fonts.get(font)).nominalGlyph('W').?, 36.5, .{})));
    const count = glyphs.entries.count();
    try prepareText(list.commands, .{ .x = 0, .y = 0, .width = 160, .height = 36 }, &glyphs, &shapes, null);
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
    oversized[7].glyph_run.scale = 20;
    try std.testing.expectError(error.GlyphAtlasFull, renderer.renderText(.{ .commands = &oversized }, &target, &glyphs, &shapes));
    try target.readPixels(&actual, 160 * 4, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    try renderer.renderText(list, &target, &glyphs, &shapes);
    try target.readPixels(&actual, 160 * 4, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);

    // A8 path descriptors must restore the atlas before text; rebinding text's
    // set 0 must in turn preserve the gradient table used by the next solid.
    const triangle = try path.Path.create(std.testing.allocator, &.{
        .{ .move = .{} }, .{ .line = .{ .x = 8 } }, .{ .line = .{ .x = 4, .y = 3 } }, .close,
    }, .{ .fill = .nonzero });
    defer triangle.release();
    const gradient = try paint.LinearGradient.init(.{ .x = 8 }, .{ .x = 32 }, &.{
        .{ .offset = 0, .color = Color.rgba(240, 80, 10, 255) },
        .{ .offset = 1, .color = Color.rgba(20, 80, 230, 180) },
    });
    const mixed = [_]scene.Command{
        commands[0],
        commands[1],
        .{ .path = .{ .path = triangle, .identity = triangle.identity, .origin = .{ .x = 8, .y = 30 }, .scale = 1, .bounds = try path.deviceBounds(triangle, .{ .x = 8, .y = 30 }, 1), .color = Color.rgba(0, 0, 0, 0), .gradient = gradient } },
        commands[7],
        .{ .decorated_rectangle = .{ .bounds = .{ .x = 24, .y = 30, .width = 8, .height = 3 }, .background_gradient = gradient } },
        .pop_clip,
    };
    const mixed_list: scene.DisplayList = .{ .commands = &mixed };
    try software.renderText(mixed_list, .{ .pixels = &expected, .width = 160, .height = 36, .stride = 160 * 4, .format = .rgba8_unorm }, &software_glyphs, &shapes);
    try renderer.renderText(mixed_list, &target, &glyphs, &shapes);
    try target.readPixels(&actual, 160 * 4, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    for ([_]*GraphicsReadback{ &graphics, &direct_graphics }) |output| {
        try renderer.renderGraphicsResources(mixed_list, &output.target, &glyphs, &shapes, null, null, false);
        try output.target.wait(&renderer);
        for (0..36) |y| for (0..160) |x|
            try output.expectPixel(x, y, expected[(y * 160 + x) * 4 ..][0..4].*);
    }
    var clipped: [mixed.len + 2]scene.Command = undefined;
    clipped[0] = mixed[0];
    clipped[1] = .{ .push_clip_rounded = .{ .bounds = .{ .x = 8, .y = 3, .width = 134, .height = 30 }, .corner_radius = 14 } };
    @memcpy(clipped[2 .. clipped.len - 1], mixed[1..]);
    clipped[clipped.len - 1] = .pop_clip;
    const clipped_list: scene.DisplayList = .{ .commands = &clipped };
    try software.renderText(clipped_list, .{ .pixels = &expected, .width = 160, .height = 36, .stride = 640, .format = .rgba8_unorm }, &software_glyphs, &shapes);
    try renderer.renderText(clipped_list, &target, &glyphs, &shapes);
    try target.readPixels(&actual, 640, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    for ([_]*GraphicsReadback{ &graphics, &direct_graphics }) |output| {
        try renderer.renderGraphicsResources(clipped_list, &output.target, &glyphs, &shapes, null, null, false);
        try output.target.wait(&renderer);
        for (0..36) |y| for (0..160) |x|
            try output.expectPixel(x, y, expected[(y * 160 + x) * 4 ..][0..4].*);
    }
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
        .{ .push_clip_rect = .{ .x = 0, .y = 72, .width = 160, .height = 10 } },
        .{ .paragraph = .{ .layout = layout, .origin = .{ .x = 0, .y = 72 }, .scale = 2, .color = Color.rgba(255, 0, 0, 255) } },
        .pop_clip,
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
    var entries = glyphs.entries.keyIterator();
    while (entries.next()) |key| try std.testing.expect(key.size_26_6 != 1824); // 14.25 * 2 * 64
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
    var clipped = [_]scene.Command{
        commands[0],
        .{ .push_clip_rounded = .{ .bounds = .{ .x = 5, .y = 1, .width = 120, .height = 60 }, .corner_radius = 25 } },
        commands[4],
        commands[5],
        .pop_clip,
        .pop_clip,
    };
    const clipped_list: scene.DisplayList = .{ .commands = &clipped };
    for ([_]*GraphicsReadback{ &graphics, &direct }, 0..) |output, index| {
        clipped[0].clear = Color.rgba(20, 30, 40, if (index == 0) 0 else 255);
        try software.renderParagraphs(clipped_list, .{ .pixels = &expected, .width = 160, .height = 72, .stride = 640, .format = .rgba8_unorm }, &software_glyphs, &paragraphs);
        try renderer.renderParagraphs(clipped_list, &target, &glyphs, &paragraphs);
        try target.readPixels(&actual, 640, .rgba8_unorm);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        try renderer.renderGraphicsResources(clipped_list, &output.target, &glyphs, null, &paragraphs, null, false);
        try output.target.wait(&renderer);
        for (0..72) |y| for (0..160) |x|
            try output.expectPixel(x, y, expected[(y * 160 + x) * 4 ..][0..4].*);
    }
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
    var gradients = try TableUpload.gradients(&renderer, &commands);
    defer gradients.deinit(&renderer);
    var rounded = try TableUpload.clips(&renderer, &commands);
    defer rounded.deinit(&renderer);
    renderer.renderPresentationRegion(&commands, &target, .{ .x = 0, .y = 0, .width = 32, .height = 12 }, null, null, null, &uploads, &.{}, &gradients, &rounded, &.{});
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

test "Vulkan path uploads pad A8 words and copy borrowed bytes" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var target = try Target.init(&renderer, 2, 1);
    defer target.deinit(&renderer);
    for ([_]?*const Target{ &target, null }) |destination| {
        var mask = [_]u8{ 9, 127, 255, 42, 0, 89, 213, 11, 73, 96, 254, 1, 33, 160, 220 };
        var resource = try CoverageUploads.upload(&renderer, &mask, 16, destination);
        defer {
            c.vkDestroyDescriptorPool(renderer.device, resource.pool, null);
            resource.pixels.deinit(&renderer);
        }
        const bytes = @as([*]const u8, @ptrCast(resource.pixels.mapping))[0..16];
        try std.testing.expectEqualSlices(u8, &mask, bytes[0..15]);
        try std.testing.expectEqual(@as(u8, 0), bytes[15]);
        @memset(&mask, 0);
        try std.testing.expectEqual(@as(u8, 9), bytes[0]);
        try std.testing.expectEqual(@as(u8, 220), bytes[14]);
    }
}

test "Vulkan path uploads deduplicate translations and clean up allocation failures" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const geometry = try path.Path.create(std.testing.allocator, &.{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .line = .{ .x = 3, .y = 0 } },
        .{ .line = .{ .x = 3, .y = 5 } },
        .{ .line = .{ .x = 0, .y = 5 } },
        .close,
    }, .{ .fill = .nonzero });
    defer geometry.release();
    var commands: [64]scene.Command = undefined;
    for (&commands, 0..) |*command, index| {
        const origin: @import("../../core/geometry.zig").PointF = .{ .x = @as(f32, @floatFromInt(index)) - 19, .y = 2 };
        command.* = .{ .path = .{
            .path = geometry,
            .identity = geometry.identity,
            .origin = origin,
            .scale = 1,
            .bounds = try path.deviceBounds(geometry, origin, 1),
            .color = Color.rgba(@intCast(index), 80, 150, 190),
        } };
    }
    // The translated/tinted commands use the same raster. A changed phase and
    // scale must not alias that upload, even though the identity is unchanged.
    commands[1].path.origin.x += 0.25;
    commands[1].path.bounds = try path.deviceBounds(geometry, commands[1].path.origin, 1);
    commands[2].path.scale = 1.5;
    commands[2].path.bounds = try path.deviceBounds(geometry, commands[2].path.origin, 1.5);
    var target = try Target.init(&renderer, 2, 1);
    defer target.deinit(&renderer);
    const original_limit = renderer.max_image_pixels;
    for ([_]?*const Target{ &target, null }) |destination| {
        var uploads = try CoverageUploads.init(&renderer, &commands, destination);
        try std.testing.expectEqual(@as(usize, 3), uploads.resources.items.len);
        try std.testing.expectEqual(commands.len, uploads.entries.items.len);
        try std.testing.expectEqual(uploads.entries.items[0].resource_index, uploads.entries.items[63].resource_index);
        try std.testing.expectEqual(@as(i32, 63), uploads.entries.items[63].bounds.x - uploads.entries.items[0].bounds.x);
        const budget = uploads.byte_size;
        uploads.deinit(&renderer);
        try std.testing.expectEqual(@as(usize, 0), uploads.resources.items.len);
        renderer.max_image_pixels = budget / 4 - 1;
        try std.testing.expectError(error.CoverageUploadBudgetExceeded, CoverageUploads.init(&renderer, &commands, destination));
        renderer.max_image_pixels += 1;
        uploads = try CoverageUploads.init(&renderer, &commands, destination);
        try std.testing.expectEqual(budget, uploads.byte_size);
        uploads.deinit(&renderer);
        renderer.max_image_pixels = original_limit;
        try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
            fn check(allocator: std.mem.Allocator, r: *Renderer, batch: []const scene.Command, output: ?*const Target) !void {
                const original = r.allocator;
                r.allocator = allocator;
                defer r.allocator = original;
                var copies = try CoverageUploads.init(r, batch, output);
                defer copies.deinit(r);
            }
        }.check, .{ &renderer, @as([]const scene.Command, &commands), destination });
    }
}

test "Vulkan paths preserve targets on preflight failure and outlive native masks" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const geometry = try path.Path.create(std.testing.allocator, &.{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .line = .{ .x = 5, .y = 1 } },
        .{ .line = .{ .x = 2, .y = 7 } },
        .close,
    }, .{ .fill = .nonzero });
    var native_live = true;
    defer if (native_live) geometry.release();
    const empty = try path.Path.create(std.testing.allocator, &.{}, .{ .fill = .nonzero });
    defer if (native_live) empty.release();
    const origin: @import("../../core/geometry.zig").PointF = .{ .x = -1.25, .y = -0.5 };
    const second_origin: @import("../../core/geometry.zig").PointF = .{ .x = 7.75, .y = 2.5 };
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(32, 64, 96, 255) },
        .{ .push_clip_rect = .{ .x = 0, .y = 1, .width = 12, .height = 8 } },
        .{ .path = .{ .path = geometry, .identity = geometry.identity, .origin = origin, .scale = 1, .bounds = try path.deviceBounds(geometry, origin, 1), .color = Color.rgba(230, 60, 100, 180) } },
        .{ .path = .{ .path = empty, .identity = empty.identity, .origin = origin, .scale = 1, .bounds = try path.deviceBounds(empty, origin, 1), .color = Color.rgba(255, 255, 255, 255) } },
        .{ .path = .{ .path = geometry, .identity = geometry.identity, .origin = second_origin, .scale = 1, .bounds = try path.deviceBounds(geometry, second_origin, 1), .color = Color.rgba(30, 220, 90, 150) } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 4, .y = 2, .width = 3, .height = 2 }, .color = Color.rgba(180, 100, 220, 120) } },
        .pop_clip,
    };
    // Two regions replay every command; the empty path must keep its slot.
    const list: scene.DisplayList = .{ .commands = &commands, .damage = .{ .regions = &.{
        .{ .x = 0, .y = 0, .width = 6, .height = 10 },
        .{ .x = 6, .y = 0, .width = 8, .height = 10 },
    } } };
    var expected: [14 * 10 * 4]u8 = undefined;
    try @import("../software/root.zig").render(list, .{ .pixels = &expected, .width = 14, .height = 10, .stride = 14 * 4, .format = .rgba8_unorm });
    var target = try Target.init(&renderer, 14, 10);
    defer target.deinit(&renderer);
    try renderer.render(list, &target);
    var actual: [expected.len]u8 = undefined;
    try target.readPixels(&actual, 14 * 4, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    var linear = try GraphicsReadback.init(&renderer, 14, 10);
    defer linear.deinit(&renderer);
    var direct = try GraphicsReadback.initMode(&renderer, 14, 10, null, true);
    defer direct.deinit(&renderer);
    const original_limit = renderer.max_image_pixels;
    renderer.max_image_pixels = 1;
    try std.testing.expectError(error.CoverageUploadBudgetExceeded, renderer.render(list, &target));
    try target.readPixels(&actual, 14 * 4, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    for ([_]*DmabufTarget{ &linear.target, &direct.target }) |output| {
        try std.testing.expectError(error.CoverageUploadBudgetExceeded, renderer.renderGraphicsResources(list, output, null, null, null, null, false));
        try std.testing.expect(!output.gpu_pending);
        try std.testing.expectEqual(@as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_UNDEFINED), output.layout);
        if (output.linear) |attachment| try std.testing.expect(!attachment.initialized);
    }
    renderer.max_image_pixels = original_limit;
    try renderer.renderGraphicsResources(list, &direct.target, null, null, null, null, false);
    try direct.target.wait(&renderer);
    // An initialized direct target honors both damage regions instead of
    // replacing them with the first-frame full repaint.
    try renderer.renderGraphicsResources(list, &direct.target, null, null, null, null, false);
    commands[0].clear.a = 0;
    var transparent: [expected.len]u8 = undefined;
    try @import("../software/root.zig").render(list, .{ .pixels = &transparent, .width = 14, .height = 10, .stride = 14 * 4, .format = .rgba8_unorm });
    try renderer.renderGraphicsResources(list, &linear.target, null, null, null, null, false);
    for ([_]*DmabufTarget{ &linear.target, &direct.target }) |output| {
        try std.testing.expect(output.gpu_pending);
        try std.testing.expectEqual(@as(usize, 3), output.coverage_uploads.entries.items.len);
        try std.testing.expectEqual(@as(usize, 1), output.coverage_uploads.resources.items.len);
        try std.testing.expectEqual(@as(?usize, null), output.coverage_uploads.entries.items[1].resource_index);
    }
    // Neither geometry nor borrowed CPU pixels survive to fence completion.
    geometry.release();
    empty.release();
    native_live = false;
    renderer.path_masks.deinit();
    renderer.path_masks = path.MaskCache.init(std.testing.allocator);
    try linear.target.wait(&renderer);
    try vk(c.vkWaitForFences(renderer.device, 1, &direct.target.fence, c.VK_TRUE, std.math.maxInt(u64)), error.DeviceLost);
    try std.testing.expect(try direct.target.ready(&renderer));
    try std.testing.expectEqual(@as(usize, 0), linear.target.coverage_uploads.resources.items.len);
    try std.testing.expectEqual(@as(usize, 0), direct.target.coverage_uploads.resources.items.len);
    for (0..10) |y| for (0..14) |x| {
        const pixel = expected[(y * 14 + x) * 4 ..][0..4].*;
        try linear.expectPixel(x, y, transparent[(y * 14 + x) * 4 ..][0..4].*);
        try direct.expectPixel(x, y, pixel);
    };
}

test "Vulkan shadow and path uploads deduplicate within one shared budget" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const geometry = try path.Path.create(std.testing.allocator, &.{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .line = .{ .x = 6, .y = 1 } },
        .{ .line = .{ .x = 2, .y = 4 } },
        .close,
    }, .{ .fill = .nonzero });
    defer geometry.release();
    const shape: shadow.Shape = .{ .box = .{ .x = 7, .y = 4, .width = 9, .height = 5 }, .corner_radius = 2, .offset = .{ .x = -1.25, .y = 2.5 }, .blur = 2, .spread = 0.5 };
    var translated = shape;
    translated.box.x -= 11;
    translated.box.y += 3;
    const empty: shadow.Shape = .{ .box = .{ .x = 0, .y = 0, .width = 0, .height = 5 }, .blur = 2 };
    const path_bounds = try path.deviceBounds(geometry, .{}, 1);
    const shadow_bounds = try shadow.deviceBounds(shape);
    const commands = [_]scene.Command{
        .{ .path = .{ .path = geometry, .identity = geometry.identity, .origin = .{}, .scale = 1, .bounds = path_bounds, .color = Color.rgba(120, 40, 70, 180) } },
        .{ .shadow = .{ .shape = shape, .bounds = shadow_bounds, .color = Color.rgba(0, 0, 0, 150) } },
        .{ .path = .{ .path = geometry, .identity = geometry.identity, .origin = .{ .x = 12 }, .scale = 1, .bounds = try path.deviceBounds(geometry, .{ .x = 12 }, 1), .color = Color.rgba(20, 190, 130, 140) } },
        .{ .shadow = .{ .shape = translated, .bounds = try shadow.deviceBounds(translated), .color = Color.rgba(240, 130, 10, 100) } },
        .{ .shadow = .{ .shape = empty, .bounds = try shadow.deviceBounds(empty), .color = Color.rgba(255, 255, 255, 255) } },
    };
    // Derive the budget from raster extents, not the upload accounting under test.
    const path_bytes = (@as(u64, path_bounds.width) * path_bounds.height + 3) / 4 * 4;
    const shadow_bytes = (@as(u64, shadow_bounds.width) * shadow_bounds.height + 3) / 4 * 4;
    const budget = path_bytes + shadow_bytes;
    var target = try Target.init(&renderer, 1, 1);
    defer target.deinit(&renderer);
    const original_limit = renderer.max_image_pixels;
    for ([_]?*const Target{ &target, null }) |destination| {
        renderer.max_image_pixels = budget / 4 - 1;
        // Each mask fits alone; splitting budgets by kind would wrongly pass.
        try std.testing.expect(@max(path_bytes, shadow_bytes) <= renderer.max_image_pixels * 4);
        try std.testing.expectError(error.CoverageUploadBudgetExceeded, CoverageUploads.init(&renderer, &commands, destination));
        renderer.max_image_pixels += 1;
        var uploads = try CoverageUploads.init(&renderer, &commands, destination);
        try std.testing.expectEqual(budget, uploads.byte_size);
        try std.testing.expectEqual(@as(usize, 2), uploads.resources.items.len);
        try std.testing.expectEqual(commands.len, uploads.entries.items.len);
        for (uploads.entries.items, [_]?usize{ 0, 1, 0, 1, null }) |entry, expected|
            try std.testing.expectEqual(expected, entry.resource_index);
        try std.testing.expectEqual(@as(i32, 12), uploads.entries.items[2].bounds.x - uploads.entries.items[0].bounds.x);
        try std.testing.expectEqual(@as(i32, -11), uploads.entries.items[3].bounds.x - uploads.entries.items[1].bounds.x);
        try std.testing.expectEqual(@as(i32, 3), uploads.entries.items[3].bounds.y - uploads.entries.items[1].bounds.y);
        uploads.deinit(&renderer);
        renderer.max_image_pixels = original_limit;
        try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
            fn check(allocator: std.mem.Allocator, r: *Renderer, batch: []const scene.Command, output: ?*const Target) !void {
                const original = r.allocator;
                r.allocator = allocator;
                defer r.allocator = original;
                var copies = try CoverageUploads.init(r, batch, output);
                defer copies.deinit(r);
            }
        }.check, .{ &renderer, @as([]const scene.Command, &commands), destination });
    }
}

test "Vulkan shadows interleave with paths and outlive CPU caches on both graphics targets" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const geometry = try path.Path.create(std.testing.allocator, &.{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .line = .{ .x = 29, .y = 10 } },
        .{ .line = .{ .x = 3, .y = 23 } },
        .close,
    }, .{ .fill = .nonzero });
    var native_live = true;
    defer if (native_live) geometry.release();
    const blurred: shadow.Shape = .{ .box = .{ .x = 5, .y = 6, .width = 14, .height = 10 }, .corner_radius = 3, .offset = .{ .x = -2.25, .y = 2.5 }, .blur = 4, .spread = 1.25 };
    const sharp: shadow.Shape = .{ .box = .{ .x = 31, .y = 7, .width = 8, .height = 6 }, .offset = .{ .x = -3, .y = 2 } };
    const empty: shadow.Shape = .{ .box = .{ .x = 0, .y = 0, .width = 0, .height = 3 }, .blur = 4 };
    const origin: @import("../../core/geometry.zig").PointF = .{ .x = 0.5, .y = 1.25 };
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(36, 50, 90, 255) },
        .{ .push_clip_rect = .{ .x = 2, .y = 1, .width = 42, .height = 28 } },
        .{ .shadow = .{ .shape = blurred, .bounds = try shadow.deviceBounds(blurred), .color = Color.rgba(240, 80, 50, 150) } },
        .{ .path = .{ .path = geometry, .identity = geometry.identity, .origin = origin, .scale = 1, .bounds = try path.deviceBounds(geometry, origin, 1), .color = Color.rgba(40, 210, 90, 170) } },
        .{ .shadow = .{ .shape = empty, .bounds = try shadow.deviceBounds(empty), .color = Color.rgba(255, 255, 255, 255) } },
        .{ .shadow = .{ .shape = blurred, .bounds = try shadow.deviceBounds(blurred), .color = Color.rgba(50, 100, 240, 110) } },
        .{ .shadow = .{ .shape = sharp, .bounds = try shadow.deviceBounds(sharp), .color = Color.rgba(230, 150, 40, 160) } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 32, .y = 8, .width = 5, .height = 3 }, .color = Color.rgba(170, 80, 200, 160) } },
        .pop_clip,
    };
    const list: scene.DisplayList = .{ .commands = &commands, .damage = .{ .regions = &.{
        .{ .x = 0, .y = 0, .width = 13, .height = 32 },
        .{ .x = 13, .y = 0, .width = 35, .height = 32 },
    } } };
    var expected: [48 * 32 * 4]u8 = undefined;
    const software = @import("../software/root.zig");
    try software.render(list, .{ .pixels = &expected, .width = 48, .height = 32, .stride = 48 * 4, .format = .rgba8_unorm });
    var reversed: [expected.len]u8 = undefined;
    std.mem.swap(scene.Command, &commands[2], &commands[3]);
    try software.render(list, .{ .pixels = &reversed, .width = 48, .height = 32, .stride = 48 * 4, .format = .rgba8_unorm });
    try std.testing.expect(!std.mem.eql(u8, &expected, &reversed));
    std.mem.swap(scene.Command, &commands[2], &commands[3]);
    var target = try Target.init(&renderer, 48, 32);
    defer target.deinit(&renderer);
    try renderer.render(list, &target);
    var actual: [expected.len]u8 = undefined;
    try target.readPixels(&actual, 48 * 4, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    var direct = try GraphicsReadback.initMode(&renderer, 48, 32, null, true);
    defer direct.deinit(&renderer);
    // Direct sRGB8 quantizes after every draw, and hardware conversion can
    // accumulate more than one byte of drift across draws. Check each added
    // draw against software over the previous observed destination instead of
    // widening the one-byte tolerance, then check damage replay exactly.
    var encoded_steps: [expected.len]u8 = undefined;
    const encoded_target: software.Target = .{ .pixels = &encoded_steps, .width = 48, .height = 32, .stride = 48 * 4, .format = .rgba8_unorm };
    try software.render(.{ .commands = commands[0..1] }, encoded_target);
    for (commands[2 .. commands.len - 1], 2..) |command, index| {
        const batch = [_]scene.Command{ commands[1], command, .pop_clip };
        try software.render(.{ .commands = &batch }, encoded_target);
        var prefix: [commands.len]scene.Command = undefined;
        @memcpy(prefix[0 .. index + 1], commands[0 .. index + 1]);
        prefix[index + 1] = .pop_clip;
        try renderer.renderGraphicsResources(.{ .commands = prefix[0 .. index + 2] }, &direct.target, null, null, null, null, false);
        try direct.target.wait(&renderer);
        for (0..32) |y| for (0..48) |x| {
            const pixel = encoded_steps[(y * 48 + x) * 4 ..][0..4];
            try direct.expectPixel(x, y, pixel.*);
            pixel.* = direct.pixel(x, y);
        };
    }
    try renderer.renderGraphicsResources(list, &direct.target, null, null, null, null, false);
    commands[0].clear.a = 0;
    var transparent: [expected.len]u8 = undefined;
    try software.render(list, .{ .pixels = &transparent, .width = 48, .height = 32, .stride = 48 * 4, .format = .rgba8_unorm });
    try renderer.render(list, &target);
    try target.readPixels(&actual, 48 * 4, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &transparent, &actual);
    var linear = try GraphicsReadback.init(&renderer, 48, 32);
    defer linear.deinit(&renderer);
    try renderer.renderGraphicsResources(list, &linear.target, null, null, null, null, false);
    for ([_]*DmabufTarget{ &linear.target, &direct.target }) |output| {
        try std.testing.expect(output.gpu_pending);
        try std.testing.expectEqual(@as(usize, 5), output.coverage_uploads.entries.items.len);
        try std.testing.expectEqual(@as(usize, 3), output.coverage_uploads.resources.items.len);
        for (output.coverage_uploads.entries.items, [_]?usize{ 0, 1, null, 0, 2 }) |entry, expected_index|
            try std.testing.expectEqual(expected_index, entry.resource_index);
    }
    geometry.release();
    native_live = false;
    renderer.path_masks.deinit();
    renderer.path_masks = path.MaskCache.init(std.testing.allocator);
    renderer.shadow_masks.deinit();
    renderer.shadow_masks = shadow.MaskCache.init(std.testing.allocator);
    try linear.target.wait(&renderer);
    try vk(c.vkWaitForFences(renderer.device, 1, &direct.target.fence, c.VK_TRUE, std.math.maxInt(u64)), error.DeviceLost);
    try std.testing.expect(try direct.target.ready(&renderer));
    try std.testing.expectEqual(@as(usize, 0), linear.target.coverage_uploads.resources.items.len);
    try std.testing.expectEqual(@as(usize, 0), direct.target.coverage_uploads.resources.items.len);
    for (0..32) |y| for (0..48) |x| {
        try linear.expectPixel(x, y, transparent[(y * 48 + x) * 4 ..][0..4].*);
        try std.testing.expectEqual(encoded_steps[(y * 48 + x) * 4 ..][0..4].*, direct.pixel(x, y));
    };
}

test "Vulkan gradient tables copy prepared stops and enforce budgets before target changes" {
    try std.testing.expectEqual(@as(usize, 160), @sizeOf(GradientRecord));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(GradientRecord, "direction"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(GradientRecord, "count"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(GradientRecord, "stops"));
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const gradient = try paint.LinearGradient.init(.{ .x = -2 }, .{ .x = 6 }, &.{
        .{ .offset = 0, .color = Color.rgba(255, 0, 0, 255) },
        .{ .offset = 1, .color = Color.rgba(0, 255, 0, 128) },
    });
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(11, 22, 33, 255) },
        .{ .decorated_rectangle = .{ .bounds = .{ .x = 0, .y = 0, .width = 4, .height = 2 }, .background_gradient = gradient } },
        .{ .decorated_rectangle = .{ .bounds = .{ .x = 0, .y = 0, .width = 4, .height = 2 }, .background_gradient = gradient } },
    };
    var uploads = try TableUpload.gradients(&renderer, &commands);
    defer uploads.deinit(&renderer);
    const records = @as([*]const GradientRecord, @ptrCast(@alignCast(uploads.pixels.?.mapping)))[0..2];
    try std.testing.expectEqual(@as(u64, 320), uploads.pixels.?.byte_size);
    try std.testing.expectEqual([2]f32{ -2, 0 }, records[0].start);
    try std.testing.expectEqual([2]f32{ 0.125, 0 }, records[0].direction);
    try std.testing.expectEqual([4]u32{ 0, 65535, 0xffff0000, 0 }, records[0].stops[0]);
    try std.testing.expectEqual([4]u32{ 65535, 0x80800000, 0x80800000, 0 }, records[1].stops[1]);
    try std.testing.expectEqual([4]u32{ 0, 0, 0, 0 }, records[1].stops[7]);
    commands[1].decorated_rectangle.background_gradient.?.stops[0].color = Color.rgba(0, 0, 255, 0);
    try std.testing.expectEqual(@as(u32, 65535), records[0].stops[0][1]);
    commands[1].decorated_rectangle.background_gradient = gradient;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator, r: *Renderer, batch: []const scene.Command) !void {
            const original = r.allocator;
            r.allocator = allocator;
            defer r.allocator = original;
            var copies = try TableUpload.gradients(r, batch);
            defer copies.deinit(r);
        }
    }.check, .{ &renderer, @as([]const scene.Command, &commands) });
    var target = try Target.init(&renderer, 4, 2);
    defer target.deinit(&renderer);
    try renderer.render(.{ .commands = commands[0..1] }, &target);
    var before: [32]u8 = undefined;
    try target.readPixels(&before, 16, .rgba8_unorm);
    var linear = try GraphicsReadback.init(&renderer, 4, 2);
    defer linear.deinit(&renderer);
    var direct = try GraphicsReadback.initMode(&renderer, 4, 2, null, true);
    defer direct.deinit(&renderer);
    const original_limit = renderer.max_image_pixels;
    renderer.max_image_pixels = 79; // One word below two 160-byte records.
    try std.testing.expectError(error.GradientUploadBudgetExceeded, renderer.render(.{ .commands = &commands }, &target));
    var after: [32]u8 = undefined;
    try target.readPixels(&after, 16, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &before, &after);
    for ([_]*DmabufTarget{ &linear.target, &direct.target }) |output| {
        try std.testing.expectError(error.GradientUploadBudgetExceeded, renderer.renderGraphicsResources(.{ .commands = &commands }, output, null, null, null, null, false));
        try std.testing.expect(!output.gpu_pending);
        try std.testing.expectEqual(@as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_UNDEFINED), output.layout);
        try std.testing.expect(output.gradient_uploads.pixels == null);
        if (output.linear) |attachment| try std.testing.expect(!attachment.initialized);
    }
    renderer.max_image_pixels = 80;
    var exact = try TableUpload.gradients(&renderer, &commands);
    exact.deinit(&renderer);
    renderer.max_image_pixels = original_limit;
    commands[2].decorated_rectangle.background_gradient.?.count = 9;
    try std.testing.expectError(error.InvalidGradient, renderer.render(.{ .commands = &commands }, &target));
    try target.readPixels(&after, 16, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &before, &after);
}

test "Vulkan gradients sample exact linear16 stops ties and projection" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var target = try Target.init(&renderer, 17, 9);
    defer target.deinit(&renderer);
    var linear = try GraphicsReadback.init(&renderer, 17, 9);
    defer linear.deinit(&renderer);
    var direct = try GraphicsReadback.initMode(&renderer, 17, 9, null, true);
    defer direct.deinit(&renderer);
    const gradients = [_]paint.LinearGradient{
        try paint.LinearGradient.init(.{ .x = -1.5, .y = 3.5 }, .{ .x = 6.5, .y = 3.5 }, &.{
            .{ .offset = 0, .color = Color.rgba(128, 64, 32, 192) },
            .{ .offset = 1, .color = Color.rgba(16, 200, 250, 85) },
        }),
        try paint.LinearGradient.init(.{ .x = 3.5, .y = 2.5 }, .{ .x = 11.5, .y = 6.5 }, &.{
            .{ .offset = 0.1, .color = Color.rgba(255, 0, 0, 255) },
            .{ .offset = 0.25, .color = Color.rgba(0, 255, 0, 255) },
            .{ .offset = 0.25, .color = Color.rgba(0, 0, 255, 128) },
            .{ .offset = 0.5, .color = Color.rgba(255, 255, 255, 255) },
            .{ .offset = 0.500001, .color = Color.rgba(0, 255, 255, 0) },
            .{ .offset = 0.75, .color = Color.rgba(80, 180, 30, 180) },
            .{ .offset = 0.9, .color = Color.rgba(255, 255, 255, 255) },
            .{ .offset = 1, .color = Color.rgba(255, 255, 255, 255) },
        }),
        try paint.LinearGradient.init(.{ .x = 11.25, .y = -3.5 }, .{ .x = -7.5, .y = 13.125 }, &.{
            .{ .offset = 0, .color = Color.rgba(255, 0, 0, 255) },
            .{ .offset = 1, .color = Color.rgba(0, 0, 255, 0) },
        }),
        // Translate the native no-FMA adversarial point to pixel (0.5,0.5).
        // Both endpoint deltas remain exactly (17,13) in binary32.
        try paint.LinearGradient.init(.{ .x = -15.5810546875, .y = -5.9951171875 }, .{ .x = 1.4189453125, .y = 7.0048828125 }, &.{
            .{ .offset = 0, .color = Color.rgba(255, 0, 0, 255) },
            .{ .offset = 1, .color = Color.rgba(0, 0, 255, 255) },
        }),
    };
    for (gradients, 0..) |gradient, index| {
        const commands = [_]scene.Command{.{
            .decorated_rectangle = .{
                .bounds = .{ .x = 0, .y = 0, .width = 17, .height = 9 },
                .background = Color.rgba(255, 0, 255, 255), // Must be overridden.
                .background_gradient = gradient,
                .blend = .source,
            },
        }};
        try renderer.render(.{ .commands = &commands }, &target);
        const pixels = @as([*]const LinearRgba16, @ptrCast(@alignCast(target.mapping)))[0 .. 17 * 9];
        const prepared = try gradient.prepare();
        for (pixels, 0..) |pixel, i| try std.testing.expectEqual(prepared.sample(.{
            .x = @as(f32, @floatFromInt(i % 17)) + 0.5,
            .y = @as(f32, @floatFromInt(i / 17)) + 0.5,
        }), pixel);
        // Independent asymmetric native golden at t=1/4, now sampled by GPU.
        if (index == 0) try std.testing.expectEqual(LinearRgba16{ .r = 8016, .g = 5052, .b = 5756, .a = 42469 }, pixels[0]);
        if (index == 1) {
            // (7.5,4.5) is exactly halfway: the quantized transparent tie wins.
            try std.testing.expectEqual(LinearRgba16.transparent, pixels[4 * 17 + 7]);
            try std.testing.expectEqual(LinearRgba16{ .r = 0, .g = 0, .b = 32896, .a = 32896 }, pixels[3 * 17 + 5]);
        }
        if (index == 3) try std.testing.expectEqual(LinearRgba16{ .r = 14335, .g = 0, .b = 51200, .a = 65535 }, pixels[0]);
        const list: scene.DisplayList = .{ .commands = &commands };
        // Legacy opaque background cannot make a translucent gradient opaque.
        if (!gradient.isOpaque()) try std.testing.expectError(error.OpaqueSceneRequired, renderer.renderGraphicsResources(list, &direct.target, null, null, null, null, false));
        const output = if (gradient.isOpaque()) &direct else &linear;
        try renderer.renderGraphicsResources(list, &output.target, null, null, null, null, false);
        try output.target.wait(&renderer);
        for (pixels, 0..) |pixel, i| {
            const encoded = pixel.toSrgba8();
            try output.expectPixel(i % 17, i / 17, .{ encoded.r, encoded.g, encoded.b, encoded.a });
        }
    }
}

test "Vulkan gradients interleave paths images solids and survive damage and async lifetimes" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const geometry = try path.Path.create(std.testing.allocator, &.{
        .{ .move = .{ .x = 0, .y = 0 } },
        .{ .line = .{ .x = 35, .y = 11 } },
        .{ .line = .{ .x = 8, .y = 29 } },
        .close,
    }, .{ .fill = .nonzero });
    defer geometry.release();
    const empty = try path.Path.create(std.testing.allocator, &.{}, .{ .fill = .nonzero });
    defer empty.release();
    var images = try ImageCache.init(std.testing.allocator, 1);
    defer images.deinit();
    const image = try @import("../image_test.zig").insertFixture(&images);
    const gradient = try paint.LinearGradient.init(.{ .x = 3.5, .y = 2.5 }, .{ .x = 56.5, .y = 33.5 }, &.{
        .{ .offset = 0, .color = Color.rgba(250, 100, 30, 230) },
        .{ .offset = 0.5, .color = Color.rgba(80, 210, 160, 180) },
        .{ .offset = 0.5, .color = Color.rgba(190, 60, 220, 200) },
        .{ .offset = 1, .color = Color.rgba(30, 80, 250, 0) },
    });
    const reverse = try paint.LinearGradient.init(.{ .x = 56.5, .y = 33.5 }, .{ .x = 3.5, .y = 2.5 }, gradient.stops[0..gradient.count]);
    const origin: paint.PointF = .{ .x = -1.25, .y = 3.5 };
    const translated: paint.PointF = .{ .x = 26.75, .y = 6.5 };
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(24, 42, 65, 255) },
        .{ .push_clip_rect = .{ .x = 2, .y = 1, .width = 60, .height = 37 } },
        .{ .decorated_rectangle = .{ .bounds = .{ .x = 1, .y = 1, .width = 61, .height = 36 }, .background_gradient = gradient, .corner_radius = 4, .border_width = 1, .border_color = Color.rgba(150, 170, 200, 220) } },
        .{ .path = .{ .path = empty, .identity = empty.identity, .origin = .{}, .scale = 1, .bounds = try path.deviceBounds(empty, .{}, 1), .color = Color.rgba(255, 0, 0, 255), .gradient = reverse } },
        .{ .decorated_rectangle = .{ .bounds = .{ .x = -99, .y = 0, .width = 1, .height = 1 }, .background_gradient = reverse } },
        .{ .image = .{ .image = image, .bounds = .{ .x = 5, .y = 6, .width = 13, .height = 9 }, .fit = .fill } },
        .{ .path = .{ .path = geometry, .identity = geometry.identity, .origin = origin, .scale = 1, .bounds = try path.deviceBounds(geometry, origin, 1), .color = Color.rgba(255, 0, 0, 255), .gradient = reverse } },
        .{ .path = .{ .path = geometry, .identity = geometry.identity, .origin = translated, .scale = 1, .bounds = try path.deviceBounds(geometry, translated, 1), .color = Color.rgba(20, 170, 230, 120) } },
        .{ .decorated_rectangle = .{ .bounds = .{ .x = 38, .y = 24, .width = 19, .height = 10 }, .background_gradient = gradient, .corner_radius = 2 } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 41, .y = 5, .width = 7, .height = 5 }, .color = Color.rgba(220, 170, 40, 160) } },
        .pop_clip,
    };
    const list: scene.DisplayList = .{ .commands = &commands, .damage = .{ .regions = &.{
        .{ .x = 0, .y = 0, .width = 21, .height = 40 },
        .{ .x = 21, .y = 0, .width = 43, .height = 40 },
    } } };
    const software = @import("../software/root.zig");
    var expected: [64 * 40 * 4]u8 = undefined;
    const expected_target: software.Target = .{ .pixels = &expected, .width = 64, .height = 40, .stride = 64 * 4, .format = .rgba8_unorm };
    try software.renderResources(list, expected_target, null, null, null, &images);
    var target = try Target.init(&renderer, 64, 40);
    defer target.deinit(&renderer);
    try renderer.renderResources(list, &target, null, null, null, &images);
    var actual: [expected.len]u8 = undefined;
    try target.readPixels(&actual, 64 * 4, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    var direct = try GraphicsReadback.initMode(&renderer, 64, 40, null, true);
    defer direct.deinit(&renderer);
    // Keep the existing one-byte direct tolerance, comparing each added draw
    // over the prior quantized destination rather than accumulated drift.
    try software.render(.{ .commands = commands[0..1] }, expected_target);
    for (commands[2 .. commands.len - 1], 2..) |command, index| {
        const batch = [_]scene.Command{ commands[1], command, .pop_clip };
        try software.renderResources(.{ .commands = &batch }, expected_target, null, null, null, &images);
        var prefix: [commands.len]scene.Command = undefined;
        @memcpy(prefix[0 .. index + 1], commands[0 .. index + 1]);
        prefix[index + 1] = .pop_clip;
        try renderer.renderGraphicsResources(.{ .commands = prefix[0 .. index + 2] }, &direct.target, null, null, null, &images, false);
        try direct.target.wait(&renderer);
        for (0..40) |y| for (0..64) |x| {
            const pixel = expected[(y * 64 + x) * 4 ..][0..4];
            try direct.expectPixel(x, y, pixel.*);
            pixel.* = direct.pixel(x, y);
        };
    }
    try renderer.renderGraphicsResources(list, &direct.target, null, null, null, &images, false);
    commands[0].clear.a = 0;
    // Source blending exercises the erase/add presentation pair with a table.
    commands[8].decorated_rectangle.blend = .source;
    var transparent: [expected.len]u8 = undefined;
    const transparent_target: software.Target = .{ .pixels = &transparent, .width = 64, .height = 40, .stride = 64 * 4, .format = .rgba8_unorm };
    try software.renderResources(list, transparent_target, null, null, null, &images);
    try renderer.renderResources(list, &target, null, null, null, &images);
    try target.readPixels(&actual, 64 * 4, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &transparent, &actual);
    var linear = try GraphicsReadback.init(&renderer, 64, 40);
    defer linear.deinit(&renderer);
    var shared = try GraphicsReadback.initWithLinear(&renderer, 64, 40, linear.target.linear);
    defer shared.deinit(&renderer);
    try renderer.renderGraphicsResources(list, &linear.target, null, null, null, &images, false);
    // A second queued slot updates only the source rectangle in shared storage.
    // Every command is traversed, so clipped and empty gradients retain indexes.
    commands[8].decorated_rectangle.background_gradient = reverse;
    try software.renderResources(.{ .commands = &commands }, transparent_target, null, null, null, &images);
    try renderer.renderGraphicsResources(.{ .commands = &commands, .damage = .{ .regions = &.{commands[8].decorated_rectangle.bounds} } }, &shared.target, null, null, null, &images, false);
    for ([_]*DmabufTarget{ &direct.target, &linear.target, &shared.target }) |output| {
        try std.testing.expect(output.gpu_pending);
        try std.testing.expectEqual(@as(u64, 5 * 160), output.gradient_uploads.pixels.?.byte_size);
        try std.testing.expect(output.gradient_uploads.descriptor != null);
    }
    // Poison every caller-owned stop table before fences are collected.
    @memset(&commands, .{ .clear = Color.rgba(0, 0, 0, 0) });
    try images.release(image);
    try linear.target.wait(&renderer);
    try shared.target.wait(&renderer);
    try vk(c.vkWaitForFences(renderer.device, 1, &direct.target.fence, c.VK_TRUE, std.math.maxInt(u64)), error.DeviceLost);
    try std.testing.expect(try direct.target.ready(&renderer));
    for ([_]*DmabufTarget{ &direct.target, &linear.target, &shared.target }) |output|
        try std.testing.expect(output.gradient_uploads.pixels == null and output.gradient_uploads.descriptor == null);
    for (0..40) |y| for (0..64) |x| {
        try shared.expectPixel(x, y, transparent[(y * 64 + x) * 4 ..][0..4].*);
        try std.testing.expectEqual(expected[(y * 64 + x) * 4 ..][0..4].*, direct.pixel(x, y));
    };
}

test "Vulkan transforms lower nested Tree origins and reconstruct changed paint damage" {
    const ui = @import("../../ui/render_object/root.zig");
    const geometry = @import("../../core/geometry.zig");
    var tree: ui.Tree = undefined;
    try tree.init(std.testing.allocator, 4);
    defer tree.deinit();
    const root = try tree.create(.{ .stack = .{ .clip = true } });
    const outer = try tree.create(.{ .box = .{
        .width = 32,
        .height = 24,
        .padding = .{ .left = 3, .top = 5 },
        .alignment = .{},
        .opacity = 0.5,
        .transform = .{ .translation = .{ .x = 7, .y = -3 }, .scale = 1.5, .origin = .{ .x = 4, .y = 10 } },
    } });
    var inner_style: ui.types.Box = .{
        .width = 12,
        .height = 8,
        .background = Color.rgba(255, 0, 0, 255),
        .transform = .{ .translation = .{ .x = -2, .y = 4 }, .scale = 0.5, .origin = .{ .x = 6, .y = 2 } },
    };
    const inner = try tree.create(.{ .box = inner_style });
    const sibling = try tree.create(.{ .box = .{ .width = 6, .height = 4, .background = Color.rgba(0, 0, 255, 255) } });
    try tree.appendChild(root, outer, .{ .stack = .{ .x = 8, .y = 6 } });
    try tree.appendChild(outer, inner, .none);
    try tree.appendChild(root, sibling, .{ .stack = .{ .x = 50, .y = 8 } });
    _ = try tree.layout(root, @import("../../ui/layout/constraints.zig").Constraints.tight(.{ .width = 80, .height = 60 }));
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var target = try Target.init(&renderer, 100, 75);
    defer target.deinit(&renderer);
    var direct = try GraphicsReadback.initMode(&renderer, 100, 75, null, true);
    defer direct.deinit(&renderer);
    var linear = try GraphicsReadback.init(&renderer, 100, 75);
    defer linear.deinit(&renderer);
    var tracker = try @import("../../scene/damage.zig").Tracker.init(std.testing.allocator, 12);
    defer tracker.deinit();
    const viewport: RectI = .{ .x = 0, .y = 0, .width = 100, .height = 75 };
    // Before output scaling the first composition is .75*p+(10.75,4.75),
    // where p is the absolute layout point. Inner starts at (11,11), hence
    // (19,13), then 1.25 output scaling gives (23.75,16.25), size 11.25x7.5.
    // The second composition is 1.875*p+(3.625,-15.875), giving device
    // (30.3125,5.9375), size 28.125x18.75. Bounds round outward independently.
    const red_bounds = [_]RectI{
        .{ .x = 23, .y = 16, .width = 12, .height = 8 },
        .{ .x = 30, .y = 5, .width = 29, .height = 20 },
    };
    const blue_bounds: RectI = .{ .x = 62, .y = 10, .width = 8, .height = 5 };
    for (red_bounds, 0..) |red, frame| {
        if (frame == 1) {
            inner_style.transform = .{ .translation = .{ .x = 6, .y = 0 }, .scale = 1.25, .origin = .{ .x = 6, .y = 2 } };
            try tree.update(inner, .{ .box = inner_style });
            try std.testing.expect(!try tree.layoutDirty(root));
        }
        var storage: [12]scene.Command = undefined;
        var builder = try ui.Builder.init(&storage, 1.25);
        try builder.clear(Color.rgba(255, 255, 255, 255));
        try tree.buildScene(root, &builder);
        try std.testing.expectEqual(@as(usize, 7), builder.count);
        try std.testing.expectEqual(red, storage[3].solid_rectangle.bounds);
        try std.testing.expectEqual(blue_bounds, storage[5].solid_rectangle.bounds);
        try std.testing.expectEqual(geometry.Transform{ .scale = 1.25 }, builder.transform);
        try std.testing.expectEqual(geometry.SizeF{ .width = 12, .height = 8 }, try tree.nodeSize(inner));
        for ([_]ui.NodeHandle{ root, outer, inner, sibling }) |node|
            try std.testing.expectEqual(@as(usize, 1), try tree.layoutCount(node));
        var list = builder.displayList();
        list.damage = try tracker.compare(list.commands, viewport);
        if (frame == 0) {
            try std.testing.expect(list.damage == .full);
        } else {
            try std.testing.expectEqualSlices(RectI, &.{.{ .x = 23, .y = 5, .width = 36, .height = 20 }}, list.damage.regions);
        }
        try renderer.render(list, &target);
        var actual: [100 * 75 * 4]u8 = undefined;
        try target.readPixels(&actual, 400, .rgba8_unorm);
        var expected: [actual.len]u8 = @splat(255);
        // Independent raster golden: red isolation over white gives 255,188,188;
        // the untransformed blue sibling stays outside the opacity scope.
        for (@intCast(red.y)..@as(usize, @intCast(red.y)) + red.height) |y|
            for (@intCast(red.x)..@as(usize, @intCast(red.x)) + red.width) |x| {
                expected[(y * 100 + x) * 4 ..][0..4].* = .{ 255, 188, 188, 255 };
            };
        for (10..15) |y| for (62..70) |x| {
            expected[(y * 100 + x) * 4 ..][0..4].* = .{ 0, 0, 255, 255 };
        };
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        for ([_]*GraphicsReadback{ &direct, &linear }) |output| {
            try renderer.renderGraphicsResources(list, &output.target, null, null, null, null, false);
            try output.target.wait(&renderer);
            for (0..75) |y| for (0..100) |x| try output.expectPixel(x, y, expected[(y * 100 + x) * 4 ..][0..4].*);
        }
        tracker.submitted();
        try std.testing.expectEqual(@as(usize, 0), (try tracker.compare(list.commands, viewport)).regions.len);
    }
}

test "Vulkan transforms lower mixed Builder coverage gradients images and rounded opacity" {
    const Builder = @import("../../ui/render_object/scene_builder.zig").Builder;
    const PointF = @import("../../core/geometry.zig").PointF;
    const RectF = @import("../../core/geometry.zig").RectF;
    const software = @import("../software/root.zig");
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var images = try ImageCache.init(std.testing.allocator, 1);
    defer images.deinit();
    const image = try @import("../image_test.zig").insertFixture(&images);
    const native_path = try path.Path.create(std.testing.allocator, &.{
        .{ .move = .{ .x = 0, .y = 0 } }, .{ .line = .{ .x = 20, .y = 0 } }, .{ .line = .{ .x = 4, .y = 16 } }, .close,
    }, .{ .fill = .nonzero });
    defer native_path.release();
    const gradient = try paint.LinearGradient.init(.{ .x = 0, .y = 0 }, .{ .x = 32, .y = 24 }, &.{
        .{ .offset = 0, .color = Color.rgba(240, 60, 20, 220) },
        .{ .offset = 0.375, .color = Color.rgba(40, 200, 70, 90) },
        .{ .offset = 1, .color = Color.rgba(30, 80, 240, 170) },
    });
    var storage: [24]scene.Command = undefined;
    var builder = try Builder.init(&storage, 1.25);
    const output_transform = builder.transform;
    try builder.clear(Color.rgba(25, 40, 65, 255));
    // Parent maps p to 1.875*p+(8.125,9.375) in device pixels. The child
    // composes to .9375*p+(10.9375,15.9375), not a scaled parent translation.
    builder.transform = try builder.transform.compose(.{ .translation = .{ .x = 8, .y = 10 }, .scale = 1.5, .origin = .{ .x = 3, .y = 5 } });
    const parent_transform = builder.transform;
    try builder.pushOpacity(0.6);
    const box: RectF = .{ .x = 2, .y = 2, .width = 32, .height = 24 };
    const shadow_index = builder.count;
    try builder.boxShadow(box, 4, .{ .offset = .{ .x = -3, .y = 2 }, .blur = 4, .spread = 1.5, .color = Color.rgba(10, 20, 30, 190) });
    const rectangle_index = builder.count;
    try builder.gradientRectangle(box, gradient, .{ .x = 2, .y = 2 }, Color.rgba(230, 190, 70, 255), 1.2, 4);
    const rounded_index = builder.count;
    try builder.pushRoundedClip(box, 4);
    builder.transform = try builder.transform.compose(.{ .translation = .{ .x = -2, .y = 3 }, .scale = 0.5, .origin = .{ .x = 7, .y = 1 } });
    const clip_index = builder.count;
    try builder.pushClip(.{ .x = 4, .y = 3, .width = 44, .height = 30 });
    const image_index = builder.count;
    try builder.image(image, .{ .x = 5, .y = 5, .width = 25, .height = 18 }, .fill);
    const path_index = builder.count;
    try builder.gradientPath(native_path, .{ .x = 5, .y = 7 }, gradient);
    try builder.popClip();
    builder.transform = parent_transform;
    try builder.solidRectangle(.{ .x = 26, .y = 15, .width = 6, .height = 5 }, Color.rgba(240, 100, 180, 150));
    try builder.popClip();
    try builder.popOpacity();
    builder.transform = output_transform;
    try builder.solidRectangle(.{ .x = 2, .y = 2, .width = 4, .height = 3 }, Color.rgba(0, 255, 0, 255));
    const snapped: RectI = .{ .x = 12, .y = 13, .width = 60, .height = 45 };
    const shadow_value = storage[shadow_index].shadow.shape;
    try std.testing.expectEqual(snapped, shadow_value.box);
    try std.testing.expectEqual(@as(u32, 8), shadow_value.corner_radius);
    try std.testing.expectEqual(PointF{ .x = -5.625, .y = 3.75 }, shadow_value.offset);
    try std.testing.expectEqual(@as(f32, 7.5), shadow_value.blur);
    try std.testing.expectEqual(@as(f32, 2.8125), shadow_value.spread);
    const rectangle = storage[rectangle_index].decorated_rectangle;
    try std.testing.expectEqual(snapped, rectangle.bounds);
    try std.testing.expectEqual(@as(u32, 3), rectangle.border_width);
    try std.testing.expectEqual(@as(u32, 8), rectangle.corner_radius);
    try std.testing.expectEqual(PointF{ .x = 11.875, .y = 13.125 }, rectangle.background_gradient.?.start);
    try std.testing.expectEqual(PointF{ .x = 71.875, .y = 58.125 }, rectangle.background_gradient.?.end);
    try std.testing.expectEqual(scene.RoundedClip{ .bounds = snapped, .corner_radius = 8 }, storage[rounded_index].push_clip_rounded);
    try std.testing.expectEqual(RectI{ .x = 14, .y = 18, .width = 42, .height = 29 }, storage[clip_index].push_clip_rect);
    try std.testing.expectEqual(RectI{ .x = 15, .y = 20, .width = 25, .height = 18 }, storage[image_index].image.bounds);
    const path_value = storage[path_index].path;
    try std.testing.expectEqual(PointF{ .x = 15.625, .y = 22.5 }, path_value.origin);
    try std.testing.expectEqual(@as(f32, 0.9375), path_value.scale);
    try std.testing.expectEqual(PointF{ .x = 15.625, .y = 22.5 }, path_value.gradient.?.start);
    try std.testing.expectEqual(PointF{ .x = 45.625, .y = 45 }, path_value.gradient.?.end);
    var target = try Target.init(&renderer, 96, 72);
    defer target.deinit(&renderer);
    var direct = try GraphicsReadback.initMode(&renderer, 96, 72, null, true);
    defer direct.deinit(&renderer);
    var linear = try GraphicsReadback.init(&renderer, 96, 72);
    defer linear.deinit(&renderer);
    for ([_]u8{ 255, 0 }) |alpha| {
        storage[0].clear.a = alpha;
        var list = builder.displayList();
        list.damage = .{ .regions = &.{
            .{ .x = 0, .y = 0, .width = 29, .height = 72 },
            .{ .x = 29, .y = 0, .width = 67, .height = 72 },
        } };
        var expected: [96 * 72 * 4]u8 = undefined;
        var actual: [expected.len]u8 = undefined;
        try software.renderResources(list, .{ .pixels = &expected, .width = 96, .height = 72, .stride = 384, .format = .rgba8_unorm, .allocator = std.testing.allocator }, null, null, null, &images);
        try renderer.renderResources(list, &target, null, null, null, &images);
        try target.readPixels(&actual, 384, .rgba8_unorm);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, actual[(3 * 96 + 3) * 4 ..][0..4].*);
        try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, actual[(6 * 96 + 7) * 4 ..][0..4].*);
        try std.testing.expectEqual([4]u8{ if (alpha == 0) 0 else 25, if (alpha == 0) 0 else 40, if (alpha == 0) 0 else 65, alpha }, actual[(3 * 96 + 8) * 4 ..][0..4].*);
        const output = if (alpha == 255) &direct else &linear;
        try renderer.renderGraphicsResources(list, &output.target, null, null, null, &images, false);
        try output.target.wait(&renderer);
        for (0..72) |y| for (0..96) |x| try output.expectPixel(x, y, expected[(y * 96 + x) * 4 ..][0..4].*);
    }
}

test "Vulkan transforms lower fractional glyph and paragraph positions with restored sibling scale" {
    if (comptime !has_freetype) return error.SkipZigTest;
    const Builder = @import("../../ui/render_object/scene_builder.zig").Builder;
    const PointF = @import("../../core/geometry.zig").PointF;
    const software = @import("../software/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try text.bundled.acquire(&fonts, .sans, .regular, .roman);
    defer fonts.release(font) catch unreachable;
    const emoji = try fonts.acquire(.{ .key = .{ .file = "/fixtures/EmojiTest.ttf", .index = 0 }, .bytes = @embedFile("../../text/fonts/EmojiTest.ttf") });
    defer fonts.release(emoji) catch unreachable;
    var shapes = text.ShapeCache.init(std.testing.allocator, &fonts);
    defer shapes.deinit();
    const shape = try shapes.acquire(.{
        .spec = .{ .paragraph = "🚀 Wa", .direction = .left_to_right, .script = .latin, .language = "en", .logical_size = 13.25 },
        .candidates = &.{ font, emoji },
        .configuration_revision = 1,
    });
    defer shapes.release(shape) catch unreachable;
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const paragraph = try paragraphs.acquire(.{ .utf8 = "paint 👋 scale", .language = "en", .logical_size = 11.25, .max_width = 58, .candidates = &.{ font, emoji }, .configuration_revision = 1 });
    defer paragraphs.release(paragraph) catch unreachable;
    var storage: [10]scene.Command = undefined;
    var builder = try Builder.init(&storage, 1.5);
    const output_transform = builder.transform;
    try builder.clear(Color.rgba(25, 40, 65, 255));
    // Device parent: 1.125*p+(-1.5,12). Nested device map:
    // 1.6875*p+(3,6.375). Expected origins below are calculated directly.
    builder.transform = try builder.transform.compose(.{ .translation = .{ .x = -3, .y = 7 }, .scale = 0.75, .origin = .{ .x = 8, .y = 4 } });
    try builder.pushRoundedClip(.{ .x = 0, .y = 0, .width = 100, .height = 64 }, 8);
    try builder.pushOpacity(0.6);
    builder.transform = try builder.transform.compose(.{ .translation = .{ .x = 5, .y = -2 }, .scale = 1.5, .origin = .{ .x = 2, .y = 6 } });
    try builder.glyphRun(shape, .{ .x = 4, .y = 16 }, Color.rgba(250, 230, 180, 220));
    try builder.paragraph(paragraph, .{ .x = 18, .y = 24 }, Color.rgba(140, 240, 200, 230));
    try builder.popOpacity();
    try builder.popClip();
    builder.transform = output_transform;
    try builder.glyphRun(shape, .{ .x = 76, .y = 16 }, Color.rgba(190, 220, 250, 255));
    try std.testing.expectEqual(scene.RoundedClip{ .bounds = .{ .x = -2, .y = 12, .width = 113, .height = 72 }, .corner_radius = 9 }, storage[1].push_clip_rounded);
    try std.testing.expectEqual(PointF{ .x = 9.75, .y = 33.375 }, storage[3].glyph_run.origin);
    try std.testing.expectEqual(@as(f32, 1.6875), storage[3].glyph_run.scale);
    try std.testing.expectEqual(PointF{ .x = 33.375, .y = 46.875 }, storage[4].paragraph.origin);
    try std.testing.expectEqual(@as(f32, 1.6875), storage[4].paragraph.scale);
    try std.testing.expectEqual(PointF{ .x = 114, .y = 24 }, storage[7].glyph_run.origin);
    try std.testing.expectEqual(@as(f32, 1.5), storage[7].glyph_run.scale);
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var glyphs = try GlyphCache.init(std.testing.allocator, &fonts, &renderer);
    defer glyphs.deinit();
    var software_glyphs = try software.GlyphCache.init(std.testing.allocator, &fonts);
    defer software_glyphs.deinit();
    var target = try Target.init(&renderer, 192, 120);
    defer target.deinit(&renderer);
    var direct = try GraphicsReadback.initMode(&renderer, 192, 120, null, true);
    defer direct.deinit(&renderer);
    var linear = try GraphicsReadback.init(&renderer, 192, 120);
    defer linear.deinit(&renderer);
    for ([_]u8{ 255, 0 }) |alpha| {
        storage[0].clear.a = alpha;
        const list = builder.displayList();
        var expected: [192 * 120 * 4]u8 = undefined;
        var actual: [expected.len]u8 = undefined;
        try software.renderResources(list, .{ .pixels = &expected, .width = 192, .height = 120, .stride = 768, .format = .rgba8_unorm, .allocator = std.testing.allocator }, &software_glyphs, &shapes, &paragraphs, null);
        try renderer.renderResources(list, &target, &glyphs, &shapes, &paragraphs, null);
        try target.readPixels(&actual, 768, .rgba8_unorm);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        const output = if (alpha == 255) &direct else &linear;
        try renderer.renderGraphicsResources(list, &output.target, &glyphs, &shapes, &paragraphs, null, false);
        try output.target.wait(&renderer);
        for (0..120) |y| for (0..192) |x| try output.expectPixel(x, y, expected[(y * 192 + x) * 4 ..][0..4].*);
    }
}

test "Vulkan opacity isolates overlaps erasure and nested cropped layers" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const black: scene.Command = .{ .solid_rectangle = .{ .bounds = .{ .x = 3, .y = 2, .width = 8, .height = 6 }, .color = Color.rgba(0, 0, 0, 255) } };
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(255, 255, 255, 255) },
        .{ .push_opacity = 32768 },
        black,
        black,
        .{ .push_opacity = 32768 },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 9, .y = 4, .width = 5, .height = 6 }, .color = Color.rgba(0, 0, 0, 255) } },
        .pop_opacity,
        .{ .solid_rectangle = .{ .bounds = .{ .x = 5, .y = 4, .width = 2, .height = 2 }, .color = Color.rgba(0, 0, 0, 0), .blend = .source } },
        .pop_opacity,
        .{ .solid_rectangle = .{ .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .color = Color.rgba(255, 0, 0, 255) } },
    };
    const software = @import("../software/root.zig");
    var expected: [16 * 12 * 4]u8 = undefined;
    var actual: [expected.len]u8 = undefined;
    const reference: software.Target = .{ .pixels = &expected, .width = 16, .height = 12, .stride = 64, .format = .rgba8_unorm, .allocator = std.testing.allocator };
    var target = try Target.init(&renderer, 16, 12);
    defer target.deinit(&renderer);
    var direct = try GraphicsReadback.initMode(&renderer, 16, 12, null, true);
    defer direct.deinit(&renderer);
    var linear = try GraphicsReadback.init(&renderer, 16, 12);
    defer linear.deinit(&renderer);
    for ([_]u16{ 32768, 65535, 0 }) |opacity| {
        commands[1].push_opacity = opacity;
        const list: scene.DisplayList = .{ .commands = &commands, .damage = .{ .regions = &.{
            .{ .x = 0, .y = 0, .width = 7, .height = 12 },
            .{ .x = 7, .y = 0, .width = 9, .height = 12 },
        } } };
        try software.render(list, reference);
        try renderer.render(list, &target);
        try target.readPixels(&actual, 64, .rgba8_unorm);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        if (opacity == 32768) {
            // Independent goldens distinguish isolation from child alpha and
            // parent erasure, including a nested pixel outside the first box.
            try std.testing.expectEqual([4]u8{ 188, 188, 188, 255 }, actual[(3 * 16 + 4) * 4 ..][0..4].*);
            try std.testing.expectEqual([4]u8{ 225, 225, 225, 255 }, actual[(9 * 16 + 13) * 4 ..][0..4].*);
        }
        try std.testing.expectEqual([4]u8{ 255, 255, 255, 255 }, actual[(4 * 16 + 5) * 4 ..][0..4].*);
        for ([_]*GraphicsReadback{ &direct, &linear }) |output| {
            try renderer.renderGraphicsResources(list, &output.target, null, null, null, null, false);
            try std.testing.expectEqual(@as(usize, 2), output.target.opacity_layers.entries.len);
            try std.testing.expectEqual(@as(usize, if (opacity == 0) 0 else (11 * 8 + 5 * 6) * 8), output.target.opacity_layers.byte_size);
            try output.target.wait(&renderer);
            try std.testing.expectEqual(@as(usize, 0), output.target.opacity_layers.entries.len);
            for (0..12) |y| for (0..16) |x| try output.expectPixel(x, y, expected[(y * 16 + x) * 4 ..][0..4].*);
        }
    }
    const before = expected;
    commands[1].push_opacity = 32768;
    try software.render(.{ .commands = &commands }, reference);
    const partial: scene.DisplayList = .{ .commands = &commands, .damage = .{ .regions = &.{
        .{ .x = 3, .y = 2, .width = 3, .height = 3 },
        .{ .x = 10, .y = 7, .width = 2, .height = 2 },
    } } };
    try renderer.render(partial, &target);
    try target.readPixels(&actual, 64, .rgba8_unorm);
    for ([_]*GraphicsReadback{ &direct, &linear }) |output| {
        try renderer.renderGraphicsResources(partial, &output.target, null, null, null, null, false);
        try std.testing.expectEqual(@as(usize, (9 * 7 + 2 * 2) * 8), output.target.opacity_layers.byte_size);
        try output.target.wait(&renderer);
        for (0..12) |y| for (0..16) |x| {
            const inside = (x >= 3 and x < 6 and y >= 2 and y < 5) or (x >= 10 and x < 12 and y >= 7 and y < 9);
            const offset = (y * 16 + x) * 4;
            const pixel = if (inside) expected[offset..][0..4].* else before[offset..][0..4].*;
            try std.testing.expectEqual(pixel, actual[offset..][0..4].*);
            try output.expectPixel(x, y, pixel);
        };
    }
    // Partial input on a never-used direct image must initialize all layers
    // as well as all final pixels, including groups outside requested damage.
    var fresh = try GraphicsReadback.initMode(&renderer, 16, 12, null, true);
    defer fresh.deinit(&renderer);
    try renderer.renderGraphicsResources(partial, &fresh.target, null, null, null, null, false);
    try std.testing.expectEqual(@as(usize, (11 * 8 + 5 * 6) * 8), fresh.target.opacity_layers.byte_size);
    try fresh.target.wait(&renderer);
    for (0..12) |y| for (0..16) |x| try fresh.expectPixel(x, y, expected[(y * 16 + x) * 4 ..][0..4].*);
}

test "Vulkan opacity applies ancestor clips once and inner clips per draw" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const white: scene.Command = .{ .solid_rectangle = .{ .bounds = .{ .x = 0, .y = 0, .width = 16, .height = 16 }, .color = Color.rgba(255, 255, 255, 255) } };
    const outer: scene.Command = .{ .push_clip_rounded = .{ .bounds = .{ .x = 2, .y = 3, .width = 13, .height = 11 }, .corner_radius = 5 } };
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(0, 0, 0, 0) }, outer, .{ .push_opacity = 65535 }, white, white, .pop_opacity, .pop_clip,
    };
    var target = try Target.init(&renderer, 16, 16);
    defer target.deinit(&renderer);
    var output = try GraphicsReadback.init(&renderer, 16, 16);
    defer output.deinit(&renderer);
    const software = @import("../software/root.zig");
    var expected: [16 * 16 * 4]u8 = undefined;
    var actual: [expected.len]u8 = undefined;
    for ([_]u8{ 90, 45, 74 }) |golden| {
        if (golden == 45) commands[2].push_opacity = 32768;
        if (golden == 74) commands = .{ commands[0], commands[2], outer, white, white, .pop_clip, .pop_opacity };
        const list: scene.DisplayList = .{ .commands = &commands };
        try software.render(list, .{ .pixels = &expected, .width = 16, .height = 16, .stride = 64, .format = .rgba8_unorm, .allocator = std.testing.allocator });
        try renderer.render(list, &target);
        try target.readPixels(&actual, 64, .rgba8_unorm);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        try std.testing.expectEqual([4]u8{ golden, golden, golden, golden }, actual[(3 * 16 + 4) * 4 ..][0..4].*);
        try renderer.renderGraphicsResources(list, &output.target, null, null, null, null, false);
        try output.target.wait(&renderer);
        for (0..16) |y| for (0..16) |x| try output.expectPixel(x, y, expected[(y * 16 + x) * 4 ..][0..4].*);
    }
}

test "Vulkan opacity mixed resources preserve indexes and queued layer lifetimes" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const geometry = try path.Path.create(std.testing.allocator, &.{
        .{ .move = .{ .x = -5, .y = -2 } }, .{ .line = .{ .x = 67, .y = 11 } }, .{ .line = .{ .x = 13, .y = 41 } }, .close,
    }, .{ .fill = .nonzero });
    defer geometry.release();
    var images = try ImageCache.init(std.testing.allocator, 1);
    defer images.deinit();
    const image = try @import("../image_test.zig").insertFixture(&images);
    const gradient = try paint.LinearGradient.init(.{ .x = 4, .y = 3 }, .{ .x = 58, .y = 35 }, &.{
        .{ .offset = 0, .color = Color.rgba(240, 80, 30, 210) },
        .{ .offset = 1, .color = Color.rgba(40, 120, 250, 110) },
    });
    const path_command: scene.Command = .{ .path = .{ .path = geometry, .identity = geometry.identity, .origin = .{ .x = -0.25, .y = 0.5 }, .scale = 1, .bounds = try path.deviceBounds(geometry, .{ .x = -0.25, .y = 0.5 }, 1), .color = Color.rgba(255, 255, 255, 255), .gradient = gradient } };
    const image_command: scene.Command = .{ .image = .{ .image = image, .bounds = .{ .x = 2, .y = 2, .width = 51, .height = 31 }, .fit = .fill } };
    const shadow_shape: shadow.Shape = .{ .box = .{ .x = 14, .y = 7, .width = 31, .height = 22 }, .corner_radius = 3, .offset = .{ .x = -3.25, .y = 2.5 }, .blur = 6 };
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(25, 40, 65, 255) },
        .{ .push_clip_rounded = .{ .bounds = .{ .x = 3, .y = 2, .width = 58, .height = 35 }, .corner_radius = 12 } },
        .{ .push_opacity = 43001 },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 1, .y = 1, .width = 62, .height = 38 }, .color = Color.rgba(50, 160, 220, 190) } },
        .{ .push_clip_rounded = .{ .bounds = .{ .x = 7, .y = 5, .width = 46, .height = 26 }, .corner_radius = 10 } },
        .{ .push_opacity = 51003 },
        image_command,
        path_command,
        .{ .push_opacity = 0 },
        path_command,
        .{ .push_clip_rounded = .{ .bounds = .{ .x = 9, .y = 9, .width = 0, .height = 8 }, .corner_radius = 4 } },
        image_command,
        .pop_clip,
        .pop_opacity,
        .{ .shadow = .{ .shape = shadow_shape, .bounds = try shadow.deviceBounds(shadow_shape), .color = Color.rgba(90, 230, 40, 150) } },
        .{ .decorated_rectangle = .{ .bounds = .{ .x = 5, .y = 7, .width = 49, .height = 25 }, .background_gradient = gradient, .corner_radius = 4, .border_width = 2, .border_color = Color.rgba(230, 180, 40, 210), .blend = .source } },
        .pop_opacity,
        image_command,
        .{ .solid_rectangle = .{ .bounds = .{ .x = 32, .y = 15, .width = 25, .height = 24 }, .color = Color.rgba(0, 0, 0, 0), .blend = .source } },
        .pop_clip,
        path_command,
        .pop_opacity,
        .pop_clip,
        .{ .push_clip_rect = .{ .x = 61, .y = 0, .width = 3, .height = 40 } },
        path_command,
        image_command,
        .pop_clip,
        .{ .solid_rectangle = .{ .bounds = .{ .x = 1, .y = 1, .width = 3, .height = 3 }, .color = Color.rgba(250, 190, 30, 255) } },
    };
    const software = @import("../software/root.zig");
    var expected: [64 * 40 * 4]u8 = undefined;
    var actual: [expected.len]u8 = undefined;
    const reference: software.Target = .{ .pixels = &expected, .width = 64, .height = 40, .stride = 256, .format = .rgba8_unorm, .allocator = std.testing.allocator };
    const list: scene.DisplayList = .{ .commands = &commands, .damage = .{ .regions = &.{
        .{ .x = 0, .y = 0, .width = 19, .height = 40 },
        .{ .x = 19, .y = 0, .width = 45, .height = 40 },
    } } };
    try software.renderResources(list, reference, null, null, null, &images);
    var target = try Target.init(&renderer, 64, 40);
    defer target.deinit(&renderer);
    try renderer.renderResources(list, &target, null, null, null, &images);
    try target.readPixels(&actual, 256, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    var direct = try GraphicsReadback.initMode(&renderer, 64, 40, null, true);
    defer direct.deinit(&renderer);
    var linear = try GraphicsReadback.init(&renderer, 64, 40);
    defer linear.deinit(&renderer);
    var shared = try GraphicsReadback.initWithLinear(&renderer, 64, 40, linear.target.linear);
    defer shared.deinit(&renderer);
    try renderer.renderGraphicsResources(list, &direct.target, null, null, null, &images, false);
    try renderer.renderGraphicsResources(list, &linear.target, null, null, null, &images, false);
    // Full cropped groups are recomputed; only these damaged columns update
    // the existing shared attachment. No CPU wait between the two slots.
    commands[5].push_opacity = 21987;
    const damage = [_]RectI{
        .{ .x = 7, .y = 5, .width = 18, .height = 26 },
        .{ .x = 25, .y = 5, .width = 28, .height = 26 },
    };
    var updated = expected;
    try software.renderResources(.{ .commands = &commands, .damage = .{ .regions = &damage } }, .{ .pixels = &updated, .width = 64, .height = 40, .stride = 256, .format = .rgba8_unorm, .allocator = std.testing.allocator }, null, null, null, &images);
    try renderer.renderGraphicsResources(.{ .commands = &commands, .damage = .{ .regions = &damage } }, &shared.target, null, null, null, &images, false);
    for ([_]*DmabufTarget{ &direct.target, &linear.target, &shared.target }) |output| {
        try std.testing.expect(output.gpu_pending);
        try std.testing.expectEqual(@as(usize, 3), output.opacity_layers.entries.len);
        try std.testing.expect(output.opacity_layers.entries[2].pixels == null);
        const records = @as([*]const ClipRecord, @ptrCast(@alignCast(output.clip_uploads.pixels.?.mapping)))[0..3];
        // Outer, inner, and hidden inner all start independent clip chains.
        for (records) |record| try std.testing.expectEqual(@as(u32, 0), record.parent);
    }
    @memset(&commands, .{ .clear = Color.rgba(0, 0, 0, 0) });
    try images.release(image);
    renderer.path_masks.deinit();
    renderer.path_masks = path.MaskCache.init(renderer.allocator);
    renderer.shadow_masks.deinit();
    renderer.shadow_masks = shadow.MaskCache.init(renderer.allocator);
    try linear.target.wait(&renderer);
    try shared.target.wait(&renderer);
    try vk(c.vkWaitForFences(renderer.device, 1, &direct.target.fence, c.VK_TRUE, std.math.maxInt(u64)), error.DeviceLost);
    try std.testing.expect(try direct.target.ready(&renderer));
    for ([_]*DmabufTarget{ &direct.target, &linear.target, &shared.target }) |output|
        try std.testing.expect(output.opacity_layers.entries.len == 0 and output.opacity_layers.pool == null);
    for (0..40) |y| for (0..64) |x| {
        try direct.expectPixel(x, y, expected[(y * 64 + x) * 4 ..][0..4].*);
        try linear.expectPixel(x, y, expected[(y * 64 + x) * 4 ..][0..4].*);
        try shared.expectPixel(x, y, updated[(y * 64 + x) * 4 ..][0..4].*);
    };
}

test "Vulkan opacity retains outset shadow pixels when union moves left and up" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const box: RectI = .{ .x = 20, .y = 30, .width = 80, .height = 60 };
    const shape: shadow.Shape = .{ .box = box, .offset = .{ .x = 20, .y = 12 } };
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(232, 238, 244, 255) },
        .{ .push_opacity = 32768 },
        .{ .shadow = .{ .shape = shape, .bounds = try shadow.deviceBounds(shape), .color = Color.rgba(32, 48, 64, 255) } },
        .{ .decorated_rectangle = .{ .bounds = box, .background = Color.rgba(240, 190, 40, 255), .border_color = Color.rgba(20, 30, 40, 255), .border_width = 3 } },
        .pop_opacity,
    };
    const list: scene.DisplayList = .{ .commands = &commands };
    var target = try Target.init(&renderer, 140, 120);
    defer target.deinit(&renderer);
    try renderer.render(list, &target);
    var pixels: [140 * 120 * 4]u8 = undefined;
    try target.readPixels(&pixels, 560, .rgba8_unorm);
    try std.testing.expectEqual([4]u8{ 172, 177, 184, 255 }, pixels[(60 * 140 + 110) * 4 ..][0..4].*);
    var direct = try GraphicsReadback.initMode(&renderer, 140, 120, null, true);
    defer direct.deinit(&renderer);
    var linear = try GraphicsReadback.init(&renderer, 140, 120);
    defer linear.deinit(&renderer);
    for ([_]*GraphicsReadback{ &direct, &linear }) |output| {
        try renderer.renderGraphicsResources(list, &output.target, null, null, null, null, false);
        try output.target.wait(&renderer);
        for (0..120) |y| for (0..140) |x| try output.expectPixel(x, y, pixels[(y * 140 + x) * 4 ..][0..4].*);
    }
}

test "Vulkan opacity preflight bounds budgets resources and allocation failures preserve targets" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const box: RectI = .{ .x = 2, .y = 1, .width = 5, .height = 6 };
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(31, 51, 79, 255) },
        .{ .push_opacity = 37129 },
        .{ .solid_rectangle = .{ .bounds = box, .color = Color.rgba(255, 170, 20, 255) } },
        .{ .push_opacity = 51007 },
        .{ .solid_rectangle = .{ .bounds = box, .color = Color.rgba(40, 150, 240, 210) } },
        .pop_opacity,
        .pop_opacity,
    };
    var target = try Target.init(&renderer, 8, 8);
    defer target.deinit(&renderer);
    var direct = try GraphicsReadback.initMode(&renderer, 8, 8, null, true);
    defer direct.deinit(&renderer);
    var linear = try GraphicsReadback.init(&renderer, 8, 8);
    defer linear.deinit(&renderer);
    const checks = struct {
        fn check(allocator: std.mem.Allocator, r: *Renderer, batch: []const scene.Command, output: *Target, graphics: ?*DmabufTarget) !void {
            const old = r.allocator;
            r.allocator = allocator;
            defer r.allocator = old;
            if (graphics) |g| {
                r.renderGraphicsResources(.{ .commands = batch }, g, null, null, null, null, false) catch |err| {
                    try std.testing.expect(!g.gpu_pending and g.opacity_layers.entries.len == 0);
                    try std.testing.expectEqual(@as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_UNDEFINED), g.layout);
                    if (g.linear) |attachment| try std.testing.expect(!attachment.initialized);
                    return err;
                };
                try g.wait(r);
                // The check harness reuses the target across injected failures.
                g.layout = c.VK_IMAGE_LAYOUT_UNDEFINED;
                if (g.linear) |attachment| attachment.initialized = false;
            } else {
                const bytes = @as([*]u8, @ptrCast(output.mapping))[0..output.byte_size];
                @memset(bytes, 73);
                r.render(.{ .commands = batch }, output) catch |err| {
                    for (bytes) |value| try std.testing.expectEqual(@as(u8, 73), value);
                    return err;
                };
            }
        }
    };
    for ([_]?*DmabufTarget{ null, &direct.target, &linear.target }) |output|
        try std.testing.checkAllAllocationFailures(std.testing.allocator, checks.check, .{ &renderer, @as([]const scene.Command, &commands), &target, output });
    const huge: scene.Command = .{ .solid_rectangle = .{ .bounds = .{ .x = 0, .y = 0, .width = 2048, .height = 2048 }, .color = Color.rgba(255, 255, 255, 255) } };
    // Three individually legal32MiB layers exceed the aggregate64MiB cap.
    try std.testing.expectError(error.OpacityBudgetExceeded, OpacityLayers.init(&renderer, &.{ .{ .push_opacity = 1 }, .{ .push_opacity = 1 }, .{ .push_opacity = 1 }, huge, .pop_opacity, .pop_opacity, .pop_opacity }, huge.solid_rectangle.bounds, .full));
    const original_limit = renderer.max_pixels;
    renderer.max_pixels = 29;
    try std.testing.expectError(error.InvalidExtent, OpacityLayers.init(&renderer, &commands, .{ .x = 0, .y = 0, .width = 8, .height = 8 }, .full));
    renderer.max_pixels = 30;
    var exact = try OpacityLayers.init(&renderer, &commands, .{ .x = 0, .y = 0, .width = 8, .height = 8 }, .full);
    try std.testing.expectEqual(@as(usize, 480), exact.byte_size);
    exact.deinit(&renderer);
    renderer.max_pixels = original_limit;
    var images = try ImageCache.init(std.testing.allocator, 1);
    defer images.deinit();
    const image = try @import("../image_test.zig").insertFixture(&images);
    try images.release(image);
    const hidden = [_]scene.Command{ commands[0], .{ .push_opacity = 0 }, .{ .image = .{ .image = image, .bounds = box } }, .pop_opacity };
    try std.testing.expectError(error.StaleImageHandle, renderer.renderResources(.{ .commands = &hidden }, &target, null, null, null, &images));
    for ([_]*DmabufTarget{ &direct.target, &linear.target }) |output| {
        try std.testing.expectError(error.StaleImageHandle, renderer.renderGraphicsResources(.{ .commands = &hidden }, output, null, null, null, &images, false));
        try std.testing.expect(!output.gpu_pending and output.opacity_layers.entries.len == 0);
    }
}

test "Vulkan opacity restores text atlas after images and group composites" {
    if (comptime !has_freetype) return error.SkipZigTest;
    const software = @import("../software/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const font = try text.bundled.acquire(&fonts, .sans, .regular, .roman);
    defer fonts.release(font) catch unreachable;
    const emoji = try fonts.acquire(.{ .key = .{ .file = "/fixtures/EmojiTest.ttf", .index = 0 }, .bytes = @embedFile("../../text/fonts/EmojiTest.ttf") });
    defer fonts.release(emoji) catch unreachable;
    var shapes = text.ShapeCache.init(std.testing.allocator, &fonts);
    defer shapes.deinit();
    const shape = try shapes.acquire(.{
        .spec = .{ .paragraph = "🚀 GPU", .direction = .left_to_right, .script = .latin, .language = "en", .logical_size = 16.25 },
        .candidates = &.{ font, emoji },
        .configuration_revision = 1,
    });
    defer shapes.release(shape) catch unreachable;
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();
    const layout = try paragraphs.acquire(.{ .utf8 = "group 👋", .language = "en", .logical_size = 14.25, .max_width = 85, .candidates = &.{ font, emoji }, .configuration_revision = 1 });
    defer paragraphs.release(layout) catch unreachable;
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var glyphs = try GlyphCache.init(std.testing.allocator, &fonts, &renderer);
    defer glyphs.deinit();
    var software_glyphs = try software.GlyphCache.init(std.testing.allocator, &fonts);
    defer software_glyphs.deinit();
    var images = try ImageCache.init(std.testing.allocator, 1);
    defer images.deinit();
    const image = try @import("../image_test.zig").insertFixture(&images);
    const commands = [_]scene.Command{
        .{ .clear = Color.rgba(25, 40, 65, 255) },
        .{ .push_clip_rounded = .{ .bounds = .{ .x = 4, .y = 3, .width = 112, .height = 56 }, .corner_radius = 9 } },
        .{ .push_opacity = 47013 },
        .{ .image = .{ .image = image, .bounds = .{ .x = 5, .y = 6, .width = 40, .height = 35 }, .fit = .fill } },
        .{ .glyph_run = .{ .shape = shape, .origin = .{ .x = 5.25, .y = 24.5 }, .scale = 1, .color = Color.rgba(250, 230, 180, 220) } },
        .{ .push_opacity = 51007 },
        .{ .paragraph = .{ .layout = layout, .origin = .{ .x = 23.5, .y = 28.25 }, .scale = 1, .color = Color.rgba(200, 230, 250, 240) } },
        .pop_opacity,
        .{ .glyph_run = .{ .shape = shape, .origin = .{ .x = 39.75, .y = 55.25 }, .scale = 1, .color = Color.rgba(140, 240, 200, 200) } },
        .pop_opacity,
        .pop_clip,
    };
    const list: scene.DisplayList = .{ .commands = &commands };
    var expected: [120 * 64 * 4]u8 = undefined;
    var actual: [expected.len]u8 = undefined;
    try software.renderResources(list, .{ .pixels = &expected, .width = 120, .height = 64, .stride = 480, .format = .rgba8_unorm, .allocator = std.testing.allocator }, &software_glyphs, &shapes, &paragraphs, &images);
    var target = try Target.init(&renderer, 120, 64);
    defer target.deinit(&renderer);
    try renderer.renderResources(list, &target, &glyphs, &shapes, &paragraphs, &images);
    try target.readPixels(&actual, 480, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    var direct = try GraphicsReadback.initMode(&renderer, 120, 64, null, true);
    defer direct.deinit(&renderer);
    var linear = try GraphicsReadback.init(&renderer, 120, 64);
    defer linear.deinit(&renderer);
    // Force the next submission to perform an atlas transfer into compute and
    // fragment consumers, rather than only reusing the headless upload.
    try glyphs.reset();
    for ([_]*GraphicsReadback{ &direct, &linear }) |output| {
        try renderer.renderGraphicsResources(list, &output.target, &glyphs, &shapes, &paragraphs, &images, false);
        try output.target.wait(&renderer);
        for (0..64) |y| for (0..120) |x| try output.expectPixel(x, y, expected[(y * 120 + x) * 4 ..][0..4].*);
    }
}

test "Vulkan rounded clip tables preserve parents budgets and failure cleanup" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(ClipRecord));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(ClipRecord, "parent"));
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const bounds: RectI = .{ .x = -3, .y = 2, .width = 23, .height = 21 };
    const rounded: scene.Command = .{ .push_clip_rounded = .{ .bounds = bounds, .corner_radius = 8 } };
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(10, 30, 70, 255) },
        rounded,
        .{ .push_clip_rect = bounds },
        rounded,
        .pop_clip,
        .pop_clip,
        rounded,
        .pop_clip,
        .pop_clip,
        rounded,
        rounded,
        .pop_clip,
        rounded,
        .pop_clip,
        .pop_clip,
    };
    try (scene.DisplayList{ .commands = &commands }).validate();
    var table = try TableUpload.clips(&renderer, &commands);
    defer table.deinit(&renderer);
    const records = @as([*]const ClipRecord, @ptrCast(@alignCast(table.pixels.?.mapping)))[0..6];
    for (records, [_]u32{ 0, 1, 1, 0, 4, 4 }) |record, parent| {
        try std.testing.expectEqual(parent, record.parent);
        try std.testing.expectEqual([2]i32{ -3, 2 }, record.origin);
        try std.testing.expectEqual([2]u32{ 23, 21 }, record.size);
    }
    commands[1].push_clip_rounded.bounds.x = 100;
    try std.testing.expectEqual(@as(i32, -3), records[0].origin[0]);
    commands[1] = rounded;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, struct {
        fn check(allocator: std.mem.Allocator, r: *Renderer, batch: []const scene.Command) !void {
            const original = r.allocator;
            r.allocator = allocator;
            defer r.allocator = original;
            var copy = try TableUpload.clips(r, batch);
            defer copy.deinit(r);
        }
    }.check, .{ &renderer, @as([]const scene.Command, &commands) });
    var target = try Target.init(&renderer, 8, 8);
    defer target.deinit(&renderer);
    try renderer.render(.{ .commands = commands[0..1] }, &target);
    var before: [8 * 8 * 4]u8 = undefined;
    try target.readPixels(&before, 32, .rgba8_unorm);
    var direct = try GraphicsReadback.initMode(&renderer, 8, 8, null, true);
    defer direct.deinit(&renderer);
    var linear = try GraphicsReadback.init(&renderer, 8, 8);
    defer linear.deinit(&renderer);
    const original_limit = renderer.max_image_pixels;
    renderer.max_image_pixels = 47; // Gradient dummy fits; six clip records do not.
    try std.testing.expectError(error.ClipUploadBudgetExceeded, renderer.render(.{ .commands = &commands }, &target));
    var after: [before.len]u8 = undefined;
    try target.readPixels(&after, 32, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &before, &after);
    for ([_]*DmabufTarget{ &direct.target, &linear.target }) |output| {
        try std.testing.expectError(error.ClipUploadBudgetExceeded, renderer.renderGraphicsResources(.{ .commands = &commands }, output, null, null, null, null, false));
        try std.testing.expect(output.clip_uploads.pixels == null and !output.gpu_pending);
        try std.testing.expectEqual(@as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_UNDEFINED), output.layout);
        if (output.linear) |attachment| try std.testing.expect(!attachment.initialized);
    }
    renderer.max_image_pixels = 48;
    var exact = try TableUpload.clips(&renderer, &commands);
    exact.deinit(&renderer);
    renderer.max_image_pixels = original_limit;
}

test "Vulkan rounded clips use exact outer to inner A8 and covered source erasure" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const clips = [_]scene.RoundedClip{
        .{ .bounds = .{ .x = -3, .y = 3, .width = 23, .height = 21 }, .corner_radius = 8 },
        .{ .bounds = .{ .x = -3, .y = 3, .width = 23, .height = 21 }, .corner_radius = 9 },
        .{ .bounds = .{ .x = 1, .y = 2, .width = 23, .height = 21 }, .corner_radius = 7 },
    };
    // Independent SDF/A8 golden: reversing these ancestors gives54, not55.
    for (clips, [_]u8{ 217, 163, 100 }) |clip, alpha| try std.testing.expectEqual(alpha, clip.coverage(3, 3));
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(0, 0, 0, 255) },
        .{ .push_clip_rounded = clips[0] },
        .{ .push_clip_rect = .{ .x = 0, .y = 0, .width = 32, .height = 28 } },
        .{ .push_clip_rounded = clips[1] },
        .{ .push_clip_rounded = clips[2] },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 0, .y = 0, .width = 32, .height = 28 }, .color = Color.rgba(255, 255, 255, 255) } },
        .pop_clip,
        .pop_clip,
        .pop_clip,
        .pop_clip,
    };
    var target = try Target.init(&renderer, 32, 28);
    defer target.deinit(&renderer);
    var linear = try GraphicsReadback.init(&renderer, 32, 28);
    defer linear.deinit(&renderer);
    var direct = try GraphicsReadback.initMode(&renderer, 32, 28, null, true);
    defer direct.deinit(&renderer);
    for (0..2) |mode| {
        if (mode == 1) commands[5].solid_rectangle = .{ .bounds = .{ .x = 0, .y = 0, .width = 32, .height = 28 }, .color = Color.rgba(0, 0, 0, 0), .blend = .source };
        const list: scene.DisplayList = .{ .commands = &commands, .damage = .{ .regions = &.{
            .{ .x = 0, .y = 0, .width = 11, .height = 28 },
            .{ .x = 11, .y = 0, .width = 21, .height = 28 },
        } } };
        try renderer.render(list, &target);
        const output = if (mode == 0) &direct else &linear;
        try renderer.renderGraphicsResources(list, &output.target, null, null, null, null, false);
        try output.target.wait(&renderer);
        const pixels = @as([*]const LinearRgba16, @ptrCast(@alignCast(target.mapping)))[0 .. 32 * 28];
        for (pixels, 0..) |pixel, i| {
            const x = i % 32;
            const y = i / 32;
            var alpha: u32 = 255;
            for (clips) |clip| alpha = (alpha * clip.coverage(x, y) + 127) / 255;
            const channel: u16 = @intCast(alpha * 257);
            const expected: LinearRgba16 = if (mode == 0) .{ .r = channel, .g = channel, .b = channel, .a = 65535 } else .{ .r = 0, .g = 0, .b = 0, .a = 65535 - channel };
            try std.testing.expectEqual(expected, pixel);
            const encoded = expected.toSrgba8();
            try output.expectPixel(x, y, .{ encoded.r, encoded.g, encoded.b, encoded.a });
        }
        try std.testing.expectEqual(@as(u16, if (mode == 0) 14135 else 51400), if (mode == 0) pixels[3 * 32 + 3].r else pixels[3 * 32 + 3].a);
    }
    // The shader stack must handle the public maximum depth, not just one or
    // two clips; odd dimensions also exercise integer radius clamping.
    var deep: [max_clip_depth * 2 + 2]scene.Command = undefined;
    deep[0] = commands[0];
    for (deep[1 .. max_clip_depth + 1]) |*command| command.* = .{ .push_clip_rounded = .{ .bounds = .{ .x = 1, .y = 1, .width = 7, .height = 5 }, .corner_radius = 999 } };
    deep[max_clip_depth + 1] = commands[5];
    @memset(deep[max_clip_depth + 2 ..], .pop_clip);
    var expected: [32 * 28 * 4]u8 = undefined;
    try @import("../software/root.zig").render(.{ .commands = &deep }, .{ .pixels = &expected, .width = 32, .height = 28, .stride = 128, .format = .rgba8_unorm });
    try renderer.render(.{ .commands = &deep }, &target);
    var actual: [expected.len]u8 = undefined;
    try target.readPixels(&actual, 128, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "Vulkan rounded clips cover mixed draws damage and queued table lifetimes" {
    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    const geometry = try path.Path.create(std.testing.allocator, &.{
        .{ .move = .{ .x = -5, .y = -2 } }, .{ .line = .{ .x = 67, .y = 11 } }, .{ .line = .{ .x = 13, .y = 41 } }, .close,
    }, .{ .fill = .nonzero });
    defer geometry.release();
    var images = try ImageCache.init(std.testing.allocator, 1);
    defer images.deinit();
    const image = try @import("../image_test.zig").insertFixture(&images);
    const gradient = try paint.LinearGradient.init(.{ .x = 4, .y = 3 }, .{ .x = 58, .y = 35 }, &.{
        .{ .offset = 0, .color = Color.rgba(240, 80, 30, 210) },
        .{ .offset = 1, .color = Color.rgba(40, 120, 250, 110) },
    });
    const path_command: scene.Command = .{ .path = .{ .path = geometry, .identity = geometry.identity, .origin = .{ .x = -0.25, .y = 0.5 }, .scale = 1, .bounds = try path.deviceBounds(geometry, .{ .x = -0.25, .y = 0.5 }, 1), .color = Color.rgba(255, 255, 255, 255), .gradient = gradient } };
    const image_command: scene.Command = .{ .image = .{ .image = image, .bounds = .{ .x = 2, .y = 2, .width = 51, .height = 31 }, .fit = .fill } };
    const shadow_shape: shadow.Shape = .{ .box = .{ .x = 14, .y = 7, .width = 31, .height = 22 }, .corner_radius = 3, .offset = .{ .x = -3.25, .y = 2.5 }, .blur = 6 };
    var commands = [_]scene.Command{
        .{ .clear = Color.rgba(25, 40, 65, 255) },
        .{ .push_clip_rounded = .{ .bounds = .{ .x = 3, .y = 2, .width = 58, .height = 35 }, .corner_radius = 12 } },
        .{ .solid_rectangle = .{ .bounds = .{ .x = 0, .y = 0, .width = 64, .height = 40 }, .color = Color.rgba(50, 160, 220, 190) } },
        .{ .push_clip_rounded = .{ .bounds = .{ .x = 7, .y = 5, .width = 46, .height = 26 }, .corner_radius = 10 } },
        .{ .push_clip_rect = .{ .x = 0, .y = 3, .width = 57, .height = 33 } },
        image_command,
        path_command,
        .{ .shadow = .{ .shape = shadow_shape, .bounds = try shadow.deviceBounds(shadow_shape), .color = Color.rgba(90, 230, 40, 150) } },
        .{ .decorated_rectangle = .{ .bounds = .{ .x = 5, .y = 7, .width = 49, .height = 25 }, .background_gradient = gradient, .corner_radius = 4, .border_width = 2, .border_color = Color.rgba(230, 180, 40, 210) } },
        .{ .push_clip_rounded = .{ .bounds = .{ .x = 9, .y = 9, .width = 0, .height = 8 }, .corner_radius = 4 } },
        path_command,
        image_command,
        .pop_clip,
        .{ .solid_rectangle = .{ .bounds = .{ .x = 32, .y = 15, .width = 25, .height = 24 }, .color = Color.rgba(230, 70, 100, 145) } },
        .pop_clip,
        .pop_clip,
        .{ .solid_rectangle = .{ .bounds = .{ .x = 4, .y = 3, .width = 6, .height = 29 }, .color = Color.rgba(170, 70, 230, 160) } },
        .pop_clip,
        .{ .solid_rectangle = .{ .bounds = .{ .x = 1, .y = 1, .width = 3, .height = 3 }, .color = Color.rgba(250, 190, 30, 255) } },
    };
    const list: scene.DisplayList = .{ .commands = &commands, .damage = .{ .regions = &.{
        .{ .x = 0, .y = 0, .width = 19, .height = 40 },
        .{ .x = 19, .y = 0, .width = 45, .height = 40 },
    } } };
    const software = @import("../software/root.zig");
    var expected: [64 * 40 * 4]u8 = undefined;
    const reference: software.Target = .{ .pixels = &expected, .width = 64, .height = 40, .stride = 256, .format = .rgba8_unorm };
    try software.renderResources(list, reference, null, null, null, &images);
    var target = try Target.init(&renderer, 64, 40);
    defer target.deinit(&renderer);
    try renderer.renderResources(list, &target, null, null, null, &images);
    var actual: [expected.len]u8 = undefined;
    try target.readPixels(&actual, 256, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
    var direct = try GraphicsReadback.initMode(&renderer, 64, 40, null, true);
    defer direct.deinit(&renderer);
    // Direct hardware quantizes after each primitive: test each added draw over
    // the previously observed destination, without widening one-byte tolerance.
    try software.render(.{ .commands = commands[0..1] }, reference);
    var active: [max_clip_depth]scene.Command = undefined;
    var depth: usize = 0;
    for (commands[1..], 1..) |command, index| switch (command) {
        .push_clip_rect, .push_clip_rounded => {
            active[depth] = command;
            depth += 1;
        },
        .pop_clip => depth -= 1,
        else => {
            var batch: [max_clip_depth * 2 + 1]scene.Command = undefined;
            @memcpy(batch[0..depth], active[0..depth]);
            batch[depth] = command;
            @memset(batch[depth + 1 .. depth * 2 + 1], .pop_clip);
            try software.renderResources(.{ .commands = batch[0 .. depth * 2 + 1] }, reference, null, null, null, &images);
            var prefix: [commands.len + max_clip_depth]scene.Command = undefined;
            @memcpy(prefix[0 .. index + 1], commands[0 .. index + 1]);
            @memset(prefix[index + 1 .. index + 1 + depth], .pop_clip);
            try renderer.renderGraphicsResources(.{ .commands = prefix[0 .. index + 1 + depth] }, &direct.target, null, null, null, &images, false);
            try direct.target.wait(&renderer);
            for (0..40) |y| for (0..64) |x| {
                const pixel = expected[(y * 64 + x) * 4 ..][0..4];
                try direct.expectPixel(x, y, pixel.*);
                pixel.* = direct.pixel(x, y);
            };
        },
    };
    try renderer.renderGraphicsResources(list, &direct.target, null, null, null, &images, false);
    var transparent: [expected.len]u8 = undefined;
    const transparent_reference: software.Target = .{ .pixels = &transparent, .width = 64, .height = 40, .stride = 256, .format = .rgba8_unorm };
    commands[0].clear.a = 0;
    commands[8].decorated_rectangle.blend = .source;
    commands[13].solid_rectangle.color = Color.rgba(0, 0, 0, 0);
    commands[13].solid_rectangle.blend = .source;
    try software.renderResources(list, transparent_reference, null, null, null, &images);
    try renderer.renderResources(list, &target, null, null, null, &images);
    try target.readPixels(&actual, 256, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &transparent, &actual);
    var linear = try GraphicsReadback.init(&renderer, 64, 40);
    defer linear.deinit(&renderer);
    var shared = try GraphicsReadback.initWithLinear(&renderer, 64, 40, linear.target.linear);
    defer shared.deinit(&renderer);
    try renderer.renderGraphicsResources(list, &linear.target, null, null, null, &images, false);
    // Change only the inner analytic clip and reconstruct its affected extent
    // in another queued slot sharing the linear attachment.
    commands[3].push_clip_rounded.corner_radius = 4;
    try software.renderResources(.{ .commands = &commands }, transparent_reference, null, null, null, &images);
    try renderer.renderGraphicsResources(.{ .commands = &commands, .damage = .{ .regions = &.{commands[3].push_clip_rounded.bounds} } }, &shared.target, null, null, null, &images, false);
    for ([_]*DmabufTarget{ &direct.target, &linear.target, &shared.target }) |output| {
        try std.testing.expect(output.gpu_pending);
        try std.testing.expectEqual(@as(usize, 3 * 32), output.clip_uploads.pixels.?.byte_size);
    }
    @memset(&commands, .{ .clear = Color.rgba(0, 0, 0, 0) });
    try images.release(image);
    try linear.target.wait(&renderer);
    try shared.target.wait(&renderer);
    try vk(c.vkWaitForFences(renderer.device, 1, &direct.target.fence, c.VK_TRUE, std.math.maxInt(u64)), error.DeviceLost);
    try std.testing.expect(try direct.target.ready(&renderer));
    for ([_]*DmabufTarget{ &direct.target, &linear.target, &shared.target }) |output|
        try std.testing.expect(output.clip_uploads.pixels == null and output.clip_uploads.descriptor == null);
    for (0..40) |y| for (0..64) |x| {
        try shared.expectPixel(x, y, transparent[(y * 64 + x) * 4 ..][0..4].*);
        try std.testing.expectEqual(expected[(y * 64 + x) * 4 ..][0..4].*, direct.pixel(x, y));
    };
}

test "Vulkan styled paragraphs rasterize run fonts sizes colors and wrapping" {
    if (comptime !has_freetype) return error.SkipZigTest;
    const software = @import("../software/root.zig");
    var fonts = text.FontCache.init(std.testing.allocator);
    defer fonts.deinit();
    const sans = try text.bundled.acquire(&fonts, .sans, .regular, .roman);
    defer fonts.release(sans) catch unreachable;
    const serif = try text.bundled.acquire(&fonts, .serif, .bold, .italic);
    defer fonts.release(serif) catch unreachable;
    const mono = try text.bundled.acquire(&fonts, .monospace, .semibold, .roman);
    defer fonts.release(mono) catch unreachable;
    var paragraphs = text.ParagraphCache.init(std.testing.allocator, &fonts);
    defer paragraphs.deinit();

    const pieces = [_][]const u8{ "small ", "DISPLAY ", "finish" };
    const sizes = [_]f32{ 10.25, 23.5, 14.75 };
    const colors = [_]Color{
        Color.rgba(235, 65, 75, 255),
        Color.rgba(45, 205, 115, 230),
        Color.rgba(75, 125, 245, 210),
    };
    const candidates = [_]text.FontHandle{ sans, serif, mono };
    var plain: [pieces.len]text.ParagraphHandle = undefined;
    var acquired: usize = 0;
    defer for (plain[0..acquired]) |handle| paragraphs.release(handle) catch unreachable;
    var widest: f32 = 0;
    for (pieces, 0..) |piece, i| {
        plain[i] = try paragraphs.acquire(.{
            .utf8 = piece,
            .language = "en",
            .logical_size = sizes[i],
            .max_width = 500,
            .candidates = candidates[i..][0..1],
            .configuration_revision = 1,
        });
        acquired += 1;
        const layout = try paragraphs.get(plain[i]);
        try std.testing.expectEqual(@as(usize, 1), layout.positioned.lines.len);
        widest = @max(widest, layout.positioned.lines[0].advance);
    }

    const source = pieces[0] ++ pieces[1] ++ pieces[2];
    const runs = [_]text.StyledRun{
        .{ .byte_start = 0, .byte_end = pieces[0].len, .logical_size = sizes[0], .candidate_start = 0, .candidate_count = 1, .color = colors[0] },
        .{ .byte_start = pieces[0].len, .byte_end = pieces[0].len + pieces[1].len, .logical_size = sizes[1], .candidate_start = 1, .candidate_count = 1, .color = colors[1] },
        .{ .byte_start = pieces[0].len + pieces[1].len, .byte_end = source.len, .logical_size = sizes[2], .candidate_start = 2, .candidate_count = 1, .color = colors[2] },
    };
    const rich = try paragraphs.acquire(.{
        .utf8 = source,
        .language = "en",
        .logical_size = 17,
        .max_width = widest + 0.5,
        .candidates = &candidates,
        .runs = &runs,
        .configuration_revision = 1,
    });
    defer paragraphs.release(rich) catch unreachable;
    const rich_layout = try paragraphs.get(rich);
    try std.testing.expectEqual(@as(usize, pieces.len), rich_layout.positioned.lines.len);
    for (rich_layout.positioned.lines, runs) |line, run| {
        try std.testing.expectEqual(run.byte_start, line.byte_start);
        try std.testing.expectEqual(run.byte_end - run.byte_start, line.byte_len);
    }

    // Build the golden from independently laid-out, single-style paragraphs.
    // Their own advances selected the wrap width above, and their own heights
    // determine each baseline; the rich paragraph renderer cannot make this
    // reference agree by incorrectly applying its default size or color.
    const origin = @import("../../core/geometry.zig").PointF{ .x = 7.375, .y = 4.625 };
    const scale: f32 = 1.375;
    var reference_commands: [pieces.len + 1]scene.Command = undefined;
    reference_commands[0] = .{ .clear = Color.rgba(19, 27, 41, 255) };
    var y: f32 = 0;
    for (plain, 0..) |handle, i| {
        reference_commands[i + 1] = .{ .paragraph = .{
            .layout = handle,
            .origin = .{ .x = origin.x, .y = origin.y + y * scale },
            .scale = scale,
            .color = colors[i],
        } };
        y += (try paragraphs.get(handle)).positioned.height();
    }
    const rich_commands = [_]scene.Command{
        reference_commands[0],
        .{ .paragraph = .{ .layout = rich, .origin = origin, .scale = scale, .color = Color.rgba(245, 210, 35, 255) } },
    };
    var software_glyphs = try software.GlyphCache.init(std.testing.allocator, &fonts);
    defer software_glyphs.deinit();
    var expected: [180 * 130 * 4]u8 = undefined;
    try software.renderResources(.{ .commands = &reference_commands }, .{ .pixels = &expected, .width = 180, .height = 130, .stride = 720, .format = .rgba8_unorm, .allocator = std.testing.allocator }, &software_glyphs, null, &paragraphs, null);

    var renderer = init(std.testing.allocator) catch |err| switch (err) {
        error.VulkanUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer renderer.deinit();
    var glyphs = try GlyphCache.init(std.testing.allocator, &fonts, &renderer);
    defer glyphs.deinit();
    var target = try Target.init(&renderer, 180, 130);
    defer target.deinit(&renderer);
    try renderer.renderResources(.{ .commands = &rich_commands }, &target, &glyphs, null, &paragraphs, null);
    var actual: [expected.len]u8 = undefined;
    try target.readPixels(&actual, 720, .rgba8_unorm);
    try std.testing.expectEqualSlices(u8, &expected, &actual);

    var direct = try GraphicsReadback.initMode(&renderer, 180, 130, null, true);
    defer direct.deinit(&renderer);
    var linear = try GraphicsReadback.init(&renderer, 180, 130);
    defer linear.deinit(&renderer);
    for ([_]*GraphicsReadback{ &direct, &linear }) |output| {
        try renderer.renderGraphicsResources(.{ .commands = &rich_commands }, &output.target, &glyphs, null, &paragraphs, null, false);
        try output.target.wait(&renderer);
        for (0..130) |py| for (0..180) |px|
            try output.expectPixel(px, py, expected[(py * 180 + px) * 4 ..][0..4].*);
    }
}
