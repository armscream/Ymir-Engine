package Vulkan

// Core
import intr "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:fmt"

// Vendor
import vk "vendor:vulkan"
import glfw "vendor:glfw"

// Local packages
import "../../Libs/vma"

RENDERMODE :: enum {
    FIFO_RELAXED, // Tutorial uses this one
    MAILBOX, // Preferred later
    IMMEDIATE,
    FIFO,
}
RENDER_MODE := RENDERMODE.FIFO_RELAXED

Allocated_Image :: struct {
    device:       vk.Device,
    image:        vk.Image,
    image_view:   vk.ImageView,
    image_extent: vk.Extent3D,
    image_format: vk.Format,
    allocator:    vma.Allocator,
    allocation:   vma.Allocation,
}

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
    if self.window == nil {
        fmt.println("Vulkan renderer window not initialized")
        return
    }
    log.info("Entering main loop...")

    loop: for !glfw.WindowShouldClose(self.window) {
        glfw.PollEvents() // Poll window events (e.g., close, minimize)
        // Do not draw if we are minimized
        if glfw.GetWindowAttrib(self.window, glfw.ICONIFIED) != 0 {
            glfw.WaitEvents() // Wait to avoid endless spinning
            continue
        }
        // End GLFW stuff

        engine_draw(&self) or_return
    }

    log.info("Exiting...")

    return true
}

destroy_image :: proc(self: Allocated_Image) {
    vk.DestroyImageView(self.device, self.image_view, nil)
    vma.destroy_image(self.allocator, self.image, self.allocation)
}