package Vulkan

import "core:fmt"
import vk "vendor:vulkan"
import "vendor:glfw"

draw_frame :: proc(runtime: rawptr, screen_width: i32, screen_height: i32) {
    _ = runtime

    // Check if window is initialized before drawing
    if window == nil {
        fmt.println("Vulkan renderer window not initialized")
        return
    }

    // Check if window is minimized (iconified)
    if glfw.GetWindowAttrib(window, glfw.ICONIFIED) != 0 {
        // Skip rendering while minimized
        return
    }

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
}
