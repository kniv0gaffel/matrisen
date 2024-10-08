const std = @import("std");
const t = @import("types.zig");
const c = @import("clibs.zig");
const log = std.log.scoped(.vkInit);

pub const VkiInstanceOpts = struct {
    application_name: [:0]const u8 = "vki",
    application_version: u32 = c.VK_MAKE_VERSION(1, 0, 0),
    engine_name: ?[:0]const u8 = null,
    engine_version: u32 = c.VK_MAKE_VERSION(1, 0, 0),
    api_version: u32 = c.VK_MAKE_VERSION(1, 0, 0),
    debug: bool = false,
    debug_callback: c.PFN_vkDebugUtilsMessengerCallbackEXT = null,
    required_extensions: []const [*c]const u8 = &.{},
    alloc_cb: ?*c.VkAllocationCallbacks = null,
};

pub const Instance = struct {
    handle: c.VkInstance = null,
    debug_messenger: c.VkDebugUtilsMessengerEXT = null,

    pub fn create(alloc: std.mem.Allocator, opts: VkiInstanceOpts) !Instance {
        if (opts.api_version > c.VK_MAKE_VERSION(1, 0, 0)) {
            var api_requested = opts.api_version;
            try check_vk(c.vkEnumerateInstanceVersion(@ptrCast(&api_requested)));
        }

        var enable_validation = opts.debug;

        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Get supported layers and extensions
        var layer_count: u32 = undefined;
        try check_vk(c.vkEnumerateInstanceLayerProperties(&layer_count, null));
        const layer_props = try arena.alloc(c.VkLayerProperties, layer_count);
        try check_vk(c.vkEnumerateInstanceLayerProperties(&layer_count, layer_props.ptr));

        var extension_count: u32 = undefined;
        try check_vk(c.vkEnumerateInstanceExtensionProperties(null, &extension_count, null));
        const extension_props = try arena.alloc(c.VkExtensionProperties, extension_count);
        try check_vk(c.vkEnumerateInstanceExtensionProperties(null, &extension_count, extension_props.ptr));

        // Check if the validation layer is supported
        var layers = std.ArrayListUnmanaged([*c]const u8){};
        if (enable_validation) {
            enable_validation = blk: for (layer_props) |layer_prop| {
                const layer_name: [*c]const u8 = @ptrCast(layer_prop.layerName[0..]);
                const validation_layer_name: [*c]const u8 = "VK_LAYER_KHRONOS_validation";
                if (std.mem.eql(u8, std.mem.span(validation_layer_name), std.mem.span(layer_name))) {
                    try layers.append(arena, validation_layer_name);
                    break :blk true;
                }
            } else false;
        }

        var extensions = std.ArrayListUnmanaged([*c]const u8){};
        const ExtensionFinder = struct {
            fn find(name: [*c]const u8, props: []c.VkExtensionProperties) bool {
                for (props) |prop| {
                    const prop_name: [*c]const u8 = @ptrCast(prop.extensionName[0..]);
                    if (std.mem.eql(u8, std.mem.span(name), std.mem.span(prop_name))) {
                        return true;
                    }
                }
                return false;
            }
        };

        for (opts.required_extensions) |required_ext| {
            if (ExtensionFinder.find(required_ext, extension_props)) {
                try extensions.append(arena, required_ext);
            } else {
                log.err("Required vulkan extension not supported: {s}", .{required_ext});
                return error.vulkan_extension_not_supported;
            }
        }

        if (enable_validation and ExtensionFinder.find("VK_EXT_debug_utils", extension_props)) {
            try extensions.append(arena, "VK_EXT_debug_utils");
        } else {
            enable_validation = false;
        }

        const app_info = std.mem.zeroInit(c.VkApplicationInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .apiVersion = opts.api_version,
            .pApplicationName = opts.application_name,
            .pEngineName = opts.engine_name orelse opts.application_name,
        });

        const instance_info = std.mem.zeroInit(c.VkInstanceCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = @as(u32, @intCast(layers.items.len)),
            .ppEnabledLayerNames = layers.items.ptr,
            .enabledExtensionCount = @as(u32, @intCast(extensions.items.len)),
            .ppEnabledExtensionNames = extensions.items.ptr,
        });

        var instance: c.VkInstance = undefined;
        try check_vk(c.vkCreateInstance(&instance_info, opts.alloc_cb, &instance));
        log.info("Created vulkan instance.", .{});

        const debug_messenger = if (enable_validation)
            try create_debug_callback(instance, opts)
        else
            null;

        return .{ .handle = instance, .debug_messenger = debug_messenger };
    }
};

pub const PhysicalDeviceSelectionCriteria = enum {
    First,
    PreferDiscrete,
    PreferIntegrated,
};

