package Vulkan

// Core
import "base:runtime"
import "core:log"
// Vendor
import glfw "vendor:glfw"
import vk "vendor:vulkan"
// Local packages
import "../../Libs/vkb"
import glog "../../glogger"

Engine :: struct {
	// Platform
    window_extent:        vk.Extent2D,
	window:                glfw.WindowHandle,
	is_initialized:        bool,
	stop_rendering:        bool,
	Debug:                 bool,
	// Vulkan
	vk_instance:           vk.Instance,
	vk_physical_device:    vk.PhysicalDevice,
	vk_surface:            vk.SurfaceKHR,
	vk_device:             vk.Device,
	// Swapchain
	vk_swapchain:          vk.SwapchainKHR,
	swapchain_extent:      vk.Extent2D,
	swapchain_format:      vk.Format,
	swapchain_images:      []vk.Image,
	swapchain_image_views: []vk.ImageView,
	vkb:                   struct {
		instance:        ^vkb.Instance,
		physical_device: ^vkb.Physical_Device,
		device:          ^vkb.Device,
		swapchain:       ^vkb.Swapchain,
	},
}


@(require_results)
engine_init :: proc(self: ^Engine) -> (ok: bool) {
	ensure(self != nil, "Invalid 'Engine' object")
	// Set window callbacks
	glfw.SetFramebufferSizeCallback(self.window, callback_framebuffer_size)

	// Everything went fine
	self.is_initialized = true

	engine_init_vulkan(self) or_return

	engine_init_swapchain(self) or_return

	engine_init_commands(self) or_return

	engine_init_sync_structures(self) or_return

	// Everything went fine
	self.is_initialized = true

	return true
}

engine_init_vulkan :: proc(self: ^Engine) -> (ok: bool) {
	// Make the vulkan instance, with basic debug features
	instance_builder := vkb.init_instance_builder() or_return
	defer vkb.destroy_instance_builder(&instance_builder)

	vkb.instance_set_app_name(&instance_builder, "Ymir Engine: Vulkan Renderer")
	vkb.instance_require_api_version(&instance_builder, vk.API_VERSION_1_3)

	if self.Debug { // Enable validation layers and debug callbacks in debug mode
		vkb.instance_request_validation_layers(&instance_builder)


		default_debug_callback :: proc "system" (
			message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
			message_types: vk.DebugUtilsMessageTypeFlagsEXT,
			p_callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
			p_user_data: rawptr,
		) -> b32 {
			context = runtime.default_context()
			context.logger = glog.g_logger

			if .WARNING in message_severity {
				log.warnf("[%v]: %s", message_types, p_callback_data.pMessage)
			} else if .ERROR in message_severity {
				log.errorf("[%v]: %s", message_types, p_callback_data.pMessage)
				runtime.debug_trap()
			} else {
				log.infof("[%v]: %s", message_types, p_callback_data.pMessage)
			}

			return false // Applications must return false here
		}

		vkb.instance_set_debug_callback(&instance_builder, default_debug_callback)
		vkb.instance_set_debug_callback_user_data_pointer(&instance_builder, self)
	}

	// Grab the instance
	self.vkb.instance = vkb.build_instance(&instance_builder) or_return
	self.vk_instance = self.vkb.instance.handle
	defer if !ok {
		vkb.destroy_instance(self.vkb.instance)
	}

	// Surface
	vk_check(
		glfw.CreateWindowSurface(self.vk_instance, self.window, nil, &self.vk_surface),
	) or_return
	defer if !ok {
		vkb.destroy_surface(self.vkb.instance, self.vk_surface)
	}

	// Vulkan 1.2 features
	features_12 := vk.PhysicalDeviceVulkan12Features {
		// Allows shaders to directly access buffer memory using GPU addresses
		bufferDeviceAddress = true,
		// Enables dynamic indexing of descriptors and more flexible descriptor usage
		descriptorIndexing  = true,
	}

	// Vulkan 1.3 features
	features_13 := vk.PhysicalDeviceVulkan13Features {
		// Eliminates the need for render pass objects, simplifying rendering setup
		dynamicRendering = true,
		// Provides improved synchronization primitives with simpler usage patterns
		synchronization2 = true,
	}

	// Use vk-bootstrap to select a gpu.
	// We want a gpu that can write to the GLFW surface and supports vulkan 1.3
	// with the correct features
	selector := vkb.init_physical_device_selector(self.vkb.instance) or_return
	defer vkb.destroy_physical_device_selector(&selector)

	vkb.selector_set_minimum_version(&selector, vk.API_VERSION_1_3)
	vkb.selector_set_required_features_13(&selector, features_13)
	vkb.selector_set_required_features_12(&selector, features_12)
	vkb.selector_set_surface(&selector, self.vk_surface)

	self.vkb.physical_device = vkb.select_physical_device(&selector) or_return
	self.vk_physical_device = self.vkb.physical_device.handle
	defer if !ok {
		vkb.destroy_physical_device(self.vkb.physical_device)
	}

	// Create the final vulkan device
	device_builder := vkb.init_device_builder(self.vkb.physical_device) or_return
	defer vkb.destroy_device_builder(&device_builder)

	self.vkb.device = vkb.build_device(&device_builder) or_return
	self.vk_device = self.vkb.device.handle
	defer if !ok {
		vkb.destroy_device(self.vkb.device)
	}


	return true
}

