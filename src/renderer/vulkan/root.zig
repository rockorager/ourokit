//! Synchronous headless Vulkan renderer for the renderer-neutral scene.
//!
//! `Renderer` owns the Vulkan instance, device, queue, and compute pipeline.
//! `Target` owns host-visible Vulkan storage and can later be replaced by an
//! exportable-image target without changing scene semantics. Calls are serial;
//! `render` waits for GPU completion before returning so readback is safe.

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

instance: c.VkInstance,
memory_properties: c.VkPhysicalDeviceMemoryProperties,
device: c.VkDevice,
queue: c.VkQueue,
descriptor_layout: c.VkDescriptorSetLayout,
pipeline_layout: c.VkPipelineLayout,
pipeline: c.VkPipeline,
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

    pub fn init(renderer: *Renderer, width: u32, height: u32) !Target {
        const pixel_count = std.math.mul(u64, width, height) catch return error.InvalidExtent;
        if (pixel_count == 0 or pixel_count > renderer.max_pixels) return error.InvalidExtent;
        const byte_size_u64 = std.math.mul(u64, pixel_count, 4) catch return error.InvalidExtent;
        const byte_size = std.math.cast(usize, byte_size_u64) orelse return error.InvalidExtent;

        var buffer_info: c.VkBufferCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = byte_size,
            .usage = c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
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
            switch (format) {
                .rgba8_unorm => @memcpy(destination, source_row),
                .bgra8_unorm => {
                    for (0..self.width) |x| {
                        destination[x * 4 + 0] = source_row[x * 4 + 2];
                        destination[x * 4 + 1] = source_row[x * 4 + 1];
                        destination[x * 4 + 2] = source_row[x * 4 + 0];
                        destination[x * 4 + 3] = source_row[x * 4 + 3];
                    }
                },
            }
        }
    }
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

pub fn init(allocator: std.mem.Allocator) !Renderer {
    if (builtin.cpu.arch.endian() != .little) return error.UnsupportedEndian;

    var app_info: c.VkApplicationInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = "ourokit",
        .applicationVersion = 1,
        .pEngineName = "ourokit",
        .engineVersion = 1,
        .apiVersion = c.VK_API_VERSION_1_0,
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
    const priority: f32 = 1;
    var queue_info: c.VkDeviceQueueCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueFamilyIndex = selection.queue_family,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    var device_info: c.VkDeviceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = 0,
        .ppEnabledExtensionNames = null,
        .pEnabledFeatures = null,
    };
    var device: c.VkDevice = undefined;
    try vk(c.vkCreateDevice(selection.physical_device, &device_info, null, &device), error.CreateDeviceFailed);
    errdefer c.vkDestroyDevice(device, null);
    var queue: c.VkQueue = undefined;
    c.vkGetDeviceQueue(device, selection.queue_family, 0, &queue);

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
        .memory_properties = memory_properties,
        .device = device,
        .queue = queue,
        .descriptor_layout = descriptor_layout,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
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
    c.vkDestroyPipeline(self.device, self.pipeline, null);
    c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
    c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_layout, null);
    c.vkDestroyDevice(self.device, null);
    c.vkDestroyInstance(self.instance, null);
    self.* = undefined;
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
        .full => self.renderRegion(list.commands, target.width, bounds),
        .regions => |regions| for (regions) |region| {
            const clipped = RectI.intersect(region, bounds);
            if (!clipped.isEmpty()) self.renderRegion(list.commands, target.width, clipped);
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

fn renderRegion(self: *Renderer, commands: []const scene.Command, target_width: u32, damage: RectI) void {
    var clips: [max_clip_depth + 1]RectI = undefined;
    clips[0] = damage;
    var depth: usize = 0;
    for (commands) |command| switch (command) {
        .clear => |color| self.fill(target_width, damage, color, .source),
        .push_clip_rect => |clip| {
            depth += 1;
            clips[depth] = RectI.intersect(clips[depth - 1], clip);
        },
        .pop_clip => depth -= 1,
        .solid_rectangle => |rectangle| self.fill(
            target_width,
            RectI.intersect(rectangle.bounds, clips[depth]),
            rectangle.color,
            rectangle.blend,
        ),
    };
}

fn fill(self: *Renderer, target_width: u32, bounds: RectI, color: Color, blend: scene.BlendMode) void {
    if (bounds.isEmpty()) return;
    const source = color.premultiplied();
    const push: Push = .{
        .target_width = target_width,
        .left = bounds.x,
        .top = bounds.y,
        .right = @intCast(@as(i64, bounds.x) + bounds.width),
        .bottom = @intCast(@as(i64, bounds.y) + bounds.height),
        .source = @as(u32, source.r) |
            (@as(u32, source.g) << 8) |
            (@as(u32, source.b) << 16) |
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
        var queue_count: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, null);
        const queues = try allocator.alloc(c.VkQueueFamilyProperties, queue_count);
        defer allocator.free(queues);
        c.vkGetPhysicalDeviceQueueFamilyProperties(physical_device, &queue_count, queues.ptr);
        for (queues[0..queue_count], 0..) |queue, index| {
            if (queue.queueCount > 0 and queue.queueFlags & c.VK_QUEUE_COMPUTE_BIT != 0) return .{
                .physical_device = physical_device,
                .queue_family = @intCast(index),
            };
        }
    }
    return error.ComputeQueueUnavailable;
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