pub const PhysicalDeviceSelectOpts = struct { min_api_version: u32 = c.VK_MAKE_VERSION(1, 3, 0), required_extensions: []const [*c]const u8 = &.{}, surface: ?c.VkSurfaceKHR, criteria: PhysicalDeviceSelectionCriteria = .PreferDiscrete };

pub const PhysicalDevice = struct {
    handle: c.VkPhysicalDevice = null,
    properties: c.VkPhysicalDeviceProperties = undefined,
    graphics_queue_family: u32 = undefined,
    present_queue_family: u32 = undefined,
    compute_queue_family: u32 = undefined,
    transfer_queue_family: u32 = undefined,

    const INVALID_QUEUE_FAMILY_INDEX = std.math.maxInt(u32);

    pub fn select(a: std.mem.Allocator, instance: c.VkInstance, opts: PhysicalDeviceSelectOpts) !PhysicalDevice {
        var physical_device_count: u32 = undefined;
        try check_vk(c.vkEnumeratePhysicalDevices(instance, &physical_device_count, null));

        var arena_state = std.heap.ArenaAllocator.init(a);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const physical_devices = try arena.alloc(c.VkPhysicalDevice, physical_device_count);
        try check_vk(c.vkEnumeratePhysicalDevices(instance, &physical_device_count, physical_devices.ptr));

        var suitable_pd: ?PhysicalDevice = null;

        for (physical_devices) |device| {
            const pd = make_physical_device(a, device, opts.surface) catch continue;
            _ = is_physical_device_suitable(a, pd, opts) catch continue;
            switch (opts.criteria) {
                PhysicalDeviceSelectionCriteria.First => {
                    suitable_pd = pd;
                    break;
                },
                PhysicalDeviceSelectionCriteria.PreferDiscrete => {
                    if (pd.properties.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
                        suitable_pd = pd;
                        break;
                    } else if (suitable_pd == null) {
                        suitable_pd = pd;
                    }
                },
                PhysicalDeviceSelectionCriteria.PreferIntegrated => {
                    if (pd.properties.deviceType == c.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU) {
                        suitable_pd = pd;
                        break;
                    } else if (suitable_pd == null) {
                        suitable_pd = pd;
                    }
                },
            }
        }

        if (suitable_pd == null) {
            log.err("No suitable physical device found.", .{});
            return error.vulkan_no_suitable_physical_device;
        }
        const res = suitable_pd.?;

        const device_name = @as([*:0]const u8, @ptrCast(@alignCast(res.properties.deviceName[0..])));
        log.info("Selected physical device: {s}", .{device_name});

        return res;
    }

    fn make_physical_device(a: std.mem.Allocator, device: c.VkPhysicalDevice, surface: ?c.VkSurfaceKHR) !PhysicalDevice {
        var props = std.mem.zeroInit(c.VkPhysicalDeviceProperties, .{});
        c.vkGetPhysicalDeviceProperties(device, &props);

        var graphics_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;
        var present_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;
        var compute_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;
        var transfer_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;

        var queue_family_count: u32 = undefined;
        c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);
        const queue_families = try a.alloc(c.VkQueueFamilyProperties, queue_family_count);
        defer a.free(queue_families);
        c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

        for (queue_families, 0..) |queue_family, i| {
            const index: u32 = @intCast(i);

            if (graphics_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
                queue_family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0)
            {
                graphics_queue_family = index;
            }

            if (surface) |surf| {
                if (present_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX) {
                    var present_support: c.VkBool32 = undefined;
                    try check_vk(c.vkGetPhysicalDeviceSurfaceSupportKHR(device, index, surf, &present_support));
                    if (present_support == c.VK_TRUE) {
                        present_queue_family = index;
                    }
                }
            }

            if (compute_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
                queue_family.queueFlags & c.VK_QUEUE_COMPUTE_BIT != 0)
            {
                compute_queue_family = index;
            }

            if (transfer_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
                queue_family.queueFlags & c.VK_QUEUE_TRANSFER_BIT != 0)
            {
                transfer_queue_family = index;
            }

            if (graphics_queue_family != PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
                present_queue_family != PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
                compute_queue_family != PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
                transfer_queue_family != PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX)
            {
                break;
            }
        }

        return .{
            .handle = device,
            .properties = props,
            .graphics_queue_family = graphics_queue_family,
            .present_queue_family = present_queue_family,
            .compute_queue_family = compute_queue_family,
            .transfer_queue_family = transfer_queue_family,
        };
    }

    fn is_physical_device_suitable(a: std.mem.Allocator, device: PhysicalDevice, opts: PhysicalDeviceSelectOpts) !bool {
        if (device.properties.apiVersion < opts.min_api_version) {
            return false;
        }

        if (device.graphics_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX or
            device.present_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX or
            device.compute_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX or
            device.transfer_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX)
        {
            return false;
        }

        var arena_state = std.heap.ArenaAllocator.init(a);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        if (opts.surface) |surf| {
            const swapchain_support = try SwapchainSupportInfo.init(arena, device.handle, surf);
            defer swapchain_support.deinit(arena);
            if (swapchain_support.formats.len == 0 or swapchain_support.present_modes.len == 0) {
                return false;
            }
        }

        if (opts.required_extensions.len > 0) {
            var device_extension_count: u32 = undefined;
            try check_vk(c.vkEnumerateDeviceExtensionProperties(device.handle, null, &device_extension_count, null));
            const device_extensions = try arena.alloc(c.VkExtensionProperties, device_extension_count);
            try check_vk(c.vkEnumerateDeviceExtensionProperties(device.handle, null, &device_extension_count, device_extensions.ptr));

            _ = blk: for (opts.required_extensions) |req_ext| {
                for (device_extensions) |device_ext| {
                    const device_ext_name: [*c]const u8 = @ptrCast(device_ext.extensionName[0..]);
                    if (std.mem.eql(u8, std.mem.span(req_ext), std.mem.span(device_ext_name))) {
                        break :blk true;
                    }
                }
            } else return false;
        }

        return true;
    }
};

