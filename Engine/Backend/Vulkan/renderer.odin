package Vulkan


// Core
import "core:fmt"
import "core:log"
// Vendor
import vk "vendor:vulkan"


// --- Vulkan frame begin ---
// 1. Acquire next image from swapchain
//    - vkAcquireNextImageKHR(...)
// 2. Begin command buffer recording
//    - vkBeginCommandBuffer(...)
// 3. Begin render pass
//    - vkCmdBeginRenderPass(..., clear color = black)

// --- Mesh Shader Pipeline Setup ---
// 4. Bind mesh shader pipeline
//    - vkCmdBindPipeline(..., mesh_shader_pipeline)
// 5. Bind descriptor sets (uniforms, textures, etc.)
//    - vkCmdBindDescriptorSets(...)
// 6. Bind any required vertex/index/meshlet buffers
//    - vkCmdBindVertexBuffers(...)
//    - vkCmdBindIndexBuffer(...)
//    - vkCmdBindMeshletBuffers(...)
// 7. Push constants if needed
//    - vkCmdPushConstants(...)

// --- Mesh Shader Draw Call ---
// 8. Issue mesh shader draw call
//    - vkCmdDrawMeshTasksNV(...)
//    - or vkCmdDrawMeshTasksEXT(...)
//    - or vendor-specific mesh shader draw commands

// --- End Render Pass and Submit ---
// 9. End render pass
//    - vkCmdEndRenderPass(...)
// 10. End command buffer
//     - vkEndCommandBuffer(...)
// 11. Submit command buffer to graphics queue
//     - vkQueueSubmit(...)
// 12. Present swapchain image
//     - vkQueuePresentKHR(...)

// (Insert Vulkan resource management and synchronization as needed)

engine_draw :: proc(self: ^Engine) -> (ok: bool) {
	frame := engine_get_current_frame(self)

	// Wait until the gpu has finished rendering the last frame. Timeout of 1 second
	vk_check(vk.WaitForFences(self.vk_device, 1, &frame.render_fence, true, 1e9)) or_return
	vk_check(vk.ResetFences(self.vk_device, 1, &frame.render_fence)) or_return

	// Request image from the swapchain
	vk_check(
		vk.AcquireNextImageKHR(
			self.vk_device,
			self.vk_swapchain,
			1e9,
			frame.swapchain_semaphore,
			0,
			&frame.swapchain_image_index,
		),
	) or_return

	return true
}
