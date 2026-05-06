package Vulkan

// Core
import "base:runtime"
import "core:fmt"
import "core:log"
// Vendor
import glfw "vendor:glfw"
import vk "vendor:vulkan"
// Local packages
import im "../../Libs/imgui"
import im_glfw "../../Libs/imgui/imgui_impl_glfw"
import im_vk "../../Libs/imgui/imgui_impl_vulkan"
import "../../Libs/vkb"
import "../../Libs/vma"
import glog "../../glogger"

ODIN_DEBUG :: #config(ODIN_DEBUG, false)

Frame_Data :: struct {
	command_pool:          vk.CommandPool,
	main_command_buffer:   vk.CommandBuffer,
	swapchain_semaphore:   vk.Semaphore,
	render_semaphore:      vk.Semaphore,
	render_fence:          vk.Fence,
	deletion_queue:        Deletion_Queue,
	swapchain_image_index: u32,
}

FRAME_OVERLAP :: 2

Engine :: struct {
	// Platform
	window_extent:                vk.Extent2D,
	window:                       glfw.WindowHandle,
	window_title:                 string,
	main_deletion_queue:          Deletion_Queue,
	is_initialized:               bool,
	stop_rendering:               bool,
	vma_allocator:                vma.Allocator,

	// GPU Context
	vk_debug_messenger:           vk.DebugUtilsMessengerEXT,
	vk_instance:                  vk.Instance,
	vk_physical_device:           vk.PhysicalDevice,
	vk_surface:                   vk.SurfaceKHR,
	vk_device:                    vk.Device,

	// Swapchain
	vk_swapchain:                 vk.SwapchainKHR,
	swapchain_format:             vk.Format,
	swapchain_extent:             vk.Extent2D,
	swapchain_images:             []vk.Image,
	swapchain_image_views:        []vk.ImageView,
	swapchain_image_semaphores:   []vk.Semaphore,

	// vk-bootstrap
	vkb:                          struct {
		instance:        ^vkb.Instance,
		physical_device: ^vkb.Physical_Device,
		device:          ^vkb.Device,
		swapchain:       ^vkb.Swapchain,
	},

	// Frame resources
	frames:                       [FRAME_OVERLAP]Frame_Data,
	frame_number:                 int,
	graphics_queue:               vk.Queue,
	graphics_queue_family:        u32,

	// Draw resources
	draw_image:                   Allocated_Image,
	draw_extent:                  vk.Extent2D,

	// Descriptors
	global_descriptor_allocator:  Descriptor_Allocator,
	draw_image_descriptors:       vk.DescriptorSet,
	draw_image_descriptor_layout: vk.DescriptorSetLayout,

	// Pipeline
	gradient_pipeline:            vk.Pipeline,
	gradient_pipeline_layout:     vk.PipelineLayout,
	triangle_pipeline_layout:     vk.PipelineLayout,
	triangle_pipeline:            vk.Pipeline,

	// Effects
	background_effects:           [Compute_Effect_Kind]Compute_Effect,
	current_background_effect:    Compute_Effect_Kind,
}

Compute_Push_Constants :: struct {
	data1: [4]f32,
	data2: [4]f32,
	data3: [4]f32,
	data4: [4]f32,
}

Compute_Effect_Kind :: enum {
	Gradient,
	Sky,
}

