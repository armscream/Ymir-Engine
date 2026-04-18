package soft

import "core:c"
import "core:strings"
import "vendor:sdl3"

window: ^sdl3.Window
renderer: ^sdl3.Renderer

init_window :: proc(window_name: string, x: i32, y: i32, width: i32, height: i32) -> ^sdl3.Window {
    if !sdl3.Init(sdl3.INIT_VIDEO) {
        return nil
    }

    window_name_c, _ := strings.clone_to_cstring(window_name)
    if window_name_c == nil {
        return nil
    }
    defer delete(window_name_c)

    window = sdl3.CreateWindow(window_name_c, width, height, sdl3.WindowFlags{.RESIZABLE})
    if window == nil {
        return nil
    }

    renderer = sdl3.CreateRenderer(window, nil)
    if renderer == nil {
        sdl3.DestroyWindow(window)
        window = nil
        sdl3.Quit()
        return nil
    }

    pos_x := c.int(x)
    pos_y := c.int(y)
    if x < 0 {
        pos_x = sdl3.WINDOWPOS_CENTERED
    }
    if y < 0 {
        pos_y = sdl3.WINDOWPOS_CENTERED
    }

    _ = sdl3.SetWindowPosition(window, pos_x, pos_y)
    return window
}

@(private) is_escape_binding :: proc(escape_key: i32) -> bool {
    category := (escape_key >> 16) & 0xFFFF
    value := escape_key & 0xFFFF

    // Engine keycode only: Keyboard category and Escape value.
    return category == 1 && value == 1
}

poll_should_quit :: proc(escape_key: i32) -> bool {
    event: sdl3.Event
    for sdl3.PollEvent(&event) {
        #partial switch event.type {
        case .QUIT, .WINDOW_DESTROYED:
            return true
        case .KEY_DOWN:
            if is_escape_binding(escape_key) && event.key.key == sdl3.K_ESCAPE {
                return true
            }
        }
    }

    return false
}

get_window_state :: proc(x, y, width, height: ^i32, fullscreen: ^bool) -> bool {
    if window == nil {
        return false
    }

    pos_x, pos_y: c.int
    w, h: c.int
    if !sdl3.GetWindowPosition(window, &pos_x, &pos_y) {
        return false
    }
    if !sdl3.GetWindowSize(window, &w, &h) {
        return false
    }

    if x != nil {
        x^ = i32(pos_x)
    }
    if y != nil {
        y^ = i32(pos_y)
    }
    if width != nil {
        width^ = i32(w)
    }
    if height != nil {
        height^ = i32(h)
    }
    if fullscreen != nil {
        // SDL3 returns a display mode pointer when fullscreen is active.
        fullscreen^ = sdl3.GetWindowFullscreenMode(window) != nil
    }

    return true
}

shutdown_window :: proc() {
    if renderer != nil {
        sdl3.DestroyRenderer(renderer)
        renderer = nil
    }

    if window != nil {
        sdl3.DestroyWindow(window)
        window = nil
    }
    sdl3.Quit()
}

