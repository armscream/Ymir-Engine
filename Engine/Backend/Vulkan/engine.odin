package Vulkan

// Core
import "base:runtime"
import "core:fmt"
import "core:log"
// Vendor
import glfw "vendor:glfw"
import vk "vendor:vulkan"
// Local packages
import "../../Libs/vkb"
import glog "../../glogger"

ODIN_DEBUG :: #config(ODIN_DEBUG, false)

Engine :: struct {
	// Platform
	window_extent:         vk.Extent2D,
	window:                glfw.WindowHandle,
	is_initialized:        bool,
	stop_rendering:        bool,
	Debug:                 bool,
	// Vulkan
	vk_instance:           vk.Instance,
	vk_physical_device:    vk.PhysicalDevice,
	vk_surface:            vk.SurfaceKHR,
	vk_device:             vk.Device,
	vk_debug_messenger:    vk.DebugUtilsMessengerEXT,
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

	// Store the current logger for later use inside callbacks
	glog.g_logger = context.logger
	// Set the window user pointer so we can get the engine from callbacks
	glfw.SetWindowUserPointer(self.window, self)

	// Set window callbacks
	glfw.SetFramebufferSizeCallback(self.window, callback_framebuffer_size)

	engine_init_vulkan(self) or_return

	engine_init_swapchain(self) or_return

	engine_init_commands(self) or_return

	engine_init_sync_structures(self) or_return

	// Everything went fine
	self.is_initialized = true

	return true
}

// Shuts down the engine.
engine_cleanup :: proc(self: ^Engine) {
	if !self.is_initialized {
		return
	}

	// Make sure the gpu has stopped doing its things
	ensure(vk.DeviceWaitIdle(self.vk_device) == .SUCCESS)
	engine_destroy_swapchain(self)

	vk.DestroySurfaceKHR(self.vk_instance, self.vk_surface, nil)
	vkb.destroy_device(self.vkb.device)

	// Destroy Vulkan debug messenger before destroying instance
	vk.DestroyDebugUtilsMessengerEXT(self.vk_instance, self.vk_debug_messenger, nil)

	vkb.destroy_physical_device(self.vkb.physical_device)
	vkb.destroy_instance(self.vkb.instance)


	destroy_window(self.window)
}

engine_init_vulkan :: proc(self: ^Engine) -> (ok: bool) {
	// Make the vulkan instance, with basic debug features
	instance_builder := vkb.init_instance_builder() or_return
	defer vkb.destroy_instance_builder(&instance_builder)

	vkb.instance_set_app_name(&instance_builder, "Example Vulkan Application")
	vkb.instance_require_api_version(&instance_builder, vk.API_VERSION_1_3)

	when ODIN_DEBUG {
		context = runtime.default_context()
		ta := context.temp_allocator
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

		// Explicitly enable VK_EXT_debug_utils and debug messenger
		vkb.instance_enable_extension(&instance_builder, vk.EXT_DEBUG_UTILS_EXTENSION_NAME)
		instance_builder.use_debug_messenger = true

		vkb.instance_request_validation_layers(&instance_builder)
		vkb.instance_set_debug_callback(&instance_builder, default_debug_callback)
		fmt.println("[VK DEBUG] Debug callback set (no return value to check).")
		vkb.instance_set_debug_callback_user_data_pointer(&instance_builder, self)

		// Ensure all severities are enabled
		instance_builder.debug_message_severity = vk.DebugUtilsMessageSeverityFlagsEXT {
			.VERBOSE,
			//.INFO,
			.WARNING,
			.ERROR,
		}
		instance_builder.debug_message_type = vk.DebugUtilsMessageTypeFlagsEXT {
			.GENERAL,
			.VALIDATION,
			.PERFORMANCE,
		}

		VK_LAYER_LUNARG_MONITOR :: "VK_LAYER_LUNARG_monitor"
		VK_LAYER_KHRONOS_validation :: "VK_LAYER_KHRONOS_validation"

		info := vkb.get_system_info(ta) // enables validation layers.
		if vkb.is_layer_available(&info, VK_LAYER_KHRONOS_validation) {
			fmt.println("[VK DEBUG] VK_LAYER_KHRONOS_validation is available and will be enabled.")
			when ODIN_OS == .Windows || ODIN_OS == .Linux {
				vkb.instance_enable_layer(&instance_builder, VK_LAYER_KHRONOS_validation)
			}
		} else {
			fmt.println("[VK DEBUG] VK_LAYER_KHRONOS_validation is NOT available!")
		}

		if vkb.is_layer_available(&info, VK_LAYER_LUNARG_MONITOR) {
			// Displays FPS in the application's title bar. It is only compatible
			// with the Win32 and XCB windowing systems.
			// https://vulkan.lunarg.com/doc/sdk/latest/windows/monitor_layer.html
			when ODIN_OS == .Windows || ODIN_OS == .Linux {
				vkb.instance_enable_layer(&instance_builder, VK_LAYER_LUNARG_MONITOR)
			}
		}
	}

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


// File-scope Vulkan debug callback for validation diagnostics
// Should be under a When ODIN_DEBUG, but it's not working for some reason, so it's always included for now
default_debug_callback :: proc "system" (
	message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
	message_types: vk.DebugUtilsMessageTypeFlagsEXT,
	p_callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
	p_user_data: rawptr,
) -> b32 {
	context = runtime.default_context()
	context.logger = glog.g_logger
	fmt.println("[VK DEBUG] === DEBUG CALLBACK TRIGGERED ===")

	if .WARNING in message_severity do fmt.println("[VK DEBUG] Validation layer warning:")

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

destroy_window :: proc(window: glfw.WindowHandle) {
	glfw.DestroyWindow(window)
	glfw.Terminate()
}