Compute_Effect :: struct {
	name:     cstring,
	pipeline: vk.Pipeline,
	layout:   vk.PipelineLayout,
	data:     Compute_Push_Constants,
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

	engine_init_descriptors(self) or_return

	engine_init_pipelines(self) or_return

	engine_init_imgui(self) or_return

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

	for &frame in self.frames {
		vk.DestroyCommandPool(self.vk_device, frame.command_pool, nil)

		// Destroy sync objects
		vk.DestroyFence(self.vk_device, frame.render_fence, nil)
		vk.DestroySemaphore(self.vk_device, frame.render_semaphore, nil)
		vk.DestroySemaphore(self.vk_device, frame.swapchain_semaphore, nil)

		// Flush and destroy the peer frame deletion queue
		deletion_queue_destroy(&frame.deletion_queue)
	}

	// Flush and destroy the global deletion queue
	deletion_queue_destroy(&self.main_deletion_queue)

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

	// Vulkan 1.1 features
	features_11 := vk.PhysicalDeviceVulkan11Features {
		shaderDrawParameters = true,
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
	vkb.selector_set_required_features_11(&selector, features_11)
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

	// use vk-bootstrap to get a Graphics queue
	self.graphics_queue = vkb.device_get_queue(self.vkb.device, .Graphics) or_return
	self.graphics_queue_family = vkb.device_get_queue_index(self.vkb.device, .Graphics)

	// Initialize global deletion queue
	deletion_queue_init(&self.main_deletion_queue, self.vk_device)

	// Initializes a subset of Vulkan functions required by VMA
	vma_vulkan_functions := vma.create_vulkan_functions()

	allocator_create_info: vma.Allocator_Create_Info = {
		flags            = {.Buffer_Device_Address},
		instance         = self.vk_instance,
		physical_device  = self.vk_physical_device,
		device           = self.vk_device,
		vulkan_functions = &vma_vulkan_functions,
	}

	vk_check(
		vma.create_allocator(allocator_create_info, &self.vma_allocator),
		"Failed to Create Vulkan Memory Allocator",
	) or_return

	deletion_queue_push(&self.main_deletion_queue, self.vma_allocator)

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

	vkb.swapchain_builder_set_present_mode(&builder, .FIFO)
	vkb.swapchain_builder_set_present_mode(&builder, .IMMEDIATE)
	vkb.swapchain_builder_set_present_mode(&builder, .MAILBOX)
	vkb.swapchain_builder_set_desired_extent(&builder, extent.width, extent.height)
	vkb.swapchain_builder_add_image_usage_flags(&builder, {.TRANSFER_DST})

	self.vkb.swapchain = vkb.build_swapchain(&builder) or_return
	self.vk_swapchain = self.vkb.swapchain.handle
	self.swapchain_extent = self.vkb.swapchain.extent

	self.swapchain_images = vkb.swapchain_get_images(self.vkb.swapchain) or_return
	self.swapchain_image_views = vkb.swapchain_get_image_views(self.vkb.swapchain) or_return
	self.swapchain_image_semaphores = make([]vk.Semaphore, len(self.swapchain_images))[:]
	defer if !ok {delete(self.swapchain_image_semaphores)}

	// These need to be created here so that they are recreated when we resize.
	semaphore_create_info := semaphore_create_info()
	for &semaphore in self.swapchain_image_semaphores {
		vk_check(
			vk.CreateSemaphore(self.vk_device, &semaphore_create_info, nil, &semaphore),
		) or_return
	}

	return true
}

engine_init_swapchain :: proc(self: ^Engine) -> (ok: bool) {
	engine_create_swapchain(self, self.window_extent) or_return

	// Draw image size will match the window
	draw_image_extent := vk.Extent3D {
		width  = self.window_extent.width,
		height = self.window_extent.height,
		depth  = 1,
	}

	// Hardcoding the draw format to 32 bit float
	self.draw_image.image_format = .R16G16B16A16_SFLOAT
	self.draw_image.image_extent = draw_image_extent
	self.draw_image.allocator = self.vma_allocator
	self.draw_image.device = self.vk_device

	draw_image_usages := vk.ImageUsageFlags {
		.TRANSFER_SRC,
		.TRANSFER_DST,
		.STORAGE,
		.COLOR_ATTACHMENT,
	}

	rimg_info := image_create_info(
		self.draw_image.image_format,
		draw_image_usages,
		draw_image_extent,
	)

	// For the draw image, we want to allocate it from gpu local memory
	rimg_allocinfo := vma.Allocation_Create_Info {
		usage          = .Gpu_Only,
		required_flags = {.DEVICE_LOCAL},
	}

	// Allocate and create the image
	vk_check(
		vma.create_image(
			self.vma_allocator,
			rimg_info,
			rimg_allocinfo,
			&self.draw_image.image,
			&self.draw_image.allocation,
			nil,
		),
	) or_return
	defer if !ok {
		vma.destroy_image(self.vma_allocator, self.draw_image.image, nil)
	}

	// Build a image-view for the draw image to use for rendering
	rview_info := imageview_create_info(
		self.draw_image.image_format,
		self.draw_image.image,
		{.COLOR},
	)

	vk_check(
		vk.CreateImageView(self.vk_device, &rview_info, nil, &self.draw_image.image_view),
	) or_return
	defer if !ok {
		vk.DestroyImageView(self.vk_device, self.draw_image.image_view, nil)
	}

	// Add to deletion queues
	deletion_queue_push(&self.main_deletion_queue, self.draw_image)

	return true
}

@(require_results)
engine_init_commands :: proc(self: ^Engine) -> (ok: bool) {
	// Create a command pool for commands submitted to the graphics queue.
	// We also want the pool to allow for resetting of individual command buffers.
	command_pool_info := command_pool_create_info(
		self.graphics_queue_family,
		{.RESET_COMMAND_BUFFER},
	)

	for i in 0 ..< FRAME_OVERLAP {
		// Create peer frame deletion queue
		deletion_queue_init(&self.frames[i].deletion_queue, self.vk_device)
		// Create the command pool
		vk_check(
			vk.CreateCommandPool(
				self.vk_device,
				&command_pool_info,
				nil,
				&self.frames[i].command_pool,
			),
		) or_return

		// Allocate the default command buffer that we will use for rendering
		cmd_alloc_info := command_buffer_allocate_info(self.frames[i].command_pool)

		vk_check(
			vk.AllocateCommandBuffers(
				self.vk_device,
				&cmd_alloc_info,
				&self.frames[i].main_command_buffer,
			),
		) or_return
	}

	return true
}

engine_get_current_frame :: #force_inline proc(self: ^Engine) -> ^Frame_Data #no_bounds_check {
	return &self.frames[self.frame_number % FRAME_OVERLAP]
}

