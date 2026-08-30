//! Vulkan renderer for the renderer-neutral scene.
//!
//! Exact headless `Target` rendering is synchronous and uses integer compute.
//! Presentation targets use an asynchronous graphics pipeline and render
//! directly into modifier-selected exportable images.

const Renderer = @This();

const std = @import("std");
const builtin = @import("builtin");
const Color = @import("../../core/color.zig").Color;
const RectI = @import("../../core/geometry.zig").RectI;
const scene = @import("../../scene/root.zig");

const c = @cImport({
    @cInclude("vulkan/vulkan.h");
});

const max_clip_depth = 64;
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
presentation_render_pass: c.VkRenderPass,
presentation_pipeline_layout: c.VkPipelineLayout,
presentation_pipeline: c.VkPipeline,
descriptor_pool: c.VkDescriptorPool,
command_pool: c.VkCommandPool,
command_buffer: c.VkCommandBuffer,
fence: c.VkFence,
max_pixels: u64,

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
        const pixel_count = std.math.mul(u64, width, height) catch return error.InvalidExtent;
        if (pixel_count == 0 or pixel_count > renderer.max_pixels) return error.InvalidExtent;
        const byte_size_u64 = std.math.mul(u64, pixel_count, 4) catch return error.InvalidExtent;
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
        const source: [*]const u8 = @ptrCast(self.mapping);
        for (0..self.height) |y| {
            const source_row = source[y * row_bytes ..][0..row_bytes];
            const destination = pixels[y * stride ..][0..row_bytes];
            switch (self.format) {
                .rgba => switch (format) {
                    .rgba8_unorm => @memcpy(destination, source_row),
                    .bgra8_unorm => swapRedBlue(destination, source_row, self.width),
                },
                .bgra => switch (format) {
                    .rgba8_unorm => swapRedBlue(destination, source_row, self.width),
                    .bgra8_unorm => @memcpy(destination, source_row),
                },
            }
        }
    }

    fn swapRedBlue(destination: []u8, source: []const u8, width: u32) void {
        for (0..width) |x| {
            destination[x * 4 + 0] = source[x * 4 + 2];
            destination[x * 4 + 1] = source[x * 4 + 1];
            destination[x * 4 + 2] = source[x * 4 + 0];
            destination[x * 4 + 3] = source[x * 4 + 3];
        }
    }
};

const StorageFormat = enum { rgba, bgra };

pub const DmabufPlane = struct {
    offset: u32,
    stride: u32,
};

