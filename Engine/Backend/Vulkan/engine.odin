package Vulkan

// Core
import "base:runtime"
import "core:log"
// Vendor
import vk "vendor:vulkan"
import glfw "vendor:glfw"
// Local packages
import "../../Libs/vkb" 
import glog "../../glogger"

Engine :: struct {
    // Platform
    window: glfw.WindowHandle,
    is_initialized: bool,
    stop_rendering: bool,
    Debug: bool,
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
    // Make the vulkan instance, with basic debug features
    instance_builder := vkb.init_instance_builder() or_return
    defer vkb.destroy_instance_builder(&instance_builder)

    vkb.instance_set_app_name(&instance_builder, "Example Vulkan Application")
    vkb.instance_require_api_version(&instance_builder, vk.API_VERSION_1_3)

    if self.Debug {
        vkb.instance_request_validation_layers(&instance_builder)

        default_debug_callback :: proc "system" (
            message_severity: vk.DebugUtilsMessageSeverityFlagsEXT,
            message_types: vk.DebugUtilsMessageTypeFlagsEXT,
            p_callback_data: ^vk.DebugUtilsMessengerCallbackDataEXT,
            p_user_data: rawptr,
        ) -> b32 {
            context = runtime.default_context()
            context.logger = glog.g_logger

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

        vkb.instance_set_debug_callback(&instance_builder, default_debug_callback)
        vkb.instance_set_debug_callback_user_data_pointer(&instance_builder, self)
    }

    // Grab the instance
    self.vkb.instance = vkb.build_instance(&instance_builder) or_return
    self.vk_instance = self.vkb.instance.handle
    defer if !ok {
        vkb.destroy_instance(self.vkb.instance)
    }

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