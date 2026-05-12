package Vulkan

// Core
import la "core:math/linalg"
// Vendor
import glfw "vendor:glfw"
import vk "vendor:vulkan"
// Local packages
import "../../Libs/vkb"
import "../../Libs/vma"
import core "../../core"

ODIN_DEBUG :: #config(ODIN_DEBUG, false)

Frame_Data :: struct {
	command_pool:          vk.CommandPool,
	main_command_buffer:   vk.CommandBuffer,
	swapchain_semaphore:   vk.Semaphore,
	render_semaphore:      vk.Semaphore,
	render_fence:          vk.Fence,
	deletion_queue:        Deletion_Queue,
	frame_descriptors:     Descriptor_Allocator_Growable,
	swapchain_image_index: u32,
}

FRAME_OVERLAP :: 2

GPU_Scene_Data :: struct {
	view:               la.Matrix4x4f32,
	proj:               la.Matrix4x4f32,
	viewproj:           la.Matrix4x4f32,
	ambient_color:      la.Vector4f32,
	sunlight_direction: la.Vector4f32, // w for sun power
	sunlight_color:     la.Vector4f32,
}

Engine :: struct {
	// Platform
	window_extent:                    vk.Extent2D,
	window:                           glfw.WindowHandle,
	window_title:                     string,
	is_initialized:                   bool,
	stop_rendering:                   bool,

	// GPU Context
	vk_debug_messenger:               vk.DebugUtilsMessengerEXT,
	vk_instance:                      vk.Instance,
	vk_physical_device:               vk.PhysicalDevice,
	vk_surface:                       vk.SurfaceKHR,
	vk_device:                        vk.Device,

	// Queue management
	graphics_queue:                   vk.Queue,
	graphics_queue_family:            u32,

	// Swapchain
	vk_swapchain:                     vk.SwapchainKHR,
	swapchain_format:                 vk.Format,
	swapchain_extent:                 vk.Extent2D,
	swapchain_images:                 []vk.Image,
	swapchain_image_views:            []vk.ImageView,
	swapchain_image_semaphores:       []vk.Semaphore,

	// Frame management
	frames:                           [FRAME_OVERLAP]Frame_Data,
	frame_number:                     int,

	// Memory management
	vma_allocator:                    vma.Allocator,
	main_deletion_queue:              Deletion_Queue,

	// Descriptor management
	global_descriptor_allocator:      Descriptor_Allocator,
	draw_image_descriptors:           vk.DescriptorSet,
	draw_image_descriptor_layout:     vk.DescriptorSetLayout,

	// immediate submit structures
	imm_fence:                        vk.Fence,
	imm_command_buffer:               vk.CommandBuffer,
	imm_command_pool:                 vk.CommandPool,

	// Rendering resources
	draw_image:                       Allocated_Image,
	depth_image:                      Allocated_Image,
	draw_extent:                      vk.Extent2D,
	render_scale:                     f32,
	gradient_pipeline_layout:         vk.PipelineLayout,
	background_effects:               [Compute_Effect_Kind]Compute_Effect,
	current_background_effect:        Compute_Effect_Kind,
	mesh_pipeline_layout:             vk.PipelineLayout,
	mesh_pipeline:                    vk.Pipeline,

	// Scene
	main_draw_context:                Draw_Context,
	name_for_node:                    map[string]u32,
	scene:                            Scene,
	scene_data:                       GPU_Scene_Data,
	gpu_scene_data_descriptor_layout: vk.DescriptorSetLayout,

	// Textures
	white_image:                      Allocated_Image,
	black_image:                      Allocated_Image,
	grey_image:                       Allocated_Image,
	error_checkerboard_image:         Allocated_Image,
	default_sampler_linear:           vk.Sampler,
	default_sampler_nearest:          vk.Sampler,
	single_image_descriptor_layout:   vk.DescriptorSetLayout,

	// Materials
	default_material_data:            Material_Instance,
	metal_rough_material:             Metallic_Roughness,

	// Helper libraries
	vkb:                              struct {
		instance:        ^vkb.Instance,
		physical_device: ^vkb.Physical_Device,
		device:          ^vkb.Device,
		swapchain:       ^vkb.Swapchain,
	},
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

// Updates the scene state and prepares render objects.
engine_update_scene :: proc(self: ^Engine) {
    // Clear previous render objects
    clear(&self.main_draw_context.opaque_surfaces)

	// Refresh hierarchical world transforms before building draw list.
	update_all_transforms(&self.scene)

    // Find and draw all root nodes
    for &hierarchy, i in self.scene.hierarchy {
        if hierarchy.parent == -1 {
            scene_draw_node(&self.scene, i, &self.main_draw_context)
        }
    }

    // Set up Camera
    aspect := f32(self.window_extent.width) / f32(self.window_extent.height)
    self.scene_data.view = la.matrix4_translate_f32({0, 0, -5})
    self.scene_data.proj = core.matrix4_perspective_reverse_z_f32(
        f32(la.to_radians(70.0)),
        aspect,
        0.1,
        true, // Invert Y to match OpenGL/glTF conventions
    )
    self.scene_data.viewproj = la.matrix_mul(self.scene_data.proj, self.scene_data.view)

    // Default lighting parameters
    self.scene_data.ambient_color = {0.1, 0.1, 0.1, 1.0}
    self.scene_data.sunlight_color = {1.0, 1.0, 1.0, 1.0}
    self.scene_data.sunlight_direction = {0, 1, 0.5, 1.0}
}

destroy_window :: proc(window: glfw.WindowHandle) {
	glfw.DestroyWindow(window)
	glfw.Terminate()
}
