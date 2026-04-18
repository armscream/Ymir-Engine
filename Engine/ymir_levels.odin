package ye

import "core:encoding/json"
import "core:fmt"
import "core:os"


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