const DeviceCreateOpts = struct {
    physical_device: PhysicalDevice,
    extensions: []const [*c]const u8 = &.{},
    features: ?c.VkPhysicalDeviceFeatures = null,
    alloc_cb: ?*const c.VkAllocationCallbacks = null,
    pnext: ?*const anyopaque = null,
};

pub const Device = struct {
    handle: c.VkDevice = null,
    graphics_queue: c.VkQueue = null,
    present_queue: c.VkQueue = null,
    compute_queue: c.VkQueue = null,
    transfer_queue: c.VkQueue = null,

    pub fn create(a: std.mem.Allocator, opts: DeviceCreateOpts) !Device {
        var arena_state = std.heap.ArenaAllocator.init(a);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var queue_create_infos = std.ArrayListUnmanaged(c.VkDeviceQueueCreateInfo){};
        const queue_priorities: f32 = 1.0;
        var queue_family_set = std.AutoArrayHashMapUnmanaged(u32, void){};
        try queue_family_set.put(arena, opts.physical_device.graphics_queue_family, {});
        try queue_family_set.put(arena, opts.physical_device.present_queue_family, {});
        try queue_family_set.put(arena, opts.physical_device.compute_queue_family, {});
        try queue_family_set.put(arena, opts.physical_device.transfer_queue_family, {});
        var qfi_iter = queue_family_set.iterator();
        try queue_create_infos.ensureTotalCapacity(arena, queue_family_set.count());
        while (qfi_iter.next()) |qfi| {
            try queue_create_infos.append(arena, std.mem.zeroInit(c.VkDeviceQueueCreateInfo, .{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = qfi.key_ptr.*,
                .queueCount = 1,
                .pQueuePriorities = &queue_priorities,
            }));
        }

        const device_info = std.mem.zeroInit(c.VkDeviceCreateInfo, .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = opts.pnext,
            .queueCreateInfoCount = @as(u32, @intCast(queue_create_infos.items.len)),
            .pQueueCreateInfos = queue_create_infos.items.ptr,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = @as(u32, @intCast(opts.extensions.len)),
            .ppEnabledExtensionNames = opts.extensions.ptr,
            .pEnabledFeatures = if (opts.features) |capture| &capture else null,
        });

        var device: c.VkDevice = undefined;
        try check_vk(c.vkCreateDevice(opts.physical_device.handle, &device_info, opts.alloc_cb, &device));

        var graphics_queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(device, opts.physical_device.graphics_queue_family, 0, &graphics_queue);
        var present_queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(device, opts.physical_device.present_queue_family, 0, &present_queue);
        var compute_queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(device, opts.physical_device.compute_queue_family, 0, &compute_queue);
        var transfer_queue: c.VkQueue = undefined;
        c.vkGetDeviceQueue(device, opts.physical_device.transfer_queue_family, 0, &transfer_queue);

        return .{
            .handle = device,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .compute_queue = compute_queue,
            .transfer_queue = transfer_queue,
        };
    }
};

const SwapchainSupportInfo = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR = undefined,
    formats: []c.VkSurfaceFormatKHR = &.{},
    present_modes: []c.VkPresentModeKHR = &.{},

    fn init(a: std.mem.Allocator, device: c.VkPhysicalDevice, surface: c.VkSurfaceKHR) !SwapchainSupportInfo {
        var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        try check_vk(c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &capabilities));

        var format_count: u32 = undefined;
        try check_vk(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null));
        const formats = try a.alloc(c.VkSurfaceFormatKHR, format_count);
        try check_vk(c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, formats.ptr));

        var present_mode_count: u32 = undefined;
        try check_vk(c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null));
        const present_modes = try a.alloc(c.VkPresentModeKHR, present_mode_count);
        try check_vk(c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, present_modes.ptr));

        return .{
            .capabilities = capabilities,
            .formats = formats,
            .present_modes = present_modes,
        };
    }

    fn deinit(self: *const SwapchainSupportInfo, a: std.mem.Allocator) void {
        a.free(self.formats);
        a.free(self.present_modes);
    }
};

