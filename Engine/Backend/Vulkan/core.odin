package Vulkan

// Core
import intr "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:fmt"

// Vendor
import vk "vendor:vulkan"
import glfw "vendor:glfw"

@(require_results)
vk_check :: #force_inline proc(
    res: vk.Result,
    message := "Detected Vulkan error",
    loc := #caller_location,
) -> bool {
    if intr.expect(res, vk.Result.SUCCESS) == .SUCCESS {
        return true
    }
    log.errorf("[Vulkan Error] %s: %v", message, res)
    runtime.print_caller_location(loc)
    return false
}

// Run main loop.
@(require_results)
engine_run :: proc(runtime: rawptr) -> (ok: bool) {
    _ = runtime
    if window == nil {
        fmt.println("Vulkan renderer window not initialized")
        return
    }
    log.info("Entering main loop...")

    loop: for !glfw.WindowShouldClose(window) {
        glfw.PollEvents() // Poll window events (e.g., close, minimize)
        // Do not draw if we are minimized
        if glfw.GetWindowAttrib(window, glfw.ICONIFIED) != 0 {
            glfw.WaitEvents() // Wait to avoid endless spinning
            continue
        }
        // End GLFW stuff

        draw_frame()
    }

    log.info("Exiting...")

    return true
}