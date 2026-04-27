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

import "core:c"
import "core:strings"
import "vendor:glfw"
import vk "vendor:vulkan"

window: glfw.WindowHandle  
// vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))   

init_window :: proc(window_name: string, x: i32, y: i32, width: i32, height: i32) -> glfw.WindowHandle {
    if !glfw.Init() {
        return nil
    }

    window_name_c, _ := strings.clone_to_cstring(window_name)
    if window_name_c == nil {
        glfw.Terminate()
        return nil
    }
    defer delete(window_name_c)

    glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)  // Correct for Vulkan
    glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)

    window = glfw.CreateWindow(width, height, window_name_c, nil, nil)
    if window == nil {
        glfw.Terminate()
        return nil
    }

    pos_x := c.int(x)
    pos_y := c.int(y)
    if x < 0 {
        glfw.SetWindowPos(window, 0,0) // Centered horizontally
    }
    if y < 0 {
        glfw.SetWindowPos(window, 0,0) // Centered vertically
    }

    glfw.SetWindowPos(window, pos_x, pos_y)
    return window
}   

shutdown_window :: proc() {
    if window != nil {
        glfw.DestroyWindow(window)
        window = nil
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
    if window == nil {
        return false
    }
    if is_escape_binding(escape_key) {
        return bool(glfw.WindowShouldClose(window))
    }
    return false
}

get_window_state :: proc(x: ^i32, y: ^i32, width: ^i32, height: ^i32, fullscreen: ^bool) -> bool {
    if window == nil {
        return false
    }
    xpos, ypos := glfw.GetWindowPos(window)
    width_c, height_c := glfw.GetWindowSize(window)
    x^ = xpos
    y^ = ypos
    width^ = width_c
    height^ = height_c
    fullscreen^ = glfw.GetWindowMonitor(window) != nil
    return true
}