pub const SwapchainCreateOpts = struct {
    physical_device: c.VkPhysicalDevice,
    graphics_queue_family: u32,
    present_queue_family: u32,
    device: c.VkDevice,
    surface: c.VkSurfaceKHR,
    old_swapchain: c.VkSwapchainKHR = null,
    format: c.VkSurfaceFormatKHR = undefined,
    vsync: bool = false,
    triple_buffer: bool = false,
    window_width: u32 = 0,
    window_height: u32 = 0,
    alloc_cb: ?*c.VkAllocationCallbacks = null,
};

pub const Swapchain = struct {
    handle: c.VkSwapchainKHR = null,
    images: []c.VkImage = &.{},
    image_views: []c.VkImageView = &.{},
    format: c.VkFormat = undefined,
    extent: c.VkExtent2D = undefined,

    pub fn create(a: std.mem.Allocator, opts: SwapchainCreateOpts) !Swapchain {
        const support_info = try SwapchainSupportInfo.init(a, opts.physical_device, opts.surface);
        defer support_info.deinit(a);

        const format = pick_format(support_info.formats, opts);
        const present_mode = pick_present_mode(support_info.present_modes, opts);
        // log.info("Selected swapchain format: {d}, present mode: {d}", .{ format, present_mode });
        const extent = make_extent(support_info.capabilities, opts);

        const image_count = blk: {
            const desired_count = support_info.capabilities.minImageCount + 1;
            if (support_info.capabilities.maxImageCount > 0) {
                break :blk @min(desired_count, support_info.capabilities.maxImageCount);
            }
            break :blk desired_count;
        };

        var swapchain_info = std.mem.zeroInit(c.VkSwapchainCreateInfoKHR, .{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .surface = opts.surface,
            .minImageCount = image_count,
            .imageFormat = format,
            .imageColorSpace = c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .preTransform = support_info.capabilities.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = present_mode,
            .clipped = c.VK_TRUE,
            .oldSwapchain = opts.old_swapchain,
        });

        if (opts.graphics_queue_family != opts.present_queue_family) {
            const queue_family_indices: []const u32 = &.{
                opts.graphics_queue_family,
                opts.present_queue_family,
            };
            swapchain_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
            swapchain_info.queueFamilyIndexCount = 2;
            swapchain_info.pQueueFamilyIndices = queue_family_indices.ptr;
        } else {
            swapchain_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        }

        var swapchain: c.VkSwapchainKHR = undefined;
        try check_vk(c.vkCreateSwapchainKHR(opts.device, &swapchain_info, opts.alloc_cb, &swapchain));
        errdefer c.vkDestroySwapchainKHR(opts.device, swapchain, opts.alloc_cb);

        // Try and fetch the images from the swpachain.
        var swapchain_image_count: u32 = undefined;
        try check_vk(c.vkGetSwapchainImagesKHR(opts.device, swapchain, &swapchain_image_count, null));
        const swapchain_images = try a.alloc(c.VkImage, swapchain_image_count);
        errdefer a.free(swapchain_images);
        try check_vk(c.vkGetSwapchainImagesKHR(opts.device, swapchain, &swapchain_image_count, swapchain_images.ptr));

        // Create image views for the swapchain images.
        const swapchain_image_views = try a.alloc(c.VkImageView, swapchain_image_count);
        errdefer a.free(swapchain_image_views);

        for (swapchain_images, swapchain_image_views) |image, *view| {
            view.* = try create_image_view(opts.device, image, format, c.VK_IMAGE_ASPECT_COLOR_BIT, opts.alloc_cb);
        }

        return .{
            .handle = swapchain,
            .images = swapchain_images,
            .image_views = swapchain_image_views,
            .format = format,
            .extent = extent,
        };
    }

    fn pick_format(formats: []const c.VkSurfaceFormatKHR, opts: SwapchainCreateOpts) c.VkFormat {
        const desired_format = opts.format;
        for (formats) |format| {
            if (format.format == desired_format.format and
                format.colorSpace == desired_format.colorSpace)
            {
                return format.format;
            }
        }
        return formats[0].format;
    }

    fn pick_present_mode(modes: []const c.VkPresentModeKHR, opts: SwapchainCreateOpts) c.VkPresentModeKHR {
        if (opts.vsync == true) {
            for (modes) |mode| {
                if (mode == c.VK_PRESENT_MODE_FIFO_RELAXED_KHR) {
                    return mode;
                }
            }
        } else {
            for (modes) |mode| {
                if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
                    return mode;
                }
            }
        }
        return c.VK_PRESENT_MODE_FIFO_KHR;
    }

    fn make_extent(capabilities: c.VkSurfaceCapabilitiesKHR, opts: SwapchainCreateOpts) c.VkExtent2D {
        if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
            return capabilities.currentExtent;
        }

        var extent = c.VkExtent2D{
            .width = opts.window_width,
            .height = opts.window_height,
        };

        extent.width = @max(capabilities.minImageExtent.width, @min(capabilities.maxImageExtent.width, extent.width));
        extent.height = @max(capabilities.minImageExtent.height, @min(capabilities.maxImageExtent.height, extent.height));

        return extent;
    }
};

