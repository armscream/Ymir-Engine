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
	frame := engine_get_current_frame(self)

	// The the current command buffer, naming it cmd for shorter writing
	cmd := frame.main_command_buffer

	// Now that we are sure that the commands finished executing, we can safely
	// reset the command buffer to begin recording again.
	vk_check(vk.ResetCommandBuffer(cmd, {})) or_return

	// Begin the command buffer recording. We will use this command buffer exactly
	// once, so we want to let vulkan know that
	cmd_begin_info := command_buffer_begin_info({.ONE_TIME_SUBMIT})

	self.draw_extent.width = self.draw_image.image_extent.width
	self.draw_extent.height = self.draw_image.image_extent.height

	// Start the command buffer recording
	vk_check(vk.BeginCommandBuffer(cmd, &cmd_begin_info)) or_return

	// Transition our main draw image into general layout so we can write into it
	// we will overwrite it all so we dont care about what was the older layout
	transition_image(cmd, self.draw_image.image, .UNDEFINED, .GENERAL)

	// Clear the image
	engine_draw_background(self, cmd) or_return

	transition_image(cmd, self.draw_image.image, .GENERAL, .COLOR_ATTACHMENT_OPTIMAL)

	// Draw the triangle
	engine_draw_geometry(self, cmd) or_return

	// Transition the draw image and the swapchain image into their correct transfer layouts
	transition_image(cmd, self.draw_image.image, .COLOR_ATTACHMENT_OPTIMAL, .TRANSFER_SRC_OPTIMAL)
	transition_image(
		cmd,
		self.swapchain_images[frame.swapchain_image_index],
		.UNDEFINED,
		.TRANSFER_DST_OPTIMAL,
	)

	// ExecEte a copy from the draw image into the swapchain
	copy_image_to_image(
		cmd,
		self.draw_image.image,
		self.swapchain_images[frame.swapchain_image_index],
		self.draw_extent,
		self.swapchain_extent,
	)

	// Set swapchain image layout to Attachment Optimal so we can draw it
	transition_image(
		cmd,
		self.swapchain_images[frame.swapchain_image_index],
		.TRANSFER_DST_OPTIMAL,
		.COLOR_ATTACHMENT_OPTIMAL,
	)

	// Draw imgui into the swapchain image
	engine_draw_imgui(self, cmd, self.swapchain_image_views[frame.swapchain_image_index])

	// Set swapchain image layout to Present so we can show it on the screen
	transition_image(
		cmd,
		self.swapchain_images[frame.swapchain_image_index],
		.COLOR_ATTACHMENT_OPTIMAL,
		.PRESENT_SRC_KHR,
	)

	// Finalize the command buffer (we can no longer add commands, but it can now be executed)
	vk_check(vk.EndCommandBuffer(cmd)) or_return

	// Prepare the submission to the queue. we want to wait on the
	// `swapchain_semaphore`, as that semaphore is signaled when the swapchain is
	// ready. We will signal the `ready_for_present_semaphore`, to signal that
	// rendering has finished.

	ready_for_present_semaphore := self.swapchain_image_semaphores[frame.swapchain_image_index]

	cmd_info := command_buffer_submit_info(cmd)
	signal_info := semaphore_submit_info({.ALL_GRAPHICS}, ready_for_present_semaphore)
	wait_info := semaphore_submit_info({.COLOR_ATTACHMENT_OUTPUT_KHR}, frame.swapchain_semaphore)

	submit := submit_info(&cmd_info, &signal_info, &wait_info)

	// Submit command buffer to the queue and execute it. `render_fence` will now
	// block until the graphic commands finish execution.
	vk_check(vk.QueueSubmit2(self.graphics_queue, 1, &submit, frame.render_fence)) or_return

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
		pImageIndices      = &frame.swapchain_image_index,
	}

	vk_check(vk.QueuePresentKHR(self.graphics_queue, &present_info)) or_return

	// Increase the number of frames drawn
	self.frame_number += 1

	return true
}

engine_draw_background :: proc(self: ^Engine, cmd: vk.CommandBuffer) -> (ok: bool) {
	effect := &self.background_effects[self.current_background_effect]

	// Bind the compute pipeline
	vk.CmdBindPipeline(cmd, .COMPUTE, effect.pipeline)

	// Bind the descriptor set containing the draw image
	vk.CmdBindDescriptorSets(
		cmd,
		.COMPUTE,
		self.gradient_pipeline_layout,
		0,
		1,
		&self.draw_image_descriptors,
		0,
		nil,
	)

	// Push constants
	vk.CmdPushConstants(
		cmd,
		self.gradient_pipeline_layout,
		{.COMPUTE},
		0,
		size_of(Compute_Push_Constants),
		&effect.data,
	)

	// Dispatch the compute shader
	vk.CmdDispatch(
		cmd,
		u32(math.ceil_f32(f32(self.draw_extent.width) / 16.0)),
		u32(math.ceil_f32(f32(self.draw_extent.height) / 16.0)),
		1,
	)

	return true
}
