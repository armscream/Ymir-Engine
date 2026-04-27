package Vulkan

// Core
import "base:runtime"
// Vendor
import vk "vendor:vulkan"
import glfw "vendor:glfw"
// Local packages
import "../../Libs/vkb" 

Engine :: struct {
    // Platform
    window: glfw.WindowHandle,
    is_initialized: bool,
    stop_rendering: bool,
    // Vulkan
    vk_instance:         vk.Instance,
    vk_physical_device:  vk.PhysicalDevice,
    vk_surface:          vk.SurfaceKHR,
    vk_device:           vk.Device,
    vkb:                   struct {
        instance:        ^vkb.Instance,
        physical_device: ^vkb.Physical_Device,
        device:          ^vkb.Device,
    },
}

@require_results
engine_init :: proc (self: ^Engine) -> (ok: bool) {
    ensure(self != nil, "Invalid 'Engine' object")
    // Set window callbacks
    glfw.SetFramebufferSizeCallback(self.window, callback_framebuffer_size)

    // Everything went fine
    self.is_initialized = true

    engine_init_vulkan(self) or_return

    engine_init_swapchain(self) or_return

    engine_init_commands(self) or_return

    engine_init_sync_structures(self) or_return

    // Everything went fine
    self.is_initialized = true

    return true
}


engine_init_vulkan :: proc(self: ^Engine) -> (ok: bool) {
    return true
}

engine_init_swapchain :: proc(self: ^Engine) -> (ok: bool) {
    return true
}

engine_init_commands :: proc(self: ^Engine) -> (ok: bool) {
    return true
}

engine_init_sync_structures :: proc(self: ^Engine) -> (ok: bool) {
    return true
}   