pub fn transition_image(cmd: c.VkCommandBuffer, image: c.VkImage, current_layout: c.VkImageLayout, new_layout: c.VkImageLayout) void {
    var barrier = std.mem.zeroInit(c.VkImageMemoryBarrier2, .{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2 });
    barrier.srcStageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
    barrier.srcAccessMask = c.VK_ACCESS_2_MEMORY_WRITE_BIT;
    barrier.dstStageMask = c.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_2_MEMORY_WRITE_BIT | c.VK_ACCESS_2_MEMORY_READ_BIT;
    barrier.oldLayout = current_layout;
    barrier.newLayout = new_layout;

    const aspect_mask: u32 = if (new_layout == c.VK_IMAGE_LAYOUT_DEPTH_ATTACHMENT_OPTIMAL) c.VK_IMAGE_ASPECT_DEPTH_BIT else c.VK_IMAGE_ASPECT_COLOR_BIT;
    const subresource_range = std.mem.zeroInit(c.VkImageSubresourceRange, .{
        .aspectMask = aspect_mask,
        .baseMipLevel = 0,
        .levelCount = c.VK_REMAINING_MIP_LEVELS,
        .baseArrayLayer = 0,
        .layerCount = c.VK_REMAINING_ARRAY_LAYERS,
    });

    barrier.image = image;
    barrier.subresourceRange = subresource_range;

    const dep_info = std.mem.zeroInit(c.VkDependencyInfoKHR, .{
        .sType = c.VK_STRUCTURE_TYPE_DEPENDENCY_INFO_KHR,
        .imageMemoryBarrierCount = 1,
        .pImageMemoryBarriers = &barrier,
    });

    c.vkCmdPipelineBarrier2(cmd, &dep_info);
}

pub fn copy_image_to_image(cmd: c.VkCommandBuffer, src: c.VkImage, dst: c.VkImage, src_size: c.VkExtent2D, dst_size: c.VkExtent2D) void {
    var blit_region = c.VkImageBlit2{ .sType = c.VK_STRUCTURE_TYPE_IMAGE_BLIT_2, .pNext = null };
    blit_region.srcOffsets[1].x = @intCast(src_size.width);
    blit_region.srcOffsets[1].y = @intCast(src_size.height);
    blit_region.srcOffsets[1].z = 1;
    blit_region.dstOffsets[1].x = @intCast(dst_size.width);
    blit_region.dstOffsets[1].y = @intCast(dst_size.height);
    blit_region.dstOffsets[1].z = 1;
    blit_region.srcSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    blit_region.srcSubresource.baseArrayLayer = 0;
    blit_region.srcSubresource.layerCount = 1;
    blit_region.srcSubresource.mipLevel = 0;
    blit_region.dstSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    blit_region.dstSubresource.baseArrayLayer = 0;
    blit_region.dstSubresource.layerCount = 1;
    blit_region.dstSubresource.mipLevel = 0;

    var blit_info = c.VkBlitImageInfo2{ .sType = c.VK_STRUCTURE_TYPE_BLIT_IMAGE_INFO_2, .pNext = null };
    blit_info.srcImage = src;
    blit_info.srcImageLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    blit_info.dstImage = dst;
    blit_info.dstImageLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    blit_info.regionCount = 1;
    blit_info.pRegions = &blit_region;
    blit_info.filter = c.VK_FILTER_NEAREST;

    c.vkCmdBlitImage2(cmd, &blit_info);
}