@(require_results)
engine_init_sync_structures :: proc(self: ^Engine) -> (ok: bool) {
	// Create synchronization structures, one fence to control when the gpu has finished
	// rendering the frame, and a semaphore to synchronize rendering with swapchain. We want
	// the fence to start signaled so we can wait on it on the first frame.
	fence_create_info := fence_create_info({.SIGNALED})
	semaphore_create_info := semaphore_create_info()

	for &frame in self.frames {
		vk_check(
			vk.CreateFence(self.vk_device, &fence_create_info, nil, &frame.render_fence),
		) or_return

		vk_check(
			vk.CreateSemaphore(
				self.vk_device,
				&semaphore_create_info,
				nil,
				&frame.swapchain_semaphore,
			),
		) or_return
	}

	return true
}

engine_destroy_swapchain :: proc(self: ^Engine) {
	vkb.destroy_swapchain(self.vkb.swapchain)
	vkb.swapchain_destroy_image_views(self.vkb.swapchain, self.swapchain_image_views)

	for semaphore in self.swapchain_image_semaphores {
		vk.DestroySemaphore(self.vk_device, semaphore, nil)
	}

	delete(self.swapchain_image_views)
	delete(self.swapchain_images)
}

destroy_window :: proc(window: glfw.WindowHandle) {
	glfw.DestroyWindow(window)
	glfw.Terminate()
}

