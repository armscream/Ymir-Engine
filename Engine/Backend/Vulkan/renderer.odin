package Vulkan


// Core
import "core:fmt"
import "core:log"
import "core:math"
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



// Draw loop.
@(require_results)
engine_draw :: proc(self: ^Engine) -> (ok: bool) {
	// Steps:
	//
	// 1. Waits for the GPU to finish the previous frame
	// 2. Acquires the next swapchain image
	// 3. Records rendering commands into a command buffer
	// 4. Submits the command buffer to the GPU for execution
	// 5. Presents the rendered image to the screen

	render_fence := engine_get_current_frame(self).render_fence

	// Wait until the gpu has finished rendering the last frame. Timeout of 1 second
	vk_check(vk.WaitForFences(self.vk_device, 1, &render_fence, true, 1000000000)) or_return
	vk_check(vk.ResetFences(self.vk_device, 1, &render_fence)) or_return

	// Request image from the swapchain
	swapchain_semaphore := engine_get_current_frame(self).swapchain_semaphore
	swapchain_image_index: u32 = ---
	vk_check(
		vk.AcquireNextImageKHR(
			self.vk_device,
			self.vk_swapchain,
			1000000000,
			swapchain_semaphore,
			0,
			&swapchain_image_index,
		),
	) or_return

	// The the current command buffer, naming it cmd for shorter writing
	cmd := engine_get_current_frame(self).main_command_buffer

	// Now that we are sure that the commands finished executing, we can safely reset the
	// command buffer to begin recording again.
	vk_check(vk.ResetCommandBuffer(cmd, {})) or_return

	// Begin the command buffer recording. We will use this command buffer exactly once, so we
	// want to let vulkan know that
	cmd_begin_info := command_buffer_begin_info({.ONE_TIME_SUBMIT})

	// Start the command buffer recording
	vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info)) or_return

	// Make the swapchain image into writeable mode before rendering
	transition_image(cmd, self.swapchain_images[swapchain_image_index], .UNDEFINED, .GENERAL)

	// Make a clear-color from frame number. This will flash with a 120 frame period.
	flash := abs(math.sin(f32(self.frame_number) / 120.0))
	clear_value := vk.ClearColorValue {
		float32 = {0.0, 0.0, flash, 1.0},
	}

	clear_range := image_subresource_range({.COLOR})

	// Clear image
	vk.CmdClearColorImage(
		cmd,
		self.swapchain_images[swapchain_image_index],
		.GENERAL,
		&clear_value,
		1,
		&clear_range,
	)

	// Make the swapchain image into presentable mode
	transition_image(cmd, self.swapchain_images[swapchain_image_index], .GENERAL, .PRESENT_SRC_KHR)

	// Finalize the command buffer (we can no longer add commands, but it can now be executed)
	vk_check(vk.EndCommandBuffer(cmd)) or_return

	// Prepare the submission to the queue. we want to wait on the `swapchain_semaphore`, as that
	// semaphore is signaled when the swapchain is ready. We will signal the
	// `ready_for_present_semaphore` to signal that rendering has finished.

	// frame := engine_get_current_frame(self)
	ready_for_present_semaphore := self.swapchain_image_semaphores[swapchain_image_index]

	cmd_info := command_buffer_submit_info(cmd)
	signal_info := semaphore_submit_info({.ALL_GRAPHICS}, ready_for_present_semaphore)
	wait_info := semaphore_submit_info({.COLOR_ATTACHMENT_OUTPUT_KHR}, swapchain_semaphore)

	submit := submit_info(&cmd_info, &signal_info, &wait_info)

	// Submit command buffer to the queue and execute it. `render_fence` will now block until the
	// graphic commands finish execution.
	vk_check(vk.QueueSubmit2(self.graphics_queue, 1, &submit, render_fence)) or_return

	// Prepare present
	//
	// This will put the image we just rendered to into the visible window. we want to wait on
	// the `ready_for_present_semaphore` for that, as its necessary that drawing commands
	// have finished before the image is displayed to the user.
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		pSwapchains        = &self.vk_swapchain,
		swapchainCount     = 1,
		pWaitSemaphores    = &ready_for_present_semaphore,
		waitSemaphoreCount = 1,
		pImageIndices      = &swapchain_image_index,
	}

	vk_check(vk.QueuePresentKHR(self.graphics_queue, &present_info)) or_return

	//increase the number of frames drawn
	self.frame_number += 1

	return true
}
