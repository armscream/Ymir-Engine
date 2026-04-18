package game

import ye "../Engine"
import "core:fmt"
import "core:mem"

startup_mode:= ye.Engine_Startup.game
game_config_path := "Config/game.json"

run_game := bool(true)

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

    // Boot the engine runtime and ensure it shuts down properly.
    // This loads config, level data, ECS DB files, and initializes YMIR_ECS handles.
    runtime, ok := ye.boot_runtime(game_config_path)
    if !ok {
        return
    }
    // Always run full shutdown sequence (save + cleanup), even on early returns.
    defer ye.shutdown_runtime(&runtime)

    // Initialize the game with the specified renderer backend
    ye.init_engine(runtime.config)
    switch startup_mode {
    case ye.Engine_Startup.editor:
        fmt.println("Starting in editor mode")
        // Editor-specific initialization code goes here
    case ye.Engine_Startup.game:
        fmt.println("Starting in game mode")


        // Main gameplay loop entrypoint.
            for run_game {
            if ye.should_quit(&runtime) {
                run_game = false
                break
            }
            run() // Calling game loop in game.odin and destroying based off backend
            ye.draw_frame(&runtime)

        }
    }
}
