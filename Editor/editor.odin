package editor

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import ye "../Engine"
import "vendor:glfw"
import "vendor:imgui"

RUNANIMATIONGRAPHEDITOR: bool = false
RUNMATERIALGRAPHEDITOR: bool = false
RUNLEVELEDITOR: bool = false

window: glfw.WindowHandle

Window_Settings :: struct {
	window_x:      i32,
	window_y:      i32,
	window_width:  i32,
	window_height: i32,
	fullscreen:    bool,
}

Editor_Settings :: struct {
	window:       Window_Settings,
	animgraph:    Window_Settings,
	materialgraph: Window_Settings,
	level:        Window_Settings,
}

Editor_Config_File :: struct {
	editor_name: string,
	settings:    Editor_Settings,
}


main :: proc() {
	    // Memory tracking
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    context.allocator = mem.tracking_allocator(&track)

    defer {
        for _, entry in track.allocation_map {
            fmt.eprintf("%v leaked %v bytes\n", entry.location, entry.size)
        }
        for entry in track.bad_free_array {
            fmt.eprintf("%v bad free\n", entry.location)
        }
        mem.tracking_allocator_destroy(&track)
    }
    // End memory tracking


	startup_mode := ye.Engine_Startup.editor
	_ = startup_mode
	run_game := false

	config_path := resolve_editor_config_path()

	cfg, ok := load_editor_config(config_path)
	if !ok {
		return
	}
	defer free_editor_config(&cfg)

	if !create_window(cfg.editor_name, cfg.settings.window) {
		return
	}

    // Create game instance if running game from editor, otherwise just run editor windows.
	if run_game {
	    rungame()
	}
    

	for glfw.WindowShouldClose(window) == glfw.FALSE {
		if RUNANIMATIONGRAPHEDITOR {
			run_animationgraph_editor()
		}
		if RUNMATERIALGRAPHEDITOR {
			run_materialgraph_editor()
		}
		if RUNLEVELEDITOR {
			run_level_editor()
		}

		glfw.PollEvents()
	}

	capture_main_window_settings(&cfg.settings.window)
	_ = save_editor_config(config_path, cfg)
	destroy_window()
}

@(private) default_window_settings :: proc(fullscreen: bool) -> Window_Settings {
	return Window_Settings{
		window_x = -1,
		window_y = -1,
		window_width = 1280,
		window_height = 720,
		fullscreen = fullscreen,
	}
}

@(private) default_editor_settings :: proc() -> Editor_Settings {
	return Editor_Settings{
		window = default_window_settings(true),
		animgraph = default_window_settings(false),
		materialgraph = default_window_settings(false),
		level = default_window_settings(false),
	}
}

@(private) default_editor_config :: proc() -> Editor_Config_File {
	return Editor_Config_File{
		editor_name = "Ymir Editor",
		settings = default_editor_settings(),
	}
}

@(private) ensure_editor_name :: proc(cfg: ^Editor_Config_File) -> bool {
	if cfg.editor_name != "" {
		return true
	}

	name, err := strings.clone("Ymir Editor", context.allocator)
	if err != nil {
		fmt.eprintln("Failed to allocate default editor name")
		return false
	}
	cfg.editor_name = name
	return true
}

@(private) free_editor_config :: proc(cfg: ^Editor_Config_File) {
	if cfg.editor_name != "" {
		delete(cfg.editor_name)
		cfg.editor_name = ""
	}
}

@(private) normalize_window_settings :: proc(w: ^Window_Settings, fullscreen_default: bool) {
	if w.window_width <= 0 {
		w.window_width = 1280
	}
	if w.window_height <= 0 {
		w.window_height = 720
	}
	if w.window_x == 0 && w.window_y == 0 && w.window_width == 1280 && w.window_height == 720 && !w.fullscreen && fullscreen_default {
		// Likely zero-value from missing JSON section; first run should default fullscreen.
		w.fullscreen = true
		w.window_x = -1
		w.window_y = -1
	}
}

@(private) normalize_editor_settings :: proc(s: ^Editor_Settings) {
	normalize_window_settings(&s.window, true)
	normalize_window_settings(&s.animgraph, false)
	normalize_window_settings(&s.materialgraph, false)
	normalize_window_settings(&s.level, false)
}

@(private) resolve_editor_config_path :: proc() -> string {
	if os.exists("Editor") {
		return "Editor/editor.json"
	}
	return "editor.json"
}

