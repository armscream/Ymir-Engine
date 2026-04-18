// Software renderer backend for Ymir Engine.
package soft

import "vendor:sdl3"

draw_frame :: proc(runtime: rawptr, screen_width: i32, screen_height: i32) {
	_ = runtime

	if renderer == nil {
		return
	}

	_ = sdl3.SetRenderDrawColor(renderer, 255, 64, 64, 255)
	_ = sdl3.RenderPoint(renderer, f32(screen_width) * 0.5, f32(screen_height) * 0.5)

	_ = sdl3.RenderPresent(renderer)
}