engine_init_descriptors :: proc(self: ^Engine) -> (ok: bool) {
	// Create a descriptor pool that will hold 10 sets with 1 image each
	sizes := []Pool_Size_Ratio{{.STORAGE_IMAGE, 1}}

	descriptor_allocator_init_pool(
		&self.global_descriptor_allocator,
		self.vk_device,
		10,
		sizes,
	) or_return
	deletion_queue_push(&self.main_deletion_queue, self.global_descriptor_allocator.pool)

	{
		// Make the descriptor set layout for our compute draw
		builder: Descriptor_Layout_Builder
		descriptor_layout_builder_init(&builder, self.vk_device)
		descriptor_layout_builder_add_binding(&builder, 0, .STORAGE_IMAGE)
		self.draw_image_descriptor_layout = descriptor_layout_builder_build(
			&builder,
			{.COMPUTE},
		) or_return
	}
	deletion_queue_push(&self.main_deletion_queue, self.draw_image_descriptor_layout)

	// Allocate a descriptor set for our draw image
	self.draw_image_descriptors = descriptor_allocator_allocate(
		&self.global_descriptor_allocator,
		self.vk_device,
		&self.draw_image_descriptor_layout,
	) or_return

	img_info := vk.DescriptorImageInfo {
		imageLayout = .GENERAL,
		imageView   = self.draw_image.image_view,
	}

	draw_image_write := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstBinding      = 0,
		dstSet          = self.draw_image_descriptors,
		descriptorCount = 1,
		descriptorType  = .STORAGE_IMAGE,
		pImageInfo      = &img_info,
	}

	vk.UpdateDescriptorSets(self.vk_device, 1, &draw_image_write, 0, nil)

	return true
}

engine_init_pipelines :: proc(self: ^Engine) -> (ok: bool) {
	// Compute pipelines
	engine_init_background_pipelines(self) or_return
	// Graphics pipelines
	engine_init_triangle_pipeline(self) or_return

	return true
}

engine_init_background_pipelines :: proc(self: ^Engine) -> (ok: bool) {
	push_constant := vk.PushConstantRange {
		offset     = 0,
		size       = size_of(Compute_Push_Constants),
		stageFlags = {.COMPUTE},
	}

	compute_layout := vk.PipelineLayoutCreateInfo {
		sType                  = .PIPELINE_LAYOUT_CREATE_INFO,
		pSetLayouts            = &self.draw_image_descriptor_layout,
		setLayoutCount         = 1,
		pPushConstantRanges    = &push_constant,
		pushConstantRangeCount = 1,
	}

	vk_check(
		vk.CreatePipelineLayout(
			self.vk_device,
			&compute_layout,
			nil,
			&self.gradient_pipeline_layout,
		),
	) or_return

	gradient_color_shader := create_shader_module(
		self.vk_device,
		#load("/shaders/compiled/gradient_color.comp.spv"),
	) or_return
	defer vk.DestroyShaderModule(self.vk_device, gradient_color_shader, nil)

	sky_shader := create_shader_module(
		self.vk_device,
		#load("/shaders/compiled/sky.comp.spv"),
	) or_return
	defer vk.DestroyShaderModule(self.vk_device, sky_shader, nil)

	stage_info := vk.PipelineShaderStageCreateInfo {
		sType  = .PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage  = {.COMPUTE},
		module = gradient_color_shader,
		pName  = "main",
	}

	compute_pipeline_create_info := vk.ComputePipelineCreateInfo {
		sType  = .COMPUTE_PIPELINE_CREATE_INFO,
		layout = self.gradient_pipeline_layout,
		stage  = stage_info,
	}

	gradient_color := Compute_Effect {
		layout = self.gradient_pipeline_layout,
		name = "Gradient Color",
		data = {data1 = {1, 0, 0, 1}, data2 = {0, 0, 1, 1}},
	}

	vk_check(
		vk.CreateComputePipelines(
			self.vk_device,
			0,
			1,
			&compute_pipeline_create_info,
			nil,
			&gradient_color.pipeline,
		),
	) or_return

	// Change the shader module only to create the sky shader
	compute_pipeline_create_info.stage.module = sky_shader

	sky := Compute_Effect {
		layout = self.gradient_pipeline_layout,
		name = "Sky",
		data = {data1 = {0.1, 0.2, 0.4, 0.97}},
	}

	vk_check(
		vk.CreateComputePipelines(
			self.vk_device,
			0,
			1,
			&compute_pipeline_create_info,
			nil,
			&sky.pipeline,
		),
	) or_return

	// Set the 2 background effects
	self.background_effects[.Gradient] = gradient_color
	self.background_effects[.Sky] = sky
	//self.current_background_effect = .Gradient //////////////////////////
	//self.gradient_pipeline = gradient_color.pipeline /////////////////////////////////

	deletion_queue_push(&self.main_deletion_queue, self.gradient_pipeline_layout)
	deletion_queue_push(&self.main_deletion_queue, gradient_color.pipeline)
	deletion_queue_push(&self.main_deletion_queue, sky.pipeline)

	return true
}

