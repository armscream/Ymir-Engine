// --- Vulkan Platform/Backend Outline ---
//
// 1. Vulkan Initialization (init_vulkan)
//    - Create Vulkan instance
//    - Select physical device (GPU)
//    - Create logical device and queues
//    - Create surface from GLFW window
//    - Create swapchain
//    - Create image views for swapchain images
//    - Create render pass (with clear color, etc.)
//    - Create framebuffers for each swapchain image
//    - Create command pool and command buffers
//    - Create synchronization primitives (semaphores, fences)
//    - Create mesh shader pipeline (shaders, pipeline layout, etc.)
//    - Create descriptor sets, uniform buffers, etc.
//    - Any other resources needed for rendering
//
// 2. Vulkan Shutdown (shutdown_vulkan)
//    - Wait for device idle
//    - Destroy all Vulkan resources in reverse order of creation
//    - Destroy swapchain, framebuffers, pipelines, descriptor sets, etc.
//    - Destroy logical device, surface, and Vulkan instance
//
// 3. Platform-Specific Code
//    - Window creation (already in init_window)
//    - Input handling (poll events, key/mouse callbacks)
//    - Fullscreen, resize, and window state management
//    - Pass window handle/surface to Vulkan for surface creation
//
// 4. Renderer/Scene Graph Integration
//    - Pass scene graph/mesh data to renderer for mesh shader pipeline
//    - Upload mesh/vertex/index data to GPU buffers
//    - Update uniform buffers, descriptor sets per frame
//    - Provide hooks for renderer to access scene data each frame
//    - Handle dynamic resource updates (resizing, hot-reload, etc.)
//
// 5. Main Loop Integration
//    - Call draw_frame each frame
//    - Poll events (glfw.PollEvents())
//    - Handle window close/minimize/fullscreen
//    - Present frame and synchronize

package Vulkan
// Engine
import glog "../../glogger"
// Core
import "base:runtime"
import "core:log"
import "core:c"
import "core:strings"
// Vendor
import vk "vendor:vulkan"
import glfw "vendor:glfw"

glfw_error_callback :: proc "c" (error: i32, description: cstring) {
    context = runtime.default_context()
    context.logger = glog.g_logger
    log.errorf("GLFW [%d]: %s", error, description)
}

self := Engine {}

init_window :: proc(window_name: string, x: i32, y: i32, width: i32, height: i32) -> glfw.WindowHandle {
    // We initialize GLFW and create a window with it.
    ensure(bool(glfw.Init()), "Failed to initialize GLFW")

    glfw.SetErrorCallback(glfw_error_callback)

    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    window_name_c, _ := strings.clone_to_cstring(window_name, context.temp_allocator)
    if window_name_c == nil {
        glfw.Terminate()
        return nil
    }

    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)  // Correct for Vulkan
    glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)

    pos_x := c.int(x)
    pos_y := c.int(y)
    self.window = glfw.CreateWindow(width, height, window_name_c, nil, nil)
    if self.window == nil {
        log.error("Failed to create a Window")
        glfw.Terminate()
        return nil
    }
    glfw.SetWindowPos(self.window, pos_x, pos_y)

    if !engine_init(&self) {
        log.error("Failed to initialize Vulkan engine")
        shutdown_window()
        return nil
    }

    return self.window
}


shutdown_window :: proc() {
    if self.window != nil {
        glfw.DestroyWindow(self.window)
        self.window = nil
    }
    glfw.Terminate()
}

@(private) is_escape_binding :: proc(escape_key: i32) -> bool {
    category := (escape_key >> 16) & 0xFFFF
    value := escape_key & 0xFFFF

    // Engine keycode only: Keyboard category and Escape value.
    return category == 1 && value == 1
}

poll_should_quit :: proc(escape_key: i32) -> bool {
    if self.window == nil {
        return false
    }
    if is_escape_binding(escape_key) {
        return bool(glfw.WindowShouldClose(self.window))
    }
    return false
}

get_window_state :: proc(x: ^i32, y: ^i32, width: ^i32, height: ^i32, fullscreen: ^bool) -> bool {
    if self.window == nil {
        return false
    }
    xpos, ypos := glfw.GetWindowPos(self.window)
    width_c, height_c := glfw.GetWindowSize(self.window)
    x^ = xpos
    y^ = ypos
    width^ = width_c
    height^ = height_c
    fullscreen^ = glfw.GetWindowMonitor(self.window) != nil
    return true
}


// -----------------------------------------------------------------------------
// Callbacks
// -----------------------------------------------------------------------------

callback_framebuffer_size :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
    // TODO: Implement later
}


