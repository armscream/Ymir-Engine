// Software renderer backend for Ymir Engine.
package soft

import "vendor:sdl3"
import "core:fmt"

draw_frame :: proc(runtime: rawptr, screen_width: i32, screen_height: i32) {
	_ = runtime

    // Check if window and renderer are initialized before drawing, dont draw if window minimized.
	if window == nil || renderer == nil {
        fmt.println("Software renderer window or renderer not initialized")
		return
	}
    flags := sdl3.GetWindowFlags(window)
    if .MINIMIZED in flags {
        // Skip rendering while minimized
        return
    }
    //          -----------------------------------------------

    // Clear the screen with a solid color and create a pixel. This is all i am doing with SDL as the rest is software
	_ = sdl3.SetRenderDrawColor(renderer, 255, 64, 64, 255)
	_ = sdl3.RenderPoint(renderer, f32(screen_width) * 0.5, f32(screen_height) * 0.5)

	_ = sdl3.RenderPresent(renderer)
    //          -----------------------------------------------        
}