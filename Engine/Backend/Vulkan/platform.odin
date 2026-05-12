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
import "core:fmt"
// Vendor
import vk "vendor:vulkan"
import glfw "vendor:glfw"


Monitor_Info :: struct {
    refresh_rate:      u32,
    frame_time_target: f64, // in seconds
}

WINDOW_TITLE_BUFFER_LEN :: #config(WINDOW_TITLE_BUFFER_LEN, 256)

window_update_title_with_fps :: proc(window: glfw.WindowHandle, title: string, fps: f64) {
    buffer: [WINDOW_TITLE_BUFFER_LEN]byte
    formatted := fmt.bprintf(buffer[:], "%s - FPS = %.2f", title, fps)
    if len(formatted) >= WINDOW_TITLE_BUFFER_LEN {
        buffer[WINDOW_TITLE_BUFFER_LEN - 1] = 0 // Truncate and null-terminate
        log.warnf(
            "Window title truncated: buffer size (%d) exceeded by '%s'",
            WINDOW_TITLE_BUFFER_LEN,
            formatted,
        )
    } else if len(formatted) == 0 || buffer[len(formatted) - 1] != 0 {
        buffer[len(formatted)] = 0
    }
    glfw.SetWindowTitle(window, cstring(raw_data(buffer[:])))
}

get_primary_monitor_info :: proc() -> (info: Monitor_Info) {
    mode := glfw.GetVideoMode(glfw.GetPrimaryMonitor())
    info = Monitor_Info {
        refresh_rate      = u32(mode.refresh_rate),
        frame_time_target = 1.0 / f64(mode.refresh_rate),
    }
    return
}

glfw_error_callback :: proc "c" (error: i32, description: cstring) {
    context = runtime.default_context()
    context.logger = glog.g_logger
    log.errorf("GLFW [%d]: %s", error, description)
}

self := Engine {}

init_window :: proc(window_name: string, x: i32, y: i32, width: i32, height: i32) -> glfw.WindowHandle {
    // We initialize GLFW and create a window with it.
    ensure(bool(glfw.Init()), "Failed to initialize GLFW")

    self.window_title = strings.clone(window_name, context.allocator)
    
    glfw.SetErrorCallback(glfw_error_callback)

    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    TITLE, _ := strings.clone_to_cstring(window_name, context.temp_allocator)
    if TITLE == nil {
        glfw.Terminate()
        return nil
    }

    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)  // Correct for Vulkan
    glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)

    pos_x := c.int(x)
    pos_y := c.int(y)
    self.window_extent = vk.Extent2D{u32(width), u32(height)}
    self.window = glfw.CreateWindow(width, height, TITLE, nil, nil)
    if self.window == nil {
        log.error("Failed to create a Window")
        glfw.Terminate()
        return nil
    }
    glfw.SetWindowPos(self.window, pos_x, pos_y)

    if !engine_init(&self) {
        log.error("Failed to initialize Vulkan engine")
        destroy_window(self.window)
        self.window = nil
        return nil
    }
    return self.window
}


@(private) is_escape_binding :: proc(escape_key: i32) -> bool {
    category := (escape_key >> 16) & 0xFFFF
    value := escape_key & 0xFFFF

    // Engine keycode only: Keyboard category and Escape value.
    return category == 1 && value == 1
}

poll_should_quit :: proc(escape_key: i32) -> bool {
    if self.window == nil || !self.is_initialized {
        return true
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

shutdown_window :: proc() {
    if self.is_initialized {
        engine_cleanup(&self)
    }
    if len(self.window_title) > 0 {
        delete(self.window_title)
        self.window_title = ""
    }
}

load_level_from_json :: proc(file_path: string) -> bool {
    if !self.is_initialized {
        log.warn("load_level_from_json: Vulkan backend is not initialized")
        return false
    }
    return scene_load_from_file(&self, file_path)
}

save_level_to_json :: proc(file_path: string) -> bool {
    if !self.is_initialized {
        log.warn("save_level_to_json: Vulkan backend is not initialized")
        return false
    }
    return scene_save_to_file(&self, file_path)
}

get_monitor_resolution :: proc() -> (u32, u32) {
    mode := glfw.GetVideoMode(glfw.GetPrimaryMonitor())
    ensure(mode != nil)
    return u32(mode.width), u32(mode.height)
}

// -----------------------------------------------------------------------------
// Callbacks
// -----------------------------------------------------------------------------

callback_framebuffer_size :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
    // TODO: Implement later
}