@(private) load_editor_config :: proc(path: string) -> (cfg: Editor_Config_File, ok: bool) {
	cfg = default_editor_config()

	if !os.exists(path) {
		if !ensure_editor_name(&cfg) {
			return Editor_Config_File{}, false
		}
		_ = save_editor_config(path, cfg)
		return cfg, true
	}

	raw, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil {
		fmt.eprintln("Failed to read editor config:", read_err)
		return Editor_Config_File{}, false
	}
	defer delete(raw)

	if unmarshal_err := json.unmarshal(raw, &cfg); unmarshal_err != nil {
		fmt.eprintln("Failed to parse editor config:", unmarshal_err)
		free_editor_config(&cfg)
		return Editor_Config_File{}, false
	}

	if !ensure_editor_name(&cfg) {
		free_editor_config(&cfg)
		return Editor_Config_File{}, false
	}
	normalize_editor_settings(&cfg.settings)
	return cfg, true
}

@(private) save_editor_config :: proc(path: string, cfg: Editor_Config_File) -> bool {
	out, err := json.marshal(cfg, allocator = context.temp_allocator)
	if err != nil {
		fmt.eprintln("Failed to serialize editor config:", err)
		return false
	}

	write_err := os.write_entire_file(
		path,
		out,
		os.Permissions_Read_All + {.Write_User},
		true,
	)
	if write_err != nil {
		fmt.eprintln("Failed to write editor config:", write_err)
		return false
	}
	return true
}

@(private) create_window :: proc(game_name: string, settings: Window_Settings) -> bool {
	if !glfw.Init() {
		fmt.eprintln("Failed to initialize GLFW")
		return false
	}

	title, alloc_err := strings.clone_to_cstring(game_name)
	if alloc_err != nil {
		fmt.eprintln("Failed to allocate GLFW window title")
		glfw.Terminate()
		return false
	}
	defer delete(title)

	glfw.DefaultWindowHints()

	width := settings.window_width
	height := settings.window_height

	monitor: glfw.MonitorHandle = nil
	if settings.fullscreen {
		monitor = glfw.GetPrimaryMonitor()
		if monitor != nil {
			mode := glfw.GetVideoMode(monitor)
			if mode != nil {
				width = i32(mode.width)
				height = i32(mode.height)
			}
		}
	}

	window = glfw.CreateWindow(width, height, title, monitor, nil)
	if window == nil {
		fmt.eprintln("Failed to create GLFW window")
		glfw.Terminate()
		return false
	}

	if monitor == nil {
		if settings.window_x >= 0 && settings.window_y >= 0 {
			glfw.SetWindowPos(window, settings.window_x, settings.window_y)
		}
	}

	glfw.ShowWindow(window)
	return true
}

@(private) capture_main_window_settings :: proc(dst: ^Window_Settings) {
	if window == nil {
		return
	}

	width, height := glfw.GetWindowSize(window)
	dst.window_width = i32(width)
	dst.window_height = i32(height)
	dst.fullscreen = glfw.GetWindowMonitor(window) != nil

	if !dst.fullscreen {
		x, y := glfw.GetWindowPos(window)
		dst.window_x = i32(x)
		dst.window_y = i32(y)
	}
}

@(private) destroy_window :: proc() {
	if window != nil {
		glfw.DestroyWindow(window)
		window = nil
	}
	glfw.Terminate()
}

@(private) rungame :: proc() {
    working_dir := "."

    if !os.exists("run_from_game_config.ps1") {
        if os.exists("../run_from_game_config.ps1") {
            working_dir = ".."
        } else {
            fmt.eprintln("Could not find run_from_game_config.ps1 from current or parent directory")
            return
        }
    }

	desc := os.Process_Desc{
		working_dir = working_dir,
		stdin = os.stdin,
		stdout = os.stdout,
		stderr = os.stderr,
		command = {
			"powershell.exe",
			"-NoProfile",
			"-ExecutionPolicy",
			"Bypass",
			"-File",
			"run_from_game_config.ps1",
		},
	}

	process, err := os.process_start(desc)
	if err != nil {
		fmt.eprintln("Failed to start game build/run PowerShell:", err)
		return
	}

	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		fmt.eprintln("Failed while waiting for game build/run PowerShell:", wait_err)
		return
	}
	if !state.success || state.exit_code != 0 {
		fmt.eprintln("Game build/run script exited with code:", state.exit_code)
	}
}