engine_init_imgui :: proc(self: ^Engine) -> (ok: bool) {
	im.CHECKVERSION()

	// 1: create descriptor pool for IMGUI
	// The size of the pool is very oversize, but it's copied from imgui demo itself.
	pool_sizes := []vk.DescriptorPoolSize {
		{.SAMPLER, 1000},
		{.COMBINED_IMAGE_SAMPLER, 1000},
		{.SAMPLED_IMAGE, 1000},
		{.STORAGE_IMAGE, 1000},
		{.UNIFORM_TEXEL_BUFFER, 1000},
		{.STORAGE_TEXEL_BUFFER, 1000},
		{.UNIFORM_BUFFER, 1000},
		{.STORAGE_BUFFER, 1000},
		{.UNIFORM_BUFFER_DYNAMIC, 1000},
		{.STORAGE_BUFFER_DYNAMIC, 1000},
		{.INPUT_ATTACHMENT, 1000},
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = .DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {.FREE_DESCRIPTOR_SET},
		maxSets       = 1000,
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes),
	}

	imgui_pool: vk.DescriptorPool
	vk_check(vk.CreateDescriptorPool(self.vk_device, &pool_info, nil, &imgui_pool)) or_return

	// This initializes the core structures of imgui
	im.create_context()
	defer if !ok {im.destroy_context()}

	// This initializes imgui for GLFW
	im_glfw.init_for_vulkan(self.window, true) or_return
	defer if !ok {im_glfw.shutdown()}

	// This initializes imgui for Vulkan
	init_info := im_vk.Init_Info {
		api_version = self.vkb.instance.api_version,
		instance = self.vk_instance,
		physical_device = self.vk_physical_device,
		device = self.vk_device,
		queue = self.graphics_queue,
		descriptor_pool = imgui_pool,
		min_image_count = 3,
		image_count = 3,
		use_dynamic_rendering = true,
		pipeline_rendering_create_info = {
			sType = .PIPELINE_RENDERING_CREATE_INFO,
			colorAttachmentCount = 1,
			pColorAttachmentFormats = &self.swapchain_format,
		},
		msaa_samples = ._1,
	}

	im_vk.load_functions(
		self.vkb.instance.api_version,
		proc "c" (function_name: cstring, user_data: rawptr) -> vk.ProcVoidFunction {
			engine := cast(^Engine)user_data
			return vk.GetInstanceProcAddr(engine.vk_instance, function_name)
		},
		self,
	) or_return

	im_vk.init(&init_info) or_return
	defer if !ok {im_vk.shutdown()}

	// Remember the LIFO queue, make sure the order of push is correct
	deletion_queue_push(&self.main_deletion_queue, imgui_pool)
	deletion_queue_push(&self.main_deletion_queue, im_vk.shutdown)
	deletion_queue_push(&self.main_deletion_queue, im_glfw.shutdown)

	return true
}

engine_draw_imgui :: proc(
	self: ^Engine,
	cmd: vk.CommandBuffer,
	target_view: vk.ImageView,
) -> (
	ok: bool,
) {
	color_attachment := attachment_info(target_view, nil, .COLOR_ATTACHMENT_OPTIMAL)
	render_info := rendering_info(self.swapchain_extent, &color_attachment, nil)

	vk.CmdBeginRendering(cmd, &render_info)

	im_vk.render_draw_data(im.get_draw_data(), cmd)

	vk.CmdEndRendering(cmd)

	return
}

