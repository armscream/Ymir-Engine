package game

import ye "../Engine"
import "core:fmt"
import "core:log"
import "core:mem"

startup_mode := ye.Engine_Startup.debug
game_config_path := "Config/game.json"

run_game := bool(true)

main :: proc() {
	// Initialize the Ymir Engine //
	switch startup_mode {
	case ye.Engine_Startup.debug:
		{
			fmt.println("Starting in debug mode")
			context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
			defer log.destroy_console_logger(context.logger)

			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, context.allocator)
			context.allocator = mem.tracking_allocator(&track)

			defer {
				if len(track.allocation_map) > 0 {
					log.errorf("=== %v allocations not freed: ===", len(track.allocation_map))
					for _, entry in track.allocation_map {
						log.debugf("%v bytes @ %v", entry.size, entry.location)
					}
				}
				if len(track.bad_free_array) > 0 {
					log.errorf("=== %v incorrect frees: ===", len(track.bad_free_array))
					for entry in track.bad_free_array {
						log.debugf("%p @ %v", entry.memory, entry.location)
					}
				}
				mem.tracking_allocator_destroy(&track) // End memory tracking
			}
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
	case ye.Engine_Startup.editor:
		{
			fmt.println("Starting in editor mode")
			context.logger = log.create_console_logger(opt = {.Level, .Terminal_Color})
			defer log.destroy_console_logger(context.logger)

			track: mem.Tracking_Allocator
			mem.tracking_allocator_init(&track, context.allocator)
			context.allocator = mem.tracking_allocator(&track)

			defer {
				if len(track.allocation_map) > 0 {
					log.errorf("=== %v allocations not freed: ===", len(track.allocation_map))
					for _, entry in track.allocation_map {
						log.debugf("%v bytes @ %v", entry.size, entry.location)
					}
				}
				if len(track.bad_free_array) > 0 {
					log.errorf("=== %v incorrect frees: ===", len(track.bad_free_array))
					for entry in track.bad_free_array {
						log.debugf("%p @ %v", entry.memory, entry.location)
					}
				}
				mem.tracking_allocator_destroy(&track) // End memory tracking
			}
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
            /*for run_editor {
                if ye.should_quit(&runtime) {
                    run_editor = false
                    break
                }
                run_editor() // Calling editor loop in editor.odin and destroying based off backend
                ye.draw_frame(&runtime)
            }*/
		}
	case ye.Engine_Startup.game:
		{
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
}
