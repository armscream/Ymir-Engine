package ye

// Backends
import sdl3 "./Backend/SDL3"
import soft "./Backend/Software"
import vk "./Backend/Vulkan"
import glog "./glogger"
// Core
import "core:encoding/json"
import "core:fmt"
import "core:os"
// Vendor
import "vendor:vulkan" 

game_config_path :: "Config/game.json"

renderer_backends :: enum {
	undefined,
	SDL3,
	Vulkan,
	Software,
}

// Controls whether app main launches gameplay or editor path.
Engine_Startup :: enum {
	game,
	editor,
}

// Main game config loaded at boot.
// TODO: split renderer/window settings from gameplay config as project grows.
Game_Config :: struct {
	renderer_backend: string,
	editor_backend:   string,
	game_name:        string,
	window_x:         i32,
	window_y:         i32,
	window_width:     i32,
	window_height:    i32,
	fullscreen:       bool,
	keybinds_path:    string,
	current_level:    string,
	levels:           []string,
}

// Current level schema placeholder.
Level_Data :: struct {
	name: string,
}


@(private)
free_level_data :: proc(level_data: ^Level_Data) {
	delete(level_data.name)
}

// Runtime aggregate passed between boot and shutdown.
// Keeps everything the main loop needs in one object.
Runtime_State :: struct {
	config:           Game_Config,
	level_data:       Level_Data,
	keybinds:         Keybinds,
	keybinds_path:    string,
	game_config_path: string,
}

init_engine :: proc(config: Game_Config, debug: bool) -> (ok: bool) {
	switch config.renderer_backend {
	case "SDL3":
		_ = sdl3.init_window(
			config.game_name,
			config.window_x,
			config.window_y,
			config.window_width,
			config.window_height,
		)

	case "Vulkan":
		vk.init_window(
			config.game_name,
			config.window_x,
			config.window_y,
			config.window_width,
			config.window_height,
			debug,
		)

	case "Software":
		_ = soft.init_window(
			config.game_name,
			config.window_x,
			config.window_y,
			config.window_width,
			config.window_height,
		)

	case "undefined":
		fmt.println("Unknown renderer backend: ", config.renderer_backend)
	}
    glog.initialize()
    return true
}

should_quit :: proc(runtime: ^Runtime_State) -> bool {
	if runtime == nil {
		return false
	}

	switch runtime.config.renderer_backend {
	case "Software":
		return soft.poll_should_quit(i32(runtime.keybinds.escape))
    case "SDL3": 
        return sdl3.poll_should_quit(i32(runtime.keybinds.escape))
    case "Vulkan":
        return vk.poll_should_quit(i32(runtime.keybinds.escape))
    case "undefined":
        fmt.println("Unknown renderer backend: ", runtime.config.renderer_backend)
    }

	return false
}

// Release all dynamically allocated strings/slices from Game_Config.
// IMPORTANT: call this exactly once per config instance.
@(private)
free_game_config :: proc(config: ^Game_Config) {
	delete(config.renderer_backend)
	delete(config.editor_backend)
	delete(config.game_name)
	delete(config.keybinds_path)
	for path in config.levels do delete(path)
	delete(config.levels)
	delete(config.current_level)
}

// Full boot sequence used by app main.
// Steps:
// 1) load config
// 2) load level data
// 3) runtime ready
boot_runtime :: proc(config_path := game_config_path) -> (runtime: Runtime_State, ok: bool) {
	runtime.game_config_path = config_path

	config_data, read_err := os.read_entire_file(config_path, context.allocator)
	if read_err != nil {
		fmt.eprintln("Failed to read game config:", read_err)
		return Runtime_State{}, false
	}
	defer delete(config_data)

	if unmarshal_err := json.unmarshal(config_data, &runtime.config); unmarshal_err != nil {
		fmt.eprintln("Failed to parse game config:", unmarshal_err)
		return Runtime_State{}, false
	}

	if runtime.config.keybinds_path == "" {
		runtime.config.keybinds_path = default_keybinds_path
	}
	runtime.keybinds_path = runtime.config.keybinds_path
	runtime.keybinds, _ = load_keybinds(runtime.keybinds_path)

	level_json, level_read_err := os.read_entire_file(
		runtime.config.current_level,
		context.temp_allocator,
	)
	if level_read_err != nil {
		fmt.eprintln("Failed to read level:", level_read_err)
		free_game_config(&runtime.config)
		return Runtime_State{}, false
	}

	if level_unmarshal_err := json.unmarshal(level_json, &runtime.level_data);
	   level_unmarshal_err != nil {
		fmt.eprintln("Failed to parse level:", level_unmarshal_err)
		free_level_data(&runtime.level_data)
		free_game_config(&runtime.config)
		return Runtime_State{}, false
	}

	return runtime, true
}