engine_init_triangle_pipeline :: proc(self: ^Engine) -> (ok: bool) {
    triangle_frag_shader := create_shader_module(
        self.vk_device,
        #load("/shaders/compiled/colored_triangle.frag.spv"),
    ) or_return
    defer vk.DestroyShaderModule(self.vk_device, triangle_frag_shader, nil)

    triangle_vert_shader := create_shader_module(
        self.vk_device,
        #load("/shaders/compiled/colored_triangle.vert.spv"),
    ) or_return
    defer vk.DestroyShaderModule(self.vk_device, triangle_vert_shader, nil)

    // Build the pipeline layout that controls the inputs/outputs of the shader, we are not
    // using descriptor sets or other systems yet, so no need to use anything other than empty
    // default
    pipeline_layout_info := pipeline_layout_create_info()
    vk_check(
        vk.CreatePipelineLayout(
            self.vk_device,
            &pipeline_layout_info,
            nil,
            &self.triangle_pipeline_layout,
        ),
    ) or_return
    deletion_queue_push(&self.main_deletion_queue, self.triangle_pipeline_layout)

    builder := pipeline_builder_create_default()

    // Use the triangle layout we created
    builder.pipeline_layout = self.triangle_pipeline_layout
    // Add the vertex and pixel shaders to the pipeline
    pipeline_builder_set_shaders(&builder, triangle_vert_shader, triangle_frag_shader)
    // It will draw triangles
    pipeline_builder_set_input_topology(&builder, .TRIANGLE_LIST)
    // Filled triangles
    pipeline_builder_set_polygon_mode(&builder, .FILL)
    // No backface culling
    pipeline_builder_set_cull_mode(&builder, vk.CullModeFlags_NONE, .CLOCKWISE)
    // No multisampling
    pipeline_builder_set_multisampling_none(&builder)
    // No blending
    pipeline_builder_disable_blending(&builder)
    // No depth testing
    pipeline_builder_disable_depth_test(&builder)

    // Connect the image format we will draw into, from draw image
    pipeline_builder_set_color_attachment_format(&builder, self.draw_image.image_format)
    pipeline_builder_set_depth_attachment_format(&builder, .UNDEFINED)

    // Finally build the pipeline
    self.triangle_pipeline = pipeline_builder_build(&builder, self.vk_device) or_return
    deletion_queue_push(&self.main_deletion_queue, self.triangle_pipeline)

    return true
}

engine_draw_geometry :: proc(self: ^Engine, cmd: vk.CommandBuffer) -> (ok: bool) {
    // Begin a render pass connected to our draw image
    color_attachment := attachment_info(self.draw_image.image_view, nil, .COLOR_ATTACHMENT_OPTIMAL)

    render_info := rendering_info(self.draw_extent, &color_attachment, nil)
    vk.CmdBeginRendering(cmd, &render_info)

    vk.CmdBindPipeline(cmd, .GRAPHICS, self.triangle_pipeline)

    // Set dynamic viewport and scissor
    viewport := vk.Viewport {
        x        = 0,
        y        = 0,
        width    = f32(self.draw_extent.width),
        height   = f32(self.draw_extent.height),
        minDepth = 0.0,
        maxDepth = 1.0,
    }

    vk.CmdSetViewport(cmd, 0, 1, &viewport)

    scissor := vk.Rect2D {
        offset = {x = 0, y = 0},
        extent = {width = self.draw_extent.width, height = self.draw_extent.height},
    }

    vk.CmdSetScissor(cmd, 0, 1, &scissor)

    // Launch a draw command to draw 3 vertices
    vk.CmdDraw(cmd, 3, 1, 0, 0)

    vk.CmdEndRendering(cmd)

    return true
}