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