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
// from the vendored Dear ImGui sources via scripts/build_imgui.ps1.

package asset_converter

import "core:log"
import sdl "vendor:sdl3"

import imgui "../../dependencies/imgui"
import sdl3_imgui "../../dependencies/imgui/backends/sdl3"

// ============================================================================
// Window context
// ============================================================================

UI_State :: struct {
	window:      ^sdl.Window,
	gl_ctx:      sdl.GLContext,
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
	if !sdl.Init({.VIDEO}) {
		log.errorf("SDL_Init failed: %s", sdl.GetError())
		return .SDL_Init
	}
	// SetAppMetadata returns a bool (require_results); the result is
	// informational. We log warnings but don't bail.
	if !sdl.SetAppMetadata("Bifrost Asset Converter", "0.1", "com.bifrost.asset_converter") {
		log.warnf("SetAppMetadata returned false: %s", sdl.GetError())
	}

	// OpenGL 3.3 core profile.
	sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(sdl.GL_CONTEXT_PROFILE_CORE))
	sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)

	// Create window via the properties API.
	props := sdl.CreateProperties()
	sdl.SetStringProperty(props, "title", title)
	sdl.SetNumberProperty(props, "width",  i64(w))
	sdl.SetNumberProperty(props, "height", i64(h))
	if !sdl.SetBooleanProperty(props, "resizable", true) do log.warn("SetBooleanProperty(resizable) returned false")
	if !sdl.SetBooleanProperty(props, "opengl",    true) do log.warn("SetBooleanProperty(opengl) returned false")

	state.window = sdl.CreateWindowWithProperties(props)
	if state.window == nil {
		log.errorf("CreateWindowWithProperties failed: %s", sdl.GetError())
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

	if !sdl.GL_MakeCurrent(state.window, state.gl_ctx) {
		log.warnf("GL_MakeCurrent returned false: %s", sdl.GetError())
	}
	sdl.GL_SetSwapInterval(1)

	imgui.CHECKVERSION()
	imgui.CreateContext(nil)
	io := imgui.GetIO()
	io.ConfigFlags += {.DockingEnable, .NavEnableKeyboard}

	_ = imgui.GetStyle()

	sdl3_imgui.InitForOpenGL(state.window, state.gl_ctx)
	return .None
}

ui_shutdown :: proc(state: ^UI_State) {
	sdl3_imgui.Shutdown()
	imgui.DestroyContext(nil)
	if state.gl_ctx != nil do sdl.GL_DestroyContext(state.gl_ctx)
	if state.window  != nil do sdl.DestroyWindow(state.window)
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
			if e.key.key == sdl.Keycode(sdl.K_ESCAPE) do return true
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
