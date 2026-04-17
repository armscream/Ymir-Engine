package game

import ye "../Engine"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:os"

Game_Config :: struct {
    renderer_backend: string,
    game_name:        string,
    window_width:     i32,
    window_height:    i32,
    fullscreen:       bool,
    current_level:    string,
    levels:           []string,
}

Level_Data :: struct {
    name: string,
    // Add more level-specific data here
}

level_name_from_path :: proc(level_path: string) -> string {
    name := level_path

    // Strip directory prefix
    for i := len(name) - 1; i >= 0; i -= 1 {
        if name[i] == '/' || name[i] == '\\' {
            name = name[i+1:]
            break
        }
    }

    // Strip expected suffix
    suffix := "_lvl.json"
    if len(name) >= len(suffix) && name[len(name)-len(suffix):] == suffix {
        name = name[:len(name)-len(suffix)]
    }

    return name
}

// Appends a new level entry to the "levels" array in game.json and creates the level file.
// level_name should be a plain name, e.g. "forest" -> "Levels/forest_lvl.json"
add_level :: proc(level_name: string, config_path := "Config/game.json") {

    level_path := fmt.aprintf("Levels/%s_lvl.json", level_name, allocator = context.allocator)
    level_path_in_levels := false
    defer if !level_path_in_levels do delete(level_path)

    // Load existing config
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
    defer {
        for p in config.levels do delete(p)
        delete(config.levels)
        delete(config.renderer_backend)
        delete(config.game_name)
        delete(config.current_level)
    }

    // Check if already present
    for p in config.levels {
        if p == level_path do return
    }

    // Append the new path
    old_levels := config.levels
    new_levels := make([]string, len(old_levels) + 1)
    copy(new_levels, old_levels)
    new_levels[len(old_levels)] = level_path
    config.levels = new_levels
    delete(old_levels)
    level_path_in_levels = true

    // Create the level file if it doesn't exist
    if !os.exists(level_path) {
        empty := Level_Data{name = level_name}
        if data, err := json.marshal(empty, allocator = context.temp_allocator); err == nil {
            _ = os.write_entire_file(level_path, data)
        }
    }

    // Write updated config back
    if out, err := json.marshal(config, allocator = context.temp_allocator); err == nil {
        _ = os.write_entire_file(config_path, out)
    }
}

main :: proc () {
    // Initialize the Ymir Engine //
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

    // Load game configuration
    config_data, read_err := os.read_entire_file("Config/game.json", context.allocator)
    if read_err != nil {
        fmt.eprintln("Failed to read game config:", read_err)
        return
    }
    defer delete(config_data)
    config: Game_Config
    unmarshal_err := json.unmarshal(config_data, &config)
    if unmarshal_err != nil {
        fmt.eprintln("Failed to parse game config:", unmarshal_err)
        return
    }
    defer delete(config.renderer_backend)
    defer delete(config.game_name)
    defer {
        for path in config.levels do delete(path)
        delete(config.levels)
    }
    defer delete(config.current_level)

    // Create level files that do not yet exist
    for level_path in config.levels {
        if !os.exists(level_path) {
            empty_level := Level_Data{name = level_name_from_path(level_path)}
            if data, err := json.marshal(empty_level, allocator = context.temp_allocator); err == nil {
                _ = os.write_entire_file(level_path, data)
            }
        }
    }

    renderer_backend := config.renderer_backend
    game_name := config.game_name
    window_width := config.window_width
    window_height := config.window_height
    fullscreen := config.fullscreen
    current_level := config.current_level

    // Load level data
    level_data, level_read_err := os.read_entire_file(current_level, context.temp_allocator)
    if level_read_err != nil {
        fmt.eprintln("Failed to read level:", level_read_err)
        return
    }

    // Initialize the game with the specified renderer backend
    ye.init_engine(renderer_backend, game_name)
    ////////////////////////////////////////////////////////

    // Game loop procedure call
    run()

    ////////////////////////////////////////////////////////
    // Cleanup and shutdown code goes here
    if config_data, err := json.marshal(config, allocator = context.temp_allocator); err == nil {
        _ = os.write_entire_file("Config/game.json", config_data)
    }
    if level_data, err := json.marshal(level_data, allocator = context.temp_allocator); err == nil {
        _ = os.write_entire_file(current_level, level_data)
    }
    
}

