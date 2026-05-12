package ye

// Backends
import Bsdl3 "./Backend/SDL3"
import soft "./Backend/Software"
import vk "./Backend/Vulkan"
// Core
import "core:encoding/json"
import "core:fmt"
import "core:os"

// Current level schema placeholder.
Level_Data :: struct {
	name: string,
}

@(private)
free_level_data :: proc(level_data: ^Level_Data) {
	delete(level_data.name)
}

// Utility for adding level files and updating config in one call.
add_level :: proc(level_name: string, config_path := game_config_path) {
	level_path := fmt.aprintf("Levels/%s_lvl.json", level_name)
	level_path_in_levels := false
	defer if !level_path_in_levels do delete(level_path)

	config_data, read_err := os.read_entire_file(config_path, context.allocator)
	if read_err != nil {
		fmt.eprintln("add_level: failed to read", config_path, read_err)
		return
	}
	defer delete(config_data)

	config: Game_Config
	if unmarshal_err := json.unmarshal(config_data, &config); unmarshal_err != nil {
		fmt.eprintln("add_level: failed to parse", config_path, unmarshal_err)
		return
	}
	defer free_game_config(&config)

	for p in config.levels {
		if p == level_path do return
	}

	old_levels := config.levels
	new_levels := make([]string, len(old_levels) + 1)
	copy(new_levels, old_levels)
	new_levels[len(old_levels)] = level_path
	config.levels = new_levels
	delete(old_levels)
	level_path_in_levels = true

	if !os.exists(level_path) {
		empty := Level_Data{name = level_name}
		if data, err := json.marshal(empty, allocator = context.temp_allocator); err == nil {
			_ = os.write_entire_file(level_path, data)
		}
	}

	if out, err := json.marshal(config, allocator = context.temp_allocator); err == nil {
		_ = os.write_entire_file(config_path, out)
	}
}

save_level_to_json :: proc(
	runtime: ^Runtime_State,
	file_path: string,
	sync_renderer := true,
) -> (ok: bool) {
	ensure(runtime != nil, "Invalid runtime")
	backend_saved_scene := false

	if sync_renderer {
		switch runtime.config.renderer_backend {
		case "Vulkan":
			if !vk.save_level_to_json(file_path) {
				fmt.eprintln("Vulkan backend failed to save level scene graph:", file_path)
				return false
			}
			backend_saved_scene = true
		case "SDL3", "Software", "undefined":
			fmt.println("No scene graph save integration for backend: ", runtime.config.renderer_backend)
		}
	}

	if backend_saved_scene {
		return true
	}

	json_opt := json.Marshal_Options {
		pretty     = true,
		use_spaces = true,
		spaces     = 2,
	}

	if level_out, err := json.marshal(runtime.level_data, json_opt, context.temp_allocator);
	   err == nil {
		if write_err := os.write_entire_file(
			file_path,
			level_out,
			os.Permissions_Read_All + {.Write_User},
			true,
		); write_err != nil {
			fmt.eprintln("Failed to write level:", write_err)
			return false
		}
		return true
	}

	fmt.eprintln("Failed to serialize level json")
	return false
}

load_level_from_json :: proc(
	runtime: ^Runtime_State,
	file_path: string,
	sync_renderer := true,
) -> (ok: bool) {
	ensure(runtime != nil, "Invalid runtime")

	level_json, level_read_err := os.read_entire_file(file_path, context.temp_allocator)
	if level_read_err != nil {
		fmt.eprintln("Failed to read level:", level_read_err)
		return false
	}

	free_level_data(&runtime.level_data)
	if level_unmarshal_err := json.unmarshal(level_json, &runtime.level_data);
	   level_unmarshal_err != nil {
		fmt.eprintln("Failed to parse level:", level_unmarshal_err)
		return false
	}

	if !sync_renderer {
		return true
	}

	switch runtime.config.renderer_backend {
	case "Vulkan":
		if !vk.load_level_from_json(file_path) {
			fmt.eprintln("Vulkan backend failed to load level scene graph:", file_path)
			return false
		}
	case "SDL3", "Software", "undefined":
		// No scene graph backend integration for these paths yet.
	}

	return true
}