pub fn check_vk(result: c.VkResult) !void {
    return switch (result) {
        c.VK_SUCCESS => {},
        c.VK_NOT_READY => error.vk_not_ready,
        c.VK_TIMEOUT => error.vk_timeout,
        c.VK_EVENT_SET => error.vk_event_set,
        c.VK_EVENT_RESET => error.vk_event_reset,
        c.VK_INCOMPLETE => error.vk_incomplete,
        c.VK_ERROR_OUT_OF_HOST_MEMORY => error.vk_error_out_of_host_memory,
        c.VK_ERROR_OUT_OF_DEVICE_MEMORY => error.vk_error_out_of_device_memory,
        c.VK_ERROR_INITIALIZATION_FAILED => error.vk_error_initialization_failed,
        c.VK_ERROR_DEVICE_LOST => error.vk_error_device_lost,
        c.VK_ERROR_MEMORY_MAP_FAILED => error.vk_error_memory_map_failed,
        c.VK_ERROR_LAYER_NOT_PRESENT => error.vk_error_layer_not_present,
        c.VK_ERROR_EXTENSION_NOT_PRESENT => error.vk_error_extension_not_present,
        c.VK_ERROR_FEATURE_NOT_PRESENT => error.vk_error_feature_not_present,
        c.VK_ERROR_INCOMPATIBLE_DRIVER => error.vk_error_incompatible_driver,
        c.VK_ERROR_TOO_MANY_OBJECTS => error.vk_error_too_many_objects,
        c.VK_ERROR_FORMAT_NOT_SUPPORTED => error.vk_error_format_not_supported,
        c.VK_ERROR_FRAGMENTED_POOL => error.vk_error_fragmented_pool,
        c.VK_ERROR_UNKNOWN => error.vk_error_unknown,
        c.VK_ERROR_OUT_OF_POOL_MEMORY => error.vk_error_out_of_pool_memory,
        c.VK_ERROR_INVALID_EXTERNAL_HANDLE => error.vk_error_invalid_external_handle,
        c.VK_ERROR_FRAGMENTATION => error.vk_error_fragmentation,
        c.VK_ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => error.vk_error_invalid_opaque_capture_address,
        c.VK_PIPELINE_COMPILE_REQUIRED => error.vk_pipeline_compile_required,
        c.VK_ERROR_SURFACE_LOST_KHR => error.vk_error_surface_lost_khr,
        c.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR => error.vk_error_native_window_in_use_khr,
        c.VK_SUBOPTIMAL_KHR => error.vk_suboptimal_khr,
        c.VK_ERROR_OUT_OF_DATE_KHR => error.vk_error_out_of_date_khr,
        c.VK_ERROR_INCOMPATIBLE_DISPLAY_KHR => error.vk_error_incompatible_display_khr,
        c.VK_ERROR_VALIDATION_FAILED_EXT => error.vk_error_validation_failed_ext,
        c.VK_ERROR_INVALID_SHADER_NV => error.vk_error_invalid_shader_nv,
        c.VK_ERROR_IMAGE_USAGE_NOT_SUPPORTED_KHR => error.vk_error_image_usage_not_supported_khr,
        c.VK_ERROR_VIDEO_PICTURE_LAYOUT_NOT_SUPPORTED_KHR => error.vk_error_video_picture_layout_not_supported_khr,
        c.VK_ERROR_VIDEO_PROFILE_OPERATION_NOT_SUPPORTED_KHR => error.vk_error_video_profile_operation_not_supported_khr,
        c.VK_ERROR_VIDEO_PROFILE_FORMAT_NOT_SUPPORTED_KHR => error.vk_error_video_profile_format_not_supported_khr,
        c.VK_ERROR_VIDEO_PROFILE_CODEC_NOT_SUPPORTED_KHR => error.vk_error_video_profile_codec_not_supported_khr,
        c.VK_ERROR_VIDEO_STD_VERSION_NOT_SUPPORTED_KHR => error.vk_error_video_std_version_not_supported_khr,
        c.VK_ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT => error.vk_error_invalid_drm_format_modifier_plane_layout_ext,
        c.VK_ERROR_NOT_PERMITTED_KHR => error.vk_error_not_permitted_khr,
        c.VK_ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT => error.vk_error_full_screen_exclusive_mode_lost_ext,
        c.VK_THREAD_IDLE_KHR => error.vk_thread_idle_khr,
        c.VK_THREAD_DONE_KHR => error.vk_thread_done_khr,
        c.VK_OPERATION_DEFERRED_KHR => error.vk_operation_deferred_khr,
        c.VK_OPERATION_NOT_DEFERRED_KHR => error.vk_operation_not_deferred_khr,
        c.VK_ERROR_COMPRESSION_EXHAUSTED_EXT => error.vk_error_compression_exhausted_ext,
        c.VK_ERROR_INCOMPATIBLE_SHADER_BINARY_EXT => error.vk_error_incompatible_shader_binary_ext,
        else => error.vk_errror_unknown,
    };
}

pub fn get_destroy_debug_utils_messenger_fn(instance: c.VkInstance) c.PFN_vkDestroyDebugUtilsMessengerEXT {
    return get_vulkan_instance_funct(c.PFN_vkDestroyDebugUtilsMessengerEXT, instance, "vkDestroyDebugUtilsMessengerEXT");
}