engine_create_swapchain :: proc(self: ^Engine, extent: vk.Extent2D) -> (ok: bool) {
    self.swapchain_format = .B8G8R8A8_UNORM

    builder := vkb.init_swapchain_builder(self.vkb.device) or_return
    defer vkb.destroy_swapchain_builder(&builder)

    vkb.swapchain_builder_set_desired_format(
        &builder,
        {format = self.swapchain_format, colorSpace = .SRGB_NONLINEAR},
    )
    // Present mode: FIFO is hard Vsync
    vkb.swapchain_builder_set_present_mode(&builder, .FIFO)
    vkb.swapchain_builder_set_desired_extent(&builder, extent.width, extent.height)
    vkb.swapchain_builder_add_image_usage_flags(&builder, {.TRANSFER_DST})

    self.vkb.swapchain = vkb.build_swapchain(&builder) or_return
    self.vk_swapchain = self.vkb.swapchain.handle
    self.swapchain_extent = self.vkb.swapchain.extent

    self.swapchain_images = vkb.swapchain_get_images(self.vkb.swapchain) or_return
    self.swapchain_image_views = vkb.swapchain_get_image_views(self.vkb.swapchain) or_return

    return true
}

engine_init_swapchain :: proc(self: ^Engine) -> (ok: bool) {
    engine_create_swapchain(self, self.window_extent) or_return
    return true
}

engine_init_commands :: proc(self: ^Engine) -> (ok: bool) {
	return true
}

engine_init_sync_structures :: proc(self: ^Engine) -> (ok: bool) {
	return true
}

engine_destroy_swapchain :: proc(self: ^Engine) {
    vkb.swapchain_destroy_image_views(self.vkb.swapchain, self.swapchain_image_views)
    vkb.destroy_swapchain(self.vkb.swapchain)
    delete(self.swapchain_image_views)
    delete(self.swapchain_images)
}

engine_cleanup :: proc(self: ^Engine) {
    if !self.is_initialized {
        return
    }

    engine_destroy_swapchain(self)

    vk.DestroySurfaceKHR(self.vk_instance, self.vk_surface, nil)
    vkb.destroy_device(self.vkb.device)

    vkb.destroy_physical_device(self.vkb.physical_device)
    vkb.destroy_instance(self.vkb.instance)

    destroy_window(self.window)
}

destroy_window :: proc(window: glfw.WindowHandle) {
    glfw.DestroyWindow(window)
    glfw.Terminate()
}