/// Exportable BGRA render target. Command and fence state is per target so
/// separate presentation slots can execute concurrently.
pub const DmabufTarget = struct {
    image: c.VkImage,
    memory: c.VkDeviceMemory,
    view: c.VkImageView,
    framebuffer: c.VkFramebuffer,
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

    pub fn init(renderer: *Renderer, width: u32, height: u32, modifier: u64) !DmabufTarget {
        if (!renderer.dmabuf_enabled) return error.DmabufUnavailable;
        if (!renderer.supportsDmabufModifier(modifier)) return error.DmabufModifierUnavailable;

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
            .format = c.VK_FORMAT_B8G8R8A8_UNORM,
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
        const plane_count = renderer.modifierPlaneCount(modifier_properties.drmFormatModifier) orelse
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
            .format = c.VK_FORMAT_B8G8R8A8_UNORM,
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
        var framebuffer_info: c.VkFramebufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .renderPass = renderer.presentation_render_pass,
            .attachmentCount = 1,
            .pAttachments = &view,
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
        c.vkDestroySemaphore(renderer.device, self.timeline, null);
        c.vkDestroyFence(renderer.device, self.fence, null);
        c.vkDestroyCommandPool(renderer.device, self.command_pool, null);
        c.vkDestroyFramebuffer(renderer.device, self.framebuffer, null);
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
    color: [4]f32,
    target_size: [2]f32,
    padding: [2]f32 = .{ 0, 0 },
    bounds: [4]i32,
};

const Push = extern struct {
    target_width: u32,
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    source: u32,
    source_over: u32,
};

const PresentationObjects = struct {
    render_pass: c.VkRenderPass,
    layout: c.VkPipelineLayout,
    pipeline: c.VkPipeline,

    fn deinit(self: PresentationObjects, device: c.VkDevice) void {
        c.vkDestroyPipeline(device, self.pipeline, null);
        c.vkDestroyPipelineLayout(device, self.layout, null);
        c.vkDestroyRenderPass(device, self.render_pass, null);
    }
};

fn createPresentationPipeline(device: c.VkDevice) !PresentationObjects {
    var attachment: c.VkAttachmentDescription = .{
        .flags = 0,
        .format = c.VK_FORMAT_B8G8R8A8_UNORM,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_LOAD,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .finalLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    var attachment_reference: c.VkAttachmentReference = .{
        .attachment = 0,
        .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    var subpass: c.VkSubpassDescription = .{
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
    var render_pass_info: c.VkRenderPassCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .attachmentCount = 1,
        .pAttachments = &attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 0,
        .pDependencies = null,
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
    return .{ .render_pass = render_pass, .layout = layout, .pipeline = pipeline };
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
    const dmabuf_enabled = try supportsDeviceExtensions(allocator, selection.physical_device, &dmabuf_extensions);
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

    var binding: c.VkDescriptorSetLayoutBinding = .{
        .binding = 0,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
        .pImmutableSamplers = null,
    };
    var descriptor_layout_info: c.VkDescriptorSetLayoutCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .bindingCount = 1,
        .pBindings = &binding,
    };
    var descriptor_layout: c.VkDescriptorSetLayout = undefined;
    try vk(c.vkCreateDescriptorSetLayout(device, &descriptor_layout_info, null, &descriptor_layout), error.CreateDescriptorLayoutFailed);
    errdefer c.vkDestroyDescriptorSetLayout(device, descriptor_layout, null);

    var push_range: c.VkPushConstantRange = .{
        .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT,
        .offset = 0,
        .size = @sizeOf(Push),
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

    const presentation = try createPresentationPipeline(device);
    errdefer presentation.deinit(device);

    var pool_size: c.VkDescriptorPoolSize = .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1 };
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
        .presentation_render_pass = presentation.render_pass,
        .presentation_pipeline_layout = presentation.layout,
        .presentation_pipeline = presentation.pipeline,
        .descriptor_pool = descriptor_pool,
        .command_pool = command_pool,
        .command_buffer = command_buffer,
        .fence = fence,
        .max_pixels = @min(
            @as(u64, properties.limits.maxStorageBufferRange) / 4,
            @as(u64, properties.limits.maxComputeWorkGroupCount[0]) * local_size,
        ),
    };
}

pub fn deinit(self: *Renderer) void {
    _ = c.vkDeviceWaitIdle(self.device);
    c.vkDestroyFence(self.device, self.fence, null);
    c.vkDestroyCommandPool(self.device, self.command_pool, null);
    c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
    c.vkDestroyPipeline(self.device, self.presentation_pipeline, null);
    c.vkDestroyPipelineLayout(self.device, self.presentation_pipeline_layout, null);
    c.vkDestroyRenderPass(self.device, self.presentation_render_pass, null);
    c.vkDestroyPipeline(self.device, self.pipeline, null);
    c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
    c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_layout, null);
    c.vkDestroyDevice(self.device, null);
    c.vkDestroyInstance(self.instance, null);
    self.* = undefined;
}

pub fn supportsDmabuf(self: *const Renderer) bool {
    return self.dmabuf_enabled;
}

pub fn supportsDmabufModifier(self: *const Renderer, modifier: u64) bool {
    return self.dmabuf_enabled and supportsDmabufModifierOnDevice(self.physical_device, modifier);
}

pub fn matchesDrmDevice(self: *const Renderer, device_bytes: []const u8) bool {
    if (device_bytes.len != @sizeOf(u64)) return false;
    const device = std.mem.readInt(u64, device_bytes[0..8], .little);
    return (self.drm_primary_device != null and self.drm_primary_device.? == device) or
        (self.drm_render_device != null and self.drm_render_device.? == device);
}

fn modifierPlaneCount(self: *const Renderer, modifier: u64) ?u32 {
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
    c.vkGetPhysicalDeviceFormatProperties2(self.physical_device, c.VK_FORMAT_B8G8R8A8_UNORM, &properties);
    count = list.drmFormatModifierCount;
    if (count == 0 or count > 256) return null;
    var entries: [256]c.VkDrmFormatModifierPropertiesEXT = undefined;
    list.drmFormatModifierCount = count;
    list.pDrmFormatModifierProperties = &entries;
    c.vkGetPhysicalDeviceFormatProperties2(self.physical_device, c.VK_FORMAT_B8G8R8A8_UNORM, &properties);
    for (entries[0..list.drmFormatModifierCount]) |entry|
        if (entry.drmFormatModifier == modifier) return entry.drmFormatModifierPlaneCount;
    return null;
}

pub fn render(self: *Renderer, list: scene.DisplayList, target: *Target) !void {
    try list.validate();
    try validateClipDepth(list.commands);
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
    var buffer_info: c.VkDescriptorBufferInfo = .{ .buffer = target.buffer, .offset = 0, .range = target.byte_size };
    var descriptor_write: c.VkWriteDescriptorSet = .{
        .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .pNext = null,
        .dstSet = descriptor_set,
        .dstBinding = 0,
        .dstArrayElement = 0,
        .descriptorCount = 1,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        .pImageInfo = null,
        .pBufferInfo = &buffer_info,
        .pTexelBufferView = null,
    };
    c.vkUpdateDescriptorSets(self.device, 1, &descriptor_write, 0, null);

    try vk(c.vkResetCommandPool(self.device, self.command_pool, 0), error.ResetCommandPoolFailed);
    var begin_info: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try vk(c.vkBeginCommandBuffer(self.command_buffer, &begin_info), error.BeginCommandBufferFailed);
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
        .full => self.renderRegion(list.commands, target, bounds),
        .regions => |regions| for (regions) |region| {
            const clipped = RectI.intersect(region, bounds);
            if (!clipped.isEmpty()) self.renderRegion(list.commands, target, clipped);
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
    try vk(c.vkWaitForFences(self.device, 1, &self.fence, c.VK_TRUE, std.math.maxInt(u64)), error.DeviceLost);
}

/// Records and submits direct rendering into an exportable image. The target
/// owns its fence, so this returns after queue submission rather than waiting
/// for the GPU. Slot reuse must additionally wait for `ready` and compositor
/// release.
pub fn renderDmabuf(self: *Renderer, list: scene.DisplayList, target: *DmabufTarget) !void {
    try list.validate();
    try validateClipDepth(list.commands);
    if (!try target.ready(self)) return error.TargetBusy;
    try vk(c.vkResetCommandBuffer(target.command_buffer, 0), error.ResetCommandBufferFailed);
    var begin_info: c.VkCommandBufferBeginInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    try vk(c.vkBeginCommandBuffer(target.command_buffer, &begin_info), error.BeginCommandBufferFailed);
    var image_barrier: c.VkImageMemoryBarrier = .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = null,
        .srcAccessMask = 0,
        .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .oldLayout = target.layout,
        .newLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .srcQueueFamilyIndex = if (target.layout == c.VK_IMAGE_LAYOUT_UNDEFINED)
            c.VK_QUEUE_FAMILY_IGNORED
        else
            c.VK_QUEUE_FAMILY_FOREIGN_EXT,
        .dstQueueFamilyIndex = if (target.layout == c.VK_IMAGE_LAYOUT_UNDEFINED)
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
        .renderPass = self.presentation_render_pass,
        .framebuffer = target.framebuffer,
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = target.width, .height = target.height },
        },
        .clearValueCount = 0,
        .pClearValues = null,
    };
    c.vkCmdBeginRenderPass(target.command_buffer, &render_pass_begin, c.VK_SUBPASS_CONTENTS_INLINE);
    c.vkCmdBindPipeline(target.command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.presentation_pipeline);
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
    switch (list.damage) {
        .full => self.renderPresentationRegion(list.commands, target, bounds),
        .regions => |regions| for (regions) |region| {
            const clipped = RectI.intersect(region, bounds);
            if (!clipped.isEmpty()) self.renderPresentationRegion(list.commands, target, clipped);
        },
    }
    c.vkCmdEndRenderPass(target.command_buffer);

    image_barrier.srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    image_barrier.dstAccessMask = 0;
    image_barrier.oldLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
    image_barrier.newLayout = c.VK_IMAGE_LAYOUT_GENERAL;
    image_barrier.srcQueueFamilyIndex = self.queue_family;
    image_barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_FOREIGN_EXT;
    c.vkCmdPipelineBarrier(
        target.command_buffer,
        c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &image_barrier,
    );
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
    target.layout = c.VK_IMAGE_LAYOUT_GENERAL;
    target.gpu_pending = true;
    if (target.explicit_sync) {
        target.acquire_point = acquire_point;
        target.release_point = acquire_point + 1;
    }
}