pub fn create_image_view(device: c.VkDevice, image: c.VkImage, format: c.VkFormat, aspect_flags: c.VkImageAspectFlags, alloc_cb: ?*c.VkAllocationCallbacks) !c.VkImageView {
    const view_info = std.mem.zeroInit(c.VkImageViewCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
        .format = format,
        .components = .{ .r = c.VK_COMPONENT_SWIZZLE_IDENTITY, .g = c.VK_COMPONENT_SWIZZLE_IDENTITY, .b = c.VK_COMPONENT_SWIZZLE_IDENTITY, .a = c.VK_COMPONENT_SWIZZLE_IDENTITY },
        .subresourceRange = .{
            .aspectMask = aspect_flags,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    });

    var image_view: c.VkImageView = undefined;
    try check_vk(c.vkCreateImageView(device, &view_info, alloc_cb, &image_view));
    return image_view;
}

pub fn create_shader_module(device: c.VkDevice, code: []const u8, alloc_callback: ?*c.VkAllocationCallbacks) ?c.VkShaderModule {
    std.debug.assert(code.len % 4 == 0);

    const data: *const u32 = @alignCast(@ptrCast(code.ptr));

    const shader_module_ci = std.mem.zeroInit(c.VkShaderModuleCreateInfo, .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = data,
    });

    var shader_module: c.VkShaderModule = undefined;
    check_vk(c.vkCreateShaderModule(device, &shader_module_ci, alloc_callback, &shader_module)) catch |err| {
        log.err("Failed to create shader module with error: {s}", .{@errorName(err)});
        return null;
    };

    return shader_module;
}

fn get_vulkan_instance_funct(comptime Fn: type, instance: c.VkInstance, name: [*c]const u8) Fn {
    const get_proc_addr: c.PFN_vkGetInstanceProcAddr = @ptrCast(c.SDL_Vulkan_GetVkGetInstanceProcAddr());
    if (get_proc_addr) |get_proc_addr_fn| {
        return @ptrCast(get_proc_addr_fn(instance, name));
    }

    @panic("SDL_Vulkan_GetVkGetInstanceProcAddr returned null");
}

fn create_debug_callback(instance: c.VkInstance, opts: VkiInstanceOpts) !c.VkDebugUtilsMessengerEXT {
    const create_fn_opt = get_vulkan_instance_funct(c.PFN_vkCreateDebugUtilsMessengerEXT, instance, "vkCreateDebugUtilsMessengerEXT");
    if (create_fn_opt) |create_fn| {
        const create_info = std.mem.zeroInit(c.VkDebugUtilsMessengerCreateInfoEXT, .{
            .sType = c.VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = c.VK_DEBUG_UTILS_MESSAGE_TYPE_DEVICE_ADDRESS_BINDING_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = opts.debug_callback orelse default_debug_callback,
            .pUserData = null,
        });
        var debug_messenger: c.VkDebugUtilsMessengerEXT = undefined;
        try check_vk(create_fn(instance, &create_info, opts.alloc_cb, &debug_messenger));
        log.info("Created vulkan debug messenger.", .{});
        return debug_messenger;
    }
    return null;
}

fn default_debug_callback(
    severity: c.VkDebugUtilsMessageSeverityFlagBitsEXT,
    msg_type: c.VkDebugUtilsMessageTypeFlagsEXT,
    callback_data: ?*const c.VkDebugUtilsMessengerCallbackDataEXT,
    user_data: ?*anyopaque,
) callconv(.C) c.VkBool32 {
    _ = user_data;
    const severity_str = switch (severity) {
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT => "verbose",
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT => "info",
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT => "warning",
        c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT => "error",
        else => "unknown",
    };

    const type_str = switch (msg_type) {
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT => "general",
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT => "validation",
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT => "performance",
        c.VK_DEBUG_UTILS_MESSAGE_TYPE_DEVICE_ADDRESS_BINDING_BIT_EXT => "device address",
        else => "unknown",
    };

    const message: [*c]const u8 = if (callback_data) |cb_data| cb_data.pMessage else "NO MESSAGE!";
    log.err("[{s}][{s}]. Message:\n  {s}", .{ severity_str, type_str, message });

    if (severity >= c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
        @panic("Unrecoverable vulkan error.");
    }

    return c.VK_FALSE;
}






pub const BufferDeletionStack = struct {
    const stack_type = std.ArrayList(t.AllocatedBuffer);
    stack: stack_type = undefined,

    pub fn init(self: *@This(), alloc: std.mem.Allocator) void {
        self.stack = stack_type.init(alloc);
    }

    pub fn push(self: *@This(), buf: t.AllocatedBuffer) void {
        self.stack.append(buf) catch @panic("failed to append to deletion stack");
    }

    pub fn flush(self: *@This(), alloc: c.VmaAllocator) void {
        while (self.stack.popOrNull()) |entry| {
            c.vmaDestroyBuffer(alloc, entry.buffer, entry.allocation);
        }
    }

    pub fn deinit(self: *@This(), alloc: c.VmaAllocator) void {
        self.flush(alloc);
        self.stack.deinit();
    }
};