// Full shutdown sequence used by app main.
// Steps:
// 1) write config + level
// 2) free all runtime allocations
shutdown_runtime :: proc(runtime: ^Runtime_State) {
	// Capture latest software window state so config persists user changes.
	switch runtime.config.renderer_backend {
	case "SDL3":
	// SDL3 cleanup code goes here
        x := runtime.config.window_x
		y := runtime.config.window_y
		width := runtime.config.window_width
		height := runtime.config.window_height
		fullscreen := runtime.config.fullscreen
		if sdl3.get_window_state(&x, &y, &width, &height, &fullscreen) {
			runtime.config.window_x = x
			runtime.config.window_y = y
			runtime.config.window_width = width
			runtime.config.window_height = height
			runtime.config.fullscreen = fullscreen
		}
	case "Vulkan":
	// Vulkan cleanup code goes here
        x := runtime.config.window_x
		y := runtime.config.window_y
		width := runtime.config.window_width
		height := runtime.config.window_height
		fullscreen := runtime.config.fullscreen
        if vk.get_window_state(&x, &y, &width, &height, &fullscreen) {
            runtime.config.window_x = x
            runtime.config.window_y = y
            runtime.config.window_width = width
            runtime.config.window_height = height
            runtime.config.fullscreen = fullscreen
        }
	case "Software":
    // Software cleanup code goes here
		x := runtime.config.window_x
		y := runtime.config.window_y
		width := runtime.config.window_width
		height := runtime.config.window_height
		fullscreen := runtime.config.fullscreen
		if soft.get_window_state(&x, &y, &width, &height, &fullscreen) {
			runtime.config.window_x = x
			runtime.config.window_y = y
			runtime.config.window_width = width
			runtime.config.window_height = height
			runtime.config.fullscreen = fullscreen
		}
	case "undefined":
		fmt.println("Unknown renderer backend: ", runtime.config.renderer_backend)
	}
    // Write config and level data back to disk on shutdown.
	if config_out, err := json.marshal(runtime.config, allocator = context.temp_allocator);
	   err == nil {
		_ = os.write_entire_file(
			runtime.game_config_path,
			config_out,
			os.Permissions_Read_All + {.Write_User},
			true,
		)
	}
	if level_out, err := json.marshal(runtime.level_data, allocator = context.temp_allocator);
	   err == nil {
		_ = os.write_entire_file(
			runtime.config.current_level,
			level_out,
			os.Permissions_Read_All + {.Write_User},
			true,
		)
	}

	_ = save_keybinds(runtime.keybinds_path, runtime.keybinds)

	switch runtime.config.renderer_backend {
	case "SDL3":
        sdl3.shutdown_window()
	case "Vulkan":
		// engine cleanup is done in the backend for vulkan
	case "Software":
		soft.shutdown_window()
	case "undefined":
		fmt.println("Unknown renderer backend: ", runtime.config.renderer_backend)
	}


	free_level_data(&runtime.level_data)
	free_game_config(&runtime.config)
}

draw_frame :: proc(runtime: ^Runtime_State) {
	switch runtime.config.renderer_backend {
	case "SDL3":
		sdl3.draw_frame(runtime, runtime.config.window_width, runtime.config.window_height)
	case "Vulkan":
		result := vk.engine_run(runtime)
	case "Software":
		soft.draw_frame(runtime, runtime.config.window_width, runtime.config.window_height)
	case "undefined":
		fmt.println("Unknown renderer backend: ", runtime.config.renderer_backend)
	}
}