fn renderPresentationRegion(self: *Renderer, commands: []const scene.Command, target: *const DmabufTarget, damage: RectI) void {
    var clips: [max_clip_depth + 1]RectI = undefined;
    clips[0] = damage;
    var depth: usize = 0;
    for (commands) |command| switch (command) {
        .clear => |color| self.presentationFill(target, damage, color, .source),
        .push_clip_rect => |clip| {
            depth += 1;
            clips[depth] = RectI.intersect(clips[depth - 1], clip);
        },
        .pop_clip => depth -= 1,
        .solid_rectangle => |rectangle| self.presentationFill(
            target,
            RectI.intersect(rectangle.bounds, clips[depth]),
            rectangle.color,
            rectangle.blend,
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
    const source = color.premultiplied();
    const rectangle: c.VkClearRect = .{
        .rect = .{
            .offset = .{ .x = bounds.x, .y = bounds.y },
            .extent = .{ .width = bounds.width, .height = bounds.height },
        },
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
    if (blend == .source or source.a == 255) {
        var attachment: c.VkClearAttachment = .{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .colorAttachment = 0,
            .clearValue = .{ .color = .{ .float32 = .{
                @as(f32, @floatFromInt(source.r)) / 255,
                @as(f32, @floatFromInt(source.g)) / 255,
                @as(f32, @floatFromInt(source.b)) / 255,
                @as(f32, @floatFromInt(source.a)) / 255,
            } } },
        };
        c.vkCmdClearAttachments(target.command_buffer, 1, &attachment, 1, &rectangle);
        return;
    }
    var scissor = rectangle.rect;
    c.vkCmdSetScissor(target.command_buffer, 0, 1, &scissor);
    const right = @as(i64, bounds.x) + bounds.width;
    const bottom = @as(i64, bounds.y) + bounds.height;
    const push: PresentationPush = .{
        .color = .{
            @as(f32, @floatFromInt(source.r)) / 255,
            @as(f32, @floatFromInt(source.g)) / 255,
            @as(f32, @floatFromInt(source.b)) / 255,
            @as(f32, @floatFromInt(source.a)) / 255,
        },
        .target_size = .{ @floatFromInt(target.width), @floatFromInt(target.height) },
        .bounds = .{ bounds.x, bounds.y, @intCast(right), @intCast(bottom) },
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

fn validateClipDepth(commands: []const scene.Command) !void {
    var depth: usize = 0;
    for (commands) |command| switch (command) {
        .push_clip_rect => {
            if (depth == max_clip_depth) return error.ClipStackOverflow;
            depth += 1;
        },
        .pop_clip => depth -= 1,
        else => {},
    };
}

fn renderRegion(self: *Renderer, commands: []const scene.Command, target: *const Target, damage: RectI) void {
    var clips: [max_clip_depth + 1]RectI = undefined;
    clips[0] = damage;
    var depth: usize = 0;
    for (commands) |command| switch (command) {
        .clear => |color| self.fill(target, damage, color, .source),
        .push_clip_rect => |clip| {
            depth += 1;
            clips[depth] = RectI.intersect(clips[depth - 1], clip);
        },
        .pop_clip => depth -= 1,
        .solid_rectangle => |rectangle| self.fill(
            target,
            RectI.intersect(rectangle.bounds, clips[depth]),
            rectangle.color,
            rectangle.blend,
        ),
    };
}

fn fill(self: *Renderer, target: *const Target, bounds: RectI, color: Color, blend: scene.BlendMode) void {
    if (bounds.isEmpty()) return;
    const source = color.premultiplied();
    const push: Push = .{
        .target_width = target.width,
        .left = bounds.x,
        .top = bounds.y,
        .right = @intCast(@as(i64, bounds.x) + bounds.width),
        .bottom = @intCast(@as(i64, bounds.y) + bounds.height),
        .source = @as(u32, if (target.format == .rgba) source.r else source.b) |
            (@as(u32, source.g) << 8) |
            (@as(u32, if (target.format == .rgba) source.b else source.r) << 16) |
            (@as(u32, source.a) << 24),
        .source_over = @intFromBool(blend == .source_over and source.a != 255),
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

fn supportsDmabufModifierOnDevice(physical_device: c.VkPhysicalDevice, modifier: u64) bool {
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
    c.vkGetPhysicalDeviceFormatProperties2(physical_device, c.VK_FORMAT_B8G8R8A8_UNORM, &format_properties);
    if (modifier_list.drmFormatModifierCount == 0 or modifier_list.drmFormatModifierCount > 256) return false;
    var modifiers: [256]c.VkDrmFormatModifierPropertiesEXT = undefined;
    modifier_list.pDrmFormatModifierProperties = &modifiers;
    c.vkGetPhysicalDeviceFormatProperties2(physical_device, c.VK_FORMAT_B8G8R8A8_UNORM, &format_properties);
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
        .format = c.VK_FORMAT_B8G8R8A8_UNORM,
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
    try std.testing.expectError(error.ClipStackOverflow, validateClipDepth(&commands));
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