pub const ImageDeletionStack = struct {
    const stack_type = std.ArrayList(t.AllocatedImageAndView);
    stack: stack_type = undefined,

    pub fn init(self: *@This(), alloc: std.mem.Allocator) void {
        self.stack = stack_type.init(alloc);
    }

    pub fn push(self: *@This(), img: t.AllocatedImageAndView) void {
        self.stack.append(img) catch @panic("failed to append to deletion stack");
    }

    pub fn flush(self: *@This(),device:c.VkDevice, alloc: c.VmaAllocator ,cbs: ?*c.VkAllocationCallbacks) void {
        while (self.stack.popOrNull()) |entry| {
            c.vkDestroyImageView(device,entry.view ,cbs );
            c.vmaDestroyImage(alloc, entry.image, entry.allocation);
        }
    }

    pub fn deinit(self: *@This(),device:c.VkDevice, alloc: c.VmaAllocator ,cbs: ?*c.VkAllocationCallbacks) void {
        self.flush(device,alloc,cbs);
        self.stack.deinit();
    }
};

pub const PipelineDeletionStack = struct {
    const stack_type = std.ArrayList(c.VkPipeline);
    stack: stack_type = undefined,

    pub fn init(self: *@This(), alloc: std.mem.Allocator) void {
        self.stack = stack_type.init(alloc);
    }

    pub fn push(self: *@This(), pip: c.VkPipeline) void {
        self.stack.append(pip) catch @panic("failed to append to deletion stack");
    }

    pub fn flush(self: *@This(), device: c.VkDevice, cbs: ?*c.VkAllocationCallbacks) void {
        while (self.stack.popOrNull()) |entry| {
            c.vkDestroyPipeline(device, entry, cbs);
        }
    }

    pub fn deinit(self: *@This(), device: c.VkDevice, cbs: ?*c.VkAllocationCallbacks) void {
        self.flush(device, cbs);
        self.stack.deinit();
    }
};



pub const PipelineLayoutDeletionStack = struct {
    const stack_type = std.ArrayList(c.VkPipelineLayout);
    stack: stack_type = undefined,

    pub fn init(self: *@This(), alloc: std.mem.Allocator) void {
        self.stack = stack_type.init(alloc);
    }

    pub fn push(self: *@This(), pip: c.VkPipelineLayout) void {
        self.stack.append(pip) catch @panic("failed to append to deletion stack");
    }

    pub fn flush(self: *@This(), device: c.VkDevice, cbs: ?*c.VkAllocationCallbacks) void {
        while (self.stack.popOrNull()) |entry| {
            c.vkDestroyPipelineLayout(device, entry, cbs);
        }
    }

    pub fn deinit(self: *@This(), device: c.VkDevice, cbs: ?*c.VkAllocationCallbacks) void {
        self.flush(device, cbs);
        self.stack.deinit();
    }
};




pub const ImageViewDeletionStack = struct {
    const stack_type = std.ArrayList(c.VkImageView);
    stack: stack_type = undefined,

    pub fn init(self: *@This(), alloc: std.mem.Allocator) void {
        self.stack = stack_type.init(alloc);
    }

    pub fn push(self: *@This(), pip: c.VkImageView) void {
        self.stack.append(pip) catch @panic("failed to append to deletion stack");
    }

    pub fn flush(self: *@This(), device: c.VkDevice, cbs: ?*c.VkAllocationCallbacks) void {
        while (self.stack.popOrNull()) |entry| {
            c.vkDestroyImageView(device, entry, cbs);
        }
    }

    pub fn deinit(self: *@This(), device: c.VkDevice, cbs: ?*c.VkAllocationCallbacks) void {
        self.flush(device, cbs);
        self.stack.deinit();
    }
};



pub const SamplerDeletionStack = struct {
    const stack_type = std.ArrayList(c.VkSampler);
    stack: stack_type = undefined,

    pub fn init(self: *@This(), alloc: std.mem.Allocator) void {
        self.stack = stack_type.init(alloc);
    }

    pub fn push(self: *@This(), pip: c.VkSampler) void {
        self.stack.append(pip) catch @panic("failed to append to deletion stack");
    }

    pub fn flush(self: *@This(), device: c.VkDevice, cbs: ?*c.VkAllocationCallbacks) void {
        while (self.stack.popOrNull()) |entry| {
            c.vkDestroySampler(device, entry, cbs);
        }
    }

    pub fn deinit(self: *@This(), device: c.VkDevice, cbs: ?*c.VkAllocationCallbacks) void {
        self.flush(device, cbs);
        self.stack.deinit();
    }
};
