// Engine/src/Tools/asset_converter/ui.odin
//
// SDL3 + Dear ImGui windowing setup for the asset converter tool.
//
// Uses:
//   - vendor:sdl3               (window + event loop)
//   - Engine/src/dependencies/imgui              (imgui.odin)
//   - Engine/src/dependencies/imgui/backends/sdl3 (imgui_impl_sdl3)
//
// The ImGui static library (imgui_windows_x64.lib) is built once
// from the vendored Dear ImGui sources via the project README
// (`premake5 --backends=sdl3 vs2022` + `Build Solution`). The
// resulting .lib lives at Engine/src/dependencies/imgui/.

package asset_converter

import "core:fmt"
import "core:log"
import "core:os"
import sdl "vendor:sdl3"

import imgui "..\\..\\dependencies\\imgui"
import sdl3_imgui "..\\..\\dependencies\\imgui\\backends\\sdl3"

// ============================================================================
// Window context
// ============================================================================

UI_State :: struct {
	window:     ^sdl.Window,
	renderer:   ^sdl.Renderer,
	gl_ctx:     sdl.GLContext,
	should_quit: bool,
}

UI_Init_Error :: enum {
	None,
	SDL_Init,
	Window_Create,
	GL_Create,
	Renderer_Create,
	ImGui_Init,
}

ui_init :: proc(state: ^UI_State, title: cstring, w, h: i32) -> UI_Init_Error {
	// -- SDL --
	if !sdl.Init({.VIDEO}) {
		log.errorf("SDL_Init failed: %s", sdl.GetError())
		return .SDL_Init
	}

	sdl.SetAppMetadata("Bifrost Asset Converter", "0.1", "com.bifrost.asset_converter")

	sdl.gl_set_attribute(.CONTEXT_PROFILE_MASK, i32(sdl.GL_CONTEXT_PROFILE_CORE))
	sdl.gl_set_attribute(.CONTEXT_MAJOR_VERSION, 3)
	sdl.gl_set_attribute(.CONTEXT_MINOR_VERSION, 3)

	win_props: sdl.WindowProperties = {
		title = title,
		width = w,
		height = h,
		resizable = true,
		opengl = true,
	}
	state.window = sdl.CreateWindowWithProperties(win_props)
	if state.window == nil {
		log.errorf("SDL_CreateWindow failed: %s", sdl.GetError())
		sdl.Quit()
		return .Window_Create
	}

	state.gl_ctx = sdl.GL_CreateContext(state.window)
	if state.gl_ctx == nil {
		log.errorf("SDL_GL_CreateContext failed: %s", sdl.GetError())
		sdl.DestroyWindow(state.window)
		sdl.Quit()
		return .GL_Create
	}

	sdl.GL_MakeCurrent(state.window, state.gl_ctx)
	sdl.GL_SetSwapInterval(1) // vsync

	// -- ImGui --
	imgui.CHECKVERSION()
	imgui.CreateContext(nil)
	io := imgui.GetIO()
	io.ConfigFlags += {.DockingEnable, .NavEnableKeyboard}

	style := imgui.GetStyle()
	_ = style // default dark style for now

	sdl3_imgui.InitForOpenGL(state.window, state.gl_ctx)
	return .None
}

ui_shutdown :: proc(state: ^UI_State) {
	sdl3_imgui.Shutdown()
	imgui.DestroyContext(nil)
	if state.gl_ctx != nil do sdl.GL_DestroyContext(state.gl_ctx)
	if state.window != nil do sdl.DestroyWindow(state.window)
	sdl.Quit()
}

// process_events pumps SDL events. Returns true if the app should quit.
ui_pump_events :: proc(state: ^UI_State) -> bool {
	e: sdl.Event
	for sdl.PollEvent(&e) {
		#partial switch e.type {
		case .QUIT:
			return true
		case .WINDOW_CLOSE_REQUESTED:
			return true
		case .KEY_DOWN:
			if e.key.key == .ESCAPE do return true
		}
		sdl3_imgui.ProcessEvent(&e)
	}
	return state.should_quit
}

ui_begin_frame :: proc() {
	imgui.NewFrame()
}

ui_end_frame :: proc(state: ^UI_State) {
	imgui.Render()
	sdl.GL_SwapWindow(state.window)
}
