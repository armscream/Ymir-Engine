package Vulkan

// Vendor
import glfw "vendor:glfw"
import vk "vendor:vulkan"
// Local packages
import "../../Libs/vkb"
import "../../Libs/vma"

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
	depth_image:                  Allocated_Image,
	draw_extent:                  vk.Extent2D,
	render_scale:                 f32,

	// Descriptors
	global_descriptor_allocator:  Descriptor_Allocator,
	draw_image_descriptors:       vk.DescriptorSet,
	draw_image_descriptor_layout: vk.DescriptorSetLayout,

	// Pipeline
	gradient_pipeline:            vk.Pipeline,
	gradient_pipeline_layout:     vk.PipelineLayout,
	mesh_pipeline_layout:         vk.PipelineLayout,
	mesh_pipeline:                vk.Pipeline,

	// Effects
	background_effects:           [Compute_Effect_Kind]Compute_Effect,
	current_background_effect:    Compute_Effect_Kind,

	// Immediate submit
	imm_fence:                    vk.Fence,
	imm_command_buffer:           vk.CommandBuffer,
	imm_command_pool:             vk.CommandPool,

	//test
	test_meshes:                  Mesh_Asset_List,
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


destroy_window :: proc(window: glfw.WindowHandle) {
	glfw.DestroyWindow(window)
	glfw.Terminate()
}

